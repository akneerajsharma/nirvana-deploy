#!/usr/bin/env bash
# Nightly backup of the Postgres database and the uploads volume.
# Install:  (crontab -e)  15 2 * * * /opt/nirvana/deploy/scripts/30-backup.sh >> /var/log/nirvana-backup.log 2>&1
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${BACKUP_DIR:-/opt/nirvana/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

cd "$DEPLOY_DIR"
set -a; source .env; set +a
mkdir -p "$BACKUP_DIR"

echo "[$(date -u +%FT%TZ)] backup start"

# -Fc is Postgres' custom format: compressed, and restorable selectively with
# pg_restore rather than only as one all-or-nothing SQL replay.
docker compose exec -T postgres \
  pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc \
  > "$BACKUP_DIR/db-$STAMP.dump"

# The uploads volume is only backed up when STORAGE_PROVIDER=local — with s3
# the bucket is the system of record and this would duplicate it.
if [[ "${STORAGE_PROVIDER:-local}" != "s3" ]]; then
  docker run --rm \
    -v nirvana_uploads:/data:ro \
    -v "$BACKUP_DIR":/backup \
    alpine tar czf "/backup/uploads-$STAMP.tar.gz" -C /data .
fi

find "$BACKUP_DIR" -type f \( -name 'db-*.dump' -o -name 'uploads-*.tar.gz' \) \
  -mtime +"$RETENTION_DAYS" -delete

echo "[$(date -u +%FT%TZ)] backup done -> $BACKUP_DIR"
du -sh "$BACKUP_DIR"

# These files sit on the same EBS volume as the database they protect, which
# means they survive a bad migration but not a lost instance. Ship them off
# the box for real durability:
#   aws s3 sync "$BACKUP_DIR" "s3://<your-backup-bucket>/nirvana/" --storage-class STANDARD_IA
