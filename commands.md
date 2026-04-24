# Remote Deployment Commands

Step-by-step commands for deploying the Telegram MCP as a remote, HTTPS-protected, password-gated SSE endpoint on a cloud VPS.

> Assumed target: Amazon Linux 2023 or Ubuntu 22.04/24.04 on a VPS with a
> public IP. Replace `YOUR_EC2_IP`, `YOUR_DOMAIN` (e.g. `mcp.example.com`),
> `YOUR_SSH_KEY.pem`, and `YOUR_EMAIL@example.com` with your own values.
>
> End architecture:
> `Claude → HTTPS + Basic Auth → nginx :443 → http://127.0.0.1:8000 → MCP`

---

## First-time setup

### 1. Point DNS at the server

In your DNS provider, add:

```
Type:  A
Host:  mcp                    (or any subdomain you want)
Value: YOUR_EC2_IP
TTL:   Automatic / 300
```

Verify from your laptop:

```bash
dig +short mcp.example.com
# should print: YOUR_EC2_IP
```

### 1b. Open ports 80 and 443 in your cloud firewall

**Easy to forget — produces "connection timed out" errors that look like nginx
problems but aren't.**

**AWS EC2 console:** EC2 → Instances → click instance → **Security** tab →
click the SG name → **Edit inbound rules → Add rule** (twice):

- Type: `HTTP`,  Port: `80`,  Source: `0.0.0.0/0` (and `::/0` for IPv6)
- Type: `HTTPS`, Port: `443`, Source: `0.0.0.0/0` (and `::/0` for IPv6)

Or via AWS CLI:

```bash
SG=<your-security-group-id>   # e.g. sg-0abc1234
aws ec2 authorize-security-group-ingress --group-id $SG --protocol tcp --port 80  --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SG --protocol tcp --port 443 --cidr 0.0.0.0/0
```

DigitalOcean / Hetzner / Linode: use their cloud-firewall UI to allow 80 + 443 inbound.

**Do NOT open port 8000** to the world. That's the raw MCP port — it must stay
reachable only from localhost / the Docker bridge so everything goes through
nginx (TLS + auth + host/origin discipline).

Sanity-check from your laptop:

```bash
nc -zv mcp.example.com 80
nc -zv mcp.example.com 443
# both should print "succeeded" or "open"
```

### 2. Upload project from laptop (run in project root)

```bash
rsync -avz --progress \
  --exclude='.git' \
  --exclude='__pycache__' \
  --exclude='*.pyc' \
  --exclude='*.session' \
  --exclude='*.pem' \
  --exclude='.env' \
  -e "ssh -i YOUR_SSH_KEY.pem" \
  ./ \
  ec2-user@YOUR_EC2_IP:/home/ec2-user/telegram-mcp/
```

(Use `ubuntu@YOUR_EC2_IP` if the server is Ubuntu.)

Copy `.env` separately (contains API secrets):

```bash
scp -i YOUR_SSH_KEY.pem .env ec2-user@YOUR_EC2_IP:/home/ec2-user/telegram-mcp/.env
```

### 3. SSH in

```bash
ssh -i YOUR_SSH_KEY.pem ec2-user@YOUR_EC2_IP
```

### 4. Install Docker, Compose v1, Nginx (on the server)

Amazon Linux 2023:

```bash
sudo yum update -y
sudo yum install -y docker git nginx
sudo service docker start
sudo systemctl enable docker
sudo usermod -aG docker ec2-user
newgrp docker

# Docker Compose v1 — this repo uses `docker-compose` (hyphenated)
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
  -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
docker-compose version
```

Ubuntu 22.04/24.04:

```bash
sudo apt-get update -y
sudo apt-get install -y docker.io docker-compose-plugin nginx git apache2-utils
sudo usermod -aG docker ubuntu
newgrp docker
```

**If the VPS ships a broken `docker-buildx` plugin** (we hit this on Amazon
Linux — produces `exec format error` during builds), remove it:

```bash
sudo rm -f /usr/lib/docker/cli-plugins/docker-buildx
```

### 5. Install nginx config

```bash
sudo cp ~/telegram-mcp/nginx/nginx.conf /etc/nginx/conf.d/telegram-mcp.conf
sudo sed -i 's/YOUR_DOMAIN/mcp.example.com/g' /etc/nginx/conf.d/telegram-mcp.conf
sudo nginx -t && sudo systemctl enable nginx && sudo systemctl start nginx
```

### 6. Get TLS certificate (Let's Encrypt, free, auto-renewing)

Amazon Linux 2023:

```bash
sudo dnf install -y certbot python3-certbot-nginx
```

Ubuntu: `sudo apt-get install -y certbot python3-certbot-nginx`.

```bash
sudo certbot --nginx \
  -d mcp.example.com \
  --non-interactive --agree-tos \
  -m YOUR_EMAIL@example.com \
  --redirect
```

Certbot edits the nginx config, adds a `listen 443 ssl` block, redirects HTTP
→ HTTPS, and schedules auto-renewal via systemd timer (`systemctl list-timers
| grep certbot` to confirm).

### 6b. Protect the endpoint with a shared password (HTTP Basic Auth)

Create the password file on the server:

```bash
# Amazon Linux:
sudo dnf install -y httpd-tools
# Ubuntu:
sudo apt-get install -y apache2-utils

sudo htpasswd -cB /etc/nginx/telegram-mcp.htpasswd team
# You'll be prompted to enter the password twice.
```

**Pick an alphanumeric-only password.** Characters like `& ! @ # / : ? %` are
special in shells and URLs — they break `curl` and embedded-credential URLs
in Claude. Generate a safe one locally:

```bash
openssl rand -base64 24 | tr -d '+/=' | head -c 32
# prints a 32-char alphanumeric string, e.g. H9KmqGx0p2YaJvNbT1dCfEz4wRs8uLeo
```

The `nginx/nginx.conf` template in this repo already has the `auth_basic`
directives. If your deployed config doesn't (e.g., certbot edited it in
place), patch it with this **idempotent** script — it strips any existing
auth_basic lines first, so re-running is safe:

```bash
# 1. Strip any existing auth_basic lines
sudo sed -i '/auth_basic/d' /etc/nginx/conf.d/telegram-mcp.conf

# 2. Insert directives once — anchor is "4 spaces + keepalive_timeout",
#    which matches only the active server block (not commented templates).
sudo sed -i '/^    keepalive_timeout.*3600s;/a\
    auth_basic           "Telegram MCP (restricted)";\
    auth_basic_user_file /etc/nginx/telegram-mcp.htpasswd;' /etc/nginx/conf.d/telegram-mcp.conf

# 3. Exempt /health so monitoring works
sudo sed -i '/^    location \/health {/a\
        auth_basic off;' /etc/nginx/conf.d/telegram-mcp.conf

# 4. Confirm exactly 3 auth_basic lines
grep -n 'auth_basic' /etc/nginx/conf.d/telegram-mcp.conf

# 5. Test and reload
sudo nginx -t && sudo systemctl reload nginx
```

Smoke-test from your laptop — this should return `401 Unauthorized`:

```bash
curl -I https://mcp.example.com/sse
```

And this should stream `event: endpoint`:

```bash
curl -N -u 'team:YOUR_PASSWORD' https://mcp.example.com/sse
```

Use **single quotes** around `team:YOUR_PASSWORD` so your shell doesn't
interpret any special characters.

### 7. Build and start the MCP container

```bash
cd ~/telegram-mcp
sudo DOCKER_BUILDKIT=0 COMPOSE_DOCKER_CLI_BUILD=0 \
  docker-compose -f docker-compose.prod.yml build --no-cache
sudo docker-compose -f docker-compose.prod.yml up -d
```

Verify:

```bash
sudo docker ps                    # container should be Up
sudo docker logs telegram-mcp     # look for "Uvicorn running on http://0.0.0.0:8000"
```

### 8. End-to-end smoke test

On the server:

```bash
curl -N http://localhost:8000/sse   # direct to MCP, bypasses nginx + auth
```

From laptop (full HTTPS + auth chain):

```bash
curl -N -u 'team:YOUR_PASSWORD' https://mcp.example.com/sse
```

Expected (stream stays open):

```
event: endpoint
data: /messages/?session_id=<hex>
```

### 9. Add to Claude as a custom connector

**Settings → Connectors → Add custom connector**

- **Name:** `Telegram`
- **URL:** `https://team:YOUR_PASSWORD@mcp.example.com/sse`

The `user:password@` prefix is standard HTTP Basic Auth. Claude sends it as
an `Authorization: Basic <base64(user:pass)>` header on every request. Nginx
validates it before any traffic hits the MCP container.

**Do not paste this URL into Slack, email, or docs** — it contains the
password. Share it via password manager only.

---

## Redeploy after a code change

From laptop (project root):

```bash
rsync -avz --progress \
  --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' \
  --exclude='*.session' --exclude='*.pem' --exclude='.env' \
  -e "ssh -i YOUR_SSH_KEY.pem" \
  ./ \
  ec2-user@YOUR_EC2_IP:/home/ec2-user/telegram-mcp/
```

On the server:

```bash
cd ~/telegram-mcp
sudo DOCKER_BUILDKIT=0 COMPOSE_DOCKER_CLI_BUILD=0 \
  docker-compose -f docker-compose.prod.yml build --no-cache
sudo docker-compose -f docker-compose.prod.yml up -d --force-recreate
sudo docker logs -f telegram-mcp
```

The `--force-recreate` flag is important — without it, `up -d` may keep the
old container running if Compose thinks nothing changed. Look for a **fresh
boot timestamp** in the logs to confirm the new image is live.

---

## Useful maintenance commands (on the server)

```bash
# Live logs
sudo docker logs -f telegram-mcp

# Restart without rebuilding
sudo docker-compose -f docker-compose.prod.yml restart

# Stop
sudo docker-compose -f docker-compose.prod.yml down

# Confirm auto-restart survives reboots
sudo docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' telegram-mcp
# Should print: unless-stopped

# Nginx
sudo nginx -t                           # test config
sudo systemctl reload nginx             # apply config changes
sudo tail -f /var/log/nginx/error.log

# TLS cert
sudo certbot certificates               # list active certs + expiry
sudo certbot renew --dry-run            # test renewal flow

# Add a new user to auth
sudo htpasswd -B /etc/nginx/telegram-mcp.htpasswd alice
sudo systemctl reload nginx

# Remove a user
sudo htpasswd -D /etc/nginx/telegram-mcp.htpasswd alice
sudo systemctl reload nginx

# Rotate the team password
sudo htpasswd -B /etc/nginx/telegram-mcp.htpasswd team
sudo systemctl reload nginx
```

---

## Troubleshooting

**`failed to fetch metadata: fork/exec /usr/lib/docker/cli-plugins/docker-buildx: exec format error`**
Wrong-arch buildx binary. Delete it:
`sudo rm -f /usr/lib/docker/cli-plugins/docker-buildx` and rebuild with
`DOCKER_BUILDKIT=0 COMPOSE_DOCKER_CLI_BUILD=0 docker-compose ... build`.

**`Invalid Host header: localhost` / `421 Misdirected Request`**
MCP's DNS-rebinding protection rejected the proxied Host header. The patched
`main.py` disables it via `TransportSecuritySettings(enable_dns_rebinding_protection=False)`
plus class-level overrides of `TransportSecurityMiddleware`. If this reappears,
confirm the container was actually rebuilt (fresh timestamp in logs).

**`sudo docker compose` says `unknown shorthand flag: 'f'`**
Box has Compose v1. Use hyphenated `docker-compose` (not `docker compose`).

**Container won't start after reboot**
Check restart policy — `restart: unless-stopped` should be set in
`docker-compose.prod.yml`.

**Certbot says "domain DNS doesn't resolve"**
`dig +short mcp.example.com` from your laptop. Should print your server IP.
If not, wait a few more minutes for DNS to propagate.

**Claude connector says "URL must start with https"**
You pasted `http://...`. Use `https://team:PASSWORD@mcp.example.com/sse`.

**`curl: (28) Failed to connect ... port 443 ... Couldn't connect to server`**
Port 443 (or 80) is not open in the cloud firewall / security group. Confirm
nginx IS listening on the box: `sudo ss -tlnp | grep -E ':80|:443'`. If nginx
shows up but your laptop times out, it's the firewall — re-run step 1b.

**`401 Unauthorized` on every request**
Password wrong or htpasswd file missing. Regenerate with
`sudo htpasswd -B /etc/nginx/telegram-mcp.htpasswd team`, reload nginx, and
use the new password in the connector URL.

**Connector added, but Claude shows no tools / errors**
Confirm the SSE stream is alive:
```bash
curl -N -u 'team:PASSWORD' https://mcp.example.com/sse
```
Must print `event: endpoint` and stay open. If that works but Claude doesn't
see tools, check the container logs (`sudo docker logs -f telegram-mcp`)
while you reload the connector — you should see `GET /sse HTTP/1.1 200 OK`
followed by `POST /messages/ HTTP/1.1 202 Accepted` lines.

**Cloudflare quick tunnels (`*.trycloudflare.com`) don't work**
Cloudflare buffers SSE responses on quick tunnels, which breaks MCP's
transport. Use a real domain + Let's Encrypt, or a **named** Cloudflare
tunnel (requires a Cloudflare account + domain on Cloudflare DNS).
