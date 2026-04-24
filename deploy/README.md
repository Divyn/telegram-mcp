# Deploying Telegram MCP as a Remote Server

This guide deploys the Telegram MCP server on a VPS (AWS EC2, DigitalOcean, Hetzner, etc.) with Nginx as a reverse proxy, HTTPS via Let's Encrypt, and shared-password HTTP Basic Auth — so Claude / Cursor / any MCP client can connect to it over the internet without needing to run it locally.

See [`commands.md`](../commands.md) in the repo root for the step-by-step commands.

---

## Architecture

```
MCP Client (Claude / Cursor)
        │ HTTPS + Basic Auth
        ▼
  your-subdomain.example.com (A record → server public IP)
        │
        ▼
  Nginx :443   TLS (Let's Encrypt, auto-renewed)
               HTTP Basic Auth (bcrypt shared password)
        │ HTTP proxy_pass 127.0.0.1:8000
        ▼
  Docker container  (telegram-mcp, SSE mode)
        │
        ▼
  Telegram API (via Telethon MTProto)
```

---

## Prerequisites

| What | Minimum |
|------|---------|
| VPS | 1 vCPU / 1 GB RAM (AWS `t3.micro`, Hetzner CX11, DO droplet $4/mo) |
| OS | Ubuntu 22.04/24.04 LTS (Debian works; Amazon Linux 2023 works with minor command swaps — see `commands.md`) |
| Firewall / Security group inbound | **22** (SSH), **80** (HTTP), **443** (HTTPS). Do **NOT** open 8000. |
| Domain | Any domain you control (e.g., a `$1/yr` `.xyz`). You'll point a subdomain at the VPS. |
| Telegram API credentials | `api_id` + `api_hash` from [my.telegram.org](https://my.telegram.org) |
| Session string | Generate locally with `session_string_generator.py` (see repo root) |

---

## The short version

1. **Generate a session string** on your laptop (interactive):
   ```bash
   pip install telethon python-dotenv qrcode
   python session_string_generator.py
   ```
2. **Add a DNS A record**: `mcp` → your VPS public IP.
3. **Open ports 80 and 443** in your cloud firewall / security group.
4. **SSH into the VPS** and run the bootstrap:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/YOUR_USER/telegram-mcp/main/deploy/setup-ec2.sh \
     | sudo REPO_URL=https://github.com/YOUR_USER/telegram-mcp.git bash
   ```
5. **Fill in `.env`** with your Telegram credentials:
   ```bash
   sudo nano /opt/telegram-mcp/.env
   ```
6. **Replace `YOUR_DOMAIN`** in the nginx config:
   ```bash
   sudo sed -i 's/YOUR_DOMAIN/mcp.example.com/g' /etc/nginx/conf.d/telegram-mcp.conf
   sudo nginx -t && sudo systemctl reload nginx
   ```
7. **Set the shared access password**:
   ```bash
   sudo htpasswd -cB /etc/nginx/telegram-mcp.htpasswd team
   # Pick alphanumeric-only — see commands.md for why
   sudo systemctl reload nginx
   ```
8. **Start the MCP**:
   ```bash
   cd /opt/telegram-mcp
   sudo docker compose -f docker-compose.prod.yml up -d --build
   ```
9. **Get TLS**:
   ```bash
   sudo certbot --nginx -d mcp.example.com --redirect
   ```
10. **Test from your laptop**:
    ```bash
    curl -N -u team:YOUR_PASSWORD https://mcp.example.com/sse
    # Should stream:  event: endpoint  data: /messages/?session_id=...
    ```

---

## Claude connector URL

Paste this into **Settings → Connectors → Add custom connector** in Claude:

```
https://team:YOUR_PASSWORD@mcp.example.com/sse
```

The `user:password@` prefix is standard HTTP Basic Auth — Claude sends it as an `Authorization: Basic <base64(user:pass)>` header on every request. Nginx validates it before any traffic reaches the MCP. Share this URL only via password manager, never Slack/email/docs.

---

## Maintenance

| Task | Command |
|------|---------|
| View live logs | `sudo docker compose -f docker-compose.prod.yml logs -f` |
| Restart | `sudo docker compose -f docker-compose.prod.yml restart` |
| Update code | `git -C /opt/telegram-mcp pull && sudo docker compose -f docker-compose.prod.yml up -d --build --force-recreate` |
| Rotate password | `sudo htpasswd -B /etc/nginx/telegram-mcp.htpasswd team && sudo systemctl reload nginx` |
| Add a user | `sudo htpasswd -B /etc/nginx/telegram-mcp.htpasswd alice` (no `-c`) |
| Remove a user | `sudo htpasswd -D /etc/nginx/telegram-mcp.htpasswd alice && sudo systemctl reload nginx` |
| Renew TLS | Auto-scheduled by certbot. Dry-run: `sudo certbot renew --dry-run` |

---

## Security notes

- `.env` contains secrets — stays out of git (already in `.gitignore`).
- SSH private keys (`*.pem`, `*.key`) — also gitignored.
- The MCP container is bound to `127.0.0.1:8000` on the host. Only nginx is exposed publicly.
- MCP's built-in DNS-rebinding protection is disabled in `main.py` because nginx sets `Host: localhost` when proxying. Host/origin discipline is enforced at the nginx + TLS + Basic Auth layer instead. See comments in `main.py` near the `TransportSecuritySettings` import.
- Rotate the Telegram session string if you suspect compromise (regenerate locally, update `.env` on the server, restart the container).
