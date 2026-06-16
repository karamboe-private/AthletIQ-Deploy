# Deploy AthletIQ to piserver (Docker)

Run the full stack on a Raspberry Pi or other LAN host: **Postgres**, **EHRbase**, **API**, **Next.js frontend**, and **marketing landing page**.

## Prerequisites (on the Pi)

1. **Docker Engine** and **Compose plugin** (v2)
2. User `kbo` in the `docker` group:
   ```bash
   sudo usermod -aG docker kbo
   newgrp docker
   ```
3. **RAM**: 4 GB+ recommended (EHRbase is heavy on a Pi)
4. **SSH** from your Mac/Linux dev machine

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

`deploy/.env.pi` is gitignored.

## Deploy

From the **AthletIQ-Deploy** directory on your dev machine:

```bash
cd AthletIQ-Deploy
chmod +x scripts/deploy-piserver.sh scripts/build-and-deploy-piserver.sh
./scripts/deploy-piserver.sh
```

Or from the **repo root**:

```bash
./AthletIQ-Deploy/scripts/deploy-piserver.sh
```

First deploy builds images **on the Pi** (ARM64). Expect **15–30+ minutes**.

### Options

| Flag | Description |
|------|-------------|
| `--seed` | Load demo org/users/teams after deploy |
| `--logs` | Tail compose logs when finished |
| `--no-build` | Restart without rebuilding images |
| `--down-first` | Stop containers before deploy (volumes preserved) |

Example first-time setup with demo data:

```bash
./scripts/deploy-piserver.sh --seed
```

Routine rebuild without wiping the database:

```bash
./scripts/build-and-deploy-piserver.sh
```

## URLs

| Service | URL |
|---------|-----|
| Landing page | http://piserver:8081 |
| Web app | http://piserver:5000 |
| API health | http://piserver:8082/health |
| Swagger | Development only (`http://localhost:8080/swagger` when running locally) |

Change ports via `LANDINGPAGE_PORT`, `FRONTEND_PORT`, and `API_PORT` in `deploy/.env.pi`.

## Database migrations

The API runs **EF Core migrations automatically on startup** (`ApplyStartupAsync`). No manual `dotnet ef` step is required on the Pi.

## Demo login (after `--seed`)

- Password: `Passw0rd!`
- Admin example: `admin@demo.athletiq.local` (use the seeded organization ID on login)

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

- Increase swap, or build on a more powerful machine with `docker buildx` (advanced).

**Frontend cannot reach API**

- Compose sets `BACKEND_URL=http://api:8080` inside the Docker network. Rebuild frontend after changing API wiring:
  ```bash
  ./scripts/deploy-piserver.sh
  ```

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
- Review API keys in backend `appsettings.json` before production use.
- Swagger is disabled in Production; do not enable it on publicly exposed hosts.
