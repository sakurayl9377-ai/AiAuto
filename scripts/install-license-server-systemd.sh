#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/codemate-license-server}"
SERVICE_NAME="${SERVICE_NAME:-codemate-license-server}"
HOST_PORT="${HOST_PORT:-8086}"
PORT="${PORT:-8086}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-http://127.0.0.1:${HOST_PORT}}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run this script as root."
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "Node.js is required. Install Node.js 20+ first."
  exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "npm is required."
  exit 1
fi

if ! command -v rsync >/dev/null 2>&1; then
  apt-get update
  apt-get install -y rsync
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

mkdir -p "$APP_DIR"
rsync -a --delete \
  --exclude backend/node_modules \
  --exclude backend/data \
  --exclude backend/.env \
  "$REPO_ROOT/" "$APP_DIR/"

cd "$APP_DIR/backend"
npm ci --omit=dev
mkdir -p data

ADMIN_TOKEN="$(openssl rand -hex 32 2>/dev/null || date +%s%N | sha256sum | awk '{print $1}')"

cat > .env <<EOF_ENV
PORT=${PORT}
ADMIN_TOKEN=${ADMIN_TOKEN}
DB_PATH=${APP_DIR}/backend/data/licenses.db
PUBLIC_BASE_URL=${PUBLIC_BASE_URL}
EOF_ENV

cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF_SERVICE
[Unit]
Description=CodeMate License Server
After=network.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}/backend
EnvironmentFile=${APP_DIR}/backend/.env
ExecStart=$(command -v npm) start
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF_SERVICE

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"

echo ""
echo "CodeMate license server is running with systemd."
echo "Admin URL: ${PUBLIC_BASE_URL}/admin"
echo "Health URL: ${PUBLIC_BASE_URL}/health"
echo "Admin Token: ${ADMIN_TOKEN}"
echo ""
echo "Service commands:"
echo "  systemctl status ${SERVICE_NAME}"
echo "  journalctl -u ${SERVICE_NAME} -f"
