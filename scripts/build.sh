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
  --no-pull    Skip git pull if the repo already exists
  --browser    Pre-install Chromium/Playwright for browser tool support
  --apt PKG    Install extra APT packages (space-separated, repeatable)
  --help       Show this help message

Environment variables:
  OPENCLAW_DOCKER_APT_PACKAGES   Extra system packages (space-separated)
  OPENCLAW_INSTALL_BROWSER=1     Pre-install Chromium/Playwright

Examples:
  $(basename "$0")                        # clone/pull + build
  $(basename "$0") --no-pull              # build from existing checkout
  $(basename "$0") --browser              # build with Chromium support
  $(basename "$0") --apt "ffmpeg"         # build with extra packages
EOF
    exit 0
}

# ─── Parse flags ─────────────────────────────────────────────────────────────
NO_PULL=false
INSTALL_BROWSER="${OPENCLAW_INSTALL_BROWSER:-}"
APT_PACKAGES="${OPENCLAW_DOCKER_APT_PACKAGES:-}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-pull) NO_PULL=true ;;
        --browser) INSTALL_BROWSER=1 ;;
        --apt)     shift; APT_PACKAGES="$APT_PACKAGES ${1:-}" ;;
        --help|-h) usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
    shift
done
APT_PACKAGES="$(echo "$APT_PACKAGES" | xargs)"   # trim whitespace

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
BUILD_ARGS=()
if [[ -n "$APT_PACKAGES" ]]; then
    BUILD_ARGS+=(--build-arg "OPENCLAW_DOCKER_APT_PACKAGES=$APT_PACKAGES")
    log_info "Extra APT packages: $APT_PACKAGES"
fi
if [[ -n "$INSTALL_BROWSER" ]]; then
    BUILD_ARGS+=(--build-arg "OPENCLAW_INSTALL_BROWSER=1")
    log_info "Browser support: enabled (adds ~300MB for Chromium/Playwright)"
fi

log_info "Building Docker image $MUSTANGCLAW_IMAGE..."
docker build "${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}" -t "$MUSTANGCLAW_IMAGE" "$MUSTANGCLAW_DIR"

# ─── Clone or update Poseidon ──────────────────────────────────────────────
if [[ ! -d "$POSEIDON_DIR" ]]; then
    log_info "Cloning Poseidon repository..."
    git clone "$POSEIDON_REPO" "$POSEIDON_DIR"
elif [[ "$NO_PULL" == "false" ]]; then
    log_info "Updating Poseidon repository..."
    git -C "$POSEIDON_DIR" pull
else
    log_info "Skipping Poseidon git pull (--no-pull)."
fi

# ─── Build Poseidon overlay image ──────────────────────────────────────────
log_info "Building Poseidon overlay onto $MUSTANGCLAW_IMAGE..."
docker build -f "$PROJECT_ROOT/Dockerfile.poseidon" -t "$MUSTANGCLAW_IMAGE" "$PROJECT_ROOT"

# ─── Summary ─────────────────────────────────────────────────────────────────
IMAGE_ID=$(docker images --no-trunc --format '{{.ID}}' "$MUSTANGCLAW_IMAGE" | head -1)
IMAGE_SIZE=$(docker images --format '{{.Size}}' "$MUSTANGCLAW_IMAGE" | head -1)

log_info "Build complete."
log_info "  Image: $MUSTANGCLAW_IMAGE"
log_info "  ID:    $IMAGE_ID"
log_info "  Size:  $IMAGE_SIZE"
