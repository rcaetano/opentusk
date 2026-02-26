# shellcheck shell=bash
# config.sh — Shared variables and helper functions for OpenTusk scripts
# This file is sourced by other scripts; do not execute directly.

# ─── Ports (used in remote Tailscale serve checks) ─────────────────────────
GATEWAY_PORT=18789
POSEIDON_PORT=18791

# ─── DigitalOcean ────────────────────────────────────────────────────────────
DO_DROPLET_NAME="opentusk"
DO_REGION="fra1"
DO_SIZE="s-2vcpu-4gb"
DO_IMAGE="openclaw"                           # DO marketplace image
DO_SSH_KEY_FINGERPRINT=""                     # auto-detected or set manually
DO_SSH_KEY_FILE=""                            # local SSH private key path (blank = ssh-agent default)
DO_TAG="opentusk"
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

# ─── User Overrides (written by opentusk init) ────────────────────────────
if [[ -f "$PROJECT_ROOT/config.env" ]]; then
    source "$PROJECT_ROOT/config.env"
fi

# Expand tilde in SSH key path (config.env may contain ~/...)
DO_SSH_KEY_FILE="${DO_SSH_KEY_FILE/#\~/$HOME}"

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

# ─── SSH Helpers ────────────────────────────────────────────────────────────

# Build base SSH options: includes key file when DO_SSH_KEY_FILE is set.
SSH_BASE_OPTS=(-o StrictHostKeyChecking=accept-new)
if [[ -n "${DO_SSH_KEY_FILE:-}" && -f "$DO_SSH_KEY_FILE" ]]; then
    SSH_BASE_OPTS+=(-i "$DO_SSH_KEY_FILE" -o IdentitiesOnly=yes)
fi

# remote_exec <ip> [command...]
#   With args:   runs command on remote via ssh
#   Without args: pipes stdin to bash on remote (heredoc mode)
#
# To pass variables into a quoted heredoc, use:
#   remote_exec "$IP" bash -s "$var1" "$var2" <<'EOF'
#     echo "$1" "$2"
#   EOF
remote_exec() {
    local ip="$1"; shift
    if [[ $# -gt 0 ]]; then
        ssh "${SSH_BASE_OPTS[@]}" "${DO_SSH_USER}@${ip}" "$@"
    else
        ssh "${SSH_BASE_OPTS[@]}" "${DO_SSH_USER}@${ip}" bash
    fi
}

# wait_for_ssh <ip> [timeout] [label]
#   Polls SSH connectivity. Returns 0 on success, 1 on timeout.
wait_for_ssh() {
    local ip="$1"
    local timeout="${2:-180}"
    local label="${3:-SSH}"
    local elapsed=0
    while true; do
        if ssh "${SSH_BASE_OPTS[@]}" -o ConnectTimeout=5 "${DO_SSH_USER}@${ip}" true 2>/dev/null; then
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        if [[ $elapsed -ge $timeout ]]; then
            log_error "$label not ready after ${timeout}s."
            return 1
        fi
        printf "."
    done
}
