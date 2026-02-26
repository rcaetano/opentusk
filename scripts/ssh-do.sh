#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ─── Help ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

SSH into the OpenTusk DigitalOcean droplet.

Options:
  --tunnel    Forward gateway and Poseidon ports ($GATEWAY_PORT, $POSEIDON_PORT) over SSH
  --ip IP     Connect to a specific IP instead of auto-detecting
  --help      Show this help message

Examples:
  $(basename "$0")              # plain SSH session
  $(basename "$0") --tunnel     # SSH with port forwarding for gateway UI
  $(basename "$0") --ip 1.2.3.4 --tunnel
EOF
    exit 0
}

# ─── Parse flags ─────────────────────────────────────────────────────────────
TUNNEL=false
IP=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tunnel) TUNNEL=true; shift ;;
        --ip)     IP="$2"; shift 2 ;;
        --help|-h) usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

# ─── Prerequisites ───────────────────────────────────────────────────────────
require_cmd ssh

# ─── Resolve IP ──────────────────────────────────────────────────────────────
if [[ -z "$IP" ]]; then
    require_cmd doctl "doctl is required to auto-detect droplet IP. Install it or use --ip."
    IP=$(get_droplet_ip)
fi

# ─── Validate SSH key ────────────────────────────────────────────────────────
if [[ -z "$DO_SSH_KEY_FILE" ]]; then
    log_error "DO_SSH_KEY_FILE is not configured."
    log_error "Set it in config.env or run: opentusk init"
    exit 1
fi
if [[ ! -f "$DO_SSH_KEY_FILE" ]]; then
    log_error "SSH key file not found: $DO_SSH_KEY_FILE"
    exit 1
fi

# ─── Connect ─────────────────────────────────────────────────────────────────
if [[ "$TUNNEL" == "true" ]]; then
    log_info "Connecting with port forwarding (gateway: $GATEWAY_PORT, poseidon: $POSEIDON_PORT)..."
    log_info "Open http://localhost:${GATEWAY_PORT} in your browser once connected."
    exec ssh -i "$DO_SSH_KEY_FILE" -L "${GATEWAY_PORT}:localhost:${GATEWAY_PORT}" \
             -L "${POSEIDON_PORT}:localhost:${POSEIDON_PORT}" \
             "${DO_SSH_USER}@${IP}"
else
    log_info "Connecting to ${DO_SSH_USER}@${IP}..."
    exec ssh -i "$DO_SSH_KEY_FILE" "${DO_SSH_USER}@${IP}"
fi
