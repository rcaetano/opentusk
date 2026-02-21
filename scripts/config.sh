# config.sh — Shared variables and helper functions for MustangClaw Docker scripts
# This file is sourced by other scripts; do not execute directly.

# ─── Repository & Image ─────────────────────────────────────────────────────
MUSTANGCLAW_REPO="https://github.com/openclaw/openclaw.git"
MUSTANGCLAW_DIR="./openclaw"                      # local clone path (relative to project root)
MUSTANGCLAW_IMAGE="mustangclaw:local"
MUSTANGCLAW_CONFIG_DIR="$HOME/.mustangclaw"
MUSTANGCLAW_WORKSPACE_DIR="$HOME/.mustangclaw/workspace"

# ─── Docker Ports ────────────────────────────────────────────────────────────
GATEWAY_PORT=18789
BRIDGE_PORT=18790

# ─── DigitalOcean ────────────────────────────────────────────────────────────
DO_DROPLET_NAME="mustangclaw"
DO_REGION="nyc3"
DO_SIZE="s-2vcpu-4gb"
DO_IMAGE="docker-20-04"
DO_SSH_KEY_FINGERPRINT=""                   # auto-detected or set manually
DO_TAG="mustangclaw"

# ─── Tailscale (optional) ───────────────────────────────────────────────────
TAILSCALE_ENABLED=false
TAILSCALE_AUTH_KEY=""                        # tskey-auth-... from Tailscale admin
TAILSCALE_MODE="serve"                      # "serve" (tailnet-only) or "funnel" (public)

# ─── User Overrides (written by mustangclaw init) ─────────────────────────
if [[ -f "$MUSTANGCLAW_CONFIG_DIR/config.env" ]]; then
    source "$MUSTANGCLAW_CONFIG_DIR/config.env"
fi

# ─── Colors ──────────────────────────────────────────────────────────────────
_RED='\033[0;31m'
_YELLOW='\033[0;33m'
_GREEN='\033[0;32m'
_CYAN='\033[0;36m'
_NC='\033[0m'

# ─── Helper Functions ────────────────────────────────────────────────────────

log_info() {
    printf "${_GREEN}[INFO]${_NC} %s\n" "$*"
}

log_warn() {
    printf "${_YELLOW}[WARN]${_NC} %s\n" "$*" >&2
}

log_error() {
    printf "${_RED}[ERROR]${_NC} %s\n" "$*" >&2
}

# Check that a command exists or exit with a message.
require_cmd() {
    local cmd="$1"
    local msg="${2:-$cmd is required but not installed.}"
    if ! command -v "$cmd" &>/dev/null; then
        log_error "$msg"
        exit 1
    fi
}

# Resolve the droplet IP via doctl.
get_droplet_ip() {
    local name="${1:-$DO_DROPLET_NAME}"
    local ip
    ip=$(doctl compute droplet list --tag-name "$DO_TAG" \
        --format Name,PublicIPv4 --no-header \
        | awk -v n="$name" '$1 == n { print $2 }')
    if [[ -z "$ip" ]]; then
        log_error "Could not find droplet '$name'. Is it running?"
        return 1
    fi
    echo "$ip"
}

# Prompt user for y/n confirmation. Skipped when FORCE=true.
confirm() {
    local prompt="${1:-Are you sure?}"
    if [[ "${FORCE:-false}" == "true" ]]; then
        return 0
    fi
    printf "${_CYAN}%s [y/N]${_NC} " "$prompt"
    read -r answer
    case "$answer" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# Resolve project root (directory containing this scripts/ folder).
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
