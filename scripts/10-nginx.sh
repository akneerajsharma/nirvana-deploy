#!/usr/bin/env bash
# Renders the vhosts for $DOMAIN and obtains Let's Encrypt certificates.
# Run once, after DNS has propagated:  sudo bash scripts/10-nginx.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo." >&2
  exit 1
fi

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; source "$DEPLOY_DIR/.env"; set +a

: "${DOMAIN:?DOMAIN must be set in deploy/.env}"
CERT_EMAIL="${CERT_EMAIL:-${MAIL_FROM_ADDRESS:-}}"
: "${CERT_EMAIL:?Set CERT_EMAIL (or MAIL_FROM_ADDRESS) in deploy/.env}"

echo "==> Rendering vhosts for $DOMAIN"
# Only ${DOMAIN} is substituted — Nginx's own $host, $uri, $remote_addr etc.
# must survive untouched.
DOMAIN="$DOMAIN" envsubst '${DOMAIN}' \
  < "$DEPLOY_DIR/nginx/nirvana.conf.template" \
  > /etc/nginx/sites-available/nirvana.conf

ln -sf /etc/nginx/sites-available/nirvana.conf /etc/nginx/sites-enabled/nirvana.conf
rm -f /etc/nginx/sites-enabled/default

# app.$DOMAIN's root must exist before Nginx will start cleanly.
mkdir -p /opt/nirvana/app-web
[[ -f /opt/nirvana/app-web/index.html ]] || \
  echo '<!doctype html><title>Nirvana</title><p>Portal build not deployed yet.</p>' \
    > /opt/nirvana/app-web/index.html

nginx -t
systemctl reload nginx

echo "==> Requesting certificates"
# --nginx rewrites the server blocks above in place, adding listen 443 ssl,
# the cert paths, and an 80 -> 443 redirect.
certbot --nginx \
  -d "$DOMAIN" -d "www.$DOMAIN" -d "api.$DOMAIN" -d "app.$DOMAIN" \
  --non-interactive --agree-tos --redirect -m "$CERT_EMAIL"

nginx -t
systemctl reload nginx

# certbot's packaged systemd timer handles renewal; confirm it is armed.
systemctl list-timers snap.certbot.renew.service certbot.timer --all | head -5 || true

echo "==> Done. https://$DOMAIN, https://api.$DOMAIN, https://app.$DOMAIN are live."
echo "    Re-running this script after editing the template is safe."
