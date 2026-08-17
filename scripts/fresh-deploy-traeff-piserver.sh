#!/usr/bin/env bash
# DEV/DEMO ONLY: full fresh demo deploy to piserver — this WIPES ALL DATA.
#   1. scripts/deploy-piserver.sh --wipe       (fresh DBs)
#   2. scripts/provision-piserver.sh           (Træff org + admin)
#   3. scripts/seed-traeff-piserver.sh --dashboard  (demo data + 30 days of dashboard data)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../deploy/.env.pi"

BUILD_ON_PI=0
SKIP_BUILD=0
LOGS=0
EXTRA_ARGS=()

usage() {
  cat <<'EOF'
Usage: ./AthletIQ-Deploy/scripts/fresh-deploy-traeff-piserver.sh [options]

DEV/DEMO ONLY — wipes all data on piserver, then provisions the Træff demo
organization and seeds demo data. Not for production.

Steps:
  1. scripts/deploy-piserver.sh --wipe       (fresh DBs)
  2. scripts/provision-piserver.sh           (Træff org + admin)
  3. scripts/seed-traeff-piserver.sh --dashboard  (demo data + 30 days of dashboard data)

Options:
  --build-on-pi     Build images on the Pi instead of locally
  --skip-build      Reuse existing local :pi image tags
  --logs            Follow compose logs when finished
  --platform        Target platform for the local build (default: linux/arm64)
  -h, --help        Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-on-pi) BUILD_ON_PI=1; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --logs) LOGS=1; shift ;;
    --platform)
      EXTRA_ARGS+=(--platform "${2:?--platform requires a value}")
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

DEPLOY_ARGS=(--wipe)
[[ "$BUILD_ON_PI" -eq 1 ]] && DEPLOY_ARGS+=(--build-on-pi)
[[ "$SKIP_BUILD" -eq 1 ]] && DEPLOY_ARGS+=(--skip-build)
if (( ${#EXTRA_ARGS[@]} > 0 )); then
  DEPLOY_ARGS+=("${EXTRA_ARGS[@]}")
fi
[[ "$LOGS" -eq 1 ]] && DEPLOY_ARGS+=(--logs)

echo "==> Fresh demo deploy (DEV/DEMO — wipes all data): deploy --wipe + provision + seed"
"${SCRIPT_DIR}/deploy-piserver.sh" "${DEPLOY_ARGS[@]}"

echo "==> Provisioning Træff demo org + admin"
"${SCRIPT_DIR}/provision-piserver.sh" \
  --organization-name "${ORG_NAME:-Træff}" \
  --admin-email "${ORG_ADMIN_EMAIL:-admin@traeff.no}" \
  --admin-password "${ORG_ADMIN_PASSWORD:-Passw0rd!}"

echo "==> Seeding Træff demo data (roster + dashboard)"
"${SCRIPT_DIR}/seed-traeff-piserver.sh" --dashboard

echo "==> Fresh demo deploy finished."
