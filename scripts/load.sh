#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ─── Help ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") <FILE>

Import a Docker image from a tar or tar.gz archive.

Arguments:
  FILE    Path to the image archive (.tar or .tar.gz)

Options:
  --help  Show this help message

Examples:
  $(basename "$0") mustangclaw-local.tar.gz          # load compressed archive
  $(basename "$0") /tmp/my-image.tar                 # load uncompressed archive
EOF
    exit 0
}

# ─── Parse args ──────────────────────────────────────────────────────────────
INPUT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) usage ;;
        -*)        log_error "Unknown option: $1"; usage ;;
        *)
            if [[ -z "$INPUT" ]]; then
                INPUT="$1"
            else
                log_error "Unexpected argument: $1"; usage
            fi
            ;;
    esac
    shift
done

if [[ -z "$INPUT" ]]; then
    log_error "No input file specified."
    echo ""
    usage
fi

# ─── Prerequisites ───────────────────────────────────────────────────────────
require_cmd docker

# ─── Validate file exists ────────────────────────────────────────────────────
if [[ ! -f "$INPUT" ]]; then
    log_error "File not found: $INPUT"
    exit 1
fi

# ─── Detect compression and load ─────────────────────────────────────────────
is_gzipped() {
    case "$1" in
        *.tar.gz|*.tgz) return 0 ;;
    esac
    # Fall back to file magic bytes
    if command -v file &>/dev/null; then
        file --brief "$1" 2>/dev/null | grep -qi gzip && return 0
    fi
    return 1
}

log_info "Loading image from $INPUT..."

if is_gzipped "$INPUT"; then
    gunzip -c "$INPUT" | docker load
else
    docker load -i "$INPUT"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
log_info "Load complete."
if docker image inspect "$MUSTANGCLAW_IMAGE" &>/dev/null; then
    IMAGE_SIZE=$(docker images --format '{{.Size}}' "$MUSTANGCLAW_IMAGE" | head -1)
    log_info "  Image: $MUSTANGCLAW_IMAGE"
    log_info "  Size:  $IMAGE_SIZE"
fi
