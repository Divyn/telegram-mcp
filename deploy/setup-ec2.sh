#!/usr/bin/env bash
# deploy/setup-ec2.sh
#
# One-shot bootstrap for a fresh Ubuntu 22.04/24.04 EC2 instance.
# Run as root or with sudo:  sudo REPO_URL=https://github.com/YOUR_USER/telegram-mcp.git bash setup-ec2.sh
#
# After this script finishes:
#   1. Edit /opt/telegram-mcp/.env with your Telegram credentials
#   2. Edit /etc/nginx/conf.d/telegram-mcp.conf — replace YOUR_DOMAIN
#   3. Run:  cd /opt/telegram-mcp && docker compose -f docker-compose.prod.yml up -d
#   4. (Optional HTTPS)  sudo certbot --nginx -d YOUR_DOMAIN

set -euo pipefail

APP_DIR="/opt/telegram-mcp"
REPO_URL="${REPO_URL:-https://github.com/YOUR_USER/telegram-mcp.git}"
NGINX_SITE="telegram-mcp"

echo "==> Updating system packages..."
apt-get update -y && apt-get upgrade -y

echo "==> Installing dependencies (git, nginx, certbot, curl, apache2-utils for htpasswd)..."
apt-get install -y git nginx certbot python3-certbot-nginx curl ufw apache2-utils

echo "==> Installing Docker..."
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
fi

echo "==> Installing Docker Compose plugin..."
apt-get install -y docker-compose-plugin

echo "==> Cloning / updating repository..."
if [ -d "$APP_DIR/.git" ]; then
    git -C "$APP_DIR" pull
else
    git clone "$REPO_URL" "$APP_DIR"
fi

echo "==> Creating .env from example (if not present)..."
if [ ! -f "$APP_DIR/.env" ]; then
    cp "$APP_DIR/.env.example" "$APP_DIR/.env"
    echo ""
    echo "  *** ACTION REQUIRED ***"
    echo "  Edit $APP_DIR/.env and fill in:"
    echo "    TELEGRAM_API_ID=..."
    echo "    TELEGRAM_API_HASH=..."
    echo "    TELEGRAM_SESSION_STRING=..."
    echo ""
fi

echo "==> Installing Nginx site config..."
cp "$APP_DIR/nginx/nginx.conf" "/etc/nginx/conf.d/$NGINX_SITE.conf"
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

nginx -t
systemctl enable nginx
systemctl reload nginx

echo "==> Configuring UFW firewall..."
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw --force enable

echo ""
echo "============================================================"
echo "  Bootstrap complete!"
echo ""
echo "  Next steps:"
echo "  1. Edit $APP_DIR/.env with your Telegram credentials"
echo "  2. Edit /etc/nginx/conf.d/$NGINX_SITE.conf"
echo "       Replace YOUR_DOMAIN with your domain or public IP"
echo "     Then reload nginx:  sudo systemctl reload nginx"
echo ""
echo "  3. (Recommended) Set the shared access password:"
echo "       sudo htpasswd -cB /etc/nginx/telegram-mcp.htpasswd team"
echo "       sudo systemctl reload nginx"
echo ""
echo "  4. Start the MCP server:"
echo "       cd $APP_DIR"
echo "       sudo docker compose -f docker-compose.prod.yml up -d --build"
echo ""
echo "  5. (Optional) Get a free TLS cert:"
echo "       sudo certbot --nginx -d YOUR_DOMAIN"
echo ""
echo "  6. Test health endpoint:"
echo "       curl http://YOUR_DOMAIN/health"
echo "============================================================"
