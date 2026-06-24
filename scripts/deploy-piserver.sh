#!/usr/bin/env bash
# Deploy AthletIQ full stack to piserver via Docker Compose.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${DEPLOY_ROOT}/.." && pwd)"
ENV_FILE="${DEPLOY_ROOT}/deploy/.env.pi"
REMOTE_COMPOSE_FILE="AthletIQ-Deploy/deploy/docker-compose.yml"
REMOTE_ENV_FILE="AthletIQ-Deploy/deploy/.env.pi"

DO_BUILD=1
DO_SEED=0
DO_LOGS=0
DO_DOWN_FIRST=0

usage() {
  cat <<'EOF'
Usage: ./AthletIQ-Deploy/scripts/deploy-piserver.sh [options]

Run from the AthletIQ-Deploy directory (or repo root with that path).

Options:
  --seed         Run demo data seed after deploy (also applies any pending migrations)
  --logs         Follow compose logs after deploy
  --no-build     Skip image rebuild (docker compose up -d only)
  --down-first   Stop containers before deploy (docker compose down, volumes preserved)
  -h, --help     Show this help

Requires AthletIQ-Deploy/deploy/.env.pi (copy from deploy/.env.pi.example).
SSH: set PI_SSH_PASSWORD in deploy/.env.pi, or use key auth (ssh-copy-id).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --seed) DO_SEED=1; shift ;;
    --logs) DO_LOGS=1; shift ;;
    --no-build) DO_BUILD=0; shift ;;
    --down-first) DO_DOWN_FIRST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing ${ENV_FILE}. Copy AthletIQ-Deploy/deploy/.env.pi.example to deploy/.env.pi and edit it." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${PI_HOST:?Set PI_HOST in deploy/.env.pi}"
: "${PI_USER:?Set PI_USER in deploy/.env.pi}"
: "${PI_REMOTE_DIR:=/home/${PI_USER}/athletiq}"

SSH_TARGET="${PI_USER}@${PI_HOST}"

SSH_BASE_OPTS=(-o ConnectTimeout=30 -o StrictHostKeyChecking=accept-new)
if [[ -n "${PI_SSH_IDENTITY_FILE:-}" ]]; then
  SSH_BASE_OPTS+=(-i "${PI_SSH_IDENTITY_FILE}")
fi

require_sshpass() {
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "PI_SSH_PASSWORD is set but sshpass is not installed." >&2
    echo "  brew install hudochenkov/sshpass/sshpass" >&2
    exit 1
  fi
}

init_ssh_transport() {
  if [[ -n "${PI_SSH_PASSWORD:-}" ]]; then
    require_sshpass
    export SSHPASS="${PI_SSH_PASSWORD}"
    SSH_PW_OPTS=(
      "${SSH_BASE_OPTS[@]}"
      -o PreferredAuthentications=password
      -o PubkeyAuthentication=no
    )
    SSH_TRANSPORT=(sshpass -e ssh "${SSH_PW_OPTS[@]}")
    RSYNC_SHELL="sshpass -e ssh ${SSH_PW_OPTS[*]}"
    echo "==> Using SSH password auth to ${SSH_TARGET}"
    return
  fi

  echo "==> Checking SSH key auth to ${SSH_TARGET}"
  if ssh "${SSH_BASE_OPTS[@]}" -o BatchMode=yes "$SSH_TARGET" true 2>/dev/null; then
    SSH_TRANSPORT=(ssh "${SSH_BASE_OPTS[@]}" -o BatchMode=yes)
    RSYNC_SHELL="ssh ${SSH_BASE_OPTS[*]} -o BatchMode=yes"
    return
  fi

  echo "SSH failed. Set PI_SSH_PASSWORD in deploy/.env.pi or run ./AthletIQ-Deploy/scripts/setup-piserver-ssh.sh" >&2
  exit 1
}

ssh_cmd() {
  "${SSH_TRANSPORT[@]}" "$SSH_TARGET" "$@"
}

init_ssh_transport

echo "==> Verifying SSH access"
if ! ssh_cmd true; then
  echo "SSH login failed. Check PI_HOST, PI_USER, and PI_SSH_PASSWORD in deploy/.env.pi" >&2
  exit 1
fi

echo "==> Ensuring remote directory ${PI_REMOTE_DIR}"
ssh_cmd "mkdir -p ${PI_REMOTE_DIR}"

echo "==> Syncing repository to ${SSH_TARGET}:${PI_REMOTE_DIR}"
# shellcheck disable=SC2086
rsync -avz --delete -e "${RSYNC_SHELL}" \
  --exclude '.git/' \
  --exclude 'node_modules/' \
  --exclude '**/node_modules/' \
  --exclude '**/bin/' \
  --exclude '**/obj/' \
  --exclude '**/.next/' \
  --exclude '**/dist/' \
  --exclude '**/__pycache__/' \
  --exclude '**/.turbo/' \
  --exclude '**/.pnpm-store/' \
  --exclude '.DS_Store' \
  --exclude 'AthletIQ-mobile/' \
  --exclude 'AthletIQ/' \
  --exclude 'piserver_reversed_proxy/' \
  "${REPO_ROOT}/" "${SSH_TARGET}:${PI_REMOTE_DIR}/"

echo "==> Uploading deploy/.env.pi to Pi"
# shellcheck disable=SC2086
rsync -avz -e "${RSYNC_SHELL}" "${ENV_FILE}" "${SSH_TARGET}:${PI_REMOTE_DIR}/${REMOTE_ENV_FILE}"

COMPOSE_CMD="cd ${PI_REMOTE_DIR} && docker compose -f ${REMOTE_COMPOSE_FILE} --env-file ${REMOTE_ENV_FILE}"

if [[ "$DO_DOWN_FIRST" -eq 1 ]]; then
  echo "==> Stopping containers on ${PI_HOST} (volumes preserved)"
  ssh_cmd "${COMPOSE_CMD} down"
fi

if [[ "$DO_BUILD" -eq 1 ]]; then
  echo "==> Building and starting containers on ${PI_HOST} (this can take 15–30+ min on a Pi)"
  ssh_cmd "${COMPOSE_CMD} up -d --build"
else
  echo "==> Starting containers on ${PI_HOST} (no rebuild)"
  ssh_cmd "${COMPOSE_CMD} up -d"
fi

if [[ "$DO_SEED" -eq 1 ]]; then
  echo "==> Seeding demo data"
  ssh_cmd "${COMPOSE_CMD} run --rm api dotnet AthletIQ.Api.dll --seed"
fi

echo "==> Container status"
ssh_cmd "${COMPOSE_CMD} ps"

cat <<EOF

Deploy finished.

  App:          http://${PI_HOST}:${FRONTEND_PORT:-5000}
  Landing page: http://${PI_HOST}:${LANDINGPAGE_PORT:-8081}
  API:          http://${PI_HOST}:${API_PORT:-8082}
  Health:       http://${PI_HOST}:${API_PORT:-8082}/health

First-time login: run with --seed, then use demo credentials from AthletIQ-Deploy/deploy/README.md
EOF

if [[ "$DO_LOGS" -eq 1 ]]; then
  echo "==> Following logs (Ctrl+C to stop)"
  ssh_cmd "${COMPOSE_CMD} logs -f --tail=100"
fi
