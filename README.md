# Brave on Railway (with custom login page)

Runs [`linuxserver/brave`](https://docs.linuxserver.io/images/docker-brave/) on [Railway](https://railway.app) behind a small gateway that serves your own login page. The browser is streamed to you in the web browser through KasmVNC.

```
Internet -> Railway (HTTPS) -> gateway :8080 (login page + sessions) -> KasmVNC/Brave :3000 (internal only)
```

KasmVNC's built-in prompt is plain HTTP basic auth and can't be restyled, so the gateway handles login instead and only proxies requests (including the WebSocket stream) once you're signed in.

## Project layout

```
.
├── Dockerfile    # everything is embedded here: gateway server, login page, service script
└── README.md
```

The `Dockerfile` uses heredocs (`COPY <<'EOF' ...`), which need BuildKit. Railway builds with BuildKit, and the `# syntax=docker/dockerfile:1` line on the first line enables the feature. Keep that line at the very top.

## Deploy to Railway

1. Push this folder to a GitHub repo.
2. In Railway, create a **New Project -> Deploy from GitHub repo** and pick the repo. Railway detects the `Dockerfile` automatically.
3. Open the service's **Variables** tab and add:

   | Variable | Required | Description |
   |---|---|---|
   | `LOGIN_PASSWORD` | Yes | Password for the login page. |
   | `LOGIN_USER` | No | Username. Defaults to `admin`. |
   | `SESSION_SECRET` | No | Long random string used to sign session cookies. Set it so logins survive redeploys. |
   | `SESSION_HOURS` | No | How long a login lasts. Defaults to `168` (7 days). |
   | `PORT` | Yes | Set to `8080`. This is the gateway's port. |

   Generate a secret with: `openssl rand -hex 32`

4. Do **not** set `PASSWORD` or `CUSTOM_USER`. Those turn on KasmVNC's own basic-auth prompt on top of the login page.
5. In **Settings -> Networking**, click **Generate Domain**.
6. (Recommended) In **Settings -> Volumes**, attach a volume mounted at `/config` so your Brave profile, bookmarks and logins persist across redeploys.

Open the generated domain and sign in.

## Other environment variables

| Variable | Default | Description |
|---|---|---|
| `PUID` / `PGID` | `1000` | User and group the browser runs as. |
| `TZ` | `Etc/UTC` | Container time zone. |
| `TITLE` | `Brave` | Title shown in the browser tab. |
| `BRAVE_CLI` | `--disable-dev-shm-usage` | Extra command-line flags passed to Brave. |
| `UPSTREAM` | `http://127.0.0.1:3000` | Where the gateway forwards traffic (KasmVNC). |

## Security notes

- **Fail closed:** if `LOGIN_PASSWORD` is empty, the gateway returns a 503 error page instead of exposing the browser.
- **Brute-force protection:** 8 failed logins from one IP locks that IP out for 15 minutes. The counter is in memory, so it resets when the service restarts.
- **Sessions:** HMAC-signed, `HttpOnly`, `SameSite=Lax` cookies, and `Secure` when served over HTTPS. Without `SESSION_SECRET`, a random one is generated on each start and everyone is logged out after a redeploy.
- **WebSocket auth:** the remote-desktop stream is also protected, not just the page.
- **Single user:** there is one username and password. For multiple users, put a proper identity provider in front instead.
- Anyone who signs in gets a full browser running on your server, with whatever accounts you log into inside it. Use a strong password.

## Useful routes

- `/login` : the sign-in page
- `/logout` : ends your session
- `/healthz` : returns `ok` (handy for Railway health checks)

## Customizing the login page

In the `Dockerfile`, edit the HTML/CSS between `COPY <<'EOF_LOGIN' /opt/gateway/login.html` and `EOF_LOGIN`. Keep the `{{ERROR}}` and `{{ERROR_CLASS}}` placeholders, since the server fills them in when a login fails. The form must keep posting `username` and `password` to `/login`.

## Troubleshooting

- **"Browser is starting up" message:** Brave takes a little while to boot. Refresh after a few seconds.
- **"Gateway is not configured" message:** `LOGIN_PASSWORD` isn't set in Railway Variables.
- **Gateway not reachable (502 from Railway):** make sure `PORT=8080` is set and the domain targets that port.
- **Browser crashes or won't launch:** check the deploy logs. Railway can't set `--shm-size`, so `--disable-dev-shm-usage` is already included. If the logs show sandbox errors, add `--no-sandbox` to `BRAVE_CLI` in the `Dockerfile`.
- **Out of memory:** a full browser plus desktop is heavy. Give the service at least 1-2 GB of RAM.
- **A second password prompt appears after login:** remove `PASSWORD` and `CUSTOM_USER` from Railway Variables.
- **Logged out after every deploy:** set `SESSION_SECRET` to a fixed value.

## Local test

```bash
docker build -t brave-gateway .
docker run --rm -p 8080:8080 \
  -e PORT=8080 \
  -e LOGIN_PASSWORD=change-me \
  --shm-size=1g \
  brave-gateway
```

Then open http://localhost:8080 (the `Secure` cookie flag only applies over HTTPS, so plain HTTP works locally).
