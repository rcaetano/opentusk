#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ─── Help ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Rotate tokens for all paired devices, adding the full scope set required
since OpenClaw 2026.2.19 (operator.write + operator.read).

Fixes the "1008: pairing required" infinite loop caused by missing scopes
on devices paired before the 2026.2.19 security hardening.

See: https://github.com/openclaw/openclaw/issues/23006

Options:
  --dry-run   Show what would be done without making changes
  --force     Skip confirmation prompt
  --help      Show this help message

Examples:
  $(basename "$0")              # rotate all device tokens (with confirmation)
  $(basename "$0") --dry-run    # preview which devices would be rotated
  $(basename "$0") --force      # rotate without prompting
EOF
    exit 0
}

# ─── Parse flags ─────────────────────────────────────────────────────────────
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run)  DRY_RUN=true ;;
        --force)    FORCE=true ;;
        --help|-h)  usage ;;
        *)          log_error "Unknown option: $arg"; usage ;;
    esac
done

# ─── Full scope set (includes scopes added in 2026.2.19) ────────────────────
SCOPES=(
    operator.admin
    operator.approvals
    operator.pairing
    operator.write
    operator.read
)

# ─── Prerequisites ──────────────────────────────────────────────────────────
require_cmd docker
require_cmd python3

cd "$PROJECT_ROOT"

if [[ ! -f "$MUSTANGCLAW_DIR/.env" ]]; then
    log_error "No .env found. Run 'mustangclaw run' first to start the gateway."
    exit 1
fi

source "$MUSTANGCLAW_DIR/.env"

# ─── Resolve gateway token (same logic as run_cli) ─────────────────────────
openclaw_json="$MUSTANGCLAW_CONFIG_DIR/openclaw.json"
if [[ -f "$openclaw_json" ]]; then
    json_token=$(grep -o '"token"[[:space:]]*:[[:space:]]*"[^"]*"' "$openclaw_json" \
        | tail -1 | sed 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/' 2>/dev/null || true)
    if [[ -n "${json_token:-}" ]]; then
        OPENCLAW_GATEWAY_TOKEN="$json_token"
    fi
fi

# ─── Detect gateway container ──────────────────────────────────────────────
gw_container=$(docker ps --filter "name=^mustangclaw$" --filter "status=running" \
    --format '{{.Names}}' | head -1)

network_flag=()
if [[ -n "$gw_container" ]]; then
    network_flag=(--network "container:$gw_container")
else
    log_error "Gateway container is not running. Start it with 'mustangclaw run'."
    exit 1
fi

# ─── Helper: run openclaw CLI non-interactively ─────────────────────────────
_cli() {
    docker run --rm \
        ${network_flag[@]+"${network_flag[@]}"} \
        -e HOME=/home/node \
        -e OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN}" \
        -v "${OPENCLAW_CONFIG_DIR}:/home/node/.openclaw" \
        -v "${OPENCLAW_WORKSPACE_DIR}:/home/node/.openclaw/workspace" \
        "$MUSTANGCLAW_IMAGE" \
        node dist/index.js "$@"
}

# ─── List paired devices ───────────────────────────────────────────────────
log_info "Listing paired devices..."
devices_json=$(_cli devices list --json 2>/dev/null) || {
    log_error "Failed to list devices. Is the gateway running and healthy?"
    exit 1
}

# Parse device IDs and names from JSON
device_info=$(python3 -c "
import json, sys
try:
    devices = json.loads(sys.stdin.read())
except json.JSONDecodeError:
    sys.exit(0)
# Handle both array and {devices: [...]} formats
if isinstance(devices, dict):
    devices = devices.get('devices', devices.get('data', []))
if not isinstance(devices, list):
    sys.exit(0)
for d in devices:
    did = d.get('id', d.get('deviceId', ''))
    name = d.get('name', d.get('label', 'unnamed'))
    scopes = ','.join(d.get('scopes', d.get('scope', [])))
    if did:
        print(f'{did}\t{name}\t{scopes}')
" <<< "$devices_json")

if [[ -z "$device_info" ]]; then
    log_warn "No paired devices found. Nothing to rotate."
    exit 0
fi

# ─── Display devices ───────────────────────────────────────────────────────
device_count=$(echo "$device_info" | wc -l | tr -d ' ')
log_info "Found $device_count paired device(s):"
echo ""

while IFS=$'\t' read -r dev_id dev_name dev_scopes; do
    printf "  ${_CYAN}%-40s${_NC}  %s\n" "$dev_id" "$dev_name"
    printf "    current scopes: %s\n" "${dev_scopes:-<none>}"
done <<< "$device_info"

echo ""
log_info "Target scopes: ${SCOPES[*]}"
echo ""

# ─── Dry-run mode ──────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would rotate tokens for $device_count device(s)."
    while IFS=$'\t' read -r dev_id dev_name dev_scopes; do
        echo "  openclaw devices rotate --device $dev_id --role operator \\"
        for scope in "${SCOPES[@]}"; do
            echo "    --scope $scope \\"
        done
        echo ""
    done <<< "$device_info"
    exit 0
fi

# ─── Confirm ────────────────────────────────────────────────────────────────
if ! confirm "Rotate tokens for $device_count device(s)?"; then
    log_info "Aborted."
    exit 0
fi

# ─── Rotate each device ────────────────────────────────────────────────────
echo ""
failed=0
succeeded=0

while IFS=$'\t' read -r dev_id dev_name dev_scopes; do
    scope_args=()
    for scope in "${SCOPES[@]}"; do
        scope_args+=(--scope "$scope")
    done

    printf "  Rotating %-40s ... " "$dev_id"
    if _cli devices rotate --device "$dev_id" --role operator "${scope_args[@]}" &>/dev/null; then
        printf "${_GREEN}OK${_NC}\n"
        ((succeeded++))
    else
        printf "${_RED}FAILED${_NC}\n"
        ((failed++))
    fi
done <<< "$device_info"

# ─── Summary ───────────────────────────────────────────────────────────────
echo ""
if [[ "$failed" -eq 0 ]]; then
    log_info "All $succeeded device(s) rotated successfully. No restart required."
else
    log_warn "$succeeded succeeded, $failed failed."
    log_warn "Re-run or manually rotate the failed devices."
    exit 1
fi
