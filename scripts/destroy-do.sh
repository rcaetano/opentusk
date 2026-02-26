#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ─── Help ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Destroy the OpenTusk DigitalOcean droplet.

Options:
  --force     Skip confirmation prompt
  --help      Show this help message

Examples:
  $(basename "$0")           # destroy with confirmation
  $(basename "$0") --force   # destroy without confirmation
EOF
    exit 0
}

# ─── Parse flags ─────────────────────────────────────────────────────────────
FORCE=false
for arg in "$@"; do
    case "$arg" in
        --force)   FORCE=true ;;
        --help|-h) usage ;;
        *) log_error "Unknown option: $arg"; usage ;;
    esac
done
export FORCE

# ─── Prerequisites ───────────────────────────────────────────────────────────
require_cmd doctl

# ─── Look up droplet ────────────────────────────────────────────────────────
DROPLET_INFO=$(doctl compute droplet list --tag-name "$DO_TAG" \
    --format ID,Name,PublicIPv4 --no-header \
    | awk -v n="$DO_DROPLET_NAME" '$2 == n { print $0 }')

if [[ -z "$DROPLET_INFO" ]]; then
    log_warn "No droplet named '$DO_DROPLET_NAME' found with tag '$DO_TAG'."
    exit 0
fi

DROPLET_ID=$(echo "$DROPLET_INFO" | awk '{ print $1 }')
DROPLET_IP=$(echo "$DROPLET_INFO" | awk '{ print $3 }')

log_warn "Found droplet: $DROPLET_INFO"

# ─── Confirm ─────────────────────────────────────────────────────────────────
if ! confirm "Destroy droplet '$DO_DROPLET_NAME' ($DROPLET_ID)? This cannot be undone."; then
    log_info "Aborted."
    exit 0
fi

# ─── Destroy ─────────────────────────────────────────────────────────────────
log_info "Destroying droplet $DROPLET_ID..."
doctl compute droplet delete "$DROPLET_ID" --force

# ─── Clean up known_hosts ───────────────────────────────────────────────────
if [[ -n "$DROPLET_IP" && -f "$HOME/.ssh/known_hosts" ]]; then
    ssh-keygen -R "$DROPLET_IP" 2>/dev/null || true
    log_info "Removed $DROPLET_IP from ~/.ssh/known_hosts."
fi

log_info "Droplet '$DO_DROPLET_NAME' destroyed."
