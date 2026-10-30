FROM linuxserver/brave:latest

# ---------------------------------------------------------------------------
# Custom login gateway
#   Railway -> gateway (:8080, custom login page) -> KasmVNC/Brave (:3000, internal only)
#
# Set these in Railway -> your service -> Variables (never hardcode them here):
#   LOGIN_PASSWORD  (required) password for the login page
#   LOGIN_USER      (optional) username, defaults to "admin"
#   SESSION_SECRET  (optional) long random string so sessions survive redeploys
#   PORT            set to 8080 (the gateway's port)
#
# Do NOT set PASSWORD / CUSTOM_USER: those enable KasmVNC's own basic-auth prompt
# on top of this login page.
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

# Gateway app
COPY gateway/package.json /opt/gateway/package.json
RUN cd /opt/gateway && npm install --omit=dev
COPY gateway/server.js gateway/login.html /opt/gateway/

# Run the gateway as an s6 service next to the browser
COPY custom-services.d/gateway /custom-services.d/gateway
RUN chmod +x /custom-services.d/gateway

# Only the gateway is public. KasmVNC stays on 3000 inside the container.
EXPOSE 8080

# Persistent profile: attach a Railway Volume mounted at /config
# (Railway doesn't allow the VOLUME instruction in Dockerfiles).
