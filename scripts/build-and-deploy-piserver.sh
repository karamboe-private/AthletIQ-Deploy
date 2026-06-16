#!/usr/bin/env bash
# Build Docker images on piserver and redeploy the full stack.
# Preserves database volumes (no "docker compose down -v"). Does not seed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[1/1] Sync code, stop containers (keep DB), rebuild images, and start stack on piserver"
exec "${SCRIPT_DIR}/deploy-piserver.sh" --down-first "$@"
