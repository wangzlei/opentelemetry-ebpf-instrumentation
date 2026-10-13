// Ping demo service -- Java port of examples/ping-demo/app/server.py (JDK only:
// com.sun.net.httpserver.HttpServer + java.net.http.HttpClient forced to HTTP/1.1).
//
// Same external behaviour as the Python app: $ROLE picks the served route and the downstreams,
// $PROFILE shapes this service's own status mix + latency, POST /fault flips the profile at runtime,
// and on the OK path the service calls its downstreams first and ADOPTS a dependency's failure
// (worstStatus). CPU_SHARE spends that share of each response's target duration on real CPU work,
// bounded by this thread's CPU time (spendCpu). Downstream DNS names are expanded to every A record
// and one is picked per call, with the logical Host header kept.
//
// Deployed as the inventory service, packaged as /app/inventory-<version>.jar, so the agent's
// autoname derives "inventory" from `java -jar` without OTEL_SERVICE_NAME.

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpsConfigurator;
import com.sun.net.httpserver.HttpsServer;

import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.lang.management.ManagementFactory;
import java.lang.management.ThreadMXBean;
import java.net.DatagramSocket;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.URI;
import java.net.URLDecoder;
import java.net.UnknownHostException;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.security.cert.X509Certificate;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.TreeSet;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadLocalRandom;
import javax.crypto.SecretKeyFactory;
import javax.crypto.spec.PBEKeySpec;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLEngine;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509ExtendedTrustManager;

public class Main {
    // status, weight, mean_s, min_s, max_s -- identical to server.py PROFILES
    record Row(int status, double weight, double mean, double lo, double hi) {}

    static final Map<String, List<Row>> PROFILES = new LinkedHashMap<>(); // keeps list(PROFILES) order
    static {
        PROFILES.put("healthy", List.of(new Row(200, 1000, 0.05, 0.005, 0.40)));
        // Permanent small failure rate: 2% fault + 1% error, healthy latency otherwise.
        PROFILES.put("flaky", List.of(
            new Row(200, 970, 0.05, 0.005, 0.40),
            new Row(500, 20, 0.03, 0.002, 0.30),
            new Row(429, 10, 0.01, 0.001, 0.10)));
        PROFILES.put("degraded", List.of(new Row(200, 1000, 0.30, 0.05, 2.00)));
        PROFILES.put("erroring", List.of(
            new Row(200, 500, 0.06, 0.005, 0.50),
            new Row(404, 120, 0.01, 0.001, 0.08),
            new Row(500, 250, 0.03, 0.002, 0.30),
            new Row(429, 130, 0.01, 0.001, 0.10)));
        PROFILES.put("faulty", List.of(
            new Row(200, 200, 0.08, 0.005, 0.60),
            new Row(503, 500, 0.05, 0.002, 1.50),
            new Row(500, 300, 0.04, 0.002, 0.90)));
    }

    static final Map<String, String> ROUTES = Map.of(
        "checkout", "/checkout",
        "payment", "/charges",
        "inventory", "/reservations",
        "audit", "/audit");

    static final String ROLE = env("ROLE", "checkout");
    static final int PORT = Integer.parseInt(env("PORT", "8000"));
    static final boolean USE_TLS = env("USE_TLS", "0").equals("1");
    static final double CPU_SHARE = resolveShare(env("CPU_SHARE", "0"));
    static final List<String> PAYMENT_URLS = split(System.getenv("PAYMENT_URLS"));
    static final List<String> INVENTORY_URLS = split(System.getenv("INVENTORY_URLS"));
    static final List<String> AUDIT_URLS = split(System.getenv("AUDIT_URLS"));
    static final boolean PREFER_SAME_AZ = env("PREFER_SAME_AZ", "0").equals("1");
    static final boolean DEBUG = "1".equals(System.getenv("DEBUG"));
    // optional external stock check (API Gateway -> Lambda), POSTed on the OK path of /reservations
    static final String STOCK_URL = System.getenv().getOrDefault("STOCK_URL", "");
    static final long PID = ProcessHandle.current().pid();

    // Read per request so POST /fault flips it at runtime (instance-wide: one process).
    static volatile String profile = env("PROFILE", "healthy");

    static HttpClient client;

    static String env(String k, String def) {
        String v = System.getenv(k);
        return v == null ? def : v;
    }

    static List<String> split(String s) {
        List<String> out = new ArrayList<>();
        if (s == null) return out;
        for (String u : s.split(",", -1)) if (!u.isEmpty()) out.add(u);
        return out;
    }

    // ---- cpuwork.py ----------------------------------------------------------------------------
    static final int CHUNK_ITERATIONS = 512;
    static final double DEFAULT_WALL_CAP_SECONDS = 3.0;
    static final char[] PASSWORD = "obi-ping-demo-cpu-work".toCharArray();
    static final byte[] SALT = "obi-ping-demo-salt".getBytes(StandardCharsets.UTF_8);
    static final ThreadMXBean THREADS = ManagementFactory.getThreadMXBean();
    static final ThreadLocal<SecretKeyFactory> PBKDF2 = ThreadLocal.withInitial(() -> {
        try { return SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256"); }
        catch (Exception e) { throw new IllegalStateException(e); }
    });

    record CpuSpend(double cpuSeconds, double wallSeconds, boolean capped) {}

    static void burnChunk() {
        try { PBKDF2.get().generateSecret(new PBEKeySpec(PASSWORD, SALT, CHUNK_ITERATIONS, 256)).getEncoded(); }
        catch (Exception e) { throw new IllegalStateException(e); }
    }

    /** Occupy a core until this thread has consumed budget seconds of CPU (or the wall cap). */
    static CpuSpend spendCpu(double budget, double wallCap) {
        if (budget <= 0) return new CpuSpend(0, 0, false);
        long cpuStart = THREADS.getCurrentThreadCpuTime();
        long wallStart = System.nanoTime();
        while (true) {
            double cpu = (THREADS.getCurrentThreadCpuTime() - cpuStart) / 1e9;
            double wall = (System.nanoTime() - wallStart) / 1e9;
            if (cpu >= budget) return new CpuSpend(cpu, wall, false);
            if (wall >= wallCap) return new CpuSpend(cpu, wall, true);
            burnChunk();
        }
    }

    /** Coerce an operator-supplied share to [0,1]; unparseable or non-finite -> 0. */
    static double resolveShare(String s) {
        double v;
        try { v = Double.parseDouble(s.trim()); } catch (Exception e) { return 0.0; }
        if (!Double.isFinite(v)) return 0.0;
        return Math.min(1.0, Math.max(0.0, v));
    }

    static void logCompute(CpuSpend s) {
        double slowdown = s.cpuSeconds() > 0 ? s.wallSeconds() / s.cpuSeconds() : 0.0;
        System.out.println(String.format(Locale.ROOT,
            "cpuwork role=%s share=%.3f cpu=%.4fs wall=%.4fs slowdown=%.2f capped=%s",
            ROLE, CPU_SHARE, s.cpuSeconds(), s.wallSeconds(), slowdown, s.capped() ? "True" : "False"));
    }

    // ---- propagate.py --------------------------------------------------------------------------
    /** 0 = no dependency failed (Python None); entries of 0 are "no call / no response". */
    static int worstStatus(int... statuses) {
        int failures = 0, throttles = 0;
        for (int s : statuses) if (s >= 400) { failures++; if (s == 429) throttles++; }
        if (failures == 0) return 0;
        return failures == throttles ? 429 : 500;
    }

    // ---- server.py -----------------------------------------------------------------------------
    // Python random.triangular(low, high, mode)
    static double triangular(double low, double high, double mode) {
        double u = ThreadLocalRandom.current().nextDouble();
        if (high == low) return low;
        double c = (mode - low) / (high - low);
        if (u > c) {
            u = 1.0 - u;
            c = 1.0 - c;
            double t = low; low = high; high = t;
        }
        return low + (high - low) * Math.sqrt(u * c);
    }

    /** Returns {status, latency_s}; null when the profile is unknown (Python: KeyError -> 500). */
    static double[] pickResponse() {
        List<Row> rows = PROFILES.get(profile);
        if (rows == null) return null;
        double total = 0;
        for (Row r : rows) total += r.weight();
        double x = ThreadLocalRandom.current().nextDouble() * total, acc = 0;
        Row sel = rows.get(rows.size() - 1);
        for (Row r : rows) {
            acc += r.weight();
            if (x < acc) { sel = r; break; }
        }
        double lat = Math.min(sel.hi(), Math.max(sel.lo(), triangular(sel.lo(), sel.hi(), sel.mean())));
        return new double[] {sel.status(), lat};
    }

    record Target(String url, String ip, String hostHdr) {}

    /** One target per resolved IPv4 A record (sorted); Host header keeps the logical host:port. */
    static List<Target> targets(String raw) {
        URI u = URI.create(raw);
        String host = u.getHost();
        int port = u.getPort() == -1 ? 8000 : u.getPort();
        TreeSet<String> ips = new TreeSet<>();
        try {
            for (InetAddress a : InetAddress.getAllByName(host))
                if (a instanceof Inet4Address) ips.add(a.getHostAddress());
        } catch (UnknownHostException e) {
            // fall through: use the name as-is
        }
        if (ips.isEmpty()) ips.add(host);
        String path = u.getRawPath() == null ? "" : u.getRawPath();
        String hostHdr = host + ":" + port;
        List<Target> out = new ArrayList<>();
        for (String ip : ips) out.add(new Target(u.getScheme() + "://" + ip + ":" + port + path, ip, hostHdr));
        return out;
    }

    /** Primary private IP via the UDP-connect trick (no packet sent). */
    static String localIp() {
        try (DatagramSocket s = new DatagramSocket()) {
            s.connect(InetAddress.getByName("10.255.255.255"), 1);
            InetAddress a = s.getLocalAddress();
            return a == null || a.isAnyLocalAddress() ? null : a.getHostAddress();
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * POST {} to one downstream instance and return its status. A transport error moves on to the
     * next instance; 0 (Python None) when there was nothing to call or every target failed. No retry
     * on a status: another instance would answer from the same profile.
     */
    static int call(List<String> baseUrls, String path) {
        if (baseUrls.isEmpty()) return 0;
        List<Target> ts = new ArrayList<>();
        for (String b : baseUrls) ts.addAll(targets(b.replaceAll("/+$", "") + path));
        if (PREFER_SAME_AZ) {
            String lip = localIp();
            if (lip != null) {
                String prefix = lip.substring(0, lip.lastIndexOf('.') + 1); // /24
                List<Target> same = new ArrayList<>();
                for (Target t : ts) if (t.ip().startsWith(prefix)) same.add(t);
                if (!same.isEmpty()) ts = same;
            }
        }
        Collections.shuffle(ts, ThreadLocalRandom.current());
        for (Target t : ts) {
            try {
                HttpRequest req = HttpRequest.newBuilder(URI.create(t.url()))
                    .timeout(Duration.ofSeconds(5))
                    .header("Host", t.hostHdr())
                    .header("Content-Type", "application/json")
                    .POST(HttpRequest.BodyPublishers.ofString("{}"))
                    .build();
                return client.send(req, HttpResponse.BodyHandlers.discarding()).statusCode();
            } catch (IOException e) {
                if (DEBUG) System.err.println("call " + t.url() + " failed: " + e);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return 0;
            }
        }
        return 0;
    }

    /** POST a small stock check to an external HTTPS endpoint by its URL (no IP fan-out: TLS needs the
     *  name). Its result is not adopted: a failing stock check does not fail the reservation. */
    static void callUrl(String url) {
        try {
            HttpRequest req = HttpRequest.newBuilder(URI.create(url))
                .timeout(Duration.ofSeconds(5))
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString("{\"sku\":\"sku-" + ThreadLocalRandom.current().nextInt(100) + "\"}"))
                .build();
            client.send(req, HttpResponse.BodyHandlers.discarding());
        } catch (IOException e) {
            if (DEBUG) System.err.println("call " + url + " failed: " + e);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    /** Call this role's downstreams (sequentially) and return the status to adopt, or 0. */
    static int fanOut() {
        return switch (ROLE) {
            case "checkout" -> worstStatus(call(PAYMENT_URLS, "/charges"), call(INVENTORY_URLS, "/reservations"));
            case "payment" -> worstStatus(call(AUDIT_URLS, "/audit"));
            case "inventory" -> { if (!STOCK_URL.isEmpty()) callUrl(STOCK_URL); yield 0; }
            default -> 0; // audit: leaf
        };
    }

    // Minimal JSON helpers; keys are written sorted, like Flask's jsonify.
    static String q(String s) {
        return "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\"";
    }

    static void send(HttpExchange ex, int status, String json) throws IOException {
        byte[] b = (json + "\n").getBytes(StandardCharsets.UTF_8);
        ex.getResponseHeaders().set("Content-Type", "application/json");
        if (ex.getRequestMethod().equals("HEAD")) { ex.sendResponseHeaders(status, -1); return; }
        ex.sendResponseHeaders(status, b.length);
        try (OutputStream os = ex.getResponseBody()) { os.write(b); }
    }

    static String queryParam(String rawQuery, String name) {
        if (rawQuery == null) return null;
        for (String kv : rawQuery.split("&")) {
            int i = kv.indexOf('=');
            String k = URLDecoder.decode(i < 0 ? kv : kv.substring(0, i), StandardCharsets.UTF_8);
            if (k.equals(name)) return i < 0 ? "" : URLDecoder.decode(kv.substring(i + 1), StandardCharsets.UTF_8);
        }
        return null;
    }

    static String fmtShare(double d) {
        return Double.toString(d); // 0.0 / 0.25 / 1.0, as Python prints a float
    }

    /** Accept any downstream certificate and skip hostname checks (Python: verify=False). Demo only. */
    static SSLContext trustAll() throws Exception {
        TrustManager tm = new X509ExtendedTrustManager() {
            public void checkClientTrusted(X509Certificate[] c, String a) {}
            public void checkServerTrusted(X509Certificate[] c, String a) {}
            public void checkClientTrusted(X509Certificate[] c, String a, Socket s) {}
            public void checkServerTrusted(X509Certificate[] c, String a, Socket s) {}
            public void checkClientTrusted(X509Certificate[] c, String a, SSLEngine e) {}
            public void checkServerTrusted(X509Certificate[] c, String a, SSLEngine e) {}
            public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
        };
        SSLContext ctx = SSLContext.getInstance("TLS");
        ctx.init(null, new TrustManager[] {tm}, null);
        return ctx;
    }

    /** USE_TLS=1: serve HTTPS with the self-signed keystore baked into the image (demo only). */
    static SSLContext serverTls() throws Exception {
        String path = env("TLS_KEYSTORE", "/app/tls.p12");
        char[] pw = env("TLS_KEYSTORE_PASSWORD", "changeit").toCharArray();
        KeyStore ks = KeyStore.getInstance("PKCS12");
        try (FileInputStream in = new FileInputStream(path)) { ks.load(in, pw); }
        KeyManagerFactory kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        kmf.init(ks, pw);
        SSLContext ctx = SSLContext.getInstance("TLS");
        ctx.init(kmf.getKeyManagers(), null, null);
        return ctx;
    }

    public static void main(String[] args) throws Exception {
        // HttpClient refuses to set Host unless explicitly allowed (also set on the command line).
        System.setProperty("jdk.httpclient.allowRestrictedHeaders", "host");
        System.setProperty("jdk.internal.httpclient.disableHostnameVerification", "true");
        client = HttpClient.newBuilder()
            .version(HttpClient.Version.HTTP_1_1) // no h2c upgrade attempt
            .connectTimeout(Duration.ofSeconds(5))
            .proxy(HttpClient.Builder.NO_PROXY)
            .sslContext(trustAll())
            .build();

        String serveRoute = ROUTES.get(ROLE);
        if (serveRoute == null) throw new IllegalArgumentException("unknown ROLE " + ROLE);

        HttpServer server;
        if (USE_TLS) {
            HttpsServer https = HttpsServer.create(new InetSocketAddress("0.0.0.0", PORT), 128);
            https.setHttpsConfigurator(new HttpsConfigurator(serverTls()));
            server = https;
        } else {
            server = HttpServer.create(new InetSocketAddress("0.0.0.0", PORT), 128);
        }
        server.setExecutor(Executors.newFixedThreadPool(32));
        server.createContext("/", ex -> {
            int code = 500;
            try (InputStream in = ex.getRequestBody()) {
                in.readAllBytes();
                String path = ex.getRequestURI().getRawPath();
                String method = ex.getRequestMethod();
                if (path.equals("/healthz")) {
                    if (!method.equals("GET") && !method.equals("HEAD")) { send(ex, code = 405, "{\"error\":\"method not allowed\"}"); return; }
                    send(ex, code = 200, "{\"cpu_share\":" + fmtShare(CPU_SHARE) + ",\"ok\":true,\"pid\":" + PID
                        + ",\"profile\":" + q(profile) + ",\"role\":" + q(ROLE) + "}");
                } else if (path.equals("/fault")) {
                    if (!method.equals("POST")) { send(ex, code = 405, "{\"error\":\"method not allowed\"}"); return; }
                    String p = queryParam(ex.getRequestURI().getRawQuery(), "profile");
                    if (p == null) p = "degraded";
                    if (!PROFILES.containsKey(p)) {
                        StringBuilder v = new StringBuilder();
                        for (String n : PROFILES.keySet()) v.append(v.length() == 0 ? "" : ",").append(q(n));
                        send(ex, code = 400, "{\"error\":\"unknown profile\",\"valid\":[" + v + "]}");
                        return;
                    }
                    profile = p;
                    send(ex, code = 200, "{\"profile\":" + q(p) + ",\"role\":" + q(ROLE) + "}");
                } else if (path.equals(serveRoute)) {
                    if (!method.equals("POST")) { send(ex, code = 405, "{\"error\":\"method not allowed\"}"); return; }
                    if (DEBUG) System.err.println(method + " " + path + " Host=" + ex.getRequestHeaders().getFirst("Host"));
                    double[] pr = pickResponse();
                    if (pr == null) { send(ex, code = 500, "{\"error\":\"unknown profile\"}"); return; }
                    int status = (int) pr[0];
                    if (status < 400) {
                        // Only orchestrate on the OK path, adopting a dependency's failure as our own.
                        int downstream = fanOut();
                        if (downstream != 0) status = downstream;
                    }
                    // Split computed before the compute; the sleep is a fixed proportion, never the remainder.
                    double budget = pr[1] * CPU_SHARE, sleep = pr[1] * (1.0 - CPU_SHARE);
                    if (budget > 0) logCompute(spendCpu(budget, DEFAULT_WALL_CAP_SECONDS));
                    Thread.sleep(Duration.ofNanos(Math.round(sleep * 1e9)));
                    send(ex, code = status, "{\"role\":" + q(ROLE) + ",\"status\":" + status + "}");
                } else {
                    send(ex, code = 404, "{\"error\":\"not found\"}");
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            } catch (Exception e) {
                System.err.println("handler error: " + e);
            } finally {
                System.out.println(ex.getRequestMethod() + " " + ex.getRequestURI() + " " + code);
                ex.close();
            }
        });
        server.start();
        System.out.println("ping " + ROLE + " (Java) listening on 0.0.0.0:" + PORT + " route " + serveRoute
            + " profile " + profile + " cpu_share " + CPU_SHARE + " tls " + USE_TLS);
    }
}
