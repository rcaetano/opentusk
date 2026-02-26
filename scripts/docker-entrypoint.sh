#!/bin/sh
# Install openclaw CLI wrapper on PATH (needed by dashboard memory search, etc.)
printf '#!/bin/sh\ncd /app && exec node dist/index.js "$@"\n' > /usr/local/bin/openclaw
chmod +x /usr/local/bin/openclaw

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
    # Restart loop: if Poseidon crashes, wait briefly and restart it.
    # This runs as a background process; the gateway (PID 1) is unaffected.
    while true; do
        bun /poseidon/apps/api/src/index.ts || true
        echo "[entrypoint] Poseidon exited, restarting in 2s..."
        sleep 2
    done &
fi

exec "$@"
