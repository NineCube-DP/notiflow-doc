#!/usr/bin/env bash
set -euo pipefail

# ─── Config ───────────────────────────────────────────────────────────────────
VERSION="1.1.0"
REPO_RAW="https://raw.githubusercontent.com/NineCube-DP/notiflow-doc/main"
INSTALL_DIR="${NOTIFLOW_DIR:-$HOME/.notiflow}"

# ─── TUI ──────────────────────────────────────────────────────────────────────
RESET='\033[0m'; BOLD='\033[1m'
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[1;34m'; WHITE='\033[1;37m'; GRAY='\033[0;90m'

I_OK="✓"; I_ERR="✗"; I_WARN="!"; I_INFO="·"; I_ARROW="▶"
SPIN_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

_tw=$(tput cols 2>/dev/null || echo 64)
TW=$(( _tw > 64 ? 64 : _tw ))

ok()   { printf "  ${GREEN}${I_OK}${RESET}  %s\n"    "$*"; }
warn() { printf "  ${YELLOW}${I_WARN}${RESET}  %s\n" "$*"; }
info() { printf "  ${GRAY}${I_INFO}${RESET}  %s\n"   "$*"; }
die()  { printf "  ${RED}${I_ERR}${RESET}  %s\n" "$*" >&2; exit 1; }

hr() {
    printf "  ${GRAY}"
    printf '─%.0s' $(seq 1 $(( TW - 2 )))
    printf "${RESET}\n"
}

section() {
    local label="$1"
    local dashes=$(( TW - ${#label} - 7 ))
    [ $dashes -lt 1 ] && dashes=1
    printf "\n  ${GRAY}─── ${RESET}${BOLD}%s${RESET}${GRAY} $(printf '─%.0s' $(seq 1 $dashes))${RESET}\n\n" "$label"
}

tui_spin() {
    local label="$1"; shift
    local tmpout; tmpout=$(mktemp)
    local i=0
    "$@" >"$tmpout" 2>&1 &
    local pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${BLUE}%s${RESET}  %s " "${SPIN_FRAMES[$((i % 10))]}" "$label" >/dev/tty
        sleep 0.08
        i=$(( i + 1 ))
    done
    local rc=0
    wait "$pid" || rc=$?
    if [ $rc -eq 0 ]; then
        printf "\r  ${GREEN}${I_OK}${RESET}  %-50s\n" "$label"
    else
        printf "\r  ${RED}${I_ERR}${RESET}  %-50s\n" "$label"
        cat "$tmpout" >&2
        rm -f "$tmpout"
        exit $rc
    fi
    rm -f "$tmpout"
}

draw_menu() {
    local title="$1"; shift
    local inner=$(( TW - 6 ))
    echo
    printf "  ${GRAY}┌$(printf '─%.0s' $(seq 1 $inner))┐${RESET}\n"
    if [ -n "$title" ]; then
        printf "  ${GRAY}│${RESET}  ${BOLD}%-*s${RESET}  ${GRAY}│${RESET}\n" "$(( inner - 4 ))" "$title"
        printf "  ${GRAY}├$(printf '─%.0s' $(seq 1 $inner))┤${RESET}\n"
    fi
    local n=1
    for item in "$@"; do
        printf "  ${GRAY}│${RESET}  ${BLUE}[%d]${RESET}  %-*s${GRAY}│${RESET}\n" "$n" "$(( inner - 7 ))" "$item"
        n=$(( n + 1 ))
    done
    printf "  ${GRAY}└$(printf '─%.0s' $(seq 1 $inner))┘${RESET}\n"
    echo
}

# ─── Helpers ──────────────────────────────────────────────────────────────────
get_env()     { grep -E "^${1}=" "$INSTALL_DIR/.env" 2>/dev/null | cut -d= -f2 || echo "${2}"; }
rand_pass()   { openssl rand -hex 20; }
rand_secret() { openssl rand -base64 48; }

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
    hr
    printf '\n'
}

print_banner

# ─── Architecture ─────────────────────────────────────────────────────────────
OS=$(uname -s)
ARCH=$(uname -m)

case "$ARCH" in
    arm64|aarch64) PLATFORM="linux/arm64" ;;
    x86_64|amd64)  PLATFORM="linux/amd64" ;;
    *)             PLATFORM=""            ;;
esac

if [ -n "$PLATFORM" ]; then
    export DOCKER_DEFAULT_PLATFORM="$PLATFORM"
    info "Architecture: $ARCH ($PLATFORM)"
else
    warn "Unknown architecture '$ARCH' — using runtime default platform."
fi

# ─── Preflight ────────────────────────────────────────────────────────────────
command -v curl    >/dev/null 2>&1 || die "curl is required but not installed."
command -v openssl >/dev/null 2>&1 || die "openssl is required but not installed."

# ─── Runtime detection ────────────────────────────────────────────────────────
# Docker preferred; falls back to Podman. Checks daemon reachability, not just binary presence.
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

info "Runtime: $COMPOSE"

# ─── Podman machine (macOS) ───────────────────────────────────────────────────
if [[ "$COMPOSE" == podman* ]] && [[ "$OS" == "Darwin" ]]; then
    if podman machine list --format '{{.Running}}' 2>/dev/null | grep -q 'true'; then
        info "Podman machine is already running."
    elif podman machine list --format '{{.Name}}' 2>/dev/null | grep -q '.'; then
        info "Starting Podman machine ..."
        podman machine start
    else
        info "Initializing Podman machine ..."
        podman machine init --now
    fi
fi

# ─── Setup directory ──────────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

info "Working directory: $INSTALL_DIR"
echo

# ─── Menu (existing installation) ─────────────────────────────────────────────
if [ -f .env ]; then
    printf '\033[2J\033[H'
    print_banner

    info "Installed at $INSTALL_DIR"

    draw_menu "Manage NotiFlow" \
        "Update       pull latest & restart" \
        "Reconfigure  edit configuration" \
        "Uninstall    remove all data" \
        "Exit"

    # Drain buffered newline left over from launching the script (e.g. curl | bash)
    read -r -t 0.1 _ </dev/tty 2>/dev/null || true

    MENU_CHOICE=""
    while [ -z "$MENU_CHOICE" ]; do
        printf "  ${BLUE}${I_ARROW}${RESET}  Choose [1-4]: " >/dev/tty
        read -r MENU_CHOICE </dev/tty || true
    done

    echo

    case "$MENU_CHOICE" in
        1)
            section "Updating"
            tui_spin "Downloading latest compose file" \
                curl -fsSL "$REPO_RAW/docker-compose.yaml" -o docker-compose.yaml
            section "Pulling images"
            $COMPOSE pull
            section "Starting NotiFlow"
            $COMPOSE up -d
            APP_PORT=$(get_env APP_PORT 8080)
            DASH_PORT=$(get_env DASHBOARD_PORT 3080)
            echo
            hr
            ok "NotiFlow is up!"
            info "App         http://localhost:${APP_PORT}"
            info "Dashboard   http://localhost:${DASH_PORT}"
            hr
            ;;
        2)
            section "Reconfiguring"
            tui_spin "Downloading latest .env.example" \
                curl -fsSL "$REPO_RAW/.env.example" -o .env.example

            BACKUP=".env.backup.$(date +%Y%m%d_%H%M%S)"
            cp .env "$BACKUP"
            ok "Backed up config to $BACKUP"

            awk '
                NR==FNR {
                    if ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
                        eq = index($0, "=")
                        old[substr($0,1,eq-1)] = substr($0,eq)
                    }
                    next
                }
                /^[A-Za-z_][A-Za-z0-9_]*=/ {
                    eq = index($0, "=")
                    key = substr($0, 1, eq-1)
                    if (key in old) { print key old[key]; next }
                }
                { print }
            ' "$BACKUP" .env.example > .env
            ok "Config rebased on latest template."

            EDITOR_CMD="${EDITOR:-}"
            for e in nano vi vim; do
                [ -z "$EDITOR_CMD" ] && command -v "$e" >/dev/null 2>&1 && EDITOR_CMD="$e"
            done
            if [ -n "$EDITOR_CMD" ]; then
                info "Opening .env in ${EDITOR_CMD} — save and quit to continue ..."
                "$EDITOR_CMD" .env </dev/tty >/dev/tty
            else
                warn "No text editor found. Edit $INSTALL_DIR/.env manually, then run:"
                info "  $COMPOSE up -d"
                exit 0
            fi

            section "Restarting services"
            $COMPOSE up -d
            ok "NotiFlow restarted with new configuration."
            ;;
        3)
            echo
            warn "This will stop all NotiFlow services and delete $INSTALL_DIR."
            printf "  ${BLUE}${I_ARROW}${RESET}  Type 'yes' to confirm: " >/dev/tty
            read -r CONFIRM </dev/tty || true
            echo
            if [ "$CONFIRM" = "yes" ]; then
                section "Uninstalling"
                $COMPOSE down -v
                ok "Services stopped."
                rm -rf "$INSTALL_DIR"
                ok "NotiFlow uninstalled."
            else
                info "Uninstall aborted."
            fi
            ;;
        4)
            info "Exiting."
            ;;
        *)
            die "Invalid option."
            ;;
    esac
    exit 0
fi

# ─── Fresh install ────────────────────────────────────────────────────────────
section "Installing NotiFlow"

tui_spin "Downloading docker-compose.yaml" \
    curl -fsSL "$REPO_RAW/docker-compose.yaml" -o docker-compose.yaml

tui_spin "Downloading .env.example" \
    curl -fsSL "$REPO_RAW/.env.example" -o .env.example

cp .env.example .env

JWT=$(rand_secret)
DBPASS=$(rand_pass)

sed -i.bak "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${DBPASS}|" .env
sed -i.bak "s|^JWT_SECRET=.*|JWT_SECRET=${JWT}|"                  .env

DASHPORT=$(get_env DASHBOARD_PORT 3080)
sed -i.bak "s|^CORS_ORIGINS=.*|CORS_ORIGINS=http://localhost:${DASHPORT}|" .env
rm -f .env.bak

ok "Configuration generated."
warn "Review $INSTALL_DIR/.env before exposing this service publicly."

section "Pulling images"
$COMPOSE pull

section "Starting NotiFlow"
$COMPOSE up -d

# ─── Done ─────────────────────────────────────────────────────────────────────
APP_PORT=$(get_env APP_PORT 8080)
DASH_PORT=$(get_env DASHBOARD_PORT 3080)

echo
hr
ok "NotiFlow is up!"
info "App         http://localhost:${APP_PORT}"
info "Dashboard   http://localhost:${DASH_PORT}"
echo
info "Useful commands (run from $INSTALL_DIR):"
info "  View logs : $COMPOSE logs -f"
info "  Stop      : $COMPOSE down"
info "  Update    : run this script again"
hr
