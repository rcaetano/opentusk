#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ─── Help ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Run the MustangClaw gateway container locally via Docker Compose.

Options:
  --rebuild   Force rebuild the Docker image before starting
  --logs      Tail container logs after starting
  --stop      Stop the running gateway container
  --help      Show this help message

Examples:
  $(basename "$0")              # start gateway
  $(basename "$0") --rebuild    # rebuild image, then start
  $(basename "$0") --logs       # start and tail logs
  $(basename "$0") --stop       # stop the gateway
EOF
    exit 0
}

# ─── Parse flags ─────────────────────────────────────────────────────────────
REBUILD=false
LOGS=false
STOP=false
for arg in "$@"; do
    case "$arg" in
        --rebuild) REBUILD=true ;;
        --logs)    LOGS=true ;;
        --stop)    STOP=true ;;
        --help|-h) usage ;;
        *) log_error "Unknown option: $arg"; usage ;;
    esac
done

# ─── Prerequisites ───────────────────────────────────────────────────────────
require_cmd docker

cd "$PROJECT_ROOT"

if [[ ! -d "$MUSTANGCLAW_DIR" ]]; then
    log_error "MustangClaw repo not found at $MUSTANGCLAW_DIR. Run build.sh first."
    exit 1
fi

# ─── Stop mode ───────────────────────────────────────────────────────────────
if [[ "$STOP" == "true" ]]; then
    log_info "Stopping MustangClaw gateway..."
    docker compose -f "$MUSTANGCLAW_DIR/docker-compose.yml" down
    log_info "Gateway stopped."
    exit 0
fi

# ─── Ensure config directories ──────────────────────────────────────────────
mkdir -p "$MUSTANGCLAW_CONFIG_DIR"
mkdir -p "$MUSTANGCLAW_WORKSPACE_DIR"

# ─── Clear stale device tokens ──────────────────────────────────────────────
# Device tokens from previous sessions cause "device token mismatch" errors
# in the TUI. Clear them so fresh tokens are issued on next connect.
if ls "$MUSTANGCLAW_CONFIG_DIR/devices/"* &>/dev/null; then
    rm -f "$MUSTANGCLAW_CONFIG_DIR/devices/"*
    log_info "Cleared stale device tokens."
fi

# ─── Seed openclaw.json if missing ─────────────────────────────────────────
OPENCLAW_JSON="$MUSTANGCLAW_CONFIG_DIR/openclaw.json"
if [[ ! -f "$OPENCLAW_JSON" ]]; then
    log_info "Seeding minimal openclaw.json (gateway.mode=local)..."
    cat > "$OPENCLAW_JSON" <<'JSONEOF'
{
  "gateway": {
    "mode": "local"
  }
}
JSONEOF
fi

# ─── Patch openclaw.json for Docker compatibility ────────────────────────────
# The 'mustangclaw setup' wizard may set gateway.bind=loopback and add tailscale
# config, which conflicts with Docker networking. Fix these before starting.
if [[ -f "$OPENCLAW_JSON" ]]; then
    NEEDS_PATCH=false
    if grep -q '"bind"[[:space:]]*:[[:space:]]*"loopback"' "$OPENCLAW_JSON"; then
        NEEDS_PATCH=true
    fi
    if grep -q '"tailscale"' "$OPENCLAW_JSON"; then
        NEEDS_PATCH=true
    fi
    if [[ "$NEEDS_PATCH" == "true" ]]; then
        require_cmd python3
        python3 -c "
import json, sys
with open(sys.argv[1], 'r') as f:
    cfg = json.load(f)
gw = cfg.get('gateway', {})
gw['bind'] = 'lan'
gw.pop('tailscale', None)
cfg['gateway'] = gw
with open(sys.argv[1], 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
" "$OPENCLAW_JSON"
        log_info "Patched openclaw.json (bind=lan, removed tailscale) for Docker."
    fi
fi

# ─── Resolve gateway token ────────────────────────────────────────────────────
# Prefer the token from openclaw.json (written by 'mustangclaw setup'), then
# fall back to the .env, and finally generate a new one.
ENV_FILE="$MUSTANGCLAW_DIR/.env"
GATEWAY_TOKEN=""

if [[ -f "$OPENCLAW_JSON" ]]; then
    GATEWAY_TOKEN=$(grep -o '"token"[[:space:]]*:[[:space:]]*"[^"]*"' "$OPENCLAW_JSON" \
        | tail -1 | sed 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
fi

if [[ -z "$GATEWAY_TOKEN" ]] && [[ -f "$ENV_FILE" ]] && grep -q '^OPENCLAW_GATEWAY_TOKEN=' "$ENV_FILE"; then
    GATEWAY_TOKEN=$(grep '^OPENCLAW_GATEWAY_TOKEN=' "$ENV_FILE" | cut -d= -f2-)
fi

if [[ -z "$GATEWAY_TOKEN" ]]; then
    GATEWAY_TOKEN=$(openssl rand -hex 32)
    log_info "Generated new gateway token."
fi

# ─── Write .env ──────────────────────────────────────────────────────────────
# Keys must match what the upstream docker-compose.yml expects (OPENCLAW_*).
# Preserve any existing extra env vars the user may have added.
if [[ -f "$ENV_FILE" ]]; then
    # Remove lines we manage, keep everything else
    EXISTING=$(grep -vE '^(OPENCLAW_IMAGE|OPENCLAW_GATEWAY_TOKEN|OPENCLAW_CONFIG_DIR|OPENCLAW_WORKSPACE_DIR)=' "$ENV_FILE" || true)
else
    EXISTING=""
fi

cat > "$ENV_FILE" <<EOF
OPENCLAW_IMAGE=$MUSTANGCLAW_IMAGE
OPENCLAW_GATEWAY_TOKEN=$GATEWAY_TOKEN
OPENCLAW_CONFIG_DIR=$MUSTANGCLAW_CONFIG_DIR
OPENCLAW_WORKSPACE_DIR=$MUSTANGCLAW_WORKSPACE_DIR
EOF

if [[ -n "$EXISTING" ]]; then
    echo "$EXISTING" >> "$ENV_FILE"
fi

# ─── Generate docker-compose.override.yml ─────────────────────────────────
# Mounts our entrypoint script to patch openclaw.json on every container start,
# preventing the setup wizard's hot-reload from re-introducing tailscale/loopback
# config that conflicts with Docker networking.
ENTRYPOINT_SRC="$PROJECT_ROOT/scripts/docker-entrypoint.sh"
OVERRIDE_FILE="$MUSTANGCLAW_DIR/docker-compose.override.yml"

cat > "$OVERRIDE_FILE" <<YMLEOF
services:
  openclaw-gateway:
    volumes:
      - ${ENTRYPOINT_SRC}:/usr/local/bin/docker-entrypoint.sh:ro
    entrypoint: ["/usr/local/bin/docker-entrypoint.sh"]
YMLEOF

COMPOSE_FILES=(-f "$MUSTANGCLAW_DIR/docker-compose.yml" -f "$OVERRIDE_FILE")

# ─── Rebuild if requested ───────────────────────────────────────────────────
if [[ "$REBUILD" == "true" ]]; then
    log_info "Rebuilding Docker image..."
    docker compose "${COMPOSE_FILES[@]}" build
fi

# ─── Start gateway ───────────────────────────────────────────────────────────
log_info "Starting MustangClaw gateway..."
docker compose "${COMPOSE_FILES[@]}" up -d openclaw-gateway

# ─── Print connection info ───────────────────────────────────────────────────
log_info "Gateway is running."
log_info "  URL: http://localhost:${GATEWAY_PORT}?token=${GATEWAY_TOKEN}"

# ─── Tail logs if requested ─────────────────────────────────────────────────
if [[ "$LOGS" == "true" ]]; then
    docker compose "${COMPOSE_FILES[@]}" logs -f openclaw-gateway
fi
