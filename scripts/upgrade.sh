#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ─── Help ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Upgrade MustangClaw by pulling the latest code and rebuilding the Docker image.
Configuration in ~/.mustangclaw is never touched.

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
        if [[ "$ROLLBACK" == "true" ]]; then
            git -C "$POSEIDON_DIR" checkout HEAD~1
        else
            log_info "Pulling latest Poseidon changes..."
            git -C "$POSEIDON_DIR" pull
        fi
        log_info "Rebuilding Poseidon overlay..."
        docker build -f "$PROJECT_ROOT/Dockerfile.poseidon" -t "$MUSTANGCLAW_IMAGE" "$PROJECT_ROOT"
    fi

    log_info "Restarting containers..."
    COMPOSE_FILES=(-f "$MUSTANGCLAW_DIR/docker-compose.yml")
    if [[ -f "$MUSTANGCLAW_DIR/docker-compose.override.yml" ]]; then
        COMPOSE_FILES+=(-f "$MUSTANGCLAW_DIR/docker-compose.override.yml")
    fi
    docker compose "${COMPOSE_FILES[@]}" down
    docker compose "${COMPOSE_FILES[@]}" up -d openclaw-gateway

    log_info "Upgrade complete."
    log_info "  Previous: $OLD_SHA"
    log_info "  Current:  $NEW_SHA"
    exit 0
fi

# ─── Remote upgrade ─────────────────────────────────────────────────────────
require_cmd ssh

if [[ -z "$IP" ]]; then
    require_cmd doctl "doctl is required to auto-detect droplet IP. Install it or use --ip."
    IP=$(get_droplet_ip)
fi

GIT_CMD="git pull"
if [[ "$ROLLBACK" == "true" ]]; then
    GIT_CMD="git checkout HEAD~1"
    log_warn "Rolling back remote to previous commit..."
else
    log_info "Upgrading remote at $IP..."
fi

ssh "mustangclaw@${IP}" bash <<EOF
set -euo pipefail
cd /home/mustangclaw/mustangclaw
OLD_SHA=\$(git rev-parse --short HEAD)
$GIT_CMD
NEW_SHA=\$(git rev-parse --short HEAD)
echo "OLD_SHA=\$OLD_SHA"
echo "NEW_SHA=\$NEW_SHA"
docker build -t mustangclaw:local .
docker compose down
docker compose up -d openclaw-gateway
EOF

log_info "Remote upgrade complete at $IP."
