'use strict';

const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const httpProxy = require('http-proxy');

// ---- Config (environment variables only) ------------------------------------
const PORT = parseInt(process.env.PORT || '8080', 10);
const TARGET = process.env.UPSTREAM || 'http://127.0.0.1:3000'; // KasmVNC (plain HTTP)
const LOGIN_USER = process.env.LOGIN_USER || 'admin';
const LOGIN_PASSWORD = process.env.LOGIN_PASSWORD || '';
const SESSION_HOURS = parseInt(process.env.SESSION_HOURS || '168', 10); // 7 days
const SECRET = process.env.SESSION_SECRET || crypto.randomBytes(32).toString('hex');
const COOKIE = 'gw_session';

const LOGIN_HTML = fs.readFileSync(path.join(__dirname, 'login.html'), 'utf8');

// ---- Helpers ----------------------------------------------------------------
const sha = (s) => crypto.createHash('sha256').update(String(s)).digest();
const safeEqual = (a, b) => crypto.timingSafeEqual(sha(a), sha(b));
const sign = (v) => crypto.createHmac('sha256', SECRET).update(v).digest('hex');

function makeToken() {
  const exp = String(Date.now() + SESSION_HOURS * 3600 * 1000);
  return `${exp}.${sign(exp)}`;
}

function parseCookies(header = '') {
  const out = {};
  header.split(';').forEach((p) => {
    const i = p.indexOf('=');
    if (i > -1) {
      try { out[p.slice(0, i).trim()] = decodeURIComponent(p.slice(i + 1).trim()); }
      catch { /* ignore malformed cookie */ }
    }
  });
  return out;
}

function isAuthed(req) {
  const token = parseCookies(req.headers.cookie)[COOKIE];
  if (!token) return false;
  const [exp, sig] = token.split('.');
  if (!exp || !sig) return false;
  const expected = sign(exp);
  if (sig.length !== expected.length) return false;
  if (!crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(expected))) return false;
  return Number(exp) > Date.now();
}

function cookieHeader(value, req, maxAgeSec) {
  const secure = (req.headers['x-forwarded-proto'] || '').split(',')[0] === 'https';
  return `${COOKIE}=${encodeURIComponent(value)}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${maxAgeSec}${secure ? '; Secure' : ''}`;
}

function clientIp(req) {
  return (req.headers['x-forwarded-for'] || req.socket.remoteAddress || '').split(',')[0].trim();
}

// In-memory brute-force limiter: MAX_FAILS failures per WINDOW per IP.
const fails = new Map();
const WINDOW = 15 * 60 * 1000;
const MAX_FAILS = 8;

function isLocked(ip) {
  const e = fails.get(ip);
  if (!e) return false;
  if (Date.now() - e.first > WINDOW) { fails.delete(ip); return false; }
  return e.count >= MAX_FAILS;
}

function recordFail(ip) {
  const e = fails.get(ip);
  if (!e || Date.now() - e.first > WINDOW) fails.set(ip, { count: 1, first: Date.now() });
  else e.count += 1;
}

// Periodically drop expired entries so the map cannot grow without bound.
setInterval(() => {
  const now = Date.now();
  for (const [ip, e] of fails) if (now - e.first > WINDOW) fails.delete(ip);
}, 5 * 60 * 1000).unref();

function readBody(req, limit = 4096) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) { reject(new Error('too large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function sendLogin(res, status, error) {
  const html = LOGIN_HTML.replace('{{ERROR}}', error ? String(error) : '')
                         .replace('{{ERROR_CLASS}}', error ? 'show' : '');
  res.writeHead(status, {
    'Content-Type': 'text/html; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Frame-Options': 'DENY',
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer',
  });
  res.end(html);
}

// ---- Proxy ------------------------------------------------------------------
const proxy = httpProxy.createProxyServer({ target: TARGET, ws: true, xfwd: true });

proxy.on('error', (err, req, res) => {
  if (res && typeof res.writeHead === 'function' && !res.headersSent) {
    res.writeHead(502, { 'Content-Type': 'text/plain' });
    res.end('Browser is starting up, please refresh in a few seconds.');
  } else if (res && typeof res.destroy === 'function') {
    res.destroy();
  }
});

// Never leak the gateway session cookie to the upstream.
function stripSessionCookie(req) {
  if (!req.headers.cookie) return;
  const rest = req.headers.cookie
    .split(';')
    .filter((c) => !c.trim().startsWith(COOKIE + '='))
    .join(';')
    .trim();
  if (rest) req.headers.cookie = rest; else delete req.headers.cookie;
}

// ---- Server -----------------------------------------------------------------
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');

  // Fail closed: never expose the browser without a configured password.
  if (!LOGIN_PASSWORD) {
    res.writeHead(503, { 'Content-Type': 'text/plain' });
    res.end('Gateway is not configured: set the LOGIN_PASSWORD environment variable.');
    return;
  }

  if (url.pathname === '/healthz') { res.writeHead(200); res.end('ok'); return; }

  if (url.pathname === '/login') {
    if (req.method === 'GET') {
      if (isAuthed(req)) { res.writeHead(302, { Location: '/' }); res.end(); return; }
      return sendLogin(res, 200);
    }
    if (req.method === 'POST') {
      const ip = clientIp(req);
      if (isLocked(ip)) return sendLogin(res, 429, 'Too many attempts. Try again in a few minutes.');
      let body;
      try { body = new URLSearchParams(await readBody(req)); }
      catch { return sendLogin(res, 400, 'Bad request.'); }

      const okUser = safeEqual(body.get('username') || '', LOGIN_USER);
      const okPass = safeEqual(body.get('password') || '', LOGIN_PASSWORD);
      if (okUser && okPass) {
        fails.delete(ip);
        res.writeHead(302, {
          Location: '/',
          'Set-Cookie': cookieHeader(makeToken(), req, SESSION_HOURS * 3600),
        });
        res.end();
        return;
      }
      recordFail(ip);
      return sendLogin(res, 401, 'Incorrect username or password.');
    }
    res.writeHead(405); res.end(); return;
  }

  if (url.pathname === '/logout') {
    res.writeHead(302, { Location: '/login', 'Set-Cookie': cookieHeader('', req, 0) });
    res.end();
    return;
  }

  if (!isAuthed(req)) {
    if (req.method === 'GET' && (req.headers.accept || '').includes('text/html')) {
      res.writeHead(302, { Location: '/login' });
      res.end();
    } else {
      res.writeHead(401, { 'Content-Type': 'text/plain' });
      res.end('Unauthorized');
    }
    return;
  }

  stripSessionCookie(req);
  proxy.web(req, res);
});

// WebSocket upgrades (the actual remote-desktop stream) need auth too.
server.on('upgrade', (req, socket, head) => {
  if (!LOGIN_PASSWORD || !isAuthed(req)) {
    socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
    socket.destroy();
    return;
  }
  stripSessionCookie(req);
  proxy.ws(req, socket, head);
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[gateway] listening on :${PORT} -> ${TARGET}`);
  if (!LOGIN_PASSWORD) console.warn('[gateway] LOGIN_PASSWORD is not set; all requests return 503.');
  if (!process.env.SESSION_SECRET) console.warn('[gateway] SESSION_SECRET not set; sessions reset on restart.');
});

for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => { server.close(() => process.exit(0)); setTimeout(() => process.exit(0), 3000).unref(); });
}
