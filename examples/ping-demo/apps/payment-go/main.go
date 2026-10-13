// Ping demo service -- Go port of examples/ping-demo/app/server.py (net/http, stdlib only).
//
// Same external behaviour as the Python app: $ROLE picks the served route and the downstreams,
// $PROFILE shapes this service's own status mix + latency, POST /fault flips the profile at runtime,
// and on the OK path the service calls its downstreams first and ADOPTS a dependency's failure
// (propagate.go). CPU_SHARE spends that share of each response's target duration on real CPU work
// (cpuwork.go). Downstream DNS names are expanded to every A record and one is picked per call, with
// the logical Host header kept.
//
// Deployed as the payment service; the binary is /usr/local/bin/payment (module ping/payment), so the
// agent's autoname derives "payment" from the executable without OTEL_SERVICE_NAME. Not stripped: OBI
// Go uprobes resolve functions from the symbol table.
package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math"
	"math/big"
	mrand "math/rand/v2"
	"net"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

type row struct {
	status       int
	weight       float64
	mean, lo, hi float64 // seconds
}

// Identical to server.py PROFILES: status, weight, mean_s, min_s, max_s.
var profiles = map[string][]row{
	"healthy": {{200, 1000, 0.05, 0.005, 0.40}},
	// Permanent small failure rate: 2% fault + 1% error, healthy latency otherwise.
	"flaky": {
		{200, 970, 0.05, 0.005, 0.40},
		{500, 20, 0.03, 0.002, 0.30},
		{429, 10, 0.01, 0.001, 0.10},
	},
	"degraded": {{200, 1000, 0.30, 0.05, 2.00}},
	"erroring": {
		{200, 500, 0.06, 0.005, 0.50},
		{404, 120, 0.01, 0.001, 0.08},
		{500, 250, 0.03, 0.002, 0.30},
		{429, 130, 0.01, 0.001, 0.10},
	},
	"faulty": {
		{200, 200, 0.08, 0.005, 0.60},
		{503, 500, 0.05, 0.002, 1.50},
		{500, 300, 0.04, 0.002, 0.90},
	},
}

// The order Python's list(PROFILES) yields.
var profileNames = []string{"healthy", "flaky", "degraded", "erroring", "faulty"}

var routes = map[string]string{
	"checkout":  "/checkout",
	"payment":   "/charges",
	"inventory": "/reservations",
	"audit":     "/audit",
}

var (
	role          = getenv("ROLE", "checkout")
	port          = getenv("PORT", "8000")
	useTLS        = getenv("USE_TLS", "0") == "1"
	cpuShare      = resolveShare(getenv("CPU_SHARE", "0"))
	paymentURLs   = splitURLs(os.Getenv("PAYMENT_URLS"))
	inventoryURLs = splitURLs(os.Getenv("INVENTORY_URLS"))
	auditURLs     = splitURLs(os.Getenv("AUDIT_URLS"))
	preferSameAZ  = getenv("PREFER_SAME_AZ", "0") == "1"
	debug         = os.Getenv("DEBUG") == "1"

	// Read per request so POST /fault flips it at runtime (instance-wide: one process).
	profile atomic.Value

	// A fresh connection per call, like requests.post without a Session; self-signed downstream
	// certs are accepted (verify=False).
	client = &http.Client{
		Timeout: 5 * time.Second,
		Transport: &http.Transport{
			DisableKeepAlives: true,
			Proxy:             nil,
			TLSClientConfig:   &tls.Config{InsecureSkipVerify: true}, //nolint:gosec // demo only
		},
	}
)

func getenv(k, def string) string {
	if v, ok := os.LookupEnv(k); ok {
		return v
	}
	return def
}

func splitURLs(s string) []string {
	var out []string
	for _, u := range strings.Split(s, ",") {
		if u != "" {
			out = append(out, u)
		}
	}
	return out
}

// triangular mirrors Python's random.triangular(low, high, mode).
func triangular(low, high, mode float64) float64 {
	u := mrand.Float64()
	if high == low {
		return low
	}
	c := (mode - low) / (high - low)
	if u > c {
		u = 1.0 - u
		c = 1.0 - c
		low, high = high, low
	}
	return low + (high-low)*math.Sqrt(u*c)
}

// pickResponse: weighted row choice (random.choices) + clamped triangular latency in seconds.
// ok=false when the current profile is unknown (Python: KeyError -> 500).
func pickResponse() (int, float64, bool) {
	rows, ok := profiles[profile.Load().(string)]
	if !ok {
		return 500, 0, false
	}
	total := 0.0
	for _, r := range rows {
		total += r.weight
	}
	x := mrand.Float64() * total
	sel := rows[len(rows)-1]
	acc := 0.0
	for _, r := range rows {
		acc += r.weight
		if x < acc {
			sel = r
			break
		}
	}
	return sel.status, math.Min(sel.hi, math.Max(sel.lo, triangular(sel.lo, sel.hi, sel.mean))), true
}

type target struct{ url, ip, hostHdr string }

// targets expands a URL into one target per resolved IPv4 A record (sorted, de-duplicated); the Host
// header keeps the logical "host:port". An unresolvable name is used as-is.
func targets(raw string) []target {
	p, err := url.Parse(raw)
	if err != nil {
		return nil
	}
	host, prt := p.Hostname(), p.Port()
	if prt == "" {
		prt = "8000"
	}
	var ips []string
	if addrs, err := net.LookupIP(host); err == nil {
		set := map[string]bool{}
		for _, a := range addrs {
			if a4 := a.To4(); a4 != nil {
				set[a4.String()] = true
			}
		}
		for ip := range set {
			ips = append(ips, ip)
		}
		sort.Strings(ips)
	}
	if len(ips) == 0 {
		ips = []string{host}
	}
	out := make([]target, 0, len(ips))
	for _, ip := range ips {
		out = append(out, target{p.Scheme + "://" + ip + ":" + prt + p.Path, ip, host + ":" + prt})
	}
	return out
}

// localIP: primary private IP via the UDP-connect trick (no packet sent).
func localIP() string {
	c, err := net.Dial("udp4", "10.255.255.255:1")
	if err != nil {
		return ""
	}
	defer c.Close()
	return c.LocalAddr().(*net.UDPAddr).IP.String()
}

// call POSTs {} to one downstream instance and returns its status code. A transport error moves on
// to the next instance; 0 (Python None) when there was nothing to call or every target failed. No
// retry on a status: another instance would answer from the same profile.
func call(baseURLs []string, path string) int {
	if len(baseURLs) == 0 {
		return 0
	}
	var ts []target
	for _, b := range baseURLs {
		ts = append(ts, targets(strings.TrimRight(b, "/")+path)...)
	}
	if preferSameAZ {
		if lip := localIP(); lip != "" {
			prefix := lip[:strings.LastIndex(lip, ".")+1] // /24
			var same []target
			for _, t := range ts {
				if strings.HasPrefix(t.ip, prefix) {
					same = append(same, t)
				}
			}
			if len(same) > 0 {
				ts = same
			}
		}
	}
	mrand.Shuffle(len(ts), func(i, j int) { ts[i], ts[j] = ts[j], ts[i] })
	for _, t := range ts {
		req, err := http.NewRequest(http.MethodPost, t.url, bytes.NewReader([]byte("{}")))
		if err != nil {
			continue
		}
		req.Host = t.hostHdr
		req.Header.Set("Content-Type", "application/json")
		resp, err := client.Do(req)
		if err != nil {
			if debug {
				log.Printf("call %s (Host %s) failed: %v", t.url, t.hostHdr, err)
			}
			continue
		}
		_, _ = io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		return resp.StatusCode
	}
	return 0
}

// fanOut calls this role's downstreams (sequentially, as server.py does) and returns the status the
// caller should adopt, or 0.
func fanOut() int {
	switch role {
	case "checkout":
		return worstStatus(call(paymentURLs, "/charges"), call(inventoryURLs, "/reservations"))
	case "payment":
		return worstStatus(call(auditURLs, "/audit"))
	}
	return 0 // inventory, audit: leaves
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	b, _ := json.Marshal(v) // map keys are emitted sorted, like Flask's jsonify
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(append(b, '\n'))
}

// pyFloat marshals like Python's json (0.0, 0.25, 1.0), so /healthz reads the same in every port.
type pyFloat float64

func (f pyFloat) MarshalJSON() ([]byte, error) {
	s := strconv.FormatFloat(float64(f), 'f', -1, 64)
	if !strings.ContainsAny(s, ".eE") {
		s += ".0"
	}
	return []byte(s), nil
}

func pyBool(b bool) string {
	if b {
		return "True"
	}
	return "False"
}

// logCompute: one line per request with the measured slowdown, only when a share is set (same
// format as server.py).
func logCompute(s cpuSpend) {
	slowdown := 0.0
	if s.cpuSeconds > 0 {
		slowdown = s.wallSeconds / s.cpuSeconds
	}
	fmt.Printf("cpuwork role=%s share=%.3f cpu=%.4fs wall=%.4fs slowdown=%.2f capped=%s\n",
		role, cpuShare, s.cpuSeconds, s.wallSeconds, slowdown, pyBool(s.capped))
}

func serve(w http.ResponseWriter, r *http.Request) {
	if debug {
		log.Printf("%s %s Host=%s", r.Method, r.URL.Path, r.Host)
	}
	_, _ = io.Copy(io.Discard, r.Body)
	status, latency, ok := pickResponse()
	if !ok {
		writeJSON(w, 500, map[string]any{"error": "unknown profile"})
		return
	}
	if status < 400 {
		// Only orchestrate on the OK path, adopting a dependency's failure as this service's own.
		if downstream := fanOut(); downstream != 0 {
			status = downstream
		}
	}
	// Split computed before the compute runs; the sleep is a fixed proportion, never the remainder.
	budget, sleep := splitDuration(latency, cpuShare)
	if budget > 0 {
		logCompute(spendCPU(budget, defaultWallCapSeconds))
	}
	time.Sleep(time.Duration(sleep * float64(time.Second)))
	writeJSON(w, status, map[string]any{"role": role, "status": status})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(c int) { s.status = c; s.ResponseWriter.WriteHeader(c) }

// selfSigned makes a throwaway certificate for USE_TLS=1 (demo only), like the Python image's
// `openssl req -x509 ... -subj /CN=ping`.
func selfSigned() tls.Certificate {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		log.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()),
		Subject:      pkix.Name{CommonName: "ping"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().AddDate(10, 0, 0),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		log.Fatal(err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}
}

func main() {
	profile.Store(getenv("PROFILE", "healthy"))
	serveRoute, ok := routes[role]
	if !ok {
		log.Fatalf("unknown ROLE %q", role)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"ok": true, "role": role, "profile": profile.Load(),
			"cpu_share": pyFloat(cpuShare), "pid": os.Getpid()})
	})
	mux.HandleFunc("POST /fault", func(w http.ResponseWriter, r *http.Request) {
		p := "degraded"
		if q := r.URL.Query(); q.Has("profile") {
			p = q.Get("profile")
		}
		if _, ok := profiles[p]; !ok {
			writeJSON(w, 400, map[string]any{"error": "unknown profile", "valid": profileNames})
			return
		}
		profile.Store(p)
		writeJSON(w, 200, map[string]any{"role": role, "profile": p})
	})
	mux.HandleFunc("POST "+serveRoute, serve)
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sr := &statusRecorder{ResponseWriter: w, status: 200}
		mux.ServeHTTP(sr, r)
		log.Printf("%s %s %d", r.Method, r.URL.RequestURI(), sr.status) // access log
	})
	srv := &http.Server{Addr: "0.0.0.0:" + port, Handler: handler,
		// HTTP/1.1 only, like gunicorn (no h2 over TLS either).
		TLSNextProto: map[string]func(*http.Server, *tls.Conn, http.Handler){}}
	log.Printf("ping %s (Go) listening on 0.0.0.0:%s route %s profile %v cpu_share %.3f tls %v",
		role, port, serveRoute, profile.Load(), cpuShare, useTLS)
	if useTLS {
		srv.TLSConfig = &tls.Config{Certificates: []tls.Certificate{selfSigned()}}
		log.Fatal(srv.ListenAndServeTLS("", ""))
	}
	log.Fatal(srv.ListenAndServe())
}
