#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${REPO_URL:-}"
APP_DIR="${APP_DIR:-/opt/codemate-license-server}"
BRANCH="${BRANCH:-main}"
HOST_PORT="${HOST_PORT:-8086}"
CONTAINER_PORT="${PORT:-8787}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-}"

install_apt_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y "$@"
    return 0
  fi

  return 1
}

if [[ -z "$REPO_URL" ]]; then
  echo "REPO_URL is required."
  echo "Example:"
  echo "  REPO_URL=https://github.com/your-name/your-repo.git bash scripts/deploy-license-server.sh"
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "Installing git..."
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run as root to auto-install git."
    exit 1
  fi
  install_apt_packages git ca-certificates curl openssl
elif ! command -v curl >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
  if [[ "$(id -u)" -eq 0 ]]; then
    install_apt_packages ca-certificates curl openssl || true
  fi
fi

if ! command -v docker >/dev/null 2>&1; then
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Docker is required. Run as root to auto-install Docker, or install Docker first."
    exit 1
  fi

  if ! command -v curl >/dev/null 2>&1; then
    install_apt_packages ca-certificates curl
  fi

  echo "Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker || true
  fi
fi

if ! docker compose version >/dev/null 2>&1; then
  if [[ "$(id -u)" -eq 0 ]]; then
    install_apt_packages docker-compose-plugin || true
  fi

  if ! docker compose version >/dev/null 2>&1; then
    echo "Docker Compose plugin is required but was not found."
    exit 1
  fi
fi

mkdir -p "$APP_DIR"

if [[ -d "$APP_DIR/.git" ]]; then
  git -C "$APP_DIR" fetch --all --prune
  git -C "$APP_DIR" checkout "$BRANCH"
  git -C "$APP_DIR" pull --ff-only origin "$BRANCH"
else
  rm -rf "$APP_DIR"
  git clone --branch "$BRANCH" "$REPO_URL" "$APP_DIR"
fi

cd "$APP_DIR/backend"
mkdir -p data

if [[ -z "$PUBLIC_BASE_URL" ]]; then
  PUBLIC_BASE_URL="http://127.0.0.1:${HOST_PORT}"
fi

if [[ -f ".env" ]]; then
  ADMIN_TOKEN="$(grep -E '^ADMIN_TOKEN=' .env | sed 's/^ADMIN_TOKEN=//' || true)"
else
  ADMIN_TOKEN=""
fi

if [[ -z "$ADMIN_TOKEN" || "$ADMIN_TOKEN" == "change-me-admin-token" || "$ADMIN_TOKEN" == "replace-with-a-long-random-token" ]]; then
  ADMIN_TOKEN="$(openssl rand -hex 32 2>/dev/null || date +%s%N | sha256sum | awk '{print $1}')"
fi

cat > .env <<EOF_ENV
PORT=${CONTAINER_PORT}
HOST_PORT=${HOST_PORT}
ADMIN_TOKEN=${ADMIN_TOKEN}
DB_PATH=/app/data/licenses.db
PUBLIC_BASE_URL=${PUBLIC_BASE_URL}
EOF_ENV

docker compose up -d --build

echo ""
echo "CodeMate license server is running."
echo "Admin URL: ${PUBLIC_BASE_URL}/admin"
echo "Health URL: ${PUBLIC_BASE_URL}/health"
echo "Admin Token: ${ADMIN_TOKEN}"
echo ""
echo "Keep this token private. It is also saved in:"
echo "  ${APP_DIR}/backend/.env"
