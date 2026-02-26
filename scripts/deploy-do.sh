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
  --ip IP     Target an existing OpenClaw droplet by IP (skips DO creation)
  --dry-run   Show what would happen without creating anything
  --force     Skip confirmation prompts
  --help      Show this help message

Examples:
  $(basename "$0")                  # create and provision droplet
  $(basename "$0") --dry-run        # preview without changes
  $(basename "$0") --ip 1.2.3.4    # provision existing droplet
EOF
    exit 0
}

# ─── Parse flags ─────────────────────────────────────────────────────────────
DRY_RUN=false
FORCE=false
TARGET_IP=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --force)   FORCE=true; shift ;;
        --ip)      TARGET_IP="$2"; shift 2 ;;
        --help|-h) usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done
export FORCE

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 1: Validate prerequisites
# ═══════════════════════════════════════════════════════════════════════════════
log_info "Validating prerequisites..."

require_cmd ssh

if [[ -z "$TARGET_IP" ]]; then
    require_cmd doctl

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
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 2: Resolve droplet IP
# ═══════════════════════════════════════════════════════════════════════════════
SKIP_CLOUD_INIT=true

if [[ -n "$TARGET_IP" ]]; then
    DROPLET_IP="$TARGET_IP"
    log_info "Using provided IP: $DROPLET_IP"
else
    EXISTING_IP=$(doctl compute droplet list --tag-name "$DO_TAG" \
        --format Name,PublicIPv4 --no-header \
        | awk -v n="$DO_DROPLET_NAME" '$1 == n { print $2 }' || true)

    if [[ -n "$EXISTING_IP" ]]; then
        DROPLET_IP="$EXISTING_IP"
        log_warn "Droplet '$DO_DROPLET_NAME' already exists at $DROPLET_IP — resuming provisioning."
    else
        SKIP_CLOUD_INIT=false
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Dry run summary
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "$DRY_RUN" == "true" ]]; then
    if [[ -n "${DROPLET_IP:-}" ]]; then
        cat <<EOF

[DRY RUN] Would provision droplet at $DROPLET_IP (existing).
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
# Phase 2 (cont.): Create droplet if needed
# ═══════════════════════════════════════════════════════════════════════════════
if [[ -z "${DROPLET_IP:-}" ]]; then
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
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 3: Wait for SSH + bootstrap
# ═══════════════════════════════════════════════════════════════════════════════
log_info "Waiting for SSH to become available..."
if ! wait_for_ssh "$DROPLET_IP" 180; then
    log_error "Check droplet status: ssh ${DO_SSH_USER}@${DROPLET_IP}"
    exit 1
fi
echo ""
log_info "SSH is ready."

# Cloud-init polling (only for newly created droplets)
if [[ "$SKIP_CLOUD_INIT" == "false" ]]; then
    log_info "Waiting for cloud-init to finish..."
    CLOUD_WAIT=0
    CLOUD_MAX=600
    CLOUD_STATUS="unknown"
    while true; do
        CLOUD_STATUS=$(remote_exec "$DROPLET_IP" \
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

    # Re-verify SSH after cloud-init (sshd may restart)
    log_info "Re-verifying SSH connectivity..."
    if ! wait_for_ssh "$DROPLET_IP" 60 "SSH (post-cloud-init)"; then
        log_error "SSH connection lost after cloud-init."
        log_error "The droplet may be rebooting. Try: ssh ${DO_SSH_USER}@${DROPLET_IP}"
        exit 1
    fi
    echo ""
fi

# First-login wizard check
FIRST_LOGIN_PENDING=$(remote_exec "$DROPLET_IP" \
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
fi

# Swap setup + first-login cleanup (single SSH session)
remote_exec "$DROPLET_IP" <<'BOOTSTRAP'
set -euo pipefail

# ── Swap ──
if swapon --show | grep -q /swapfile; then
    echo "Swap already active — skipping."
else
    echo "Creating 2GB swap file..."
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    echo "Swap enabled: $(swapon --show)"
fi

# ── Clean up first-login scripts ──
rm -rf /etc/update-motd.d/99-one-click
for f in /etc/profile.d/*one-click* /etc/profile.d/*first-login* /etc/profile.d/*setup*; do
    [ -f "$f" ] && rm -f "$f"
done
if [ -f /root/.bashrc ]; then
    sed -i "/ai.provider\|first.login\|one.click.*setup\|provider.*selector/Id" /root/.bashrc
fi
BOOTSTRAP

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 4: Configure OpenClaw
# ═══════════════════════════════════════════════════════════════════════════════
log_info "Checking OpenClaw configuration..."

EXISTING_TOKEN=$(remote_exec "$DROPLET_IP" \
    "python3 -c \"import json; print(json.load(open('${REMOTE_OPENCLAW_HOME}/.openclaw/openclaw.json'))['gateway']['auth']['token'])\" 2>/dev/null" \
    || true)

if [[ -n "$EXISTING_TOKEN" ]]; then
    GATEWAY_TOKEN="$EXISTING_TOKEN"
    log_info "Recovered existing gateway token from remote (${GATEWAY_TOKEN:0:8}...)."
else
    GATEWAY_TOKEN=$(openssl rand -hex 32)
    log_info "Generated new gateway token (${GATEWAY_TOKEN:0:8}...)."

    log_info "Configuring OpenClaw on remote..."
    remote_exec "$DROPLET_IP" bash -s \
        "$REMOTE_OPENCLAW_HOME" "$GATEWAY_TOKEN" "$GATEWAY_PORT" "$POSEIDON_PORT" <<'CONFIGURE'
set -euo pipefail
OC_HOME="$1"; TOKEN="$2"; GW_PORT="$3"; POS_PORT="$4"

mkdir -p "$OC_HOME/.openclaw/workspace"
chmod 700 "$OC_HOME/.openclaw"
chmod 700 "$OC_HOME/.openclaw/workspace"

cat > "$OC_HOME/.openclaw/openclaw.json" <<JSONEOF
{
  "gateway": {
    "mode": "local",
    "auth": {
      "mode": "token",
      "token": "$TOKEN"
    }
  }
}
JSONEOF

cat > "$OC_HOME/.openclaw/config.env" <<CFGEOF
GATEWAY_PORT=$GW_PORT
POSEIDON_PORT=$POS_PORT
CFGEOF
chmod 600 "$OC_HOME/.openclaw/config.env"
chmod 600 "$OC_HOME/.openclaw/openclaw.json"

chown -R openclaw:openclaw "$OC_HOME/.openclaw"
systemctl restart openclaw
echo "OpenClaw configured and restarted."
CONFIGURE
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 5: Deploy Poseidon
# ═══════════════════════════════════════════════════════════════════════════════
if [[ -n "${POSEIDON_REPO:-}" ]]; then
    log_info "Installing bun and generating deploy key..."
    DEPLOY_PUBKEY=$(remote_exec "$DROPLET_IP" <<'BUNKEY'
set -euo pipefail

# ── Install bun ──
if ! command -v bun &>/dev/null; then
    curl -fsSL https://bun.sh/install | bash
    ln -sf "$HOME/.bun/bin/bun" /usr/local/bin/bun
fi
bun install -g pnpm
ln -sf "$(bun pm bin -g)/pnpm" /usr/local/bin/pnpm 2>/dev/null || true
echo "bun $(bun --version), pnpm $(pnpm --version)" >&2

# ── Deploy key ──
KEY_FILE="/root/.ssh/do_proxy_ed25519"
if [[ ! -f "$KEY_FILE" ]]; then
    ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "opentusk-deploy" >/dev/null 2>&1
fi
if ! grep -q "do_proxy_ed25519" /root/.ssh/config 2>/dev/null; then
    cat >> /root/.ssh/config <<'SSHCONF'

Host github.com
    IdentityFile /root/.ssh/do_proxy_ed25519
    StrictHostKeyChecking accept-new
SSHCONF
    chmod 600 /root/.ssh/config
fi

cat "${KEY_FILE}.pub"
BUNKEY
    )

    # Add deploy key to GitHub repo via gh CLI (or prompt user)
    log_info "Adding deploy key to GitHub repo..."
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

    # Verify SSH before the build session (bun install may cause sshd churn)
    log_info "Verifying SSH connectivity..."
    if ! wait_for_ssh "$DROPLET_IP" 60 "SSH (pre-build)"; then
        log_error "SSH not available before Poseidon build. Try again: ./opentusk deploy"
        exit 1
    fi
    echo ""

    # Clone/pull + build + systemd (single session)
    log_info "Cloning, building, and configuring Poseidon service..."
    remote_exec "$DROPLET_IP" bash -s \
        "$REMOTE_POSEIDON_DIR" "$POSEIDON_REPO" "$POSEIDON_BRANCH" \
        "$POSEIDON_PORT" "$GATEWAY_PORT" "$GATEWAY_TOKEN" <<'POSEIDON'
set -euo pipefail
POS_DIR="$1"; POS_REPO="$2"; POS_BRANCH="$3"
POS_PORT="$4"; GW_PORT="$5"; GW_TOKEN="$6"

# ── Git clone/pull ──
git config --global --add safe.directory "$POS_DIR" 2>/dev/null || true
if [[ -d "$POS_DIR/.git" ]]; then
    echo "Poseidon repo already cloned — pulling latest..."
    cd "$POS_DIR"
    git fetch origin
    git reset --hard "origin/$POS_BRANCH"
else
    rm -rf "$POS_DIR"
    git clone --branch "$POS_BRANCH" --depth 1 "$POS_REPO" "$POS_DIR"
fi

# ── Build ──
cd "$POS_DIR"
pnpm install --frozen-lockfile
pnpm --filter @poseidon/web build
chown -R openclaw:openclaw "$POS_DIR"

# ── Environment file ──
cat > /opt/poseidon.env <<ENVEOF
PORT=$POS_PORT
GATEWAY_URL=ws://127.0.0.1:$GW_PORT
GATEWAY_TOKEN=$GW_TOKEN
POSEIDON_STATIC_DIR=$POS_DIR/apps/web/dist
OPENCLAW_SOURCE=opentusk
ENVEOF
chmod 600 /opt/poseidon.env

# ── Systemd unit ──
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
POSEIDON
else
    log_warn "POSEIDON_REPO not set — skipping Poseidon deploy."
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 6: Tailscale (if enabled)
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "$TAILSCALE_ENABLED" == "true" ]]; then
    if [[ -z "${TAILSCALE_AUTH_KEY:-}" ]]; then
        log_warn "TAILSCALE_AUTH_KEY is empty — Tailscale will install but 'tailscale up' will fail."
        log_warn "After deploy, SSH in and run 'tailscale up' interactively (browser login)."
    fi
    log_info "Installing and configuring Tailscale..."
    remote_exec "$DROPLET_IP" bash -s \
        "$TAILSCALE_AUTH_KEY" "$DO_DROPLET_NAME" "$TAILSCALE_MODE" \
        "$POSEIDON_PORT" "$GATEWAY_PORT" <<'TAILSCALE'
set -euo pipefail
TS_KEY="$1"; TS_HOSTNAME="$2"; TS_MODE="$3"
POS_PORT="$4"; GW_PORT="$5"

# ── Install ──
if ! command -v tailscale &>/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
fi

# ── Authenticate (idempotent) ──
if tailscale status --self --json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if d.get('Self',{}).get('Online') else 1)" 2>/dev/null; then
    echo "Tailscale already online — skipping auth."
else
    tailscale up --auth-key="$TS_KEY" --hostname="$TS_HOSTNAME"
fi

# ── Serve rules (check before applying) ──
serve_out=$(tailscale serve status 2>&1 || true)
has_poseidon=false
has_gateway=false
echo "$serve_out" | grep -q "localhost:${POS_PORT}" && has_poseidon=true
echo "$serve_out" | grep -q "localhost:${GW_PORT}" && has_gateway=true

if [[ "$has_poseidon" == "true" && "$has_gateway" == "true" ]]; then
    echo "Tailscale serve rules already configured — skipping."
else
    if [[ "$TS_MODE" == "funnel" ]]; then
        tailscale funnel --bg --https=8443 "http://localhost:${GW_PORT}"
        tailscale serve --bg --https=443 "http://localhost:${POS_PORT}"
        echo "Tailscale funnel configured."
    else
        tailscale serve --bg --https=8443 "http://localhost:${GW_PORT}"
        tailscale serve --bg --https=443 "http://localhost:${POS_PORT}"
        echo "Tailscale serve configured."
    fi
fi
TAILSCALE
    log_info "Tailscale configured ($TAILSCALE_MODE mode)."
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 7: Smoke test
# ═══════════════════════════════════════════════════════════════════════════════
log_info "Running post-deploy smoke test..."

SMOKE_OUTPUT=$(remote_exec "$DROPLET_IP" bash -s \
    "${POSEIDON_REPO:+yes}" "$TAILSCALE_ENABLED" \
    "$POSEIDON_PORT" "$GATEWAY_PORT" <<'SMOKETEST'
# No set -e: collect all results even if individual checks fail
HAS_POSEIDON="$1"; TS_ENABLED="$2"
POS_PORT="$3"; GW_PORT="$4"

# OpenClaw service
oc_status=$(systemctl is-active openclaw 2>/dev/null || echo "unknown")
echo "OPENCLAW=$oc_status"

# Poseidon service
if [[ "$HAS_POSEIDON" == "yes" ]]; then
    pos_status=$(systemctl is-active poseidon 2>/dev/null || echo "unknown")
    echo "POSEIDON=$pos_status"
fi

# Tailscale
if [[ "$TS_ENABLED" == "true" ]]; then
    if ! command -v tailscale &>/dev/null; then
        echo "TAILSCALE=not_installed"
    elif ! tailscale status --self --json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if d.get('Self',{}).get('Online') else 1)" 2>/dev/null; then
        echo "TAILSCALE=not_online"
    else
        serve_out=$(tailscale serve status 2>&1)
        missing=""
        echo "$serve_out" | grep -q "localhost:${POS_PORT}" || missing="poseidon"
        echo "$serve_out" | grep -q "localhost:${GW_PORT}" || missing="${missing:+$missing,}gateway"
        if [[ -n "$missing" ]]; then
            echo "TAILSCALE=serve_missing:$missing"
        else
            echo "TAILSCALE=ok"
        fi
    fi
fi

# Gateway port (poll up to 90s)
gw_ready=false
gw_elapsed=0
while [[ $gw_elapsed -lt 90 ]]; do
    if curl -sf -o /dev/null "http://localhost:${GW_PORT}" 2>/dev/null; then
        gw_ready=true
        break
    fi
    sleep 5
    gw_elapsed=$((gw_elapsed + 5))
done
echo "GATEWAY=${gw_ready}:${gw_elapsed}"
SMOKETEST
)

# Parse smoke test results
SMOKE_OK=true

oc_val=$(echo "$SMOKE_OUTPUT" | grep "^OPENCLAW=" | cut -d= -f2-)
if [[ "$oc_val" == "active" ]]; then
    log_info "  OpenClaw service: active"
else
    log_error "  OpenClaw service: $oc_val"
    SMOKE_OK=false
fi

pos_val=$(echo "$SMOKE_OUTPUT" | grep "^POSEIDON=" | cut -d= -f2- || true)
if [[ -n "$pos_val" ]]; then
    if [[ "$pos_val" == "active" ]]; then
        log_info "  Poseidon service: active"
    else
        log_error "  Poseidon service: $pos_val"
        SMOKE_OK=false
    fi
fi

ts_val=$(echo "$SMOKE_OUTPUT" | grep "^TAILSCALE=" | cut -d= -f2- || true)
if [[ -n "$ts_val" ]]; then
    case "$ts_val" in
        ok)
            log_info "  Tailscale: online, serve configured" ;;
        not_installed)
            log_error "  Tailscale: binary not installed"
            SMOKE_OK=false ;;
        not_online)
            log_error "  Tailscale: installed but not online (auth may have failed)"
            SMOKE_OK=false ;;
        serve_missing:*)
            log_warn "  Tailscale: online but serve incomplete (${ts_val#serve_missing:})" ;;
        *)
            log_warn "  Tailscale: unknown state ($ts_val)" ;;
    esac
fi

gw_val=$(echo "$SMOKE_OUTPUT" | grep "^GATEWAY=" | cut -d= -f2- || true)
gw_ready="${gw_val%%:*}"
gw_elapsed="${gw_val##*:}"
if [[ "$gw_ready" == "true" ]]; then
    log_info "  Gateway port ${GATEWAY_PORT}: responding (took ~${gw_elapsed}s)"
else
    log_warn "  Gateway port ${GATEWAY_PORT}: not responding after 90s — may need more time"
fi

if [[ "$SMOKE_OK" != "true" ]]; then
    log_error "Smoke test failed. Check: ssh ${DO_SSH_USER}@${DROPLET_IP}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 8: Save credentials + print summary
# ═══════════════════════════════════════════════════════════════════════════════
CREDS_FILE="$HOME/.openclaw/remote-credentials"
mkdir -p "$HOME/.openclaw"
cat > "$CREDS_FILE" <<CREDEOF
# OpenTusk remote deployment credentials
# Droplet: $DO_DROPLET_NAME ($DROPLET_IP)
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
GATEWAY_TOKEN=$GATEWAY_TOKEN
CREDEOF
chmod 600 "$CREDS_FILE"

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
