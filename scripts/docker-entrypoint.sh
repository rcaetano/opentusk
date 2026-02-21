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
exec "$@"
