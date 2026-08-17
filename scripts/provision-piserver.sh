#!/usr/bin/env bash
# Provision a new organization (club) + admin user on an already-deployed Pi stack.
# No build, no deploy, no wipe, no demo data. Run once per club to add more clubs.
#
#   ./scripts/provision-piserver.sh \
#     --organization-name "Your FC" \
#     --admin-email "admin@yourfc.no" \
#     --admin-password "A-Strong-Password"
#
# Club details can also come from deploy/.env.pi (ORG_NAME, ORG_ADMIN_EMAIL,
# ORG_ADMIN_PASSWORD); CLI args take precedence. Idempotent: re-running with the
# same organization name is a no-op.
#
# Requires the stack to already be deployed (api image + compose on the Pi).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${DEPLOY_ROOT}/deploy/.env.pi"
REMOTE_COMPOSE_FILE="AthletIQ-Deploy/deploy/docker-compose.yml"
REMOTE_ENV_FILE="AthletIQ-Deploy/deploy/.env.pi"

CLUB_NAME=""
CLUB_EMAIL=""
CLUB_PASSWORD=""

usage() {
  cat <<'EOF'
Usage: ./AthletIQ-Deploy/scripts/provision-piserver.sh [options]

Provision a new organization (club) + admin user on an already-deployed stack.
Run once per club to add more clubs. No deploy/build/wipe happens.

Options:
  --organization-name <name>  Club / organization name (required)
  --admin-email <email>       Admin login email (required)
  --admin-password <pass>     Admin login password (required)
  -h, --help                  Show this help

Club details can also be set in deploy/.env.pi as ORG_NAME / ORG_ADMIN_EMAIL /
ORG_ADMIN_PASSWORD; CLI args take precedence. Re-running with the same
organization name is a no-op (idempotent).

Run AFTER the stack is deployed (requires the api image + compose on the Pi).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --organization-name) CLUB_NAME="${2:?--organization-name requires a value}"; shift 2 ;;
    --admin-email) CLUB_EMAIL="${2:?--admin-email requires a value}"; shift 2 ;;
    --admin-password) CLUB_PASSWORD="${2:?--admin-password requires a value}"; shift 2 ;;
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

# Club details: CLI args win; fall back to ORG_* in deploy/.env.pi.
CLUB_NAME="${CLUB_NAME:-${ORG_NAME:-}}"
CLUB_EMAIL="${CLUB_EMAIL:-${ORG_ADMIN_EMAIL:-}}"
CLUB_PASSWORD="${CLUB_PASSWORD:-${ORG_ADMIN_PASSWORD:-}}"

if [[ -z "$CLUB_NAME" || -z "$CLUB_EMAIL" || -z "$CLUB_PASSWORD" ]]; then
  echo "Missing club details. Provide --organization-name, --admin-email, --admin-password (or set ORG_NAME / ORG_ADMIN_EMAIL / ORG_ADMIN_PASSWORD in deploy/.env.pi)." >&2
  usage
  exit 1
fi

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

echo "==> Provisioning organization '${CLUB_NAME}' (admin: ${CLUB_EMAIL})"
ssh_cmd "${COMPOSE_CMD} run --rm api dotnet AthletIQ.Api.dll --provision --organization-name '${CLUB_NAME}' --admin-email '${CLUB_EMAIL}' --admin-password '${CLUB_PASSWORD}'"

cat <<EOF

Provisioning finished.

  Organization: ${CLUB_NAME}
  Admin:        ${CLUB_EMAIL}
  Login:        http://${PI_HOST}:${FRONTEND_PORT:-5000}

Repeat with a different --organization-name to add more clubs.
EOF
