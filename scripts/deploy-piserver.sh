#!/usr/bin/env bash
# Deploy the AthletIQ stack to piserver.
# Default: build images locally (linux/arm64) and transfer them to the Pi (fast on
# Apple Silicon). Use --build-on-pi to build on the Pi instead. No data is changed
# unless --wipe is passed. Provisioning and demo-seed live in separate scripts:
#   scripts/provision-piserver.sh  (add a club + admin)
#   scripts/seed-traeff-piserver.sh  (seed Træff demo data)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${DEPLOY_ROOT}/.." && pwd)"
ENV_FILE="${DEPLOY_ROOT}/deploy/.env.pi"
REMOTE_COMPOSE_FILE="AthletIQ-Deploy/deploy/docker-compose.yml"
REMOTE_ENV_FILE="AthletIQ-Deploy/deploy/.env.pi"

PLATFORM="${PLATFORM:-linux/arm64}"
API_IMAGE="athletiq-api:pi"
FRONTEND_IMAGE="athletiq-frontend:pi"
LANDING_IMAGE="athletiq-landingpage:pi"

DO_BUILD=1
DO_WIPE=0
DO_LOGS=0
DO_DOWN_FIRST=0
DO_BUILD_ON_PI=0

usage() {
  cat <<'EOF'
Usage: ./AthletIQ-Deploy/scripts/deploy-piserver.sh [options]

Build and deploy the AthletIQ stack to piserver. Default: build api/frontend/
landingpage locally (linux/arm64) and transfer them to the Pi (fast). No data is
changed unless --wipe is passed.

Options:
  --build-on-pi  Build images on the Pi instead of locally (slower, 15-30+ min)
  --skip-build   Reuse existing local :pi image tags (transfer only)
  --wipe         Stop the stack and delete Docker volumes (fresh DBs) before start
  --down-first   Stop containers before deploy (volumes preserved)
  --platform     Target platform for the local build (default: linux/arm64)
  --logs         Follow compose logs after deploy
  -h, --help     Show this help

Requires AthletIQ-Deploy/deploy/.env.pi (copy from deploy/.env.pi.example).
SSH: set PI_SSH_PASSWORD in deploy/.env.pi, or use key auth (ssh-copy-id).

Provisioning and demo seed are separate scripts:
  scripts/provision-piserver.sh    # add a club + admin
  scripts/seed-traeff-piserver.sh    # seed Træff demo data
  scripts/fresh-deploy-traeff-piserver.sh # demo: wipe + provision + seed in one go
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-on-pi) DO_BUILD_ON_PI=1; shift ;;
    --skip-build) DO_BUILD=0; shift ;;
    --wipe) DO_WIPE=1; shift ;;
    --down-first) DO_DOWN_FIRST=1; shift ;;
    --logs) DO_LOGS=1; shift ;;
    --platform)
      PLATFORM="${2:?--platform requires a value}"
      shift 2
      ;;
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
NEXT_PUBLIC_API_BASE_URL="${NEXT_PUBLIC_API_BASE_URL:-same-origin}"

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
ssh_cmd "mkdir -p ${PI_REMOTE_DIR}/AthletIQ-Deploy/deploy"

if [[ "$DO_BUILD_ON_PI" -eq 1 ]]; then
  # Build on the Pi: sync the source, then `docker compose up --build`.
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
else
  # Build locally (default) and transfer images to the Pi.
  for dir in AthletIQ-Backend AthletIQ-frontend AthletIQ-Landingpage; do
    if [[ ! -d "${REPO_ROOT}/${dir}" ]]; then
      echo "Missing sibling repo: ${REPO_ROOT}/${dir}" >&2
      exit 1
    fi
  done

  if ! command -v docker >/dev/null 2>&1; then
    echo "docker is required on this machine." >&2
    exit 1
  fi

  if [[ "$DO_BUILD" -eq 1 ]]; then
    echo "==> Building images locally for ${PLATFORM}"
    docker buildx build --platform "${PLATFORM}" --load \
      -t "${API_IMAGE}" \
      -f "${REPO_ROOT}/AthletIQ-Backend/Dockerfile" \
      "${REPO_ROOT}/AthletIQ-Backend"

    docker buildx build --platform "${PLATFORM}" --load \
      -t "${FRONTEND_IMAGE}" \
      --build-arg "NEXT_PUBLIC_API_BASE_URL=${NEXT_PUBLIC_API_BASE_URL}" \
      --build-arg "BACKEND_URL=http://api:8080" \
      -f "${REPO_ROOT}/AthletIQ-frontend/Dockerfile" \
      "${REPO_ROOT}/AthletIQ-frontend"

    docker buildx build --platform "${PLATFORM}" --load \
      -t "${LANDING_IMAGE}" \
      -f "${REPO_ROOT}/AthletIQ-Landingpage/Dockerfile" \
      "${REPO_ROOT}/AthletIQ-Landingpage"
  else
    echo "==> Skipping local build; transferring existing tags"
    for img in "${API_IMAGE}" "${FRONTEND_IMAGE}" "${LANDING_IMAGE}"; do
      if ! docker image inspect "${img}" >/dev/null 2>&1; then
        echo "Missing local image: ${img} (run without --skip-build)" >&2
        exit 1
      fi
    done
  fi

  echo "==> Syncing deploy compose + env to ${SSH_TARGET}"
  # shellcheck disable=SC2086
  rsync -avz -e "${RSYNC_SHELL}" \
    "${DEPLOY_ROOT}/deploy/docker-compose.yml" \
    "${SSH_TARGET}:${PI_REMOTE_DIR}/${REMOTE_COMPOSE_FILE}"
  # shellcheck disable=SC2086
  rsync -avz -e "${RSYNC_SHELL}" \
    "${ENV_FILE}" \
    "${SSH_TARGET}:${PI_REMOTE_DIR}/${REMOTE_ENV_FILE}"

  echo "==> Transferring images to ${PI_HOST} (docker save | load)"
  docker save "${API_IMAGE}" "${FRONTEND_IMAGE}" "${LANDING_IMAGE}" \
    | gzip -1 \
    | ssh_cmd "gunzip | docker load"

  COMPOSE_CMD="cd ${PI_REMOTE_DIR} && docker compose -f ${REMOTE_COMPOSE_FILE} --env-file ${REMOTE_ENV_FILE}"
fi

echo "==> Ensuring external Docker network 'web' exists"
ssh_cmd "docker network inspect web >/dev/null 2>&1 || docker network create web"

if [[ "$DO_WIPE" -eq 1 ]]; then
  echo "==> Wiping stack and volumes on ${PI_HOST} (DATABASE DATA WILL BE DELETED)"
  ssh_cmd "${COMPOSE_CMD} down -v"
fi

if [[ "$DO_DOWN_FIRST" -eq 1 ]]; then
  echo "==> Stopping containers on ${PI_HOST} (volumes preserved)"
  ssh_cmd "${COMPOSE_CMD} down"
fi

if [[ "$DO_BUILD_ON_PI" -eq 1 ]]; then
  if [[ "$DO_BUILD" -eq 1 ]]; then
    echo "==> Building and starting containers on ${PI_HOST} (this can take 15-30+ min on a Pi)"
    ssh_cmd "${COMPOSE_CMD} up -d --build"
  else
    echo "==> Starting containers on ${PI_HOST} (no rebuild)"
    ssh_cmd "${COMPOSE_CMD} up -d"
  fi
else
  echo "==> Starting stack on ${PI_HOST} (using transferred images, no remote build)"
  ssh_cmd "${COMPOSE_CMD} up -d --no-build"
  ssh_cmd "${COMPOSE_CMD} up -d --no-build --force-recreate api frontend landingpage"
fi

echo "==> Container status"
ssh_cmd "${COMPOSE_CMD} ps"

cat <<EOF

Deploy finished.

  App:          http://$\{PI_HOST\}:$\{FRONTEND_PORT:-5000\}
  Landing page: http://$\{PI_HOST\}:$\{LANDINGPAGE_PORT:-8081\}
  API:          http://$\{PI_HOST\}:$\{API_PORT:-8082\}
  Health:       http://$\{PI_HOST\}:$\{API_PORT:-8082\}/health
  MinIO API:    http://$\{PI_HOST\}:$\{MINIO_API_PORT:-9000\}
  MinIO console: http://$\{PI_HOST\}:$\{MINIO_CONSOLE_PORT:-9001\}  (user/password from MINIO_ROOT_*)

Next steps (separate scripts):
  Add a club + admin:    scripts/provision-piserver.sh --organization-name "Your FC" ...
  Seed Træff demo data:  scripts/seed-traeff-piserver.sh [--dashboard]
EOF

if [[ "$DO_LOGS" -eq 1 ]]; then
  echo "==> Following logs (Ctrl+C to stop)"
  ssh_cmd "${COMPOSE_CMD} logs -f --tail=100"
fi
