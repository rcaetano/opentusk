#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ─── Help ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Create and provision an MustangClaw gateway on a DigitalOcean droplet.

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
  Image:    $DO_IMAGE
  SSH Key:  $DO_SSH_KEY_FINGERPRINT
  Tag:      $DO_TAG
  Tailscale: $TAILSCALE_ENABLED (mode: $TAILSCALE_MODE)

Then provision via SSH:
  - Create 'mustangclaw' user with docker group
  - Configure UFW (SSH only)
  - Install fail2ban
  - Harden sshd
  - Deploy wrapper project via rsync
  - Build Docker images (openclaw + poseidon)
  - Generate gateway token
  - Start gateway via mustangclaw run
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
log_info "Creating droplet '$DO_DROPLET_NAME'..."
doctl compute droplet create "$DO_DROPLET_NAME" \
    --image "$DO_IMAGE" \
    --region "$DO_REGION" \
    --size "$DO_SIZE" \
    --ssh-keys "$DO_SSH_KEY_FINGERPRINT" \
    --tag-name "$DO_TAG" \
    --user-data-file "$SCRIPT_DIR/cloud-init.yml" \
    --wait

DROPLET_IP=$(get_droplet_ip)
log_info "Droplet created at $DROPLET_IP."

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 4: Wait for SSH
# ═══════════════════════════════════════════════════════════════════════════════
log_info "Waiting for SSH and cloud-init to finish..."
MAX_WAIT=300
ELAPSED=0
while true; do
    # Try SSH; on success check if cloud-init has finished
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
            "root@${DROPLET_IP}" "cloud-init status --wait >/dev/null 2>&1 || sleep 1; true" 2>/dev/null; then
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    if [[ $ELAPSED -ge $MAX_WAIT ]]; then
        log_error "SSH/cloud-init not ready after ${MAX_WAIT}s. Check droplet status."
        exit 1
    fi
    printf "."
done
echo ""
log_info "SSH is ready and cloud-init complete."

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 5: Security hardening (runs as root)
# ═══════════════════════════════════════════════════════════════════════════════
GATEWAY_TOKEN=$(openssl rand -hex 32)
GATEWAY_PASSWORD=$(openssl rand -hex 16)

log_info "Hardening droplet security..."

# Build the Tailscale provisioning block conditionally
TAILSCALE_BLOCK=""
if [[ "$TAILSCALE_ENABLED" == "true" ]]; then
    TAILSCALE_BLOCK=$(cat <<'TSEOF'
# ── Tailscale ────────────────────────────────────────────────────────────
echo "Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh
TSEOF
)
    # Append auth and mode configuration with variable expansion
    TAILSCALE_BLOCK="$TAILSCALE_BLOCK
tailscale up --auth-key='${TAILSCALE_AUTH_KEY}'
"
    if [[ "$TAILSCALE_MODE" == "funnel" ]]; then
        TAILSCALE_BLOCK="$TAILSCALE_BLOCK
echo 'Configuring Tailscale Funnel (gateway on 8443) + Serve (Poseidon on 443)...'
tailscale funnel --bg --https=8443 http://localhost:${GATEWAY_PORT}
tailscale serve --bg --https=443 http://localhost:${POSEIDON_PORT}
"
    elif [[ "$TAILSCALE_MODE" == "serve" ]]; then
        TAILSCALE_BLOCK="$TAILSCALE_BLOCK
echo 'Configuring Tailscale Serve (gateway on 8443, Poseidon on 443)...'
tailscale serve --bg --https=8443 http://localhost:${GATEWAY_PORT}
tailscale serve --bg --https=443 http://localhost:${POSEIDON_PORT}
"
    fi
fi

ssh "root@${DROPLET_IP}" bash <<PROVISION
set -euo pipefail

# ── Create mustangclaw user ─────────────────────────────────────────────────
if ! id mustangclaw &>/dev/null; then
    useradd -m -s /bin/bash -G docker mustangclaw
    # Copy root's authorized_keys so we can SSH as mustangclaw
    mkdir -p /home/mustangclaw/.ssh
    cp /root/.ssh/authorized_keys /home/mustangclaw/.ssh/authorized_keys
    chown -R mustangclaw:mustangclaw /home/mustangclaw/.ssh
    chmod 700 /home/mustangclaw/.ssh
    chmod 600 /home/mustangclaw/.ssh/authorized_keys
fi

# ── UFW firewall ─────────────────────────────────────────────────────────
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw --force enable

# ── Symlink mustangclaw to PATH ─────────────────────────────────────────
ln -sf /home/mustangclaw/mustangclaw/mustangclaw /usr/local/bin/mustangclaw

# ── fail2ban ─────────────────────────────────────────────────────────────
apt-get install -y fail2ban
systemctl enable fail2ban
systemctl start fail2ban

# ── SSHD hardening ───────────────────────────────────────────────────────
cat > /etc/ssh/sshd_config.d/99-mustangclaw-hardening.conf <<'SSHEOF'
PasswordAuthentication no
PermitRootLogin prohibit-password
ChallengeResponseAuthentication no
SSHEOF
systemctl reload sshd

${TAILSCALE_BLOCK}

echo "Security hardening complete."
PROVISION

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 6: Deploy wrapper project and build
# ═══════════════════════════════════════════════════════════════════════════════
log_info "Deploying MustangClaw wrapper to remote..."
rsync -avz --progress -e "ssh" \
    --exclude='openclaw/' --exclude='.git/' \
    --exclude='node_modules/' --exclude='.mustangclaw/' \
    "$PROJECT_ROOT/" "mustangclaw@${DROPLET_IP}:/home/mustangclaw/mustangclaw/"

# Rsync poseidon source separately (private repo, can't clone on remote)
if [[ -d "$PROJECT_ROOT/poseidon" ]]; then
    log_info "Syncing Poseidon source to remote..."
    rsync -avz --progress -e "ssh" \
        --exclude='.git/' --exclude='node_modules/' --exclude='dist/' \
        "$PROJECT_ROOT/poseidon/" "mustangclaw@${DROPLET_IP}:/home/mustangclaw/mustangclaw/poseidon/"
fi

log_info "Building Docker images and starting gateway on remote..."
ssh "mustangclaw@${DROPLET_IP}" bash <<DEPLOY
set -euo pipefail
cd /home/mustangclaw/mustangclaw
chmod +x mustangclaw

# Build (clones openclaw, uses rsynced poseidon, builds Docker images)
./mustangclaw build --no-pull

# Seed config directory with correct permissions
mkdir -p /home/mustangclaw/.mustangclaw/workspace
chmod 700 /home/mustangclaw/.mustangclaw
chmod 700 /home/mustangclaw/.mustangclaw/workspace

cat > /home/mustangclaw/.mustangclaw/config.env <<CFGEOF
GATEWAY_PORT=${GATEWAY_PORT}
BRIDGE_PORT=${BRIDGE_PORT}
POSEIDON_PORT=${POSEIDON_PORT}
CFGEOF
chmod 600 /home/mustangclaw/.mustangclaw/config.env

# Write openclaw.json with gateway token
cat > /home/mustangclaw/.mustangclaw/openclaw.json <<JSONEOF
{
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "auth": {
      "mode": "token",
      "token": "${GATEWAY_TOKEN}"
    }
  }
}
JSONEOF
chmod 600 /home/mustangclaw/.mustangclaw/openclaw.json

# Start the gateway (generates .env, override, starts containers with Poseidon)
./mustangclaw run

echo "Deploy complete."
DEPLOY

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 7: Post-deploy smoke test
# ═══════════════════════════════════════════════════════════════════════════════
log_info "Running post-deploy smoke test..."
SMOKE_OK=true

# Check container is running
CONTAINER_STATUS=$(ssh "mustangclaw@${DROPLET_IP}" \
    'docker ps --filter "name=^mustangclaw$" --filter "status=running" --format "{{.Status}}"' 2>/dev/null || true)
if [[ -n "$CONTAINER_STATUS" ]]; then
    log_info "  Container: running ($CONTAINER_STATUS)"
else
    log_error "  Container: NOT running"
    SMOKE_OK=false
fi

# Check gateway port is listening
if ssh "mustangclaw@${DROPLET_IP}" "curl -sf -o /dev/null http://localhost:${GATEWAY_PORT}" 2>/dev/null; then
    log_info "  Gateway port ${GATEWAY_PORT}: responding"
else
    log_warn "  Gateway port ${GATEWAY_PORT}: not responding yet (may still be starting)"
fi

if [[ "$SMOKE_OK" != "true" ]]; then
    log_error "Smoke test failed. Check: ssh mustangclaw@${DROPLET_IP}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 8: Print connection summary
# ═══════════════════════════════════════════════════════════════════════════════
log_info "Deployment complete!"
echo ""
echo "  Droplet IP:  $DROPLET_IP"
echo "  SSH:         ssh mustangclaw@${DROPLET_IP}"
echo "  Gateway:     ssh -L ${GATEWAY_PORT}:localhost:${GATEWAY_PORT} mustangclaw@${DROPLET_IP}"
echo "               then open http://localhost:${GATEWAY_PORT}"
echo ""
# Write credentials to a file instead of printing to terminal
CREDS_FILE="$MUSTANGCLAW_CONFIG_DIR/remote-credentials"
mkdir -p "$MUSTANGCLAW_CONFIG_DIR"
cat > "$CREDS_FILE" <<CREDEOF
# MustangClaw remote deployment credentials
# Droplet: $DO_DROPLET_NAME ($DROPLET_IP)
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
GATEWAY_TOKEN=$GATEWAY_TOKEN
GATEWAY_PASSWORD=$GATEWAY_PASSWORD
CREDEOF
chmod 600 "$CREDS_FILE"
echo "  Credentials saved to: $CREDS_FILE"
echo "  Gateway token:    ${GATEWAY_TOKEN:0:8}..."
echo "  Gateway password: ${GATEWAY_PASSWORD:0:8}..."
echo ""
if [[ "$TAILSCALE_ENABLED" == "true" ]]; then
    echo "  Tailscale:   $TAILSCALE_MODE mode"
    echo "  Poseidon:    https://${DO_DROPLET_NAME}.<your-tailnet>.ts.net"
    echo "  Gateway:     https://${DO_DROPLET_NAME}.<your-tailnet>.ts.net:8443"
    echo ""
fi
log_warn "Full credentials stored in $CREDS_FILE (chmod 600)."
