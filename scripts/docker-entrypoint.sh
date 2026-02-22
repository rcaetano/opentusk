#!/bin/sh
# Patch openclaw.json before starting the gateway.
# The 'mustangclaw setup' wizard may set gateway.bind=loopback and add tailscale
# config, which conflicts with Docker networking.
CONFIG="/home/node/.openclaw/openclaw.json"
if [ -f "$CONFIG" ]; then
    node -e "
const fs = require('fs');
const cfg = JSON.parse(fs.readFileSync('$CONFIG', 'utf8'));
const gw = cfg.gateway || {};
gw.bind = 'lan';
delete gw.tailscale;
cfg.gateway = gw;
fs.writeFileSync('$CONFIG', JSON.stringify(cfg, null, 2) + '\n');
" 2>/dev/null || true
fi
# ─── Start Poseidon if bundled ────────────────────────────────────────────
if [ -d "/poseidon" ] && command -v bun >/dev/null 2>&1; then
    export PORT="${POSEIDON_PORT:-18791}"
    export GATEWAY_URL="ws://127.0.0.1:${OPENCLAW_GATEWAY_PORT:-18789}"
    export GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"
    export OPENCLAW_SOURCE="local"
    export POSEIDON_STATIC_DIR="/poseidon/apps/web/dist"
    export CORS_ORIGINS="http://localhost:${PORT},http://localhost:5173,http://127.0.0.1:5173"

    echo "[entrypoint] Starting Poseidon on port $PORT..."
    bun /poseidon/apps/api/src/index.ts &
fi

exec "$@"
