#!/usr/bin/env bash
# Builds the Flutter web bundle LOCALLY and rsyncs it to the EC2 box.
#
# Flutter is not installed on the server on purpose: the SDK plus its build
# cache is several GB and would dominate a small instance's disk for an
# artifact that is just static files.
#
# Usage:
#   DOMAIN=example.com EC2_HOST=ubuntu@1.2.3.4 bash scripts/40-publish-app-web.sh
#   SSH_KEY=~/.ssh/nirvana.pem ...   (optional)
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${APP_DIR:-$(dirname "$DEPLOY_DIR")/app}"

if [[ -z "${DOMAIN:-}" && -f "$DEPLOY_DIR/.env" ]]; then
  set -a; source "$DEPLOY_DIR/.env"; set +a
fi

: "${DOMAIN:?Set DOMAIN (or fill deploy/.env)}"
: "${EC2_HOST:?Set EC2_HOST, e.g. ubuntu@13.234.56.78}"

REMOTE_DIR="${REMOTE_DIR:-/opt/nirvana/app-web}"
API_BASE_URL="${API_BASE_URL:-https://api.$DOMAIN/api/v1}"
# Built as a single string rather than an array: rsync -e takes one word-split
# argument, so a key path containing spaces has to be quoted here.
SSH_CMD="ssh -o StrictHostKeyChecking=accept-new"
[[ -n "${SSH_KEY:-}" ]] && SSH_CMD="$SSH_CMD -i '$SSH_KEY'"

command -v flutter >/dev/null || { echo "flutter not found on PATH" >&2; exit 1; }

echo "==> Building Flutter web against $API_BASE_URL"
cd "$APP_DIR"
flutter --version
flutter pub get
flutter build web \
  --release \
  -t lib/main_prod.dart \
  --dart-define=API_BASE_URL="$API_BASE_URL" \
  --base-href /

echo "==> Publishing to $EC2_HOST:$REMOTE_DIR"
# --delete removes files from the previous build that the new one no longer
# emits; without it stale hashed bundles accumulate indefinitely.
rsync -az --delete \
  -e "$SSH_CMD" \
  "$APP_DIR/build/web/" \
  "$EC2_HOST:$REMOTE_DIR/"

echo "==> Done: https://app.$DOMAIN"
echo "    Hard-refresh once; the service worker caches aggressively."
