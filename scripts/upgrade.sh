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
    # Ensure bun + pnpm are present (mirrors deploy-do.sh)
    log_info "Checking bun/pnpm on remote..."
    remote_exec "$IP" <<'BUNCHECK'
set -euo pipefail
if ! command -v bun &>/dev/null; then
    curl -fsSL https://bun.sh/install | bash
    ln -sf "$HOME/.bun/bin/bun" /usr/local/bin/bun
fi
if ! command -v pnpm &>/dev/null; then
    bun install -g pnpm
    ln -sf "$(bun pm bin -g)/pnpm" /usr/local/bin/pnpm 2>/dev/null || true
fi
echo "bun $(bun --version), pnpm $(pnpm --version)"
BUNCHECK

    log_info "Pulling and rebuilding Poseidon on remote..."
    remote_exec "$IP" bash -s \
        "$REMOTE_POSEIDON_DIR" "$POSEIDON_BRANCH" \
        "$POSEIDON_PORT" "$GATEWAY_PORT" <<'POSBUILD'
set -euo pipefail
POS_DIR="$1"; POS_BRANCH="$2"
POS_PORT="$3"; GW_PORT="$4"
git config --global --add safe.directory "$POS_DIR" 2>/dev/null || true
cd "$POS_DIR"
git fetch origin
git reset --hard "origin/$POS_BRANCH"
pnpm install --frozen-lockfile
pnpm --filter @poseidon/web build
chown -R openclaw:openclaw "$POS_DIR"

# ── Sync poseidon.env ──
if [[ -f /opt/poseidon.env ]]; then
    GW_TOKEN=$(grep -oP '^GATEWAY_TOKEN=\K.*' /opt/poseidon.env || true)
fi
if [[ -n "${GW_TOKEN:-}" ]]; then
    cat > /opt/poseidon.env <<ENVEOF
PORT=$POS_PORT
GATEWAY_URL=ws://127.0.0.1:$GW_PORT
GATEWAY_TOKEN=$GW_TOKEN
POSEIDON_STATIC_DIR=$POS_DIR/apps/web/dist
OPENCLAW_SOURCE=opentusk
CORS_ORIGINS=http://localhost:5173,http://127.0.0.1:5173
ENVEOF
    chmod 600 /opt/poseidon.env
    echo "poseidon.env synced."
else
    echo "WARNING: No GATEWAY_TOKEN in /opt/poseidon.env — skipping env sync."
fi

# ── Sync systemd unit ──
cat > /etc/systemd/system/poseidon.service <<'UNITEOF'
[Unit]
Description=Poseidon Agent Dashboard
After=openclaw.service

[Service]
Type=simple
User=openclaw
WorkingDirectory=/opt/poseidon
EnvironmentFile=/opt/poseidon.env
ExecStart=/usr/local/bin/bun apps/api/src/index.ts
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNITEOF
systemctl daemon-reload

systemctl restart poseidon
POSBUILD
else
    log_warn "POSEIDON_REPO not set — skipping Poseidon upgrade."
fi

# 3. Sync webhook files (if enabled)
if [[ "$WEBHOOK_ENABLED" == "true" && -n "${POSEIDON_REPO:-}" ]]; then
    log_info "Syncing webhook files..."

    scp "${SSH_BASE_OPTS[@]}" \
        "$SCRIPT_DIR/files/poseidon-update.sh" \
        "$SCRIPT_DIR/files/webhook.ts" \
        "${DO_SSH_USER}@${IP}:/tmp/"

    remote_exec "$IP" bash -s \
        "$WEBHOOK_PORT" "$WEBHOOK_SECRET" \
        "$REMOTE_POSEIDON_DIR" "$POSEIDON_BRANCH" \
        "$GATEWAY_PORT" "$POSEIDON_PORT" "$REMOTE_OPENCLAW_HOME" <<'WHSYNC'
set -euo pipefail
WH_PORT="$1"; WH_SECRET="$2"
POS_DIR="$3"; POS_BRANCH="$4"
GW_PORT="$5"; POS_PORT="$6"; OC_HOME="$7"

WH_DIR="/opt/poseidon-webhook"
mkdir -p "$WH_DIR"

mv /tmp/poseidon-update.sh "$WH_DIR/update.sh"
mv /tmp/webhook.ts "$WH_DIR/webhook.ts"
chmod +x "$WH_DIR/update.sh"

# Sync webhook.env
cat > "$WH_DIR/webhook.env" <<ENVEOF
WEBHOOK_PORT=$WH_PORT
WEBHOOK_SECRET=$WH_SECRET
POSEIDON_DIR=$POS_DIR
POSEIDON_BRANCH=$POS_BRANCH
GATEWAY_PORT=$GW_PORT
POSEIDON_PORT=$POS_PORT
OPENCLAW_HOME=$OC_HOME
ENVEOF
chmod 600 "$WH_DIR/webhook.env"

# Sync systemd unit
cat > /etc/systemd/system/poseidon-webhook.service <<'UNITEOF'
[Unit]
Description=Poseidon Webhook Listener
After=poseidon.service

[Service]
Type=simple
WorkingDirectory=/opt/poseidon-webhook
EnvironmentFile=/opt/poseidon-webhook/webhook.env
ExecStart=/usr/local/bin/bun webhook.ts
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNITEOF
systemctl daemon-reload

# UFW rule (idempotent)
if ! ufw status | grep -q "$WH_PORT/tcp"; then
    ufw allow "$WH_PORT/tcp"
fi

systemctl restart poseidon-webhook
echo "Webhook files synced and service restarted."
WHSYNC

    log_info "Webhook sync complete."
fi

# 4. Verify Tailscale serve (re-apply if missing)
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

    # Refresh CORS_ORIGINS + gateway allowedOrigins with current Tailscale FQDN
    log_info "Refreshing origins with current Tailscale FQDN..."
    remote_exec "$IP" bash -s "$REMOTE_OPENCLAW_HOME" <<'CORSFIX'
set -euo pipefail
OC_HOME="$1"
ts_fqdn=$(tailscale status --self --json | python3 -c "import json,sys; print(json.load(sys.stdin)['Self']['DNSName'].rstrip('.'))")
if [[ -n "$ts_fqdn" ]]; then
    # Poseidon CORS_ORIGINS
    if grep -q "^CORS_ORIGINS=" /opt/poseidon.env 2>/dev/null; then
        sed -i "s|^CORS_ORIGINS=.*|CORS_ORIGINS=https://${ts_fqdn},http://localhost:5173,http://127.0.0.1:5173|" /opt/poseidon.env
    else
        echo "CORS_ORIGINS=https://${ts_fqdn},http://localhost:5173,http://127.0.0.1:5173" >> /opt/poseidon.env
    fi
    systemctl restart poseidon
    echo "CORS_ORIGINS updated with https://${ts_fqdn}"

    # Gateway controlUi.allowedOrigins
    OC_CONFIG="${OC_HOME}/.openclaw/openclaw.json"
    if [[ -f "$OC_CONFIG" ]]; then
        python3 -c "
import json
with open('$OC_CONFIG') as f:
    cfg = json.load(f)
origins = cfg.setdefault('gateway', {}).setdefault('controlUi', {}).setdefault('allowedOrigins', [])
for o in ['https://${ts_fqdn}', 'https://${ts_fqdn}:8443']:
    if o not in origins:
        origins.append(o)
with open('$OC_CONFIG', 'w') as f:
    json.dump(cfg, f, indent=2)
"
        chown openclaw:openclaw "$OC_CONFIG"
        systemctl restart openclaw
        echo "Gateway allowedOrigins updated with https://${ts_fqdn}"
    fi
else
    echo "Could not resolve Tailscale FQDN — origins unchanged."
fi
CORSFIX
fi

log_info "Remote upgrade complete at $IP."
