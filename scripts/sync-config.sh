#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ─── Help ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Sync local ~/.openclaw configuration to the local container or remote droplet.

Options:
  --target TARGET   "local" (default) or "remote"
  --ip IP           Droplet IP for remote target (auto-detected if omitted)
  --dry-run         Show what would be synced without doing it
  --help            Show this help message

Examples:
  $(basename "$0")                          # sync to local container
  $(basename "$0") --target remote          # sync to droplet (auto-detect IP)
  $(basename "$0") --target remote --ip 1.2.3.4
  $(basename "$0") --target remote --dry-run
EOF
    exit 0
}

# ─── Parse flags ─────────────────────────────────────────────────────────────
TARGET="local"
IP=""
DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)  TARGET="$2"; shift 2 ;;
        --ip)      IP="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help|-h) usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

if [[ "$TARGET" != "local" && "$TARGET" != "remote" ]]; then
    log_error "Invalid target '$TARGET'. Must be 'local' or 'remote'."
    exit 1
fi

# ─── Validate source ────────────────────────────────────────────────────────
if [[ ! -d "$OPENCLAW_CONFIG_DIR" ]]; then
    log_error "Config directory $OPENCLAW_CONFIG_DIR does not exist. Nothing to sync."
    exit 1
fi

# ─── Sync to local container ────────────────────────────────────────────────
if [[ "$TARGET" == "local" ]]; then
    require_cmd docker

    CONTAINER="mustangclaw"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would copy $OPENCLAW_CONFIG_DIR/. to $CONTAINER:/home/node/.openclaw/"
        log_info "[DRY RUN] Would chown -R 1000:1000 /home/node/.openclaw inside container"
        log_info "[DRY RUN] Would restart $CONTAINER"
        exit 0
    fi

    log_info "Copying $OPENCLAW_CONFIG_DIR to local container..."
    docker cp "$OPENCLAW_CONFIG_DIR/." "$CONTAINER:/home/node/.openclaw/"

    log_info "Fixing ownership..."
    docker exec "$CONTAINER" chown -R 1000:1000 /home/node/.openclaw

    log_info "Restarting gateway..."
    cd "$PROJECT_ROOT"
    set_compose_files
    docker compose "${COMPOSE_FILES[@]}" restart openclaw-gateway

    log_info "Config synced to local container."
    exit 0
fi

# ─── Sync to remote droplet ─────────────────────────────────────────────────
require_cmd rsync
require_cmd ssh

if [[ -z "$IP" ]]; then
    require_cmd doctl "doctl is required to auto-detect droplet IP. Install it or use --ip."
    IP=$(get_droplet_ip)
fi

RSYNC_FLAGS=(-avz --progress)
if [[ "$DRY_RUN" == "true" ]]; then
    RSYNC_FLAGS+=(--dry-run)
fi

log_info "Syncing $OPENCLAW_CONFIG_DIR to ${DO_SSH_USER}@${IP}:${REMOTE_OPENCLAW_HOME}/.openclaw/..."
rsync "${RSYNC_FLAGS[@]}" -e "ssh" \
    "$OPENCLAW_CONFIG_DIR/" "${DO_SSH_USER}@${IP}:${REMOTE_OPENCLAW_HOME}/.openclaw/"

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would chown, update poseidon.env, and restart services on remote."
    exit 0
fi

log_info "Fixing ownership and restarting services on remote..."
# Read gateway token from local openclaw.json to update poseidon.env
LOCAL_TOKEN=$(read_json_token "$OPENCLAW_CONFIG_DIR/openclaw.json")

ssh "${DO_SSH_USER}@${IP}" bash <<REMOTESYNC
set -euo pipefail
chown -R openclaw:openclaw ${REMOTE_OPENCLAW_HOME}/.openclaw
systemctl restart openclaw

# Update Poseidon env with gateway token if poseidon.env exists
if [[ -f /opt/poseidon.env && -n "${LOCAL_TOKEN}" ]]; then
    sed -i "s|^GATEWAY_TOKEN=.*|GATEWAY_TOKEN=${LOCAL_TOKEN}|" /opt/poseidon.env
    systemctl restart poseidon
fi
REMOTESYNC

log_info "Config synced to remote droplet at $IP."
