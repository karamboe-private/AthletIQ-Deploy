#!/usr/bin/env bash
# One-time: install your SSH public key on piserver (password prompt once).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${DEPLOY_ROOT}/deploy/.env.pi"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

PI_HOST="${PI_HOST:-piserver}"
PI_USER="${PI_USER:-kbo}"
SSH_TARGET="${PI_USER}@${PI_HOST}"

IDENTITY="${PI_SSH_IDENTITY_FILE:-$HOME/.ssh/id_ed25519}"
if [[ ! -f "$IDENTITY" ]]; then
  echo "No key at ${IDENTITY}. Generating ed25519 key..."
  ssh-keygen -t ed25519 -f "$IDENTITY" -N ""
fi

echo "==> Copying ${IDENTITY}.pub to ${SSH_TARGET}"
echo "    Enter your Pi password when prompted (one time only)."
ssh-copy-id -i "${IDENTITY}.pub" \
  -o StrictHostKeyChecking=accept-new \
  -o PreferredAuthentications=password,keyboard-interactive \
  -o PubkeyAuthentication=no \
  "$SSH_TARGET"

echo "==> Verifying key login"
ssh -i "$IDENTITY" -o BatchMode=yes "$SSH_TARGET" "echo SSH key auth OK"

echo ""
echo "Done. Add to deploy/.env.pi if you use a non-default key:"
echo "  PI_SSH_IDENTITY_FILE=${IDENTITY}"
echo ""
echo "Then deploy from AthletIQ-Deploy: ./scripts/deploy-piserver.sh --seed"
