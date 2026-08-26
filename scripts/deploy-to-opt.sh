#!/usr/bin/env bash
# Deploy this project to /opt/sql-runner on the SQL execution VM.
# Run with: sudo ./scripts/deploy-to-opt.sh
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${DEST:-/opt/sql-runner}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo $0"
  exit 1
fi

mkdir -p "$DEST"
rsync -a --delete \
  --exclude '.git' \
  --exclude 'api/node_modules' \
  --exclude 'api/.env' \
  --exclude '.env' \
  "$SRC/" "$DEST/"

# Preserve existing secrets if present; otherwise copy examples.
if [ ! -f "$DEST/.env" ]; then
  cp "$DEST/.env.example" "$DEST/.env"
  echo "Created $DEST/.env — edit passwords before starting."
fi
if [ ! -f "$DEST/api/.env" ]; then
  cp "$DEST/api/.env.example" "$DEST/api/.env"
  echo "Created $DEST/api/.env — edit API_KEY and DB password before starting."
fi

chmod +x "$DEST/postgres/01_create_user.sh" "$DEST/scripts/"*.sh
chown -R root:root "$DEST"
# Keep .env readable only by root / docker
chmod 600 "$DEST/.env" "$DEST/api/.env" 2>/dev/null || true

echo "Deployed to $DEST"
echo "Next:"
echo "  1. Edit $DEST/.env and $DEST/api/.env"
echo "  2. cd $DEST && docker compose up -d --build"
echo "  3. ./scripts/test-api.sh"
