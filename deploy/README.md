# Deploy AthletIQ to piserver (Docker)

Run the full stack on a Raspberry Pi or other LAN host: **PostgreSQL**, **HAPI FHIR**, **MinIO**, **.NET API**, **Next.js frontend**, and **marketing landing page**.

## Prerequisites (on the Pi)

1. **Docker Engine** and **Compose plugin** (v2)
2. User `kbo` in the `docker` group:
   ```bash
   sudo usermod -aG docker kbo
   newgrp docker
   ```
3. **RAM**: 4 GB+ recommended (HAPI FHIR and image builds are heavy on a Pi)
4. **SSH** from your Mac/Linux dev machine
5. **External `web` Docker network** (for Traefik reverse proxy):
   ```bash
   docker network create web
   ```

## One-time setup (on your Mac)

### 1. SSH access

**Password (simplest):** set in `deploy/.env.pi` (gitignored):

```bash
PI_SSH_PASSWORD=your-pi-password
```

Install `sshpass` on your Mac once:

```bash
brew install hudochenkov/sshpass/sshpass
```

**Or SSH keys (optional):** leave `PI_SSH_PASSWORD` empty and run `./scripts/setup-piserver-ssh.sh`.

### 2. Environment file

```bash
cp deploy/.env.pi.example deploy/.env.pi
```

Edit `deploy/.env.pi`:

- Set strong `POSTGRES_PASSWORD` and `JWT_SECRET` (min 32 characters)
- Confirm `PI_HOST=piserver` resolves on your LAN (or use an IP)

AI provider settings (Gemini, OpenAI, DeepSeek, etc.) come from `AthletIQ-Backend/src/AthletIQ.Api/appsettings.json` baked into the API image. You can override them at deploy time without rebuilding via `.env.pi` (values are passed into the `api` container as `*__*` env vars):

- `CHAT_AI_PROVIDER`, `WEARABLE_AI_PROVIDER`, `NUTRITION_AI_PROVIDER`, `JOURNAL_AI_PROVIDER` — pick `Gemini`, `OpenAI`, or `DeepSeek` per capability.
- `DEEPSEEK_API_KEY`, `DEEPSEEK_MODEL` (e.g. `deepseek-v4-flash` or `deepseek-v4-pro`), `DEEPSEEK_CLINICAL_EXTRACTION_MODEL` — DeepSeek credentials/model.
- `GEMINI_API_KEY`, `GEMINI_MODEL`, `GEMINI_CLINICAL_EXTRACTION_MODEL` — Gemini credentials/model.
- `ONESIGNAL_APP_ID`, `ONESIGNAL_API_KEY` — mobile push. Without them the API logs "OneSignal is not configured" and offline users never get a notification. See `AthletIQ-mobile/docs/onesignal.md`.

Example to use DeepSeek for chat/wearable/journal and Gemini for meal photos:

```bash
CHAT_AI_PROVIDER=DeepSeek
WEARABLE_AI_PROVIDER=DeepSeek
NUTRITION_AI_PROVIDER=Gemini
JOURNAL_AI_PROVIDER=DeepSeek
DEEPSEEK_API_KEY=sk-...
DEEPSEEK_MODEL=deepseek-v4-flash
DEEPSEEK_CLINICAL_EXTRACTION_MODEL=deepseek-v4-pro
GEMINI_API_KEY=...
GEMINI_MODEL=gemini-3.5-flash
```

`deploy/.env.pi` is gitignored.

## Deploy

From the **AthletIQ-Deploy** directory on your dev machine:

```bash
cd AthletIQ-Deploy
chmod +x scripts/*.sh
```

### Quick start — fresh demo environment (DEV ONLY)

Run the one-shot demo script to build, wipe all data, create a brand-new database,
provision the Træff demo organization, and seed demo data:

```bash
./scripts/fresh-deploy-traeff-piserver.sh
```

This **wipes all data** — use it for demo/dev, not production. It chains:

1. `deploy-piserver.sh --wipe` — build + transfer + fresh DBs
2. `provision-piserver.sh` — create the `Træff` demo org + admin
3. `seed-traeff-piserver.sh --dashboard` — seed roster + 30 days of dashboard data

Building **on the Pi** instead (slower, 15–30+ min): `./scripts/fresh-deploy-traeff-piserver.sh --build-on-pi`

### The operations

| Operation | Script |
|-----------|--------|
| **Deploy** (build + transfer + start, keeps data) | `./scripts/deploy-piserver.sh` |
| **Wipe** (fresh DBs) | `./scripts/deploy-piserver.sh --wipe` |
| **Provision a club** (+ admin, no demo data) | `./scripts/provision-piserver.sh --organization-name "Your FC" ...` |
| **Seed Træff demo data** | `./scripts/seed-traeff-piserver.sh [--dashboard]` |
| **Full demo** (wipe + provision + seed + dashboard) | `./scripts/fresh-deploy-traeff-piserver.sh` |

Examples:

```bash
# Deploy a new version, keep the existing database
./scripts/deploy-piserver.sh

# Deploy a new version with fresh DBs (wipes all data)
./scripts/deploy-piserver.sh --wipe

# Deploy + wipe + provision + seed + dashboard in one go (demo/dev only)
./scripts/fresh-deploy-traeff-piserver.sh

# Build on the Pi instead of locally (slower)
./scripts/deploy-piserver.sh --build-on-pi

# Add a real club + admin on an existing stack (production)
./scripts/provision-piserver.sh \
  --organization-name "Your FC" --admin-email "admin@yourfc.no" --admin-password "A-Strong-Password"

# Seed the Træff demo roster (+ dashboard data) after deploying
./scripts/seed-traeff-piserver.sh --dashboard
```

### Flags

**`deploy-piserver.sh`** — deploy the stack (default: build locally on linux/arm64, transfer, start)

| Flag | Description |
|------|-------------|
| `--build-on-pi` | Build images on the Pi instead of locally (15–30+ min) |
| `--skip-build` | Reuse existing local `:pi` image tags (transfer only) |
| `--wipe` | `docker compose down -v` — **deletes** Postgres, HAPI, and MinIO volumes (fresh DBs + stored photos) |
| `--down-first` | Stop containers before deploy (volumes preserved) |
| `--platform` | Target platform (default `linux/arm64`) |
| `--logs` | Tail compose logs when finished |

**`provision-piserver.sh`** — create a club + admin (production; idempotent)

| Flag | Description |
|------|-------------|
| `--organization-name <name>` | Club / organization name (required) |
| `--admin-email <email>` | Admin login email (required) |
| `--admin-password <pass>` | Admin login password (required) |

Or set `ORG_NAME` / `ORG_ADMIN_EMAIL` / `ORG_ADMIN_PASSWORD` in `deploy/.env.pi` and run
without arguments.

**`seed-traeff-piserver.sh`** — seed the Træff demo data (roster + login accounts)

| Flag | Description |
|------|-------------|
| `--dashboard` | Also generate ~30 days of dashboard demo data (training/wellness/ACWR) |

**`fresh-deploy-traeff-piserver.sh`** — DEV/DEMO: wipe + provision + seed + dashboard data

| Flag | Description |
|------|-------------|
| `--build-on-pi` | Build images on the Pi instead of locally |
| `--skip-build` | Reuse existing local `:pi` tags (transfer only) |
| `--logs` | Follow compose logs when finished |
| `--platform` | Target platform for the local build |

Demo org values default to `Træff` / `admin@demo.athletiq.local` / `Passw0rd!` and can
be overridden via `ORG_NAME` / `ORG_ADMIN_EMAIL` / `ORG_ADMIN_PASSWORD` in `deploy/.env.pi`.

### Add another club (production)

On an already-deployed stack, provision a new club + admin with
`scripts/provision-piserver.sh` — no build, deploy, wipe, or demo data. Run it once
per club:

```bash
./scripts/provision-piserver.sh \
  --organization-name "Your FC" \
  --admin-email "admin@yourfc.no" \
  --admin-password "A-Strong-Password"
```

Idempotent (re-running the same org name is a no-op). Or set defaults in
`deploy/.env.pi` (`ORG_NAME` / `ORG_ADMIN_EMAIL` / `ORG_ADMIN_PASSWORD`) and run the
script without arguments.

## Stack

| Service | Image / build | Purpose |
|---------|---------------|---------|
| `postgres` | `postgres:17-alpine` | AthletIQ application database |
| `hapi-fhir-db` | `postgres:16-alpine` | HAPI FHIR persistence |
| `hapi-fhir` | `hapiproject/hapi:latest` | FHIR server (internal; journal API only) |
| `minio` | `minio/minio` | S3-compatible object storage (player profile photos) |
| `minio-init` | `minio/mc` | Creates the `athletiq-profiles` bucket on first start |
| `api` | `AthletIQ-Backend/Dockerfile` | .NET 10 API |
| `frontend` | `AthletIQ-frontend/Dockerfile` | Next.js web app |
| `landingpage` | `AthletIQ-Landingpage/Dockerfile` | Static marketing site |

HAPI FHIR is not exposed on the host — clients use AthletIQ journal endpoints, not HAPI directly.

## URLs

| Service | URL |
|---------|-----|
| Landing page | http://piserver:8081 |
| Web app | http://piserver:5000 |
| API health | http://piserver:8082/health |
| MinIO console | http://piserver:9001 |
| Swagger | Development only (`http://localhost:8080/swagger` when running locally) |

Change ports via `LANDINGPAGE_PORT`, `FRONTEND_PORT`, `API_PORT`, `MINIO_API_PORT`, and `MINIO_CONSOLE_PORT` in `deploy/.env.pi`.

## Database migrations

Migrations are applied automatically — on API startup (`ApplyStartupAsync`) and by the
`--provision` / `--seed` one-off runs. No manual `dotnet ef` step is required on the Pi.

## Demo login (after a fresh demo deploy)

- Admin: the email in `ORG_ADMIN_EMAIL` (default `admin@demo.athletiq.local`)
- Players/staff: `*@traeff.no`
- Password: `Passw0rd!`
- On login, select the seeded organization ID (shown during provisioning) or look it up
  via `GET /api/v1/auth/organizations`.

See [AthletIQ-Backend/README.md](../../AthletIQ-Backend/README.md) for seed details.

## Troubleshooting

**SSH fails with "Permission denied"**

- Run `./scripts/setup-piserver-ssh.sh` and retry.

**SSH fails with "Connection reset" or "Not allowed at this time"**

- The Pi is blocking SSH (often **fail2ban** after many failed logins from setup attempts).
- On the Pi console (or from a machine that can still SSH in):
  ```bash
  sudo fail2ban-client status sshd
  sudo fail2ban-client set sshd unbanip YOUR_MAC_LAN_IP
  ```
- Find your Mac IP: System Settings → Network, or `ipconfig getifaddr en0`
- Or wait 10–30 minutes for the ban to expire, then run `./scripts/setup-piserver-ssh.sh` once before deploy.

**Build runs out of memory on Pi**

- Prefer `./scripts/deploy-piserver.sh` (builds on your Mac, transfers images).
- Or increase swap on the Pi.

**Frontend cannot reach API**

- Compose sets `BACKEND_URL=http://api:8080` inside the Docker network. Rebuild frontend after changing API wiring:
  ```bash
  ./scripts/deploy-piserver.sh
  ```

**Journal extraction or AI features fail**

- Check provider and model settings in `AthletIQ-Backend/src/AthletIQ.Api/appsettings.json`

**Check status on the Pi**

```bash
ssh kbo@piserver 'cd ~/athletiq && docker compose -f AthletIQ-Deploy/deploy/docker-compose.yml --env-file AthletIQ-Deploy/deploy/.env.pi ps'
```

**View logs**

```bash
ssh kbo@piserver 'cd ~/athletiq && docker compose -f AthletIQ-Deploy/deploy/docker-compose.yml --env-file AthletIQ-Deploy/deploy/.env.pi logs -f'
```

## Security notes

- Replace default passwords and JWT secret in `deploy/.env.pi` before exposing the Pi on a network.
- Do not commit `deploy/.env.pi` or SSH passwords to git.
- Swagger is disabled in Production; do not enable it on publicly exposed hosts.
