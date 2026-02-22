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
  - Clone + build MustangClaw
  - Generate gateway token
  - docker compose up
EOF
    if [[ "$TAILSCALE_ENABLED" == "true" ]]; then
        echo "  - Install Tailscale ($TAILSCALE_MODE mode)"
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
log_info "Waiting for SSH to become available..."
MAX_WAIT=60
ELAPSED=0
while ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
        "root@${DROPLET_IP}" true 2>/dev/null; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    if [[ $ELAPSED -ge $MAX_WAIT ]]; then
        log_error "SSH not available after ${MAX_WAIT}s. Check droplet status."
        exit 1
    fi
    printf "."
done
echo ""
log_info "SSH is ready."

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 5: Remote provisioning
# ═══════════════════════════════════════════════════════════════════════════════
GATEWAY_TOKEN=$(openssl rand -hex 32)
GATEWAY_PASSWORD=$(openssl rand -hex 16)

log_info "Provisioning droplet..."

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
echo 'Configuring Tailscale Funnel...'
tailscale funnel --bg ${GATEWAY_PORT}
"
    elif [[ "$TAILSCALE_MODE" == "serve" ]]; then
        TAILSCALE_BLOCK="$TAILSCALE_BLOCK
echo 'Configuring Tailscale Serve...'
tailscale serve --bg ${GATEWAY_PORT}
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

# ── Clone MustangClaw ───────────────────────────────────────────────────────
if [[ ! -d /home/mustangclaw/mustangclaw ]]; then
    su - mustangclaw -c 'git clone ${MUSTANGCLAW_REPO} /home/mustangclaw/mustangclaw'
fi

# ── Build Docker image ───────────────────────────────────────────────────
su - mustangclaw -c 'cd /home/mustangclaw/mustangclaw && docker build -t mustangclaw:local .'

# ── Config directories ───────────────────────────────────────────────────
su - mustangclaw -c 'mkdir -p /home/mustangclaw/.mustangclaw/workspace'

# ── Write .env ───────────────────────────────────────────────────────────
cat > /home/mustangclaw/mustangclaw/.env <<ENVEOF
OPENCLAW_GATEWAY_TOKEN=${GATEWAY_TOKEN}
OPENCLAW_GATEWAY_PASSWORD=${GATEWAY_PASSWORD}
OPENCLAW_CONFIG_DIR=/home/mustangclaw/.mustangclaw
OPENCLAW_WORKSPACE_DIR=/home/mustangclaw/.mustangclaw/workspace
OPENCLAW_DISABLE_BONJOUR=1
ENVEOF
chown mustangclaw:mustangclaw /home/mustangclaw/mustangclaw/.env
chmod 600 /home/mustangclaw/mustangclaw/.env

${TAILSCALE_BLOCK}

# ── Generate docker-compose override (container_name) ────────────────────
cat > /home/mustangclaw/mustangclaw/docker-compose.override.yml <<'OVEOF'
services:
  openclaw-gateway:
    container_name: mustangclaw
OVEOF
chown mustangclaw:mustangclaw /home/mustangclaw/mustangclaw/docker-compose.override.yml

# ── Start containers ─────────────────────────────────────────────────────
su - mustangclaw -c 'cd /home/mustangclaw/mustangclaw && docker compose up -d openclaw-gateway'

echo "Provisioning complete."
PROVISION

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 6: Print connection summary
# ═══════════════════════════════════════════════════════════════════════════════
log_info "Deployment complete!"
echo ""
echo "  Droplet IP:  $DROPLET_IP"
echo "  SSH:         ssh mustangclaw@${DROPLET_IP}"
echo "  Gateway:     ssh -L ${GATEWAY_PORT}:localhost:${GATEWAY_PORT} mustangclaw@${DROPLET_IP}"
echo "               then open http://localhost:${GATEWAY_PORT}?token=${GATEWAY_TOKEN}"
echo ""
echo "  Gateway token:    $GATEWAY_TOKEN"
echo "  Gateway password: $GATEWAY_PASSWORD"
echo ""
if [[ "$TAILSCALE_ENABLED" == "true" ]]; then
    echo "  Tailscale:   https://${DO_DROPLET_NAME}.<your-tailnet>.ts.net"
    echo "  Mode:        $TAILSCALE_MODE"
    echo ""
fi
log_warn "Save the token and password above — they are not stored locally."
