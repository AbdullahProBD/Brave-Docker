<div align="center">

# Brave-Docker

**Brave browser in your browser. Self-hosted, secured behind a custom login page.**

[![Docker](https://img.shields.io/badge/docker-ready-2496ED?logo=docker&logoColor=white)](#quick-start)
[![Railway](https://img.shields.io/badge/deploy-Railway-0B0D0E?logo=railway&logoColor=white)](#deploy-to-railway)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

</div>

Runs [`linuxserver/brave`](https://docs.linuxserver.io/images/docker-brave/) streamed to any web browser through KasmVNC, protected by a small Node.js gateway that serves a fully custom, restylable login page. Build it from source on your own machine or server with a single command, or deploy it to Railway.

```
Internet ──> gateway :8080 (login page + sessions) ──> KasmVNC / Brave :3000 (internal only)
```

KasmVNC's built-in prompt is plain HTTP basic auth and cannot be restyled, so the gateway handles login and only proxies traffic (including the WebSocket stream) after you sign in.

## Features

- Custom, responsive login page with dark/light mode
- Signed `HttpOnly` session cookies, with `Secure` over HTTPS
- Brute-force lockout (8 failures per IP locks it out for 15 minutes)
- WebSocket stream is authenticated too, not just the page
- Fails closed: no password configured means no access
- Built from source with Docker Compose, a Makefile, or plain `docker build`
- Railway-ready, with health check and config included
- Persistent browser profile via a Docker volume

## Requirements

- [Docker](https://docs.docker.com/get-docker/) 20.10+ with the Compose plugin (`docker compose`)
- 2 GB RAM recommended (a full browser plus desktop is heavy)
- `git` (and optionally `make` and `openssl`)

## Quick start

```bash
# 1. Clone
git clone https://github.com/AbdullahProBD/Brave-Docker.git
cd Brave-Docker

# 2. Configure
cp .env.example .env
sed -i "s/^SESSION_SECRET=.*/SESSION_SECRET=$(openssl rand -hex 32)/" .env
nano .env             # set LOGIN_PASSWORD

# 3. Build from source and run
docker compose up -d --build
```

Open **http://localhost:8080** and sign in with `admin` and the password you set.

> Have `make`? Run `make setup` instead of step 2, then `make up`. Install it with `apt install -y make` if missing.

## Commands

| Command | What it does |
|---|---|
| `make setup` | Create `.env` from the template with a random `SESSION_SECRET` |
| `make up` | Build (if needed) and start in the background |
| `make down` | Stop and remove the container (data is kept) |
| `make restart` | Restart the container |
| `make logs` | Follow the logs |
| `make status` | Show container status and health |
| `make shell` | Open a shell inside the container |
| `make secret` | Print a random 64-character secret |
| `make clean` | Remove container, image **and all data** |

Without Make:

```bash
docker compose up -d --build     # start
docker compose logs -f           # logs
docker compose down              # stop
docker compose down -v           # stop and delete the browser profile
```

### Plain Docker (no Compose)

```bash
docker build -t brave-docker .
docker run -d --name brave-docker \
  -p 8080:8080 \
  -e PORT=8080 \
  -e LOGIN_PASSWORD='change-me' \
  -e SESSION_SECRET="$(openssl rand -hex 32)" \
  -e BRAVE_CLI='--disable-dev-shm-usage --no-sandbox' \
  -v brave-config:/config \
  --shm-size=1g \
  --restart unless-stopped \
  brave-docker
```

### Updating

```bash
git pull
docker compose build --pull
docker compose up -d
```

## Configuration

Set these in `.env` (Compose) or in your platform's variables (Railway, etc.).

| Variable | Required | Default | Description |
|---|---|---|---|
| `LOGIN_PASSWORD` | **Yes** | none | Password for the login page |
| `LOGIN_USER` | No | `admin` | Username |
| `SESSION_SECRET` | Recommended | random per start | Signs session cookies. Set it so logins survive restarts |
| `SESSION_HOURS` | No | `168` | Login lifetime in hours (7 days) |
| `HOST_PORT` | No | `8080` | Port exposed on your machine (Compose only) |
| `PORT` | Railway only | `8080` | Gateway listening port |
| `PUID` / `PGID` | No | `1000` | User and group the browser runs as |
| `TZ` | No | `Etc/UTC` | Container time zone |
| `TITLE` | No | `Brave` | Browser tab title |
| `BRAVE_CLI` | No | `--disable-dev-shm-usage --no-sandbox` | Extra flags passed to Brave |
| `UPSTREAM` | No | `http://127.0.0.1:3000` | Where the gateway forwards traffic |

> Do **not** set `PASSWORD` or `CUSTOM_USER`. Those enable KasmVNC's own basic-auth prompt on top of the login page.

## Deploy to Railway

1. Fork or push this repository to GitHub.
2. In Railway: **New Project → Deploy from GitHub repo** and select it. Railway detects the `Dockerfile` (and reads `railway.json`).
3. Open **Variables** and add `LOGIN_PASSWORD`, `SESSION_SECRET` and `PORT=8080`.
4. **Settings → Networking → Generate Domain**.
5. **Settings → Volumes**: attach a volume mounted at `/config` to keep your profile, bookmarks and logins.

## Project structure

```
.
├── Dockerfile                      # Image build (Brave + Node gateway)
├── docker-compose.yml              # One-command local/server deployment
├── Makefile                        # Shortcuts for common tasks
├── railway.json                    # Railway build and health check config
├── .env.example                    # Configuration template
├── gateway/
│   ├── server.js                   # Auth, sessions, rate limiting, reverse proxy
│   ├── login.html                  # Login page (edit to restyle)
│   └── package.json
└── rootfs/
    └── custom-services.d/gateway   # s6 service that starts the gateway
```

## Customizing the login page

Edit `gateway/login.html` and rebuild (`make up`). Keep the `{{ERROR}}` and `{{ERROR_CLASS}}` placeholders, and keep the form posting `username` and `password` to `/login`.

## Routes

| Route | Purpose |
|---|---|
| `/login` | Sign-in page |
| `/logout` | End the session |
| `/healthz` | Returns `ok` (used for health checks) |

## Security notes

- Always use a strong `LOGIN_PASSWORD`. Anyone who signs in controls a full browser on your server and any accounts logged into it.
- Put the service behind HTTPS (Railway does this automatically; for your own server use Caddy, Nginx or Traefik) so the session cookie is flagged `Secure`.
- The brute-force counter is in memory and resets on restart.
- There is a single user. For multiple users, put a proper identity provider in front.
- Never commit `.env`. It is already in `.gitignore`.

## Troubleshooting

| Problem | Fix |
|---|---|
| `LOGIN_PASSWORD` error on `docker compose up` | Create `.env` and set `LOGIN_PASSWORD` |
| "Browser is starting up" | Brave needs a few seconds to boot. Refresh |
| "Gateway is not configured" | `LOGIN_PASSWORD` is empty |
| 502 on Railway | Set `PORT=8080` and make sure the domain targets it |
| Browser crashes or won't launch | Check `docker compose logs -f`. `--no-sandbox` is already enabled by default |
| Out of memory | Give the host or service at least 1-2 GB RAM |
| Second password prompt after login | Remove `PASSWORD` and `CUSTOM_USER` |
| Logged out after every restart | Set a fixed `SESSION_SECRET` |
| Port 8080 already in use | Set `HOST_PORT=8081` in `.env` |

## License

[MIT](LICENSE) © AbdullahProBD
