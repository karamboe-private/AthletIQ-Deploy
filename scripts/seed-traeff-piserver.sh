#!/usr/bin/env bash
# Seed the Træff demo data into an already-provisioned org on the Pi.
# No build/deploy happens. Requires the stack to be deployed and the Træff org
# provisioned first (scripts/provision-piserver.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${DEPLOY_ROOT}/deploy/.env.pi"
REMOTE_COMPOSE_FILE="AthletIQ-Deploy/deploy/docker-compose.yml"
REMOTE_ENV_FILE="AthletIQ-Deploy/deploy/.env.pi"

DO_DASHBOARD=0

usage() {
  cat <<'EOF'
Usage: ./AthletIQ-Deploy/scripts/seed-traeff-piserver.sh [options]

Seed the Træff demo data (roster, staff, matches, login accounts) into the
already-provisioned Træff org on the Pi. No build/deploy happens.

Options:
  --dashboard  Also generate ~30 days of dashboard demo data (training/wellness/ACWR)
  -h, --help   Show this help

Requires the stack to be deployed and the Træff org provisioned first
(scripts/provision-piserver.sh).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dashboard) DO_DASHBOARD=1; shift ;;
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
    echo "==> Using SSH password auth to ${SSH_TARGET}"
    return
  fi

  echo "==> Checking SSH key auth to ${SSH_TARGET}"
  if ssh "${SSH_BASE_OPTS[@]}" -o BatchMode=yes "$SSH_TARGET" true 2>/dev/null; then
    SSH_TRANSPORT=(ssh "${SSH_BASE_OPTS[@]}" -o BatchMode=yes)
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

COMPOSE_CMD="cd ${PI_REMOTE_DIR} && docker compose -f ${REMOTE_COMPOSE_FILE} --env-file ${REMOTE_ENV_FILE}"

echo "==> Seeding Træff demo data (roster/staff/matches/login accounts)"
ssh_cmd "${COMPOSE_CMD} run --rm api dotnet AthletIQ.Api.dll --seed"

if [[ "$DO_DASHBOARD" -eq 1 ]]; then
  echo "==> Seeding dashboard demo data (training/wellness/ACWR)"
  ssh_cmd "${COMPOSE_CMD} run --rm api dotnet AthletIQ.Api.dll --seed-dashboard"
fi

echo "==> Seed complete."
