# shellcheck shell=bash
# config.sh — Shared variables and helper functions for MustangClaw Docker scripts
# This file is sourced by other scripts; do not execute directly.

# ─── Repository & Image ─────────────────────────────────────────────────────
OPENCLAW_REPO="https://github.com/openclaw/openclaw.git"
OPENCLAW_REF=""                                   # pinned commit (empty = latest main)
OPENCLAW_DIR="./openclaw"                         # local clone path (relative to project root)
OPENCLAW_IMAGE="mustangclaw:local"
OPENCLAW_CONFIG_DIR="$HOME/.openclaw"
OPENCLAW_WORKSPACE_DIR="$HOME/.openclaw/workspace"

# ─── Docker Ports ────────────────────────────────────────────────────────────
GATEWAY_PORT=18789
BRIDGE_PORT=18790

# ─── Poseidon ──────────────────────────────────────────────────────────────
POSEIDON_REPO="https://github.com/rcaetano/poseidon.git"
POSEIDON_DIR="./poseidon"                      # local clone path (relative to project root)
POSEIDON_PORT=18791

# ─── DigitalOcean ────────────────────────────────────────────────────────────
DO_DROPLET_NAME="mustangclaw"
DO_REGION="fra1"
DO_SIZE="s-4vcpu-8gb"
DO_IMAGE="docker-20-04"
DO_SSH_KEY_FINGERPRINT=""                   # auto-detected or set manually
DO_TAG="mustangclaw"

# ─── Tailscale (optional) ───────────────────────────────────────────────────
TAILSCALE_ENABLED=false
TAILSCALE_AUTH_KEY=""                        # tskey-auth-... from Tailscale admin
TAILSCALE_MODE="serve"                      # "serve" (tailnet-only) or "funnel" (public)

# ─── Auto-migration: ~/.mustangclaw → ~/.openclaw ──────────────────────────
if [[ -d "$HOME/.mustangclaw" && ! -d "$HOME/.openclaw" ]]; then
    mv "$HOME/.mustangclaw" "$HOME/.openclaw"
    [[ -t 1 ]] && printf '\033[0;32m[INFO]\033[0m Migrated config: ~/.mustangclaw -> ~/.openclaw\n'
fi

# ─── User Overrides (written by mustangclaw init) ─────────────────────────
if [[ -f "$OPENCLAW_CONFIG_DIR/config.env" ]]; then
    source "$OPENCLAW_CONFIG_DIR/config.env"
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

# ─── JSON Helpers (openclaw.json) ─────────────────────────────────────────────

# Read the gateway token from openclaw.json.
# Prints the token (empty string if not found).
read_json_token() {
    local json_file="${1:-$OPENCLAW_CONFIG_DIR/openclaw.json}"
    [[ -f "$json_file" ]] || return 0
    python3 -c "
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
    print(cfg.get('gateway',{}).get('auth',{}).get('token',''))
except: pass
" "$json_file" 2>/dev/null || true
}

# Write the gateway token to openclaw.json (sets auth.mode=token).
write_json_token() {
    local token="$1"
    local json_file="${2:-$OPENCLAW_CONFIG_DIR/openclaw.json}"
    [[ -f "$json_file" ]] || return 1
    python3 -c "
import json, sys
p, tok = sys.argv[1], sys.argv[2]
with open(p, 'r') as f:
    cfg = json.load(f)
gw = cfg.setdefault('gateway', {})
auth = gw.setdefault('auth', {})
auth['mode'] = 'token'
auth['token'] = tok
with open(p, 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
" "$json_file" "$token"
}

# Patch openclaw.json for Docker compatibility: set bind=lan, remove tailscale.
# Returns 0 if changes were made, 1 if already correct.
patch_json_for_docker() {
    local json_file="${1:-$OPENCLAW_CONFIG_DIR/openclaw.json}"
    [[ -f "$json_file" ]] || return 1
    python3 -c "
import json, sys
with open(sys.argv[1], 'r') as f:
    cfg = json.load(f)
gw = cfg.get('gateway', {})
changed = False
if gw.get('bind') != 'lan':
    gw['bind'] = 'lan'
    changed = True
if 'tailscale' in gw:
    del gw['tailscale']
    changed = True
# non-loopback bind requires controlUi.allowedOrigins or host-header fallback
cui = gw.get('controlUi', {})
if not cui.get('dangerouslyAllowHostHeaderOriginFallback'):
    cui['dangerouslyAllowHostHeaderOriginFallback'] = True
    gw['controlUi'] = cui
    changed = True
if changed:
    cfg['gateway'] = gw
    with open(sys.argv[1], 'w') as f:
        json.dump(cfg, f, indent=2)
        f.write('\n')
sys.exit(0 if changed else 1)
" "$json_file" 2>/dev/null
}

# ─── Docker Helpers ───────────────────────────────────────────────────────────

# Print the name of the running gateway container (empty if not running).
get_running_gateway() {
    docker ps --filter "name=^mustangclaw$" --filter "status=running" \
        --format '{{.Names}}' 2>/dev/null | head -1
}

# Require the gateway container to be running; exit with error if not.
# Prints the container name on success.
require_running_gateway() {
    local container
    container=$(get_running_gateway)
    if [[ -z "$container" ]]; then
        log_error "Gateway container is not running. Start it with 'mustangclaw run'."
        exit 1
    fi
    echo "$container"
}

# Set COMPOSE_FILES array with the correct docker compose file flags.
set_compose_files() {
    COMPOSE_FILES=(-f "$OPENCLAW_DIR/docker-compose.yml")
    if [[ -f "$OPENCLAW_DIR/docker-compose.override.yml" ]]; then
        COMPOSE_FILES+=(-f "$OPENCLAW_DIR/docker-compose.override.yml")
    fi
}

# Open a URL in the default browser.
open_url() {
    local url="$1"
    if command -v open &>/dev/null; then
        open "$url"
    elif command -v xdg-open &>/dev/null; then
        xdg-open "$url"
    elif command -v wslview &>/dev/null; then
        wslview "$url"
    else
        log_warn "Could not detect a browser opener. Open this URL manually:"
        echo "$url"
    fi
}
