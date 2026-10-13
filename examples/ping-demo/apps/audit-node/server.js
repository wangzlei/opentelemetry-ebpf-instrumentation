'use strict';
// Ping demo service -- Node.js port of examples/ping-demo/app/server.py (built-in modules only).
//
// Same external behaviour as the Python app: $ROLE picks the served route and the downstreams,
// $PROFILE shapes this service's own status mix + latency, POST /fault flips the profile at runtime,
// and on the OK path the service calls its downstreams first and ADOPTS a dependency's failure
// (propagate.js). CPU_SHARE spends that share of each response's target duration on real CPU work in
// a worker thread (cpuwork.js). Downstream DNS names are expanded to every A record and one is picked
// per call, with the logical Host header kept. All waits are non-blocking.
//
// Deployed as the audit service; package.json "name" is "audit-worker", which the agent's autoname
// reads without OTEL_SERVICE_NAME.

const http = require('http');
const https = require('https');
const fs = require('fs');
const dns = require('dns').promises;
const dgram = require('dgram');
const cpuwork = require('./cpuwork');
const { worstStatus } = require('./propagate');

// Identical to server.py PROFILES: [status, weight, mean_s, min_s, max_s]. Key order = list(PROFILES).
const PROFILES = {
  healthy: [[200, 1000, 0.05, 0.005, 0.40]],
  // Permanent small failure rate: 2% fault + 1% error, healthy latency otherwise.
  flaky: [
    [200, 970, 0.05, 0.005, 0.40],
    [500, 20, 0.03, 0.002, 0.30],
    [429, 10, 0.01, 0.001, 0.10],
  ],
  degraded: [[200, 1000, 0.30, 0.05, 2.00]],
  erroring: [
    [200, 500, 0.06, 0.005, 0.50],
    [404, 120, 0.01, 0.001, 0.08],
    [500, 250, 0.03, 0.002, 0.30],
    [429, 130, 0.01, 0.001, 0.10],
  ],
  faulty: [
    [200, 200, 0.08, 0.005, 0.60],
    [503, 500, 0.05, 0.002, 1.50],
    [500, 300, 0.04, 0.002, 0.90],
  ],
};
const ROUTES = { checkout: '/checkout', payment: '/charges', inventory: '/reservations', audit: '/audit' };

const env = (k, d) => (process.env[k] === undefined ? d : process.env[k]);
const split = (s) => (s || '').split(',').filter((u) => u);

const ROLE = env('ROLE', 'checkout');
const PORT = parseInt(env('PORT', '8000'), 10);
const USE_TLS = env('USE_TLS', '0') === '1';
const CPU_SHARE = cpuwork.resolveShare(env('CPU_SHARE', '0'));
const PAYMENT_URLS = split(process.env.PAYMENT_URLS);
const INVENTORY_URLS = split(process.env.INVENTORY_URLS);
const AUDIT_URLS = split(process.env.AUDIT_URLS);
const PREFER_SAME_AZ = env('PREFER_SAME_AZ', '0') === '1';
const DEBUG = process.env.DEBUG === '1';
const SERVE_ROUTE = ROUTES[ROLE];
if (!SERVE_ROUTE) throw new Error(`unknown ROLE ${ROLE}`);

// Read per request so POST /fault flips it at runtime (instance-wide: one process).
let profile = env('PROFILE', 'healthy');

// Python random.triangular(low, high, mode)
function triangular(low, high, mode) {
  let u = Math.random();
  if (high === low) return low;
  let c = (mode - low) / (high - low);
  if (u > c) {
    u = 1.0 - u;
    c = 1.0 - c;
    [low, high] = [high, low];
  }
  return low + (high - low) * Math.sqrt(u * c);
}

// -> [status, latency_s] or null when the profile is unknown (Python: KeyError -> 500)
function pickResponse() {
  const rows = Object.prototype.hasOwnProperty.call(PROFILES, profile) ? PROFILES[profile] : null;
  if (!rows) return null;
  const total = rows.reduce((a, r) => a + r[1], 0);
  const x = Math.random() * total;
  let acc = 0;
  let sel = rows[rows.length - 1];
  for (const r of rows) {
    acc += r[1];
    if (x < acc) { sel = r; break; }
  }
  const [status, , mean, lo, hi] = sel;
  return [status, Math.min(hi, Math.max(lo, triangular(lo, hi, mean)))];
}

// One target per resolved IPv4 A record (sorted); Host header keeps the logical host:port.
async function targets(raw) {
  const u = new URL(raw);
  const host = u.hostname;
  const port = u.port || '8000';
  let ips;
  try {
    const addrs = await dns.lookup(host, { family: 4, all: true });
    ips = [...new Set(addrs.map((a) => a.address))].sort();
  } catch (_) {
    ips = [];
  }
  if (ips.length === 0) ips = [host];
  return ips.map((ip) => ({ tls: u.protocol === 'https:', ip, port, path: u.pathname, hostHdr: `${host}:${port}` }));
}

// Primary private IP via the UDP-connect trick (no packet sent).
function localIp() {
  return new Promise((resolve) => {
    const s = dgram.createSocket('udp4');
    s.once('error', () => { s.close(); resolve(null); });
    s.connect(1, '10.255.255.255', () => {
      try { resolve(s.address().address); } catch (_) { resolve(null); }
      s.close();
    });
  });
}

// -> Promise<status code>; rejects on a transport error.
function post(t) {
  return new Promise((resolve, reject) => {
    const body = '{}';
    const mod = t.tls ? https : http;
    const req = mod.request({
      host: t.ip, port: t.port, path: t.path, method: 'POST', agent: false, // fresh connection per call
      rejectUnauthorized: false, // self-signed downstream certs (Python: verify=False)
      headers: { Host: t.hostHdr, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, (res) => {
      res.resume();
      res.on('end', () => resolve(res.statusCode));
      res.on('error', reject);
    });
    req.setTimeout(5000, () => req.destroy(new Error('timeout')));
    req.on('error', reject);
    req.end(body);
  });
}

// POST {} to one downstream instance and return its status. A transport error moves on to the next
// instance; null when there was nothing to call or every target failed. No retry on a status.
async function call(baseUrls, path) {
  if (baseUrls.length === 0) return null;
  let ts = [];
  for (const b of baseUrls) ts = ts.concat(await targets(b.replace(/\/+$/, '') + path));
  if (PREFER_SAME_AZ) {
    const lip = await localIp();
    if (lip) {
      const prefix = lip.slice(0, lip.lastIndexOf('.') + 1); // /24
      const same = ts.filter((t) => t.ip.startsWith(prefix));
      if (same.length) ts = same;
    }
  }
  for (let i = ts.length - 1; i > 0; i--) { // Fisher-Yates shuffle
    const j = Math.floor(Math.random() * (i + 1));
    [ts[i], ts[j]] = [ts[j], ts[i]];
  }
  for (const t of ts) {
    try {
      return await post(t);
    } catch (e) {
      if (DEBUG) console.error(`call ${t.ip}:${t.port}${t.path} (Host ${t.hostHdr}) failed: ${e.message}`);
    }
  }
  return null;
}

// Call this role's downstreams (sequentially, as server.py does); the status to adopt, or null.
async function fanOut() {
  if (ROLE === 'checkout') {
    const p = await call(PAYMENT_URLS, '/charges');
    const i = await call(INVENTORY_URLS, '/reservations');
    return worstStatus([p, i]);
  }
  if (ROLE === 'payment') return worstStatus([await call(AUDIT_URLS, '/audit')]);
  return null; // inventory, audit: leaves
}

const sleep = (s) => new Promise((r) => setTimeout(r, s * 1000));

// JSON with sorted keys, like Flask's jsonify.
function send(res, status, obj) {
  const sorted = {};
  for (const k of Object.keys(obj).sort()) sorted[k] = obj[k];
  const b = JSON.stringify(sorted) + '\n';
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(b) });
  res.end(b);
}

const pyBool = (b) => (b ? 'True' : 'False');

function logCompute(s) {
  const slowdown = s.cpuSeconds > 0 ? s.wallSeconds / s.cpuSeconds : 0;
  console.log(`cpuwork role=${ROLE} share=${CPU_SHARE.toFixed(3)} cpu=${s.cpuSeconds.toFixed(4)}s `
    + `wall=${s.wallSeconds.toFixed(4)}s slowdown=${slowdown.toFixed(2)} capped=${pyBool(s.capped)}`);
}

async function handle(req, res) {
  const u = new URL(req.url, 'http://x');
  const m = req.method;
  if (u.pathname === '/healthz') {
    if (m !== 'GET' && m !== 'HEAD') return send(res, 405, { error: 'method not allowed' });
    // cpu_share is written the way Python's json writes a float (0.0, 0.25, 1.0).
    const share = Number.isInteger(CPU_SHARE) ? CPU_SHARE.toFixed(1) : String(CPU_SHARE);
    const b = `{"cpu_share":${share},"ok":true,"pid":${process.pid},"profile":${JSON.stringify(profile)},`
      + `"role":${JSON.stringify(ROLE)}}\n`;
    res.writeHead(200, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(b) });
    return res.end(m === 'HEAD' ? undefined : b);
  }
  if (u.pathname === '/fault') {
    if (m !== 'POST') return send(res, 405, { error: 'method not allowed' });
    const p = u.searchParams.has('profile') ? u.searchParams.get('profile') : 'degraded';
    if (!Object.prototype.hasOwnProperty.call(PROFILES, p)) {
      return send(res, 400, { error: 'unknown profile', valid: Object.keys(PROFILES) });
    }
    profile = p;
    return send(res, 200, { role: ROLE, profile: p });
  }
  if (u.pathname === SERVE_ROUTE) {
    if (m !== 'POST') return send(res, 405, { error: 'method not allowed' });
    if (DEBUG) console.error(`${m} ${u.pathname} Host=${req.headers.host}`);
    const pr = pickResponse();
    if (!pr) return send(res, 500, { error: 'unknown profile' });
    let [status, latency] = pr; // eslint-disable-line prefer-const
    if (status < 400) {
      // Only orchestrate on the OK path, adopting a dependency's failure as this service's own.
      const downstream = await fanOut();
      if (downstream !== null) status = downstream;
    }
    // Split computed before the compute; the sleep is a fixed proportion, never the remainder.
    const split = cpuwork.splitDuration(latency, CPU_SHARE);
    if (split.cpuBudgetSeconds > 0) logCompute(await cpuwork.spendCpu(split.cpuBudgetSeconds));
    await sleep(split.sleepSeconds);
    return send(res, status, { role: ROLE, status });
  }
  return send(res, 404, { error: 'not found' });
}

function onRequest(req, res) {
  req.resume(); // drain the request body
  res.on('finish', () => console.log(`${req.method} ${req.url} ${res.statusCode}`));
  handle(req, res).catch((e) => {
    console.error('handler error:', e);
    if (!res.headersSent) send(res, 500, { error: 'internal error' });
  });
}

// USE_TLS=1: HTTPS with the self-signed pair baked into the image (demo only).
const server = USE_TLS
  ? https.createServer({
    cert: fs.readFileSync(env('TLS_CERT', '/app/tls/cert.pem')),
    key: fs.readFileSync(env('TLS_KEY', '/app/tls/key.pem')),
  }, onRequest)
  : http.createServer(onRequest);
server.keepAliveTimeout = 2000; // gunicorn's default keepalive is 2 s
server.listen(PORT, '0.0.0.0', () => {
  console.log(`ping ${ROLE} (Node) listening on 0.0.0.0:${PORT} route ${SERVE_ROUTE} profile ${profile} `
    + `cpu_share ${CPU_SHARE} tls ${USE_TLS}`);
});
for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => process.exit(0));
