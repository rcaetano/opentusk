# shellcheck shell=bash
# config.sh — Shared variables and helper functions for MustangClaw scripts
# This file is sourced by other scripts; do not execute directly.

# ─── Ports (used in remote Tailscale serve checks) ─────────────────────────
GATEWAY_PORT=18789
POSEIDON_PORT=18791

# ─── DigitalOcean ────────────────────────────────────────────────────────────
DO_DROPLET_NAME="mustangclaw"
DO_REGION="fra1"
DO_SIZE="s-2vcpu-4gb"
DO_IMAGE="openclaw"                           # DO marketplace image
DO_SSH_KEY_FINGERPRINT=""                     # auto-detected or set manually
DO_TAG="mustangclaw"
DO_SSH_USER="root"                            # marketplace convention

# ─── Remote Paths ──────────────────────────────────────────────────────────
REMOTE_OPENCLAW_HOME="/home/openclaw"         # marketplace user's home
REMOTE_POSEIDON_DIR="/opt/poseidon"           # where Poseidon is deployed

# ─── Poseidon ─────────────────────────────────────────────────────────────
POSEIDON_REPO="git@github.com:rcaetano/poseidon.git"
POSEIDON_BRANCH="main"

# ─── Tailscale (optional) ───────────────────────────────────────────────────
TAILSCALE_ENABLED=false
TAILSCALE_AUTH_KEY=""                        # tskey-auth-... from Tailscale admin
TAILSCALE_MODE="serve"                      # "serve" (tailnet-only) or "funnel" (public)

# ─── Resolve project root early (needed for config.env lookup) ────────────
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ─── User Overrides (written by mustangclaw init) ─────────────────────────
if [[ -f "$PROJECT_ROOT/config.env" ]]; then
    source "$PROJECT_ROOT/config.env"
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
