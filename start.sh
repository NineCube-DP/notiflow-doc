#!/usr/bin/env bash
set -euo pipefail

# ─── Config ───────────────────────────────────────────────────────────────────
VERSION="1.0.0"
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

# ─── Banner ───────────────────────────────────────────────────────────────────
print_banner() {
    printf '\n'
    printf '\033[1;37m _   _       _   _ \033[1;34m ______ _               \033[0m\n'
    printf '\033[1;37m| \\ | |     | | (_)\033[1;34m|  ____| |              \033[0m\n'
    printf '\033[1;37m|  \\| | ___ | |_ _ \033[1;34m| |__  | | _____      __\033[0m\n'
    printf '\033[1;37m| . ` |/ _ \\| __| |\033[1;34m|  __| | |/ _ \\ \\ /\\ / /\033[0m\n'
    printf '\033[1;37m| |\\  | (_) | |_| |\033[1;34m| |    | | (_) \\ V  V / \033[0m\n'
    printf '\033[1;37m|_| \\_|\\___/ \\__|_|\033[1;34m|_|    |_|\\___/ \\_/\\_/  \033[0m\n'
    printf "\033[0;90m                              v${VERSION}\033[0m\n"
    printf '\n'
}

print_banner

# ─── Architecture ─────────────────────────────────────────────────────────────
OS=$(uname -s)
ARCH=$(uname -m)

case "$ARCH" in
    arm64|aarch64) PLATFORM="linux/arm64"  ;;
    x86_64|amd64)  PLATFORM="linux/amd64"  ;;
    *)             PLATFORM=""             ;;
esac

if [ -n "$PLATFORM" ]; then
    export DOCKER_DEFAULT_PLATFORM="$PLATFORM"
    log "Architecture: $ARCH ($PLATFORM)"
else
    warn "Unknown architecture '$ARCH' — using runtime default platform."
fi

# ─── Preflight ────────────────────────────────────────────────────────────────
command -v curl    >/dev/null 2>&1 || die "curl is required but not installed."
command -v openssl >/dev/null 2>&1 || die "openssl is required but not installed."

# Detect container runtime (Docker preferred, Podman as fallback)
# For each runtime also detect the compose command (v2 plugin or v1 standalone).
COMPOSE=""
DOCKER_DAEMON_WARN=""

if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
        if docker compose version >/dev/null 2>&1; then
            COMPOSE="docker compose"
        elif command -v docker-compose >/dev/null 2>&1; then
            COMPOSE="docker-compose"
        else
            die "Docker found but Compose is not installed (tried 'docker compose' and 'docker-compose')."
        fi
    else
        DOCKER_DAEMON_WARN="Docker binary found but daemon is not running — falling back to Podman."
    fi
fi

if [ -z "$COMPOSE" ]; then
    [ -n "$DOCKER_DAEMON_WARN" ] && warn "$DOCKER_DAEMON_WARN"
    if command -v podman >/dev/null 2>&1; then
        if podman compose version >/dev/null 2>&1; then
            COMPOSE="podman compose"
        elif command -v podman-compose >/dev/null 2>&1; then
            COMPOSE="podman-compose"
        else
            die "Podman found but podman-compose is not installed. Install it with: pip3 install podman-compose"
        fi
    else
        die "No container runtime found. Install Docker (https://docs.docker.com/get-docker/) or Podman (https://podman.io/getting-started/installation)."
    fi
fi

log "Runtime: $COMPOSE"

# Podman on macOS needs a running VM (podman machine).
# Start the default machine if it exists but isn't running; init+start if it doesn't exist yet.
if [[ "$COMPOSE" == podman* ]] && [[ "$OS" == "Darwin" ]]; then
    if podman machine list --format '{{.Running}}' 2>/dev/null | grep -q 'true'; then
        log "Podman machine is already running."
    elif podman machine list --format '{{.Name}}' 2>/dev/null | grep -q '.'; then
        log "Starting Podman machine ..."
        podman machine start
    else
        log "Initializing Podman machine ..."
        podman machine init --now
    fi
fi

# ─── Setup directory ──────────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

log "Working directory: $INSTALL_DIR"

# ─── Menu (existing installation) ─────────────────────────────────────────────
if [ -f .env ]; then
    echo ""
    log "NotiFlow is already installed."
    echo ""
    echo "  1) Update      — pull latest images and restart"
    echo "  2) Reconfigure — regenerate .env with new secrets"
    echo "  3) Uninstall   — stop all services and remove data"
    echo "  4) Exit"
    echo ""
    # Drain any buffered newline left over from launching the script (e.g. curl | bash)
    read -r -t 0.1 _ </dev/tty 2>/dev/null || true

    MENU_CHOICE=""
    while [ -z "$MENU_CHOICE" ]; do
        printf "Choose [1-4]: " >/dev/tty
        read -r MENU_CHOICE </dev/tty || true
    done

    case "$MENU_CHOICE" in
        1)
            log "Downloading latest docker-compose.yaml ..."
            curl -fsSL "$REPO_RAW/docker-compose.yaml" -o docker-compose.yaml
            log "Pulling latest images ..."
            $COMPOSE pull
            log "Restarting NotiFlow ..."
            $COMPOSE up -d
            APP_PORT=$(get_env APP_PORT 8080)
            DASH_PORT=$(get_env DASHBOARD_PORT 3080)
            echo ""
            log "NotiFlow is up!"
            log "  App:       http://localhost:${APP_PORT}"
            log "  Dashboard: http://localhost:${DASH_PORT}"
            ;;
        2)
            log "Downloading latest .env.example ..."
            curl -fsSL "$REPO_RAW/.env.example" -o .env.example
            rm -f .env
            cp .env.example .env
            JWT=$(rand_secret)
            DBPASS=$(rand_pass)
            sed -i.bak "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${DBPASS}|" .env
            sed -i.bak "s|^JWT_SECRET=.*|JWT_SECRET=${JWT}|"                  .env
            DASHPORT=$(get_env DASHBOARD_PORT 3080)
            sed -i.bak "s|^CORS_ORIGINS=.*|CORS_ORIGINS=http://localhost:${DASHPORT}|" .env
            rm -f .env.bak
            warn ".env regenerated with new secrets."
            log "Restarting NotiFlow with new configuration ..."
            $COMPOSE up -d
            ;;
        3)
            warn "This will stop all NotiFlow services and delete $INSTALL_DIR."
            printf "Type 'yes' to confirm: " >/dev/tty
            read -r CONFIRM </dev/tty
            if [ "$CONFIRM" = "yes" ]; then
                log "Stopping services and removing volumes ..."
                $COMPOSE down -v
                log "Removing $INSTALL_DIR ..."
                rm -rf "$INSTALL_DIR"
                log "NotiFlow uninstalled."
            else
                log "Uninstall aborted."
            fi
            ;;
        4)
            log "Exiting."
            ;;
        *)
            die "Invalid option."
            ;;
    esac
    exit 0
fi

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

    DASHPORT=$(get_env DASHBOARD_PORT 3080)
    sed -i.bak "s|^CORS_ORIGINS=.*|CORS_ORIGINS=http://localhost:${DASHPORT}|" .env
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
