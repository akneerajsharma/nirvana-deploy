# Nirvana — single-host deployment (EC2, Ubuntu 24.04 LTS)

Runs all three surfaces on one EC2 instance:

| URL | Service | How it runs |
|---|---|---|
| `https://api.<domain>` | `backend` — NestJS API | Docker container, loopback `:3000`, behind Nginx |
| `https://<domain>` / `www` | `web` — Next.js marketing site | Docker container, loopback `:3001`, behind Nginx |
| `https://app.<domain>` | `app` — Flutter web portals | Static files in `/opt/nirvana/app-web`, served by Nginx |

Postgres 16 and Redis 7 run as containers on the same box and publish **no**
host ports — they are reachable only over the compose network. Nginx runs on
the host and owns TLS.

This replaces the ECS Fargate + Amplify + CloudFront topology described in
`docs/ARCHITECTURE.md`. See [Trade-offs](#trade-offs) for what that costs you.

## Layout on the server

```
/opt/nirvana/
├── deploy/         this directory (.env lives here, chmod 600)
├── src/
│   ├── backend/    git clone of nirvana-backend
│   └── web/        git clone of nirvana-frontend
├── app-web/        Flutter web build, rsynced from your laptop
└── backups/        nightly pg_dump + uploads tarballs
```

## Instance sizing

- **t3.small (2 vCPU / 2 GB) minimum.** The bootstrap script adds a 4 GB
  swapfile because `next build` will otherwise be OOM-killed mid-build
  (exit 137).
- **t3.medium (4 GB) recommended** once Postgres has real data — Postgres,
  Redis, Node × 2 and the build all share this box.
- **30 GB gp3 root volume minimum.** Docker images, the database, uploads
  and backups all live on it.

Security group inbound: **22, 80, 443 only**.

## First-time setup

```bash
# 1. On the instance
sudo bash /opt/nirvana/deploy/scripts/00-bootstrap.sh
# log out and back in so the docker group applies

# 2. Configure
cd /opt/nirvana/deploy
cp .env.example .env
chmod 600 .env
openssl rand -base64 48   # JWT_ACCESS_SECRET
openssl rand -base64 48   # JWT_REFRESH_SECRET  (must differ)
openssl rand -base64 32   # POSTGRES_PASSWORD
$EDITOR .env              # set DOMAIN, CERT_EMAIL and paste the secrets in
# If the GitHub repos are private, add a read-only deploy key to each and
# switch BACKEND_REPO / WEB_REPO to their git@github.com: SSH form.

# 3. DNS — four A records at the instance's Elastic IP, then wait for propagation
#    <domain>   www.<domain>   api.<domain>   app.<domain>

# 4. Nginx + Let's Encrypt
sudo bash scripts/10-nginx.sh

# 5. Deploy backend + web
bash scripts/20-deploy.sh

# 6. Seed reference data (first deploy only — it is not idempotent)
docker compose --profile tools run --rm seed

# 7. Nightly backups
sudo crontab -e
# 15 2 * * * /opt/nirvana/deploy/scripts/30-backup.sh >> /var/log/nirvana-backup.log 2>&1
```

Then, **from your laptop** (Flutter is deliberately not installed on the
server — the SDK plus build cache would dominate a small instance's disk):

```bash
cd ~/Documents/neeraj/softwares/nirvana/deploy
DOMAIN=<domain> EC2_HOST=ubuntu@<elastic-ip> SSH_KEY=~/.ssh/<key>.pem \
  bash scripts/40-publish-app-web.sh
```

**Attach an Elastic IP before setting DNS.** A stop/start on a plain EC2
instance changes its public IP, which breaks DNS and every issued certificate.

## Routine operations

| Task | Command (from `/opt/nirvana/deploy`) |
|---|---|
| Deploy both services | `bash scripts/20-deploy.sh` |
| Deploy one service | `bash scripts/20-deploy.sh backend` |
| Publish portal build | *(laptop)* `bash scripts/40-publish-app-web.sh` |
| Tail logs | `docker compose logs -f backend` |
| Status | `docker compose ps` |
| Restart one service | `docker compose restart backend` |
| Apply migrations only | `docker compose --profile tools run --rm migrate` |
| psql shell | `docker compose exec postgres psql -U nirvana -d nirvana` |
| Manual backup | `bash scripts/30-backup.sh` |
| Renew certs (manual) | `sudo certbot renew --nginx` |

`20-deploy.sh` does a `git reset --hard origin/<branch>` on each repo, builds
the image, applies migrations, then restarts. It aborts before restarting if
migrations fail, so the API is never left running against a schema it does not
match.

## Restoring a backup

```bash
cd /opt/nirvana/deploy
docker compose stop backend
cat /opt/nirvana/backups/db-<stamp>.dump | \
  docker compose exec -T postgres pg_restore -U nirvana -d nirvana --clean --if-exists
docker compose start backend
```

Uploads (when `STORAGE_PROVIDER=local`):

```bash
docker run --rm -v nirvana_uploads:/data -v /opt/nirvana/backups:/b alpine \
  tar xzf /b/uploads-<stamp>.tar.gz -C /data
```

## Things worth knowing

**`NEXT_PUBLIC_API_BASE_URL` is baked in at build time.** It is inlined into
the client bundle, so changing `DOMAIN` in `.env` requires a rebuild
(`docker compose build web`), not just a restart. `20-deploy.sh` rebuilds on
every run, so this is only a trap when restarting by hand.

**The Flutter bundle is also built against a fixed API URL.** Changing the
domain means re-running `40-publish-app-web.sh`.

**OTP login will not work until an SMS vendor is wired in.** `SMS_PROVIDER`
defaults to `console`, which logs the OTP to the container log instead of
sending it — read it with `docker compose logs backend | grep -i otp`. Vendor
choice is still open per `docs/project-context.md §8`.

**`STORAGE_PROVIDER=local` puts patient documents on this instance's EBS
volume**, served from `https://api.<domain>/uploads`. That is a single point
of loss and there is no access control on those URLs beyond the unguessable
path. Switch to `s3` before handling real patient records.

**CORS is derived from `DOMAIN`.** The backend only accepts browser requests
from `https://<domain>`, `https://www.<domain>` and `https://app.<domain>`.
Add any other origin to `CORS_ORIGINS` in `docker-compose.yml`.

**Swagger is public** at `https://api.<domain>/api/docs`. It enumerates every
endpoint in the system. Restrict it in Nginx before launch:

```nginx
location /api/docs { allow <your-ip>/32; deny all; proxy_pass http://127.0.0.1:3000; }
```

## Trade-offs

This topology is cheap and easy to reason about, and it is a real step down in
resilience from the CDK stack in `backend/infra`:

- **No redundancy.** One instance, one AZ. Any reboot, instance failure or bad
  deploy is full downtime for all three surfaces.
- **The database shares the box.** No automated point-in-time recovery, no
  failover, no managed minor-version patching. `30-backup.sh` gives you nightly
  dumps on the *same EBS volume* — ship them to S3 (the script's closing
  comment shows the `aws s3 sync` line) or you lose them with the instance.
- **Deploys have a gap.** `docker compose up -d` stops the old container before
  the new one is ready; expect a few seconds of 502s.
- **No CDN.** The marketing site is served straight from the origin, which
  works against the LCP < 2.5s target in `docs/project-context.md §4`. Putting
  CloudFront in front of `<domain>` later is additive and does not change
  anything here.
- **Compliance.** DPDP Act 2023 obligations around patient data do not relax
  because the deployment is small. Local disk storage, unencrypted EBS (check
  the volume setting) and single-copy backups are the parts to revisit first.

Reasonable for staging and early production. Revisit before real patient
volume.
