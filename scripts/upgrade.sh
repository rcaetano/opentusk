#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ─── Help ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Upgrade MustangClaw by pulling the latest code and rebuilding the Docker image.
Remote upgrade uses the marketplace updater for OpenClaw and rsyncs Poseidon.

Options:
  --target TARGET   "local" (default) or "remote"
  --ip IP           Droplet IP for remote target (auto-detected if omitted)
  --rollback        Revert to previous git commit and rebuild (local only)
  --help            Show this help message

Examples:
  $(basename "$0")                          # upgrade local
  $(basename "$0") --target remote          # upgrade droplet
  $(basename "$0") --rollback               # revert local to previous commit
EOF
    exit 0
}

# ─── Parse flags ─────────────────────────────────────────────────────────────
TARGET="local"
IP=""
ROLLBACK=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)   TARGET="$2"; shift 2 ;;
        --ip)       IP="$2"; shift 2 ;;
        --rollback) ROLLBACK=true; shift ;;
        --help|-h)  usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

if [[ "$TARGET" != "local" && "$TARGET" != "remote" ]]; then
    log_error "Invalid target '$TARGET'. Must be 'local' or 'remote'."
    exit 1
fi

# ─── Local upgrade ───────────────────────────────────────────────────────────
if [[ "$TARGET" == "local" ]]; then
    require_cmd git
    require_cmd docker

    cd "$PROJECT_ROOT"

    if [[ ! -d "$OPENCLAW_DIR" ]]; then
        log_error "MustangClaw repo not found at $OPENCLAW_DIR. Run build.sh first."
        exit 1
    fi

    OLD_SHA=$(git -C "$OPENCLAW_DIR" rev-parse --short HEAD)

    if [[ "$ROLLBACK" == "true" ]]; then
        log_warn "Rolling back to previous commit..."
        git -C "$OPENCLAW_DIR" checkout HEAD~1
    else
        log_info "Pulling latest changes..."
        git -C "$OPENCLAW_DIR" pull
    fi

    NEW_SHA=$(git -C "$OPENCLAW_DIR" rev-parse --short HEAD)

    log_info "Building Docker image..."
    docker build -t "$OPENCLAW_IMAGE" "$OPENCLAW_DIR"

    # ─── Update Poseidon ──────────────────────────────────────────────────
    if [[ -d "$POSEIDON_DIR" ]]; then
        if [[ -d "$POSEIDON_DIR/.git" ]]; then
            if [[ "$ROLLBACK" == "true" ]]; then
                git -C "$POSEIDON_DIR" checkout HEAD~1
            else
                log_info "Pulling latest Poseidon changes..."
                git -C "$POSEIDON_DIR" pull
            fi
        else
            log_info "Poseidon directory is not a git repo (rsynced copy) — skipping pull."
        fi
        log_info "Rebuilding Poseidon overlay..."
        docker build -f "$PROJECT_ROOT/Dockerfile.poseidon" -t "$OPENCLAW_IMAGE" "$PROJECT_ROOT"
    fi

    # Restart via 'mustangclaw run' to apply config patches (bind=lan, token sync, etc.)
    log_info "Restarting gateway..."
    "$PROJECT_ROOT/scripts/run-local.sh" --stop
    "$PROJECT_ROOT/scripts/run-local.sh"

    log_info "Upgrade complete."
    log_info "  Previous: $OLD_SHA"
    log_info "  Current:  $NEW_SHA"
    exit 0
fi

# ─── Remote upgrade ─────────────────────────────────────────────────────────
require_cmd ssh
require_cmd rsync

if [[ "$ROLLBACK" == "true" ]]; then
    log_error "--rollback is only supported for local upgrades."
    exit 1
fi

if [[ -z "$IP" ]]; then
    require_cmd doctl "doctl is required to auto-detect droplet IP. Install it or use --ip."
    IP=$(get_droplet_ip)
fi

log_info "Upgrading remote at $IP..."

# 1. Update OpenClaw via marketplace updater
log_info "Updating OpenClaw on remote..."
ssh "${DO_SSH_USER}@${IP}" bash <<'OCUPDATE'
set -euo pipefail
if [[ -x /opt/update-openclaw.sh ]]; then
    /opt/update-openclaw.sh
else
    echo "Marketplace updater not found — skipping OpenClaw update."
fi
systemctl restart openclaw
OCUPDATE

# 2. Rsync Poseidon source (private repo — can't git clone on remote)
if [[ -d "$PROJECT_ROOT/poseidon" ]]; then
    log_info "Syncing Poseidon source to remote..."
    rsync -avz --progress -e "ssh" \
        --exclude='.git/' --exclude='node_modules/' --exclude='dist/' \
        "$PROJECT_ROOT/poseidon/" "${DO_SSH_USER}@${IP}:${REMOTE_POSEIDON_DIR}/"

    # 3. Rebuild Poseidon + restart
    log_info "Rebuilding Poseidon on remote..."
    ssh "${DO_SSH_USER}@${IP}" bash <<POSBUILD
set -euo pipefail
cd ${REMOTE_POSEIDON_DIR}
pnpm install --frozen-lockfile
pnpm --filter @poseidon/web build
chown -R openclaw:openclaw ${REMOTE_POSEIDON_DIR}
systemctl restart poseidon
POSBUILD
else
    log_warn "Poseidon source not found locally — skipping Poseidon upgrade."
fi

log_info "Remote upgrade complete at $IP."
