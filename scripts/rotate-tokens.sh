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
    operator.read
    operator.write
    operator.admin
    operator.approvals
    operator.pairing
)

# ─── Prerequisites ──────────────────────────────────────────────────────────
require_cmd docker

# ─── Detect gateway container ──────────────────────────────────────────────
GW_CONTAINER=$(require_running_gateway)

# ─── Helper: run openclaw CLI inside the gateway container ─────────────────
_cli() {
    docker exec "$GW_CONTAINER" node dist/index.js "$@"
}

# ─── List paired devices ───────────────────────────────────────────────────
log_info "Listing paired devices..."
devices_json=$(_cli devices list --json 2>&1) || {
    log_error "Failed to list devices. Is the gateway healthy?"
    echo "$devices_json"
    exit 1
}

# Parse device IDs and current scopes from JSON
device_info=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
except json.JSONDecodeError:
    sys.exit(0)
paired = data.get('paired', [])
for d in paired:
    did = d.get('deviceId', '')
    scopes = ', '.join(d.get('scopes', []))
    client = d.get('clientId', 'unknown')
    if did:
        print(f'{did}\t{client}\t{scopes}')
" <<< "$devices_json")

if [[ -z "$device_info" ]]; then
    log_warn "No paired devices found. Nothing to rotate."
    exit 0
fi

# ─── Display devices ───────────────────────────────────────────────────────
device_count=$(echo "$device_info" | wc -l | tr -d ' ')
log_info "Found $device_count paired device(s):"
echo ""

while IFS=$'\t' read -r dev_id dev_client dev_scopes; do
    printf "  ${_CYAN}%s${_NC}  (%s)\n" "$dev_id" "$dev_client"
    printf "    current scopes: %s\n" "${dev_scopes:-<none>}"
done <<< "$device_info"

echo ""
log_info "Target scopes: ${SCOPES[*]}"
echo ""

# ─── Dry-run mode ──────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would rotate tokens for $device_count device(s)."
    while IFS=$'\t' read -r dev_id dev_client dev_scopes; do
        echo "  node dist/index.js devices rotate --device $dev_id --role operator \\"
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

while IFS=$'\t' read -r dev_id dev_client dev_scopes; do
    scope_args=()
    for scope in "${SCOPES[@]}"; do
        scope_args+=(--scope "$scope")
    done

    printf "  Rotating %s (%s) ...\n" "$dev_id" "$dev_client"
    rotate_output=""
    if rotate_output=$(_cli devices rotate --device "$dev_id" --role operator "${scope_args[@]}" 2>&1); then
        printf "    ${_GREEN}OK${_NC}\n"
        if [[ -n "$rotate_output" ]]; then
            echo "$rotate_output" | while IFS= read -r line; do
                printf "    %s\n" "$line"
            done
        fi
        ((succeeded++))
    else
        printf "    ${_RED}FAILED${_NC}\n"
        if [[ -n "$rotate_output" ]]; then
            echo "$rotate_output" | while IFS= read -r line; do
                printf "    %s\n" "$line"
            done
        fi
        ((failed++))
    fi
done <<< "$device_info"

# ─── Summary ───────────────────────────────────────────────────────────────
echo ""
if [[ "$failed" -eq 0 ]]; then
    log_info "All $succeeded device(s) rotated successfully."
    log_info "Use the returned device token in your client instead of the GATEWAY_TOKEN."
else
    log_warn "$succeeded succeeded, $failed failed."
    log_warn "Re-run or manually rotate the failed devices."
    exit 1
fi
