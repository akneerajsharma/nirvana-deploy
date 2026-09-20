#!/usr/bin/env bash
# One-time host preparation for a fresh Ubuntu 24.04 LTS EC2 instance.
# Run as the default `ubuntu` user:  sudo bash scripts/00-bootstrap.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo." >&2
  exit 1
fi

TARGET_USER="${SUDO_USER:-ubuntu}"

echo "==> Updating base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y
apt-get install -y ca-certificates curl gnupg git rsync gettext-base unattended-upgrades

# A 2 GB instance runs out of memory part-way through `next build` and the
# OOM killer takes the whole build down with a confusing exit 137. Swap makes
# a t3.small viable; it is not a substitute for RAM under steady load.
if ! swapon --show | grep -q '/swapfile'; then
  FREE_MB=$(df --output=avail -m / | tail -1 | tr -d ' ')
  SWAP_MB=4096
  # Never take more than a third of what is free. A default 8 GB root volume
  # cannot spare 4 GB: the swapfile lands the filesystem at ~99% and every
  # later docker build fails on no space left on device.
  if (( FREE_MB < SWAP_MB * 3 )); then SWAP_MB=$(( FREE_MB / 3 )); fi

  if (( SWAP_MB < 1024 )); then
    echo "!!  Only ${FREE_MB}MB free on / — skipping swapfile."
    echo "!!  Expand the root volume to at least 30 GB, then re-run this script."
  else
    echo "==> Creating ${SWAP_MB}M swapfile (${FREE_MB}MB free on /)"
    fallocate -l "${SWAP_MB}M" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    sysctl -w vm.swappiness=10
    grep -q '^vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
  fi
fi

echo "==> Installing Docker Engine + Compose plugin"
install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
fi
cat > /etc/apt/sources.list.d/docker.list <<SRC
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable
SRC
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
usermod -aG docker "$TARGET_USER"

# Docker's json-file driver has no default size cap; a chatty pino logger will
# quietly fill the root volume over a few weeks.
cat > /etc/docker/daemon.json <<'DAEMON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "5" }
}
DAEMON
systemctl restart docker

echo "==> Installing Nginx + certbot"
apt-get install -y nginx certbot python3-certbot-nginx
systemctl enable --now nginx

echo "==> Firewall"
apt-get install -y ufw
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw --force enable

echo "==> Creating /opt/nirvana layout"
mkdir -p /opt/nirvana/{src,app-web,backups}
chown -R "$TARGET_USER":"$TARGET_USER" /opt/nirvana

cat <<DONE

Bootstrap complete.

Next:
  1. Log out and back in (so the docker group applies to $TARGET_USER).
  2. Copy this deploy/ directory to /opt/nirvana/deploy.
  3. cp .env.example .env && chmod 600 .env  — then fill it in.
  4. Point DNS A records at this instance's public IP:
       <domain>  www.<domain>  api.<domain>  app.<domain>
  5. sudo bash scripts/10-nginx.sh
  6. bash scripts/20-deploy.sh

Security group must allow inbound 22, 80, 443 only.
DONE
