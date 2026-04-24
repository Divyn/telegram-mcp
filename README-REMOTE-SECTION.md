<!--
  Paste this section into the upstream README.md after the "Running with
  Docker" section, before "Configuration for Claude & Cursor".
-->

---

## ☁️ Remote Deployment (this fork's addition)

This fork adds everything needed to run the MCP as a **remote, HTTPS-protected, password-gated SSE endpoint** on a cloud VPS — so Claude (or Cursor, or any MCP client) can connect to it over the internet instead of running it locally.

**Architecture:**

```
Claude / MCP client
      │ HTTPS + Basic Auth
      ▼
your-subdomain.example.com (A → VPS public IP)
      │
      ▼
nginx :443   TLS via Let's Encrypt (auto-renewed)
             HTTP Basic Auth (shared password, bcrypt)
      │ HTTP
      ▼
uvicorn :8000   telegram-mcp container (SSE transport)
      │
      ▼
Telegram MTProto   via Telethon
```

**What this fork adds on top of upstream:**

- `Dockerfile.prod` — production image, pinned deps, non-root user.
- `docker-compose.prod.yml` — compose file with restart policy and env loading, binding MCP to `127.0.0.1:8000` so only nginx is publicly reachable.
- `nginx/nginx.conf` — reverse-proxy template with SSE-safe timeouts (`proxy_buffering off`, `proxy_read_timeout 3600s`), HTTP Basic Auth, and a `/health` exemption for monitoring.
- `deploy/setup-ec2.sh` — first-time provisioning helper for Ubuntu VPS.
- `deploy/README.md` — quick-start guide.
- `commands.md` — **the full step-by-step deploy and redeploy guide** with troubleshooting entries for every real issue encountered in the wild.
- `main.py` patch — disables the MCP SDK's DNS-rebinding Host-header check, which rejects `Host: localhost` from nginx and breaks reverse-proxy deployments. Safe here because host/origin are enforced at the nginx + TLS + Basic Auth layer.

**Security model:**

1. **TLS on port 443** via Let's Encrypt (certbot `--nginx`, auto-renewed by systemd timer).
2. **HTTP Basic Auth** with a bcrypt-hashed shared password in `/etc/nginx/telegram-mcp.htpasswd`. Every request — SSE `GET /sse`, POST `/messages/...` — must carry `Authorization: Basic <base64(user:pass)>`. Without it: `401`.
3. **Cloud firewall / security group:** only ports 80 + 443 open to the world. Port 8000 (raw MCP) is never exposed — only reachable from localhost on the box.

**The Claude connector URL is of the form:**

```
https://team:YOUR_PASSWORD@your-subdomain.example.com/sse
```

Claude's custom connector dialog accepts credentials embedded in the URL; nginx validates them before any traffic reaches the MCP. Share this URL only via password manager.

**To deploy from scratch**, see [`commands.md`](commands.md) or [`deploy/README.md`](deploy/README.md). At a high level: DNS A record → open 80/443 → install Docker + nginx → drop nginx config → certbot for TLS → htpasswd for password → `docker-compose up` → paste URL into Claude.

**Gotchas encountered in the wild** (all documented in `commands.md`):

- Amazon Linux ships a broken `docker-buildx` plugin (wrong arch). Remove it and build with `DOCKER_BUILDKIT=0` to fall back to the classic builder.
- Cloudflare quick tunnels (`*.trycloudflare.com`) **buffer SSE** and don't work for this transport — use a real domain + Let's Encrypt instead.
- Cloud firewalls default to no HTTPS: remember to open **443** (not just 80).
- Passwords with `&`, `!`, `@`, `#` break in shells and URLs — use alphanumeric-only (`openssl rand -base64 24 | tr -d '+/=' | head -c 32`).
