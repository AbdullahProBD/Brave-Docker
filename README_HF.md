---
title: Brave-Docker
emoji: 🚀
colorFrom: purple
colorTo: blue
sdk: docker
app_port: 7860
pinned: true
license: mit
secrets:
  - LOGIN_PASSWORD
  - SESSION_SECRET
---

# Brave-Docker for Hugging Face Spaces

This repository is designed to run a Brave browser behind a custom login gateway inside a Docker-based Hugging Face Space.

## Why this works on Hugging Face

The app is split into two parts:

- a Node.js gateway that exposes the public UI on port 7860
- a Brave/KasmVNC backend running internally on port 3000

The gateway authenticates users before proxying traffic to the browser.

## Required Space settings

Set these as Space secrets or environment variables before launching:

```bash
PORT=7860
LOGIN_PASSWORD=your-strong-password
SESSION_SECRET=generate-a-random-secret
```

Optional values:

```bash
LOGIN_USER=admin
SESSION_HOURS=168
BRAVE_CLI=--disable-dev-shm-usage --no-sandbox
```

## Space configuration

Use a Docker Space and keep the app listening on port 7860.

The repo's Docker image already exposes 8080 by default, but Hugging Face Spaces expects the app to listen on 7860. In the Space environment, set `PORT=7860` so the gateway binds to the correct port.

## Important notes

- This is not a normal static web app. It launches a real browser inside a container.
- A Space must have enough memory available for the browser and VNC stack.
- Some browser sandbox and desktop features may behave differently inside a Space environment.
- If the browser fails to boot, check the Space logs for Brave/KasmVNC startup issues.

## Default login

Once the app is running, open the Space URL and sign in with:

- username: `admin`
- password: whatever you configured in `LOGIN_PASSWORD`

## Security

Use a strong password and a long random `SESSION_SECRET`.

Do not expose the app without authentication. Anyone who logs in controls a full browser session inside the container.

## Troubleshooting

### 502 / browser not loading

- Make sure `PORT=7860` is set
- Make sure `LOGIN_PASSWORD` is set
- Ensure the container is still starting and Brave is not crashing

### Login page never loads

- Check the Space logs for startup errors
- Confirm the Node gateway is actually starting on `:7860`

### Browser starts, but the page is blank

- The browser may still be initializing
- Refresh after a few seconds
- Ensure the upstream target is reachable internally on `http://127.0.0.1:3000`

## Source repository

https://github.com/AbdullahProBD/Brave-Docker
