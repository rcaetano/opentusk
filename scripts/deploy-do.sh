#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ─── Help ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Create and provision an MustangClaw gateway on a DigitalOcean droplet
using the OpenClaw marketplace image.

This script is idempotent — if the droplet already exists, it will skip creation.

Options:
  --dry-run   Show what would happen without creating anything
  --force     Skip confirmation prompts
  --help      Show this help message

Examples:
  $(basename "$0")            # create and provision droplet
  $(basename "$0") --dry-run  # preview without changes
EOF
    exit 0
}

# ─── Parse flags ─────────────────────────────────────────────────────────────
DRY_RUN=false
FORCE=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --force)   FORCE=true ;;
        --help|-h) usage ;;
        *) log_error "Unknown option: $arg"; usage ;;
    esac
done
export FORCE

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 1: Validate prerequisites
# ═══════════════════════════════════════════════════════════════════════════════
log_info "Validating prerequisites..."

require_cmd doctl
require_cmd ssh
require_cmd ssh-keygen
require_cmd rsync

if [[ -z "${DIGITALOCEAN_ACCESS_TOKEN:-}" ]]; then
    log_error "DIGITALOCEAN_ACCESS_TOKEN is not set."
    log_error "Export it: export DIGITALOCEAN_ACCESS_TOKEN='dop_v1_...'"
    exit 1
fi

# Resolve SSH key fingerprint
if [[ -z "$DO_SSH_KEY_FINGERPRINT" ]]; then
    log_info "Auto-detecting SSH key from DigitalOcean..."
    DO_SSH_KEY_FINGERPRINT=$(doctl compute ssh-key list --format FingerPrint --no-header | head -1)
    if [[ -z "$DO_SSH_KEY_FINGERPRINT" ]]; then
        log_error "No SSH keys found in your DigitalOcean account."
        log_error "Add one: doctl compute ssh-key create my-key --public-key-file ~/.ssh/id_ed25519.pub"
        exit 1
    fi
    log_info "Using SSH key: $DO_SSH_KEY_FINGERPRINT"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 2: Check if droplet already exists
# ═══════════════════════════════════════════════════════════════════════════════
EXISTING_IP=$(doctl compute droplet list --tag-name "$DO_TAG" \
    --format Name,PublicIPv4 --no-header \
    | awk -v n="$DO_DROPLET_NAME" '$1 == n { print $2 }' || true)

if [[ -n "$EXISTING_IP" ]]; then
    log_warn "Droplet '$DO_DROPLET_NAME' already exists at $EXISTING_IP."
    log_warn "To recreate, run destroy-do.sh first."
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Dry run summary
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "$DRY_RUN" == "true" ]]; then
    cat <<EOF

[DRY RUN] Would create the following droplet:
  Name:     $DO_DROPLET_NAME
  Region:   $DO_REGION
  Size:     $DO_SIZE
  Image:    $DO_IMAGE (marketplace)
  SSH Key:  $DO_SSH_KEY_FINGERPRINT
  Tag:      $DO_TAG
  Tailscale: $TAILSCALE_ENABLED (mode: $TAILSCALE_MODE)

Then provision via SSH (as $DO_SSH_USER):
  - Write OpenClaw config (openclaw.json with gateway token)
  - Restart openclaw systemd service
  - Deploy Poseidon (install bun, rsync source, build, systemd service)
EOF
    if [[ "$TAILSCALE_ENABLED" == "true" ]]; then
        echo "  - Install Tailscale ($TAILSCALE_MODE mode)"
        echo "    Poseidon on HTTPS 443, Gateway on HTTPS 8443"
    fi
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 3: Create droplet
# ═══════════════════════════════════════════════════════════════════════════════
log_info "Creating droplet '$DO_DROPLET_NAME' (marketplace image: $DO_IMAGE)..."
doctl compute droplet create "$DO_DROPLET_NAME" \
    --image "$DO_IMAGE" \
    --region "$DO_REGION" \
    --size "$DO_SIZE" \
    --ssh-keys "$DO_SSH_KEY_FINGERPRINT" \
    --tag-name "$DO_TAG" \
    --wait

DROPLET_IP=$(get_droplet_ip)
log_info "Droplet created at $DROPLET_IP."

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 4: Wait for SSH
# ═══════════════════════════════════════════════════════════════════════════════
log_info "Waiting for SSH to become available..."
MAX_WAIT=180
ELAPSED=0
while true; do
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
            "${DO_SSH_USER}@${DROPLET_IP}" "true" 2>/dev/null; then
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    if [[ $ELAPSED -ge $MAX_WAIT ]]; then
        log_error "SSH not ready after ${MAX_WAIT}s. Check droplet status."
        exit 1
    fi
    printf "."
done
echo ""
log_info "SSH is ready."

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 5: Configure OpenClaw
# ═══════════════════════════════════════════════════════════════════════════════
GATEWAY_TOKEN=$(openssl rand -hex 32)

log_info "Configuring OpenClaw on remote..."

ssh "${DO_SSH_USER}@${DROPLET_IP}" bash <<CONFIGURE
set -euo pipefail

# Ensure config directory exists with correct permissions
mkdir -p ${REMOTE_OPENCLAW_HOME}/.openclaw/workspace
chmod 700 ${REMOTE_OPENCLAW_HOME}/.openclaw
chmod 700 ${REMOTE_OPENCLAW_HOME}/.openclaw/workspace

# Write openclaw.json with gateway token
cat > ${REMOTE_OPENCLAW_HOME}/.openclaw/openclaw.json <<JSONEOF
{
  "gateway": {
    "mode": "local",
    "auth": {
      "mode": "token",
      "token": "${GATEWAY_TOKEN}"
    }
  }
}
JSONEOF

# Write config.env for port settings
cat > ${REMOTE_OPENCLAW_HOME}/.openclaw/config.env <<CFGEOF
GATEWAY_PORT=${GATEWAY_PORT}
BRIDGE_PORT=${BRIDGE_PORT}
POSEIDON_PORT=${POSEIDON_PORT}
CFGEOF
chmod 600 ${REMOTE_OPENCLAW_HOME}/.openclaw/config.env
chmod 600 ${REMOTE_OPENCLAW_HOME}/.openclaw/openclaw.json

# Set ownership
chown -R openclaw:openclaw ${REMOTE_OPENCLAW_HOME}/.openclaw

# Restart OpenClaw systemd service
systemctl restart openclaw
echo "OpenClaw configured and restarted."
CONFIGURE

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 6: Deploy Poseidon
# ═══════════════════════════════════════════════════════════════════════════════
if [[ -d "$PROJECT_ROOT/poseidon" ]]; then
    log_info "Installing bun on remote..."
    ssh "${DO_SSH_USER}@${DROPLET_IP}" bash <<'BUNINSTALL'
set -euo pipefail
if ! command -v bun &>/dev/null; then
    curl -fsSL https://bun.sh/install | bash
    ln -sf "$HOME/.bun/bin/bun" /usr/local/bin/bun
fi
bun install -g pnpm
ln -sf "$(bun pm bin -g)/pnpm" /usr/local/bin/pnpm 2>/dev/null || true
echo "bun $(bun --version), pnpm $(pnpm --version)"
BUNINSTALL

    log_info "Syncing Poseidon source to remote..."
    rsync -avz --progress -e "ssh" \
        --exclude='.git/' --exclude='node_modules/' --exclude='dist/' \
        "$PROJECT_ROOT/poseidon/" "${DO_SSH_USER}@${DROPLET_IP}:${REMOTE_POSEIDON_DIR}/"

    log_info "Building Poseidon on remote..."
    ssh "${DO_SSH_USER}@${DROPLET_IP}" bash <<POSEIDON_BUILD
set -euo pipefail
cd ${REMOTE_POSEIDON_DIR}
pnpm install --frozen-lockfile
pnpm --filter @poseidon/web build
chown -R openclaw:openclaw ${REMOTE_POSEIDON_DIR}
POSEIDON_BUILD

    log_info "Creating Poseidon systemd service..."
    ssh "${DO_SSH_USER}@${DROPLET_IP}" bash <<POSEIDON_SERVICE
set -euo pipefail

# Write environment file
cat > /opt/poseidon.env <<ENVEOF
PORT=${POSEIDON_PORT}
GATEWAY_URL=http://localhost:${GATEWAY_PORT}
GATEWAY_TOKEN=${GATEWAY_TOKEN}
POSEIDON_STATIC_DIR=${REMOTE_POSEIDON_DIR}/apps/web/dist
OPENCLAW_SOURCE=mustangclaw
ENVEOF
chmod 600 /opt/poseidon.env

# Write systemd unit
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
systemctl enable poseidon
systemctl start poseidon
echo "Poseidon service started."
POSEIDON_SERVICE
else
    log_warn "Poseidon source not found at $PROJECT_ROOT/poseidon — skipping Poseidon deploy."
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 7: Tailscale (if enabled)
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "$TAILSCALE_ENABLED" == "true" ]]; then
    log_info "Installing and configuring Tailscale..."
    ssh "${DO_SSH_USER}@${DROPLET_IP}" bash <<TAILSCALE
set -euo pipefail

# Install Tailscale
if ! command -v tailscale &>/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
fi

# Authenticate
tailscale up --auth-key='${TAILSCALE_AUTH_KEY}'

# Configure serve/funnel
echo "Configuring Tailscale ${TAILSCALE_MODE}..."
TAILSCALE

    if [[ "$TAILSCALE_MODE" == "funnel" ]]; then
        ssh "${DO_SSH_USER}@${DROPLET_IP}" bash <<TSFUNNEL
tailscale funnel --bg --https=8443 http://localhost:${GATEWAY_PORT}
tailscale serve --bg --https=443 http://localhost:${POSEIDON_PORT}
TSFUNNEL
    else
        ssh "${DO_SSH_USER}@${DROPLET_IP}" bash <<TSSERVE
tailscale serve --bg --https=8443 http://localhost:${GATEWAY_PORT}
tailscale serve --bg --https=443 http://localhost:${POSEIDON_PORT}
TSSERVE
    fi

    log_info "Tailscale configured ($TAILSCALE_MODE mode)."
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 8: Smoke test
# ═══════════════════════════════════════════════════════════════════════════════
log_info "Running post-deploy smoke test..."
SMOKE_OK=true

# Check OpenClaw systemd service
OC_STATUS=$(ssh "${DO_SSH_USER}@${DROPLET_IP}" \
    'systemctl is-active openclaw 2>/dev/null' || true)
if [[ "$OC_STATUS" == "active" ]]; then
    log_info "  OpenClaw service: active"
else
    log_error "  OpenClaw service: $OC_STATUS"
    SMOKE_OK=false
fi

# Check Poseidon systemd service
if [[ -d "$PROJECT_ROOT/poseidon" ]]; then
    POS_STATUS=$(ssh "${DO_SSH_USER}@${DROPLET_IP}" \
        'systemctl is-active poseidon 2>/dev/null' || true)
    if [[ "$POS_STATUS" == "active" ]]; then
        log_info "  Poseidon service: active"
    else
        log_error "  Poseidon service: $POS_STATUS"
        SMOKE_OK=false
    fi
fi

# Check gateway port (gateway takes ~60s to initialize)
log_info "  Waiting up to 90s for gateway to start..."
GW_READY=false
GW_ELAPSED=0
while [[ $GW_ELAPSED -lt 90 ]]; do
    if ssh "${DO_SSH_USER}@${DROPLET_IP}" "curl -sf -o /dev/null http://localhost:${GATEWAY_PORT}" 2>/dev/null; then
        GW_READY=true
        break
    fi
    sleep 5
    GW_ELAPSED=$((GW_ELAPSED + 5))
    printf "."
done
echo ""
if [[ "$GW_READY" == "true" ]]; then
    log_info "  Gateway port ${GATEWAY_PORT}: responding (took ~${GW_ELAPSED}s)"
else
    log_warn "  Gateway port ${GATEWAY_PORT}: not responding after 90s — may need more time"
fi

if [[ "$SMOKE_OK" != "true" ]]; then
    log_error "Smoke test failed. Check: ssh ${DO_SSH_USER}@${DROPLET_IP}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 9: Print connection summary
# ═══════════════════════════════════════════════════════════════════════════════
log_info "Deployment complete!"
echo ""
echo "  Droplet IP:  $DROPLET_IP"
echo "  SSH:         ssh ${DO_SSH_USER}@${DROPLET_IP}"
echo "  Gateway:     ssh -L ${GATEWAY_PORT}:localhost:${GATEWAY_PORT} ${DO_SSH_USER}@${DROPLET_IP}"
echo "               then open http://localhost:${GATEWAY_PORT}"
echo ""
# Write credentials to a file instead of printing to terminal
CREDS_FILE="$OPENCLAW_CONFIG_DIR/remote-credentials"
mkdir -p "$OPENCLAW_CONFIG_DIR"
cat > "$CREDS_FILE" <<CREDEOF
# MustangClaw remote deployment credentials
# Droplet: $DO_DROPLET_NAME ($DROPLET_IP)
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
GATEWAY_TOKEN=$GATEWAY_TOKEN
CREDEOF
chmod 600 "$CREDS_FILE"
echo "  Credentials saved to: $CREDS_FILE"
echo "  Gateway token:    ${GATEWAY_TOKEN:0:8}..."
echo ""
if [[ "$TAILSCALE_ENABLED" == "true" ]]; then
    echo "  Tailscale:   $TAILSCALE_MODE mode"
    echo "  Poseidon:    https://${DO_DROPLET_NAME}.<your-tailnet>.ts.net"
    echo "  Gateway:     https://${DO_DROPLET_NAME}.<your-tailnet>.ts.net:8443"
    echo ""
fi
log_warn "Full credentials stored in $CREDS_FILE (chmod 600)."
