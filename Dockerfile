# syntax=docker/dockerfile:1
# =============================================================================
# Brave Browser in a container, behind a custom login gateway.
#
#   Internet -> gateway :8080 (login page + sessions) -> KasmVNC/Brave :3000
#
# Build from source:  docker build -t brave-docker .
# Or use:             docker compose up -d --build
# =============================================================================
FROM linuxserver/brave:latest

LABEL org.opencontainers.image.title="Brave-Docker" \
      org.opencontainers.image.description="Brave browser streamed over the web behind a custom login gateway" \
      org.opencontainers.image.source="https://github.com/AbdullahProBD/Brave-Docker" \
      org.opencontainers.image.licenses="MIT"

ENV PUID=1000 \
    PGID=1000 \
    TZ=Etc/UTC \
    TITLE="Brave" \
    BRAVE_CLI="--disable-dev-shm-usage --no-sandbox"

# Node.js runtime for the gateway
RUN apt-get update \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Gateway dependencies (separate layer so code changes don't reinstall them)
WORKDIR /opt/gateway
COPY gateway/package*.json ./
RUN npm install --omit=dev --no-audit --no-fund && npm cache clean --force

# Gateway source + login page
COPY gateway/server.js gateway/login.html ./

# s6 service that starts the gateway next to the browser
COPY rootfs/ /
RUN chmod +x /custom-services.d/gateway

# Only the gateway is public. KasmVNC stays on :3000 inside the container.
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${PORT:-8080}/healthz" || exit 1

# Persistent profile: mount a volume at /config
# (Railway does not allow the VOLUME instruction; attach one in its dashboard.)
