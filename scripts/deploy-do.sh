#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ─── Help ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Create and provision an OpenTusk gateway on a DigitalOcean droplet
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

DROPLET_EXISTED=false
if [[ -n "$EXISTING_IP" ]]; then
    DROPLET_EXISTED=true
    DROPLET_IP="$EXISTING_IP"
    log_warn "Droplet '$DO_DROPLET_NAME' already exists at $DROPLET_IP — resuming provisioning."
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Dry run summary
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "$DRY_RUN" == "true" ]]; then
    if [[ "$DROPLET_EXISTED" == "true" ]]; then
        cat <<EOF

[DRY RUN] Droplet '$DO_DROPLET_NAME' already exists at $DROPLET_IP — would resume provisioning.
EOF
    else
        cat <<EOF

[DRY RUN] Would create the following droplet:
  Name:     $DO_DROPLET_NAME
  Region:   $DO_REGION
  Size:     $DO_SIZE
  Image:    $DO_IMAGE (marketplace)
  SSH Key:  $DO_SSH_KEY_FINGERPRINT
  Tag:      $DO_TAG
EOF
    fi
    cat <<EOF
  Tailscale: $TAILSCALE_ENABLED (mode: $TAILSCALE_MODE)

Then provision via SSH (as $DO_SSH_USER):
  - Write OpenClaw config (openclaw.json with gateway token)
  - Restart openclaw systemd service
  - Deploy Poseidon (deploy key, git clone, install bun, build, systemd service)
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
if [[ "$DROPLET_EXISTED" != "true" ]]; then
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
else
    log_info "Skipping droplet creation (already exists at $DROPLET_IP)."
fi

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

# Wait for marketplace first-boot / cloud-init to finish
# The marketplace image prints "Please wait while we get your droplet ready..."
# during setup. If we run commands before it completes, the banner
# text corrupts the protocol stream.
log_info "Waiting for cloud-init to finish..."
CLOUD_WAIT=0
CLOUD_MAX=600
while true; do
    CLOUD_STATUS=$(ssh -o ConnectTimeout=5 "${DO_SSH_USER}@${DROPLET_IP}" \
        'cloud-init status 2>/dev/null | grep -oE "done|running|error" || echo "unknown"' 2>/dev/null || echo "unknown")
    if [[ "$CLOUD_STATUS" == "done" ]]; then
        break
    elif [[ "$CLOUD_STATUS" == "error" ]]; then
        log_warn "cloud-init finished with errors — continuing anyway."
        break
    fi
    sleep 5
    CLOUD_WAIT=$((CLOUD_WAIT + 5))
    if [[ $CLOUD_WAIT -ge $CLOUD_MAX ]]; then
        log_warn "cloud-init still running after ${CLOUD_MAX}s — continuing anyway."
        break
    fi
    printf "."
done
echo ""
log_info "Droplet ready (cloud-init: $CLOUD_STATUS, ${CLOUD_WAIT}s)."

# Re-verify SSH after cloud-init (cloud-init may restart sshd)
log_info "Re-verifying SSH connectivity..."
SSH_RETRY=0
SSH_RETRY_MAX=60
while true; do
    if ssh -o ConnectTimeout=5 "${DO_SSH_USER}@${DROPLET_IP}" "true" 2>/dev/null; then
        break
    fi
    sleep 5
    SSH_RETRY=$((SSH_RETRY + 5))
    if [[ $SSH_RETRY -ge $SSH_RETRY_MAX ]]; then
        log_error "SSH connection lost after cloud-init (waited ${SSH_RETRY_MAX}s)."
        log_error "The droplet may be rebooting. Try: ssh ${DO_SSH_USER}@${DROPLET_IP}"
        exit 1
    fi
    printf "."
done
echo ""

# ─── Check for first-login interactive setup ─────────────────────────────────
# The marketplace image ships an AI provider selector that runs on first
# interactive login. If we detect it hasn't been completed, ask the user to
# finish it before we proceed — otherwise it will eat stdin from our heredoc
# SSH commands and corrupt the session.
FIRST_LOGIN_PENDING=$(ssh -o ConnectTimeout=5 "${DO_SSH_USER}@${DROPLET_IP}" \
    "test -f /etc/update-motd.d/99-one-click && echo yes || echo no" 2>/dev/null || echo "unknown")

if [[ "$FIRST_LOGIN_PENDING" == "yes" ]]; then
    echo ""
    log_warn "The droplet has a first-login setup wizard (AI provider selector)."
    log_warn "Open a new terminal and run:"
    echo ""
    echo "  ./opentusk ssh"
    echo ""
    log_warn "Complete the AI provider setup, then come back here."
    printf "${_CYAN}Press Enter once you've completed the setup...${_NC} "
    read -r

    # Remove the interactive first-login scripts so they don't interfere
    # with subsequent scripted SSH sessions
    ssh "${DO_SSH_USER}@${DROPLET_IP}" bash -c "'
        rm -rf /etc/update-motd.d/99-one-click
        # Remove any profile.d or bashrc hooks that run interactive prompts
        for f in /etc/profile.d/*one-click* /etc/profile.d/*first-login* /etc/profile.d/*setup*; do
            [ -f \"\$f\" ] && rm -f \"\$f\"
        done
        # Strip any first-login selector sourced from root bashrc
        if [ -f /root/.bashrc ]; then
            sed -i \"/ai.provider\\|first.login\\|one.click.*setup\\|provider.*selector/Id\" /root/.bashrc
        fi
    '" 2>/dev/null || true
    log_info "Cleaned up first-login scripts."
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 5: Configure OpenClaw
# ═══════════════════════════════════════════════════════════════════════════════
# Check if the remote already has a gateway token (from a previous deploy)
# Use a wrapper to distinguish "no token file" from "SSH failed"
EXISTING_TOKEN=""
if ssh -o ConnectTimeout=10 "${DO_SSH_USER}@${DROPLET_IP}" "true" 2>/dev/null; then
    EXISTING_TOKEN=$(ssh "${DO_SSH_USER}@${DROPLET_IP}" \
        "python3 -c \"import json; print(json.load(open('${REMOTE_OPENCLAW_HOME}/.openclaw/openclaw.json'))['gateway']['auth']['token'])\" 2>/dev/null" \
        || true)
else
    log_error "Cannot reach droplet via SSH. Check: ssh ${DO_SSH_USER}@${DROPLET_IP}"
    exit 1
fi

if [[ -n "$EXISTING_TOKEN" ]]; then
    GATEWAY_TOKEN="$EXISTING_TOKEN"
    log_info "Recovered existing gateway token from remote (${GATEWAY_TOKEN:0:8}...)."
else
    GATEWAY_TOKEN=$(openssl rand -hex 32)
    log_info "Generated new gateway token (${GATEWAY_TOKEN:0:8}...)."

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
fi

# Persist credentials locally (before later phases can fail)
CREDS_FILE="$HOME/.openclaw/remote-credentials"
mkdir -p "$HOME/.openclaw"
cat > "$CREDS_FILE" <<CREDEOF
# OpenTusk remote deployment credentials
# Droplet: $DO_DROPLET_NAME ($DROPLET_IP)
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
GATEWAY_TOKEN=$GATEWAY_TOKEN
CREDEOF
chmod 600 "$CREDS_FILE"

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 6: Deploy Poseidon
# ═══════════════════════════════════════════════════════════════════════════════
if [[ -n "${POSEIDON_REPO:-}" ]]; then
    # Verify SSH before the most SSH-heavy phase
    log_info "Verifying SSH connectivity..."
    SSH_P6=0
    while ! ssh -o ConnectTimeout=5 "${DO_SSH_USER}@${DROPLET_IP}" "true" 2>/dev/null; do
        sleep 5
        SSH_P6=$((SSH_P6 + 5))
        if [[ $SSH_P6 -ge 60 ]]; then
            log_error "SSH not available before Poseidon deploy (waited 60s)."
            log_error "Try again later: ./opentusk deploy"
            exit 1
        fi
        printf "."
    done
    [[ $SSH_P6 -gt 0 ]] && echo ""

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

    # Generate deploy key on remote (if not already present)
    log_info "Setting up deploy key on remote..."
    DEPLOY_PUBKEY=$(ssh "${DO_SSH_USER}@${DROPLET_IP}" bash <<'DEPLOYKEY'
set -euo pipefail
KEY_FILE="/root/.ssh/poseidon_deploy_key"
if [[ ! -f "$KEY_FILE" ]]; then
    ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "opentusk-deploy" >/dev/null 2>&1
fi

# Configure SSH to use this key for github.com
if ! grep -q "poseidon_deploy_key" /root/.ssh/config 2>/dev/null; then
    cat >> /root/.ssh/config <<'SSHCONF'

Host github.com
    IdentityFile /root/.ssh/poseidon_deploy_key
    StrictHostKeyChecking accept-new
SSHCONF
    chmod 600 /root/.ssh/config
fi

cat "${KEY_FILE}.pub"
DEPLOYKEY
    )

    # Add deploy key to GitHub repo via gh CLI (or prompt user)
    log_info "Adding deploy key to GitHub repo..."
    # Extract owner/repo from SSH URL (git@github.com:owner/repo.git)
    REPO_PATH="${POSEIDON_REPO#*:}"
    REPO_PATH="${REPO_PATH%.git}"

    DEPLOY_KEY_ADDED=false
    if command -v gh &>/dev/null; then
        KEY_TITLE="opentusk-${DO_DROPLET_NAME}"
        if gh api "repos/${REPO_PATH}/keys" --method POST \
            -f title="$KEY_TITLE" -f key="$DEPLOY_PUBKEY" -F read_only=true 2>/dev/null; then
            log_info "Deploy key added to ${REPO_PATH} via gh CLI."
            DEPLOY_KEY_ADDED=true
        else
            log_warn "gh api failed — key may already exist or token lacks permissions."
        fi
    fi

    if [[ "$DEPLOY_KEY_ADDED" != "true" ]]; then
        echo ""
        log_warn "Could not add deploy key automatically."
        echo "  Add this public key as a read-only deploy key at:"
        echo "  https://github.com/${REPO_PATH}/settings/keys"
        echo ""
        echo "  $DEPLOY_PUBKEY"
        echo ""
        printf "${_CYAN}Press Enter once the deploy key is added...${_NC} "
        read -r
    fi

    log_info "Cloning Poseidon on remote..."
    ssh "${DO_SSH_USER}@${DROPLET_IP}" bash <<GITCLONE
set -euo pipefail
if [[ -d "${REMOTE_POSEIDON_DIR}/.git" ]]; then
    echo "Poseidon repo already cloned — pulling latest..."
    cd ${REMOTE_POSEIDON_DIR}
    git fetch origin
    git reset --hard origin/${POSEIDON_BRANCH}
else
    rm -rf ${REMOTE_POSEIDON_DIR}
    git clone --branch ${POSEIDON_BRANCH} --depth 1 ${POSEIDON_REPO} ${REMOTE_POSEIDON_DIR}
fi
GITCLONE

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
GATEWAY_URL=ws://127.0.0.1:${GATEWAY_PORT}
GATEWAY_TOKEN=${GATEWAY_TOKEN}
POSEIDON_STATIC_DIR=${REMOTE_POSEIDON_DIR}/apps/web/dist
OPENCLAW_SOURCE=opentusk
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
systemctl restart poseidon
echo "Poseidon service started."
POSEIDON_SERVICE
else
    log_warn "POSEIDON_REPO not set — skipping Poseidon deploy."
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 7: Tailscale (if enabled)
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "$TAILSCALE_ENABLED" == "true" ]]; then
    if [[ -z "${TAILSCALE_AUTH_KEY:-}" ]]; then
        log_warn "TAILSCALE_AUTH_KEY is empty — Tailscale will install but 'tailscale up' will fail."
        log_warn "After deploy, SSH in and run 'tailscale up' interactively (browser login)."
    fi
    log_info "Installing and configuring Tailscale..."
    ssh "${DO_SSH_USER}@${DROPLET_IP}" bash <<TAILSCALE
set -euo pipefail

# Install Tailscale
if ! command -v tailscale &>/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
fi

# Authenticate (skip if already online)
if tailscale status --self --json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if d.get('Self',{}).get('Online') else 1)" 2>/dev/null; then
    echo "Tailscale already online — skipping auth."
else
    tailscale up --auth-key="${TAILSCALE_AUTH_KEY}" --hostname="${DO_DROPLET_NAME}"
fi
TAILSCALE

    # Check if serve rules are already configured before applying
    TS_SERVE_STATUS=$(ssh "${DO_SSH_USER}@${DROPLET_IP}" 'tailscale serve status 2>&1' 2>/dev/null || true)
    TS_HAS_POSEIDON=false
    TS_HAS_GATEWAY=false
    if echo "$TS_SERVE_STATUS" | grep -q "localhost:${POSEIDON_PORT}" 2>/dev/null; then
        TS_HAS_POSEIDON=true
    fi
    if echo "$TS_SERVE_STATUS" | grep -q "localhost:${GATEWAY_PORT}" 2>/dev/null; then
        TS_HAS_GATEWAY=true
    fi

    if [[ "$TS_HAS_POSEIDON" == "true" && "$TS_HAS_GATEWAY" == "true" ]]; then
        log_info "Tailscale serve rules already configured — skipping."
    else
        log_info "Configuring Tailscale ${TAILSCALE_MODE} rules..."
        if [[ "$TAILSCALE_MODE" == "funnel" ]]; then
            ssh "${DO_SSH_USER}@${DROPLET_IP}" bash <<TSFUNNEL
set -euo pipefail
tailscale funnel --bg --https=8443 http://localhost:${GATEWAY_PORT}
tailscale serve --bg --https=443 http://localhost:${POSEIDON_PORT}
echo "Tailscale funnel configured."
TSFUNNEL
        else
            ssh "${DO_SSH_USER}@${DROPLET_IP}" bash <<TSSERVE
set -euo pipefail
tailscale serve --bg --https=8443 http://localhost:${GATEWAY_PORT}
tailscale serve --bg --https=443 http://localhost:${POSEIDON_PORT}
echo "Tailscale serve configured."
TSSERVE
        fi
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
if [[ -n "${POSEIDON_REPO:-}" ]]; then
    POS_STATUS=$(ssh "${DO_SSH_USER}@${DROPLET_IP}" \
        'systemctl is-active poseidon 2>/dev/null' || true)
    if [[ "$POS_STATUS" == "active" ]]; then
        log_info "  Poseidon service: active"
    else
        log_error "  Poseidon service: $POS_STATUS"
        SMOKE_OK=false
    fi
fi

# Check Tailscale (if enabled)
if [[ "$TAILSCALE_ENABLED" == "true" ]]; then
    TS_STATE=$(ssh "${DO_SSH_USER}@${DROPLET_IP}" bash <<'TSSMOKE'
if ! command -v tailscale &>/dev/null; then
    echo "not_installed"
    exit 0
fi
if ! tailscale status --self --json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if d.get('Self',{}).get('Online') else 1)" 2>/dev/null; then
    echo "not_online"
    exit 0
fi
serve_out=$(tailscale serve status 2>&1)
missing=""
if ! echo "$serve_out" | grep -q "localhost:${POSEIDON_PORT}"; then
    missing="poseidon"
fi
if ! echo "$serve_out" | grep -q "localhost:${GATEWAY_PORT}"; then
    missing="${missing:+$missing,}gateway"
fi
if [[ -n "$missing" ]]; then
    echo "serve_missing:$missing"
else
    echo "ok"
fi
TSSMOKE
    )
    case "$TS_STATE" in
        ok)
            log_info "  Tailscale: online, serve configured" ;;
        not_installed)
            log_error "  Tailscale: binary not installed"
            SMOKE_OK=false ;;
        not_online)
            log_error "  Tailscale: installed but not online (auth may have failed)"
            SMOKE_OK=false ;;
        serve_missing:*)
            log_warn "  Tailscale: online but serve incomplete (${TS_STATE#serve_missing:})" ;;
        *)
            log_warn "  Tailscale: unknown state ($TS_STATE)" ;;
    esac
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
