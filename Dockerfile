# syntax=docker/dockerfile:1
FROM linuxserver/brave:latest

# ---------------------------------------------------------------------------
# Brave on Railway with a custom login page. Single-file build: the login
# gateway and login page are embedded below, no other files needed.
#
#   Railway -> gateway :8080 (custom login page) -> KasmVNC/Brave :3000 (internal)
#
# Set these in Railway -> your service -> Variables (never hardcode them here):
#   LOGIN_PASSWORD  (required) password for the login page
#   LOGIN_USER      (optional) username, defaults to "admin"
#   SESSION_SECRET  (optional) long random string so sessions survive redeploys
#   PORT            set to 8080 (the gateway's port)
#
# Do NOT set PASSWORD / CUSTOM_USER: those enable KasmVNC's own basic-auth
# prompt on top of this login page.
# ---------------------------------------------------------------------------

ENV PUID=1000 \
    PGID=1000 \
    TZ=Etc/UTC \
    TITLE="Brave" \
    BRAVE_CLI="--disable-dev-shm-usage"

# Node.js for the gateway
RUN apt-get update \
 && apt-get install -y --no-install-recommends nodejs npm \
 && rm -rf /var/lib/apt/lists/*

# ---- Gateway: package.json + dependencies ----------------------------------
COPY <<'EOF_PKG' /opt/gateway/package.json
{
  "name": "login-gateway",
  "version": "1.0.0",
  "private": true,
  "main": "server.js",
  "dependencies": {
    "http-proxy": "^1.18.1"
  }
}
EOF_PKG
RUN cd /opt/gateway && npm install --omit=dev

# ---- Gateway: server --------------------------------------------------------
COPY <<'EOF_SERVER' /opt/gateway/server.js
'use strict';

const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const httpProxy = require('http-proxy');

// ---- Config (all via environment variables) ---------------------------------
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
    if (i > -1) out[p.slice(0, i).trim()] = decodeURIComponent(p.slice(i + 1).trim());
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

// Simple in-memory brute-force limiter: 8 failures / 15 min per IP.
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
});
EOF_SERVER

# ---- Gateway: custom login page (edit the HTML/CSS below to restyle) -------
COPY <<'EOF_LOGIN' /opt/gateway/login.html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Sign in · Secure Browser</title>
<style>
  :root {
    --bg: #0e1116;
    --card: #161b22;
    --border: #262d38;
    --text: #e8ecf1;
    --muted: #8b95a5;
    --accent: #ff6a2b;
    --accent-hover: #ff7f48;
    --error-bg: #3a1a1a;
    --error-text: #ff9b9b;
  }
  @media (prefers-color-scheme: light) {
    :root {
      --bg: #f3f5f8;
      --card: #ffffff;
      --border: #dfe3ea;
      --text: #151a21;
      --muted: #667085;
      --error-bg: #fdecec;
      --error-text: #b42318;
    }
  }
  * { box-sizing: border-box; }
  html, body { height: 100%; margin: 0; }
  body {
    display: grid;
    place-items: center;
    padding: 16px;
    background:
      radial-gradient(900px 500px at 15% -10%, rgba(255,106,43,.14), transparent 60%),
      radial-gradient(700px 500px at 100% 110%, rgba(255,106,43,.08), transparent 60%),
      var(--bg);
    color: var(--text);
    font: 15px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  }
  .card {
    width: 100%;
    max-width: 380px;
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 16px;
    padding: 32px 28px;
    box-shadow: 0 20px 50px rgba(0,0,0,.25);
  }
  .logo {
    width: 52px; height: 52px;
    display: grid; place-items: center;
    margin: 0 auto 18px;
    border-radius: 14px;
    background: linear-gradient(135deg, var(--accent), #ff9a5c);
  }
  .logo svg { width: 26px; height: 26px; stroke: #fff; }
  h1 { margin: 0 0 4px; font-size: 22px; text-align: center; letter-spacing: -.01em; }
  .sub { margin: 0 0 24px; text-align: center; color: var(--muted); font-size: 14px; }
  label { display: block; margin: 0 0 6px; font-size: 13px; font-weight: 600; }
  .field { margin-bottom: 16px; position: relative; }
  input {
    width: 100%;
    padding: 11px 12px;
    font: inherit;
    color: var(--text);
    background: transparent;
    border: 1px solid var(--border);
    border-radius: 10px;
    outline: none;
    transition: border-color .15s, box-shadow .15s;
  }
  input:focus { border-color: var(--accent); box-shadow: 0 0 0 3px rgba(255,106,43,.22); }
  #password { padding-right: 64px; }
  .toggle {
    position: absolute; right: 8px; bottom: 7px;
    padding: 4px 8px;
    font: inherit; font-size: 12px; font-weight: 600;
    color: var(--muted);
    background: none; border: 0; border-radius: 6px; cursor: pointer;
  }
  .toggle:hover { color: var(--text); }
  button.primary {
    width: 100%;
    margin-top: 4px;
    padding: 12px;
    font: inherit; font-weight: 600;
    color: #fff;
    background: var(--accent);
    border: 0; border-radius: 10px; cursor: pointer;
    transition: background .15s, transform .05s;
  }
  button.primary:hover { background: var(--accent-hover); }
  button.primary:active { transform: translateY(1px); }
  button.primary:disabled { opacity: .6; cursor: default; }
  .error {
    display: none;
    margin-bottom: 16px;
    padding: 10px 12px;
    font-size: 13px;
    color: var(--error-text);
    background: var(--error-bg);
    border-radius: 10px;
  }
  .error.show { display: block; }
  .foot { margin-top: 20px; text-align: center; font-size: 12px; color: var(--muted); }
</style>
</head>
<body>
  <main class="card">
    <div class="logo" aria-hidden="true">
      <svg viewBox="0 0 24 24" fill="none" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        <rect x="4" y="11" width="16" height="9" rx="2"/>
        <path d="M8 11V8a4 4 0 0 1 8 0v3"/>
      </svg>
    </div>
    <h1>Secure Browser</h1>
    <p class="sub">Sign in to continue</p>

    <form method="post" action="/login" autocomplete="on" id="form">
      <div class="error {{ERROR_CLASS}}" role="alert">{{ERROR}}</div>

      <div class="field">
        <label for="username">Username</label>
        <input id="username" name="username" type="text" autocomplete="username" autocapitalize="none" spellcheck="false" required autofocus>
      </div>

      <div class="field">
        <label for="password">Password</label>
        <input id="password" name="password" type="password" autocomplete="current-password" required>
        <button class="toggle" type="button" id="toggle" aria-label="Show password">Show</button>
      </div>

      <button class="primary" type="submit" id="submit">Sign in</button>
    </form>

    <div class="foot">Authorized access only</div>
  </main>

<script>
  var pw = document.getElementById('password');
  var toggle = document.getElementById('toggle');
  toggle.addEventListener('click', function () {
    var show = pw.type === 'password';
    pw.type = show ? 'text' : 'password';
    toggle.textContent = show ? 'Hide' : 'Show';
    toggle.setAttribute('aria-label', show ? 'Hide password' : 'Show password');
  });
  document.getElementById('form').addEventListener('submit', function () {
    var b = document.getElementById('submit');
    b.disabled = true;
    b.textContent = 'Signing in…';
  });
</script>
</body>
</html>
EOF_LOGIN

# ---- Run the gateway as an s6 service next to the browser ------------------
COPY --chmod=755 <<'EOF_SVC' /custom-services.d/gateway
#!/usr/bin/with-contenv bash
cd /opt/gateway || exit 1
exec s6-setuidgid abc node server.js
EOF_SVC

# Only the gateway is public. KasmVNC stays on 3000 inside the container.
EXPOSE 8080

# Persistent profile: attach a Railway Volume mounted at /config
# (Railway doesn't allow the VOLUME instruction in Dockerfiles).
