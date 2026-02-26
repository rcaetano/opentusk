#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ─── Help ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Upgrade the remote OpenTusk droplet. Uses the marketplace updater for
OpenClaw and pulls the latest Poseidon source via git on the remote.

Options:
  --ip IP           Droplet IP (auto-detected if omitted)
  --rollback        Revert OpenClaw to previous version on remote
  --help            Show this help message

Examples:
  $(basename "$0")                  # upgrade remote droplet
  $(basename "$0") --ip 1.2.3.4    # upgrade specific droplet
  $(basename "$0") --rollback       # revert OpenClaw on remote
EOF
    exit 0
}

# ─── Parse flags ─────────────────────────────────────────────────────────────
IP=""
ROLLBACK=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)       IP="$2"; shift 2 ;;
        --rollback) ROLLBACK=true; shift ;;
        --help|-h)  usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

# ─── Prerequisites ──────────────────────────────────────────────────────────
require_cmd ssh

if [[ -z "$IP" ]]; then
    require_cmd doctl "doctl is required to auto-detect droplet IP. Install it or use --ip."
    IP=$(get_droplet_ip)
fi

log_info "Upgrading remote at $IP..."

# 1. Update OpenClaw via marketplace updater (or rollback)
if [[ "$ROLLBACK" == "true" ]]; then
    log_info "Rolling back OpenClaw on remote..."
    remote_exec "$IP" <<'OCUPDATE'
set -euo pipefail
if [[ -x /opt/rollback-openclaw.sh ]]; then
    /opt/rollback-openclaw.sh
else
    echo "Marketplace rollback script not found — skipping OpenClaw rollback."
fi
systemctl restart openclaw
OCUPDATE
else
    log_info "Updating OpenClaw on remote..."
    remote_exec "$IP" <<'OCUPDATE'
set -euo pipefail
if [[ -x /opt/update-openclaw.sh ]]; then
    /opt/update-openclaw.sh
else
    echo "Marketplace updater not found — skipping OpenClaw update."
fi
systemctl restart openclaw
OCUPDATE
fi

# 2. Pull latest Poseidon source via git on the remote
if [[ -n "${POSEIDON_REPO:-}" ]]; then
    log_info "Pulling and rebuilding Poseidon on remote..."
    remote_exec "$IP" bash -s "$REMOTE_POSEIDON_DIR" "$POSEIDON_BRANCH" <<'POSBUILD'
set -euo pipefail
POS_DIR="$1"; POS_BRANCH="$2"
cd "$POS_DIR"
git fetch origin
git reset --hard "origin/$POS_BRANCH"
pnpm install --frozen-lockfile
pnpm --filter @poseidon/web build
chown -R openclaw:openclaw "$POS_DIR"
systemctl restart poseidon
POSBUILD
else
    log_warn "POSEIDON_REPO not set — skipping Poseidon upgrade."
fi

# 3. Verify Tailscale serve (re-apply if missing)
if [[ "$TAILSCALE_ENABLED" == "true" ]]; then
    log_info "Verifying Tailscale serve configuration..."
    SERVE_OK=$(remote_exec "$IP" bash -s "$POSEIDON_PORT" "$GATEWAY_PORT" <<'TSCHECK'
POS_PORT="$1"; GW_PORT="$2"
if ! command -v tailscale &>/dev/null; then
    echo "not_installed"
elif ! tailscale serve status 2>&1 | grep -q "localhost:${POS_PORT}"; then
    echo "missing_poseidon"
elif ! tailscale serve status 2>&1 | grep -q "localhost:${GW_PORT}"; then
    echo "missing_gateway"
else
    echo "ok"
fi
TSCHECK
    )
    if [[ "$SERVE_OK" == "not_installed" ]]; then
        log_warn "Tailscale binary not installed on remote — skipping serve verification."
        log_warn "Install with: ssh ${DO_SSH_USER}@${IP} 'curl -fsSL https://tailscale.com/install.sh | sh && tailscale up'"
    elif [[ "$SERVE_OK" != "ok" ]]; then
        log_warn "Tailscale serve incomplete ($SERVE_OK) — re-applying..."
        remote_exec "$IP" bash -s "$TAILSCALE_MODE" "$POSEIDON_PORT" "$GATEWAY_PORT" <<'TSFIX'
set -euo pipefail
TS_MODE="$1"; POS_PORT="$2"; GW_PORT="$3"
if [[ "$TS_MODE" == "funnel" ]]; then
    tailscale funnel --bg --https=8443 "http://localhost:${GW_PORT}"
    tailscale serve --bg --https=443 "http://localhost:${POS_PORT}"
else
    tailscale serve --bg --https=8443 "http://localhost:${GW_PORT}"
    tailscale serve --bg --https=443 "http://localhost:${POS_PORT}"
fi
TSFIX
        log_info "Tailscale serve re-applied."
    else
        log_info "Tailscale serve OK."
    fi
fi

log_info "Remote upgrade complete at $IP."
