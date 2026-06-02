#!/usr/bin/env bash
set -euo pipefail

# ─── Config ───────────────────────────────────────────────────────────────────
REPO_RAW="https://raw.githubusercontent.com/NineCube-DP/notiflow-doc/main"
INSTALL_DIR="${NOTIFLOW_DIR:-$HOME/.notiflow}"

# ─── Helpers ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[notiflow]${NC} $*"; }
warn() { echo -e "${YELLOW}[notiflow]${NC} $*"; }
die()  { echo -e "${RED}[notiflow]${NC} $*" >&2; exit 1; }

get_env() { grep -E "^${1}=" "$INSTALL_DIR/.env" 2>/dev/null | cut -d= -f2 || echo "${2}"; }

# hex output avoids any pipeline/filtering issues across platforms
rand_pass()   { openssl rand -hex 20; }        # 40-char hex, safe for DB passwords
rand_secret() { openssl rand -base64 48; }     # base64, safe for JWT (no | \ & in output)

# ─── Preflight ────────────────────────────────────────────────────────────────
command -v docker  >/dev/null 2>&1 || die "Docker is not installed. See https://docs.docker.com/get-docker/"
command -v curl    >/dev/null 2>&1 || die "curl is required but not installed."
command -v openssl >/dev/null 2>&1 || die "openssl is required but not installed."

# Support both Compose v2 (plugin) and v1 (standalone binary)
if docker compose version >/dev/null 2>&1; then
    COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE="docker-compose"
else
    die "Docker Compose is not installed (tried 'docker compose' and 'docker-compose')."
fi

# ─── Setup directory ──────────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

log "Working directory: $INSTALL_DIR"

# ─── Download files ───────────────────────────────────────────────────────────
log "Downloading docker-compose.yaml ..."
curl -fsSL "$REPO_RAW/docker-compose.yaml" -o docker-compose.yaml

log "Downloading .env.example ..."
curl -fsSL "$REPO_RAW/.env.example" -o .env.example

# ─── Create .env ──────────────────────────────────────────────────────────────
if [ -f .env ]; then
    log ".env already exists — skipping generation (delete it to reset)."
else
    cp .env.example .env

    JWT=$(rand_secret)
    DBPASS=$(rand_pass)

    # sed -i.bak works on both BSD (macOS) and GNU (Linux/WSL) sed
    sed -i.bak "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${DBPASS}|" .env
    sed -i.bak "s|^JWT_SECRET=.*|JWT_SECRET=${JWT}|"                  .env
    rm -f .env.bak

    warn ".env created with auto-generated secrets."
    warn "Review $INSTALL_DIR/.env before exposing this service publicly."
fi

# ─── Pull latest images & start ───────────────────────────────────────────────
log "Pulling latest images ..."
$COMPOSE pull

log "Starting NotiFlow services ..."
$COMPOSE up -d

# ─── Done ─────────────────────────────────────────────────────────────────────
APP_PORT=$(get_env APP_PORT 8080)
DASH_PORT=$(get_env DASHBOARD_PORT 80)

echo ""
log "NotiFlow is up!"
log "  App:       http://localhost:${APP_PORT}"
log "  Dashboard: http://localhost:${DASH_PORT}"
echo ""
log "Useful commands (run from $INSTALL_DIR):"
log "  View logs : $COMPOSE logs -f"
log "  Stop      : $COMPOSE down"
log "  Update    : $COMPOSE pull && $COMPOSE up -d"
