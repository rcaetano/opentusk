#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ─── Help ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Upgrade MustangClaw by pulling the latest code and rebuilding the Docker image.
Remote ~/.mustangclaw is never overwritten if it exists; seeded from local if absent.

Options:
  --target TARGET   "local" (default) or "remote"
  --ip IP           Droplet IP for remote target (auto-detected if omitted)
  --rollback        Revert to previous git commit and rebuild
  --help            Show this help message

Examples:
  $(basename "$0")                          # upgrade local
  $(basename "$0") --target remote          # upgrade droplet
  $(basename "$0") --target remote --rollback  # revert remote to previous commit
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

    if [[ ! -d "$MUSTANGCLAW_DIR" ]]; then
        log_error "MustangClaw repo not found at $MUSTANGCLAW_DIR. Run build.sh first."
        exit 1
    fi

    OLD_SHA=$(git -C "$MUSTANGCLAW_DIR" rev-parse --short HEAD)

    if [[ "$ROLLBACK" == "true" ]]; then
        log_warn "Rolling back to previous commit..."
        git -C "$MUSTANGCLAW_DIR" checkout HEAD~1
    else
        log_info "Pulling latest changes..."
        git -C "$MUSTANGCLAW_DIR" pull
    fi

    NEW_SHA=$(git -C "$MUSTANGCLAW_DIR" rev-parse --short HEAD)

    log_info "Building Docker image..."
    docker build -t "$MUSTANGCLAW_IMAGE" "$MUSTANGCLAW_DIR"

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
        docker build -f "$PROJECT_ROOT/Dockerfile.poseidon" -t "$MUSTANGCLAW_IMAGE" "$PROJECT_ROOT"
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

if [[ -z "$IP" ]]; then
    require_cmd doctl "doctl is required to auto-detect droplet IP. Install it or use --ip."
    IP=$(get_droplet_ip)
fi

if [[ "$ROLLBACK" == "true" ]]; then
    log_warn "Rolling back remote to previous commit..."
else
    log_info "Upgrading remote at $IP..."
fi

# Sync wrapper scripts to remote (excluding repos — they're handled separately)
log_info "Syncing wrapper project to remote..."
rsync -avz --progress -e "ssh" \
    --exclude='openclaw/' --exclude='poseidon/' --exclude='.git/' \
    --exclude='node_modules/' --exclude='.mustangclaw/' \
    "$PROJECT_ROOT/" "mustangclaw@${IP}:/home/mustangclaw/mustangclaw/"

# Sync poseidon source to remote (private repo — can't git clone on remote)
if [[ -d "$PROJECT_ROOT/poseidon" ]]; then
    log_info "Syncing Poseidon source to remote..."
    rsync -avz --progress -e "ssh" \
        --exclude='.git/' --exclude='node_modules/' --exclude='dist/' \
        "$PROJECT_ROOT/poseidon/" "mustangclaw@${IP}:/home/mustangclaw/mustangclaw/poseidon/"
fi

# Seed remote config from local if it doesn't exist yet (NEVER overwrite existing)
REMOTE_CONFIG_EXISTS=$(ssh "mustangclaw@${IP}" '[[ -d /home/mustangclaw/.mustangclaw ]] && echo yes || echo no')
if [[ "$REMOTE_CONFIG_EXISTS" == "no" ]]; then
    if [[ -d "$MUSTANGCLAW_CONFIG_DIR" ]]; then
        log_info "Remote ~/.mustangclaw not found — seeding from local config..."
        rsync -avz --progress -e "ssh" \
            "$MUSTANGCLAW_CONFIG_DIR/" "mustangclaw@${IP}:/home/mustangclaw/.mustangclaw/"
    else
        log_warn "Remote ~/.mustangclaw not found and no local config to seed."
    fi
else
    log_info "Remote ~/.mustangclaw exists — preserving remote config (not overwriting)."
fi

# Run upgrade on remote: pull openclaw, rebuild images (poseidon uses rsynced source),
# and restart with config patching via 'mustangclaw run'.
ROLLBACK_FLAG=""
if [[ "$ROLLBACK" == "true" ]]; then
    ROLLBACK_FLAG="--rollback"
fi

ssh "mustangclaw@${IP}" bash <<EOF
set -euo pipefail
cd /home/mustangclaw/mustangclaw
chmod +x mustangclaw
./mustangclaw upgrade $ROLLBACK_FLAG
EOF

log_info "Remote upgrade complete at $IP."
