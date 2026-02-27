#!/usr/bin/env bash
set -euo pipefail

# poseidon-update.sh — Standalone Poseidon build script
# Deployed to /opt/poseidon-webhook/update.sh on the droplet.
# Called by the webhook listener or manually. Uses flock to prevent
# concurrent builds.

LOCK_FILE="/tmp/poseidon-update.lock"
LOG_FILE="/var/log/poseidon-update.log"

# Source webhook config (POSEIDON_DIR, POSEIDON_BRANCH, GATEWAY_PORT, etc.)
if [[ -f /opt/poseidon-webhook/webhook.env ]]; then
    source /opt/poseidon-webhook/webhook.env
fi

POS_DIR="${POSEIDON_DIR:-/opt/poseidon}"
POS_BRANCH="${POSEIDON_BRANCH:-main}"
POS_PORT="${POSEIDON_PORT:-18791}"
GW_PORT="${GATEWAY_PORT:-18789}"
OC_HOME="${OPENCLAW_HOME:-/home/openclaw}"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG_FILE"
}

# ── Acquire lock (fail immediately if another build is running) ──────────
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log "ERROR: Another build is already running. Skipping."
    exit 1
fi

log "Starting Poseidon update (branch: $POS_BRANCH)..."

# ── 1. Ensure bun + pnpm ────────────────────────────────────────────────
if ! command -v bun &>/dev/null; then
    log "Installing bun..."
    curl -fsSL https://bun.sh/install | bash
    ln -sf "$HOME/.bun/bin/bun" /usr/local/bin/bun
fi
if ! command -v pnpm &>/dev/null; then
    log "Installing pnpm..."
    bun install -g pnpm
    ln -sf "$(bun pm bin -g)/pnpm" /usr/local/bin/pnpm 2>/dev/null || true
fi

# ── 2. Git fetch + reset ────────────────────────────────────────────────
log "Pulling latest from origin/$POS_BRANCH..."
git config --global --add safe.directory "$POS_DIR" 2>/dev/null || true
cd "$POS_DIR"
git fetch origin
git reset --hard "origin/$POS_BRANCH"

# ── 3. Build ─────────────────────────────────────────────────────────────
log "Installing dependencies..."
pnpm install --frozen-lockfile
log "Building Poseidon..."
pnpm --filter @poseidon/web build
chown -R openclaw:openclaw "$POS_DIR"

# ── 4. Sync poseidon.env (preserve GATEWAY_TOKEN) ───────────────────────
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
    log "poseidon.env synced."
else
    log "WARNING: No GATEWAY_TOKEN in /opt/poseidon.env — skipping env sync."
fi

# ── 5. Sync systemd unit ────────────────────────────────────────────────
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

# ── 6. Restart Poseidon ─────────────────────────────────────────────────
log "Restarting Poseidon..."
systemctl restart poseidon

# ── 7. Refresh Tailscale CORS origins (if Tailscale is present) ─────────
if command -v tailscale &>/dev/null; then
    ts_fqdn=$(tailscale status --self --json 2>/dev/null \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['Self']['DNSName'].rstrip('.'))" 2>/dev/null || true)
    if [[ -n "$ts_fqdn" ]]; then
        if grep -q "^CORS_ORIGINS=" /opt/poseidon.env 2>/dev/null; then
            sed -i "s|^CORS_ORIGINS=.*|CORS_ORIGINS=https://${ts_fqdn},http://localhost:5173,http://127.0.0.1:5173|" /opt/poseidon.env
        fi
        systemctl restart poseidon
        log "CORS_ORIGINS updated with https://${ts_fqdn}"

        # Update Gateway controlUi.allowedOrigins
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
            log "Gateway allowedOrigins updated with https://${ts_fqdn}"
        fi
    fi
fi

log "Poseidon update complete."
