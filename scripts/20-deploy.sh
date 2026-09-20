#!/usr/bin/env bash
# Pull, build, migrate, restart. Safe to re-run; this is the normal deploy.
#   bash scripts/20-deploy.sh            # deploy backend + web
#   bash scripts/20-deploy.sh backend    # deploy one service only
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$(dirname "$DEPLOY_DIR")/src"
cd "$DEPLOY_DIR"

[[ -f .env ]] || { echo "deploy/.env is missing — copy .env.example and fill it in." >&2; exit 1; }
set -a; source .env; set +a

: "${DOMAIN:?DOMAIN must be set in deploy/.env}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD must be set in deploy/.env}"
: "${JWT_ACCESS_SECRET:?JWT_ACCESS_SECRET must be set in deploy/.env}"
: "${JWT_REFRESH_SECRET:?JWT_REFRESH_SECRET must be set in deploy/.env}"

BRANCH="${GIT_BRANCH:-main}"
if [[ $# -gt 0 ]]; then TARGETS=("$@"); else TARGETS=(backend web); fi

sync_repo() {
  local name="$1" url="$2" dir="$SRC_DIR/$name"
  if [[ -d "$dir/.git" ]]; then
    echo "==> Updating $name"
    git -C "$dir" fetch --prune origin
    git -C "$dir" checkout "$BRANCH"
    git -C "$dir" reset --hard "origin/$BRANCH"
  else
    echo "==> Cloning $name"
    mkdir -p "$SRC_DIR"
    git clone --branch "$BRANCH" "$url" "$dir"
  fi
  echo "    $name @ $(git -C "$dir" rev-parse --short HEAD)"
}

for t in "${TARGETS[@]}"; do
  case "$t" in
    backend) sync_repo backend "${BACKEND_REPO:?BACKEND_REPO not set}" ;;
    web)     sync_repo web     "${WEB_REPO:?WEB_REPO not set}" ;;
    *) echo "Unknown target '$t' (expected: backend, web)" >&2; exit 1 ;;
  esac
done

echo "==> Starting data stores"
docker compose up -d postgres redis

echo "==> Building images: ${TARGETS[*]}"
docker compose build "${TARGETS[@]}"

if [[ " ${TARGETS[*]} " == *" backend "* ]]; then
  # `compose run` reuses an existing image rather than rebuilding, so without
  # this the migrate container would replay the *previous* commit's migrations.
  docker compose --profile tools build migrate seed

  echo "==> Applying database migrations"
  # Runs against the migrate stage, which still has the Prisma CLI. Deploy
  # stops here on failure rather than restarting the API against a schema it
  # does not match.
  docker compose --profile tools run --rm migrate
fi

echo "==> Restarting services"
docker compose up -d --no-deps "${TARGETS[@]}"

echo "==> Waiting for health"
for i in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:3000/api/v1/health >/dev/null 2>&1; then
    echo "    backend healthy"
    break
  fi
  [[ $i -eq 30 ]] && { echo "    backend did not become healthy — docker compose logs backend" >&2; exit 1; }
  sleep 2
done

if [[ " ${TARGETS[*]} " == *" web "* ]]; then
  for i in $(seq 1 30); do
    if curl -fsS -o /dev/null http://127.0.0.1:3001/; then
      echo "    web healthy"
      break
    fi
    [[ $i -eq 30 ]] && { echo "    web did not become healthy — docker compose logs web" >&2; exit 1; }
    sleep 2
  done
fi

echo "==> Pruning dangling images"
docker image prune -f >/dev/null

docker compose ps
echo
echo "Deployed. https://$DOMAIN  |  https://api.$DOMAIN/api/docs  |  https://app.$DOMAIN"
