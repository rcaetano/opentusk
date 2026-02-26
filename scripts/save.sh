#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ─── Help ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Export the $OPENCLAW_IMAGE Docker image to a compressed archive.

Options:
  --output PATH    Output file path (default: ./mustangclaw-local.tar.gz)
  --no-compress    Skip gzip compression (outputs raw .tar)
  --help           Show this help message

Examples:
  $(basename "$0")                                   # save to ./mustangclaw-local.tar.gz
  $(basename "$0") --output /tmp/my-image.tar.gz     # custom output path
  $(basename "$0") --no-compress                     # save uncompressed .tar
EOF
    exit 0
}

# ─── Parse flags ─────────────────────────────────────────────────────────────
OUTPUT=""
COMPRESS=true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)     shift; OUTPUT="${1:-}" ;;
        --output=*)   OUTPUT="${1#--output=}" ;;
        --no-compress) COMPRESS=false ;;
        --help|-h)    usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
    shift
done

# Set default output path based on compression mode
if [[ -z "$OUTPUT" ]]; then
    if [[ "$COMPRESS" == "true" ]]; then
        OUTPUT="./mustangclaw-local.tar.gz"
    else
        OUTPUT="./mustangclaw-local.tar"
    fi
fi

# ─── Prerequisites ───────────────────────────────────────────────────────────
require_cmd docker

# ─── Validate image exists ───────────────────────────────────────────────────
if ! docker image inspect "$OPENCLAW_IMAGE" &>/dev/null; then
    log_error "Image '$OPENCLAW_IMAGE' not found. Run 'mustangclaw build' first."
    exit 1
fi

# ─── Save image ──────────────────────────────────────────────────────────────
log_info "Saving $OPENCLAW_IMAGE to $OUTPUT..."

if [[ "$COMPRESS" == "true" ]]; then
    docker save "$OPENCLAW_IMAGE" | gzip > "$OUTPUT"
else
    docker save "$OPENCLAW_IMAGE" -o "$OUTPUT"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
FILE_SIZE=$(ls -lh "$OUTPUT" | awk '{print $5}')

log_info "Save complete."
log_info "  File: $OUTPUT"
log_info "  Size: $FILE_SIZE"
