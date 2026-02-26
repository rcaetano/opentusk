#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ─── Help ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Full sanity check of the MustangClaw setup: config, scripts, Docker image,
container internals, repos, local connectivity, and remote droplet health.

Options:
  --fix       Attempt to auto-fix common issues (restart, patch config)
  --remote    Include remote droplet checks (requires SSH access)
  --help      Show this help message

Examples:
  $(basename "$0")              # audit local setup only
  $(basename "$0") --remote     # include remote droplet checks
  $(basename "$0") --fix        # audit and fix issues
EOF
    exit 0
}

# ─── Parse flags ─────────────────────────────────────────────────────────────
CHECK_REMOTE=false
AUTO_FIX=false
for arg in "$@"; do
    case "$arg" in
        --remote)  CHECK_REMOTE=true ;;
        --fix)     AUTO_FIX=true ;;
        --help|-h) usage ;;
        *) log_error "Unknown option: $arg"; usage ;;
    esac
done

# ─── Counters ────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
WARN=0
FIXED=0

pass() { printf "${_GREEN}  [PASS]${_NC} %s\n" "$*"; PASS=$((PASS + 1)); }
fail() { printf "${_RED}  [FAIL]${_NC} %s\n" "$*"; FAIL=$((FAIL + 1)); }
warn() { printf "${_YELLOW}  [WARN]${_NC} %s\n" "$*"; WARN=$((WARN + 1)); }
skip() { printf "${_CYAN}  [SKIP]${_NC} %s\n" "$*"; }
fixed() { printf "${_GREEN}  [FIXED]${_NC} %s\n" "$*"; FIXED=$((FIXED + 1)); }

cd "$PROJECT_ROOT"

# ═════════════════════════════════════════════════════════════════════════════
# 1. Configuration files
# ═════════════════════════════════════════════════════════════════════════════
printf "\n${_CYAN}── 1. Configuration ──${_NC}\n"

if [[ -d "$OPENCLAW_CONFIG_DIR" ]]; then
    pass "Config directory exists: $OPENCLAW_CONFIG_DIR"
else
    fail "Config directory missing: $OPENCLAW_CONFIG_DIR"
fi

if [[ -f "$OPENCLAW_CONFIG_DIR/config.env" ]]; then
    pass "config.env exists"
    # Check key variables
    source "$OPENCLAW_CONFIG_DIR/config.env" 2>/dev/null || true
    if [[ -n "${GATEWAY_PORT:-}" ]]; then
        pass "GATEWAY_PORT=${GATEWAY_PORT}"
    else
        warn "GATEWAY_PORT not set in config.env"
    fi
    if [[ -n "${POSEIDON_PORT:-}" ]]; then
        pass "POSEIDON_PORT=${POSEIDON_PORT}"
    else
        warn "POSEIDON_PORT not set in config.env"
    fi
else
    fail "config.env missing — run 'mustangclaw init'"
fi

OPENCLAW_JSON="$OPENCLAW_CONFIG_DIR/openclaw.json"
if [[ -f "$OPENCLAW_JSON" ]]; then
    pass "openclaw.json exists"
    # Validate JSON
    if python3 -c "import json; json.load(open('$OPENCLAW_JSON'))" 2>/dev/null; then
        pass "openclaw.json is valid JSON"
    else
        fail "openclaw.json is not valid JSON"
    fi
    # Check gateway token
    local_token=$(read_json_token "$OPENCLAW_JSON")
    if [[ -n "$local_token" ]]; then
        pass "Gateway token present in openclaw.json (${local_token:0:8}...)"
    else
        warn "No gateway token in openclaw.json"
    fi
    # Check bind=lan
    bind_val=$(python3 -c "import json; print(json.load(open('$OPENCLAW_JSON')).get('gateway',{}).get('bind',''))" 2>/dev/null || true)
    if [[ "$bind_val" == "lan" ]]; then
        pass "gateway.bind=lan (Docker-compatible)"
    else
        warn "gateway.bind=$bind_val (expected 'lan' for Docker)"
        if [[ "$AUTO_FIX" == "true" ]]; then
            patch_json_for_docker "$OPENCLAW_JSON" && fixed "Patched gateway.bind=lan" || true
        fi
    fi
else
    fail "openclaw.json missing — run 'mustangclaw run' or 'mustangclaw setup'"
fi

# Check .env token alignment
ENV_FILE="$OPENCLAW_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
    env_token=$(grep '^OPENCLAW_GATEWAY_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)
    if [[ -n "$local_token" && -n "$env_token" ]]; then
        if [[ "$local_token" == "$env_token" ]]; then
            pass "Token aligned between openclaw.json and .env"
        else
            fail "Token mismatch: openclaw.json vs .env"
            if [[ "$AUTO_FIX" == "true" ]]; then
                # Trust openclaw.json as source of truth
                tmpfile=$(mktemp)
                awk -v tok="$local_token" \
                    '/^OPENCLAW_GATEWAY_TOKEN=/{$0="OPENCLAW_GATEWAY_TOKEN="tok}{print}' \
                    "$ENV_FILE" > "$tmpfile" && mv "$tmpfile" "$ENV_FILE"
                fixed "Synced .env token from openclaw.json"
            fi
        fi
    fi
    # Check for POSEIDON_PORT duplication
    dup_count=$(grep -c '^POSEIDON_PORT=' "$ENV_FILE" 2>/dev/null || echo "0")
    if [[ "$dup_count" -gt 1 ]]; then
        fail "POSEIDON_PORT duplicated ${dup_count}x in .env"
        if [[ "$AUTO_FIX" == "true" ]]; then
            # Remove all POSEIDON_PORT lines, will be regenerated on next run
            tmpfile=$(mktemp)
            grep -v '^POSEIDON_PORT=' "$ENV_FILE" > "$tmpfile" || true
            echo "POSEIDON_PORT=$POSEIDON_PORT" >> "$tmpfile"
            mv "$tmpfile" "$ENV_FILE"
            fixed "Deduplicated POSEIDON_PORT in .env"
        fi
    elif [[ "$dup_count" -eq 1 ]]; then
        pass "POSEIDON_PORT appears once in .env"
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# 2. Scripts
# ═════════════════════════════════════════════════════════════════════════════
printf "\n${_CYAN}── 2. Scripts ──${_NC}\n"

REQUIRED_SCRIPTS=(
    config.sh build.sh run-local.sh docker-entrypoint.sh init.sh
    deploy-do.sh destroy-do.sh sync-config.sh upgrade.sh ssh-do.sh
    save.sh load.sh sandbox-build.sh rotate-tokens.sh
)
scripts_ok=true
for script in "${REQUIRED_SCRIPTS[@]}"; do
    if [[ -f "$PROJECT_ROOT/scripts/$script" ]]; then
        if [[ -x "$PROJECT_ROOT/scripts/$script" || "$script" == "config.sh" || "$script" == "cloud-init.yml" ]]; then
            true  # fine
        else
            warn "$script exists but not executable"
            if [[ "$AUTO_FIX" == "true" ]]; then
                chmod +x "$PROJECT_ROOT/scripts/$script"
                fixed "Made $script executable"
            fi
        fi
    else
        fail "Missing script: scripts/$script"
        scripts_ok=false
    fi
done
if [[ "$scripts_ok" == "true" ]]; then
    pass "All ${#REQUIRED_SCRIPTS[@]} required scripts present"
fi

if [[ -x "$PROJECT_ROOT/mustangclaw" ]]; then
    pass "mustangclaw CLI is executable"
else
    fail "mustangclaw CLI not executable"
    if [[ "$AUTO_FIX" == "true" ]]; then
        chmod +x "$PROJECT_ROOT/mustangclaw"
        fixed "Made mustangclaw executable"
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# 3. Repositories
# ═════════════════════════════════════════════════════════════════════════════
printf "\n${_CYAN}── 3. Repositories ──${_NC}\n"

if [[ -d "$OPENCLAW_DIR/.git" ]]; then
    pass "OpenClaw repo exists at $OPENCLAW_DIR"
    oc_branch=$(git -C "$OPENCLAW_DIR" branch --show-current 2>/dev/null || echo "detached")
    pass "OpenClaw branch: $oc_branch"
    if git -C "$OPENCLAW_DIR" fetch --dry-run 2>/dev/null; then
        behind=$(git -C "$OPENCLAW_DIR" rev-list --count HEAD..origin/main 2>/dev/null || echo "?")
        if [[ "$behind" == "0" ]]; then
            pass "OpenClaw up to date with upstream"
        elif [[ "$behind" != "?" ]]; then
            warn "OpenClaw is $behind commit(s) behind upstream"
        fi
    fi
else
    fail "OpenClaw repo missing — run 'mustangclaw build'"
fi

if [[ -d "$POSEIDON_DIR" ]]; then
    pass "Poseidon repo exists at $POSEIDON_DIR"
    if [[ -d "$POSEIDON_DIR/.git" ]]; then
        pos_branch=$(git -C "$POSEIDON_DIR" branch --show-current 2>/dev/null || echo "detached")
        pass "Poseidon branch: $pos_branch"
        if git -C "$POSEIDON_DIR" fetch --dry-run 2>/dev/null; then
            behind=$(git -C "$POSEIDON_DIR" rev-list --count HEAD..origin/main 2>/dev/null || echo "?")
            if [[ "$behind" == "0" ]]; then
                pass "Poseidon up to date with upstream"
            elif [[ "$behind" != "?" ]]; then
                warn "Poseidon is $behind commit(s) behind upstream"
            fi
        fi
    else
        warn "Poseidon directory is not a git repo (rsynced copy)"
    fi
else
    fail "Poseidon repo missing — run 'mustangclaw build'"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 4. Docker image
# ═════════════════════════════════════════════════════════════════════════════
printf "\n${_CYAN}── 4. Docker Image ──${_NC}\n"

if ! command -v docker &>/dev/null; then
    fail "Docker not installed"
else
    pass "Docker installed"
    image_info=$(docker images "$OPENCLAW_IMAGE" --format '{{.Size}} (created {{.CreatedSince}})' 2>/dev/null | head -1)
    if [[ -n "$image_info" ]]; then
        pass "Image $OPENCLAW_IMAGE exists: $image_info"
        # Check if Poseidon is bundled
        has_poseidon=$(docker run --rm --entrypoint sh "$OPENCLAW_IMAGE" -c 'test -d /poseidon && echo yes || echo no' 2>/dev/null || echo "error")
        if [[ "$has_poseidon" == "yes" ]]; then
            pass "Poseidon bundled in image (/poseidon exists)"
        else
            fail "Poseidon NOT bundled in image — rebuild with 'mustangclaw build'"
        fi
        has_bun=$(docker run --rm --entrypoint sh "$OPENCLAW_IMAGE" -c 'which bun >/dev/null 2>&1 && echo yes || echo no' 2>/dev/null || echo "error")
        if [[ "$has_bun" == "yes" ]]; then
            pass "bun binary present in image"
        else
            fail "bun missing from image — rebuild with 'mustangclaw build'"
        fi
    else
        fail "Image $OPENCLAW_IMAGE not found — run 'mustangclaw build'"
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# 5. Local container
# ═════════════════════════════════════════════════════════════════════════════
printf "\n${_CYAN}── 5. Local Container ──${_NC}\n"

gw_container=$(get_running_gateway)
if [[ -n "$gw_container" ]]; then
    pass "Gateway container running: $gw_container"

    # Check HOME and config path
    container_home=$(docker exec "$gw_container" sh -c 'echo $HOME' 2>/dev/null || true)
    if [[ "$container_home" == "/home/node" ]]; then
        pass "Container HOME=/home/node"
    else
        fail "Container HOME=$container_home (expected /home/node)"
    fi

    has_config=$(docker exec "$gw_container" sh -c 'test -f /home/node/.openclaw/openclaw.json && echo yes || echo no' 2>/dev/null || true)
    if [[ "$has_config" == "yes" ]]; then
        pass "openclaw.json mounted at /home/node/.openclaw/"
    else
        fail "openclaw.json NOT found at /home/node/.openclaw/"
    fi

    has_workspace=$(docker exec "$gw_container" sh -c 'test -d /home/node/.openclaw/workspace && echo yes || echo no' 2>/dev/null || true)
    if [[ "$has_workspace" == "yes" ]]; then
        pass "Workspace mounted at /home/node/.openclaw/workspace"
    else
        warn "Workspace directory missing inside container"
    fi

    # Check Poseidon process
    poseidon_proc=$(docker exec "$gw_container" sh -c 'pgrep -f "bun.*poseidon" >/dev/null 2>&1 && echo yes || echo no' 2>/dev/null || true)
    if [[ "$poseidon_proc" == "yes" ]]; then
        pass "Poseidon process running (bun)"
    else
        warn "Poseidon process not running inside container"
    fi

    # Check gateway process
    gw_proc=$(docker exec "$gw_container" sh -c 'pgrep -f "openclaw-gateway" >/dev/null 2>&1 && echo yes || echo no' 2>/dev/null || true)
    if [[ "$gw_proc" == "yes" ]]; then
        pass "Gateway process running"
    else
        fail "Gateway process not running inside container"
    fi

    # HTTP checks
    if curl -sf -o /dev/null --max-time 5 "http://localhost:${GATEWAY_PORT}" 2>/dev/null; then
        pass "Gateway responding on http://localhost:${GATEWAY_PORT}"
    else
        fail "Gateway not responding on port ${GATEWAY_PORT}"
    fi

    if curl -sf -o /dev/null --max-time 5 "http://localhost:${POSEIDON_PORT}" 2>/dev/null; then
        pass "Poseidon responding on http://localhost:${POSEIDON_PORT}"
    else
        fail "Poseidon not responding on port ${POSEIDON_PORT}"
    fi
else
    warn "Gateway container not running"
    skip "Container internal checks (container not running)"
    skip "HTTP connectivity checks (container not running)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 6. Remote droplet (optional)
# ═════════════════════════════════════════════════════════════════════════════
if [[ "$CHECK_REMOTE" == "true" ]]; then
    printf "\n${_CYAN}── 6. Remote Droplet ──${_NC}\n"

    if ! command -v doctl &>/dev/null; then
        warn "doctl not installed — skipping remote checks"
    elif [[ -z "${DIGITALOCEAN_ACCESS_TOKEN:-}" ]]; then
        warn "DIGITALOCEAN_ACCESS_TOKEN not set — skipping remote checks"
    else
        DROPLET_IP=$(get_droplet_ip 2>/dev/null || true)
        if [[ -z "$DROPLET_IP" ]]; then
            warn "No droplet found with tag '$DO_TAG'"
        else
            pass "Droplet '$DO_DROPLET_NAME' at $DROPLET_IP"

            # SSH connectivity
            if ssh -o ConnectTimeout=5 -o BatchMode=yes "mustangclaw@${DROPLET_IP}" true 2>/dev/null; then
                pass "SSH access OK (mustangclaw@${DROPLET_IP})"

                # Container running
                remote_status=$(ssh "mustangclaw@${DROPLET_IP}" \
                    'docker ps --filter "name=^mustangclaw$" --filter "status=running" --format "{{.Status}}"' 2>/dev/null || true)
                if [[ -n "$remote_status" ]]; then
                    pass "Remote container running: $remote_status"
                else
                    fail "Remote container not running"
                fi

                # Gateway check
                if ssh "mustangclaw@${DROPLET_IP}" "curl -sf -o /dev/null http://localhost:${GATEWAY_PORT}" 2>/dev/null; then
                    pass "Remote gateway responding on port ${GATEWAY_PORT}"
                else
                    fail "Remote gateway not responding"
                fi

                # Poseidon check
                if ssh "mustangclaw@${DROPLET_IP}" "curl -sf -o /dev/null http://localhost:${POSEIDON_PORT}" 2>/dev/null; then
                    pass "Remote Poseidon responding on port ${POSEIDON_PORT}"
                else
                    fail "Remote Poseidon not responding"
                fi

                # Poseidon in container
                remote_poseidon=$(ssh "mustangclaw@${DROPLET_IP}" \
                    'docker exec mustangclaw sh -c "test -d /poseidon && echo yes || echo no"' 2>/dev/null || true)
                if [[ "$remote_poseidon" == "yes" ]]; then
                    pass "Poseidon bundled in remote image"
                else
                    fail "Poseidon NOT bundled in remote image"
                fi

                # Tailscale
                if [[ "$TAILSCALE_ENABLED" == "true" ]]; then
                    ts_status=$(ssh root@${DROPLET_IP} 'tailscale status --self --json 2>/dev/null' 2>/dev/null || true)
                    if [[ -n "$ts_status" ]]; then
                        ts_name=$(echo "$ts_status" | python3 -c "import json,sys; print(json.load(sys.stdin).get('Self',{}).get('DNSName','').split('.')[0])" 2>/dev/null || true)
                        ts_online=$(echo "$ts_status" | python3 -c "import json,sys; print(json.load(sys.stdin).get('Self',{}).get('Online',False))" 2>/dev/null || true)
                        if [[ "$ts_online" == "True" ]]; then
                            pass "Tailscale online (hostname: $ts_name)"
                        else
                            fail "Tailscale not online"
                        fi

                        # Serve config
                        serve_out=$(ssh root@${DROPLET_IP} 'tailscale serve status 2>&1' 2>/dev/null || true)
                        if echo "$serve_out" | grep -q "localhost:${POSEIDON_PORT}" 2>/dev/null; then
                            pass "Tailscale serve: Poseidon on HTTPS 443"
                        else
                            fail "Tailscale serve not configured for Poseidon"
                        fi
                        if echo "$serve_out" | grep -q "localhost:${GATEWAY_PORT}" 2>/dev/null; then
                            pass "Tailscale serve: Gateway on HTTPS 8443"
                        else
                            fail "Tailscale serve not configured for Gateway"
                        fi

                        # End-to-end HTTPS check
                        ts_fqdn=$(echo "$ts_status" | python3 -c "import json,sys; print(json.load(sys.stdin).get('Self',{}).get('DNSName','').rstrip('.'))" 2>/dev/null || true)
                        if [[ -n "$ts_fqdn" ]]; then
                            if curl -sf -o /dev/null --max-time 10 "https://${ts_fqdn}" 2>/dev/null; then
                                pass "Poseidon reachable via https://${ts_fqdn}"
                            else
                                warn "Cannot reach Poseidon via https://${ts_fqdn} (are you on the tailnet?)"
                            fi
                            if curl -sf -o /dev/null --max-time 10 "https://${ts_fqdn}:8443" 2>/dev/null; then
                                pass "Gateway reachable via https://${ts_fqdn}:8443"
                            else
                                warn "Cannot reach Gateway via https://${ts_fqdn}:8443 (are you on the tailnet?)"
                            fi
                        fi
                    else
                        fail "Cannot read Tailscale status (SSH as root may be needed)"
                    fi
                else
                    skip "Tailscale checks (TAILSCALE_ENABLED=false)"
                fi
            else
                fail "Cannot SSH to mustangclaw@${DROPLET_IP}"
                skip "Remote container and service checks"
            fi
        fi
    fi
else
    printf "\n${_CYAN}── 6. Remote Droplet ──${_NC}\n"
    skip "Remote checks (use --remote to include)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════════════════════
printf "\n${_CYAN}── Summary ──${_NC}\n"
printf "  ${_GREEN}PASS: $PASS${_NC}"
if [[ $WARN -gt 0 ]]; then printf "  ${_YELLOW}WARN: $WARN${_NC}"; fi
if [[ $FAIL -gt 0 ]]; then printf "  ${_RED}FAIL: $FAIL${_NC}"; fi
if [[ $FIXED -gt 0 ]]; then printf "  ${_GREEN}FIXED: $FIXED${_NC}"; fi
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo ""
    log_warn "There are $FAIL failing checks. Run with --fix to attempt auto-repair."
    exit 1
elif [[ $WARN -gt 0 ]]; then
    echo ""
    log_info "All critical checks passed ($WARN warnings)."
    exit 0
else
    echo ""
    log_info "All checks passed."
    exit 0
fi
