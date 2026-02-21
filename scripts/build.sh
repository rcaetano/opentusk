#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ─── Help ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Clone (or update) the MustangClaw repo and build the Docker image.

Options:
  --no-pull   Skip git pull if the repo already exists
  --help      Show this help message

Examples:
  $(basename "$0")            # clone/pull + build
  $(basename "$0") --no-pull  # build from existing checkout
EOF
    exit 0
}

# ─── Parse flags ─────────────────────────────────────────────────────────────
NO_PULL=false
for arg in "$@"; do
    case "$arg" in
        --no-pull) NO_PULL=true ;;
        --help|-h) usage ;;
        *) log_error "Unknown option: $arg"; usage ;;
    esac
done

# ─── Prerequisites ───────────────────────────────────────────────────────────
require_cmd git
require_cmd docker

# ─── Clone or update ────────────────────────────────────────────────────────
cd "$PROJECT_ROOT"

if [[ ! -d "$MUSTANGCLAW_DIR" ]]; then
    log_info "Cloning MustangClaw repository..."
    git clone "$MUSTANGCLAW_REPO" "$MUSTANGCLAW_DIR"
elif [[ "$NO_PULL" == "false" ]]; then
    log_info "Updating MustangClaw repository..."
    git -C "$MUSTANGCLAW_DIR" pull
else
    log_info "Skipping git pull (--no-pull)."
fi

# ─── Build Docker image ─────────────────────────────────────────────────────
log_info "Building Docker image $MUSTANGCLAW_IMAGE..."
docker build -t "$MUSTANGCLAW_IMAGE" "$MUSTANGCLAW_DIR"

# ─── Summary ─────────────────────────────────────────────────────────────────
IMAGE_ID=$(docker images --no-trunc --format '{{.ID}}' "$MUSTANGCLAW_IMAGE" | head -1)
IMAGE_SIZE=$(docker images --format '{{.Size}}' "$MUSTANGCLAW_IMAGE" | head -1)

log_info "Build complete."
log_info "  Image: $MUSTANGCLAW_IMAGE"
log_info "  ID:    $IMAGE_ID"
log_info "  Size:  $IMAGE_SIZE"
