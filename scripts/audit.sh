#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ─── Help ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Sanity check of the OpenTusk setup: config, scripts, and remote droplet.

Options:
  --fix       Attempt to auto-fix common issues
  --help      Show this help message

Examples:
  $(basename "$0")          # audit setup and remote droplet
  $(basename "$0") --fix    # audit and fix issues
EOF
    exit 0
}

# ─── Parse flags ─────────────────────────────────────────────────────────────
AUTO_FIX=false
for arg in "$@"; do
    case "$arg" in
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
# 1. Configuration
# ═════════════════════════════════════════════════════════════════════════════
printf "\n${_CYAN}── 1. Configuration ──${_NC}\n"

if [[ -f "$PROJECT_ROOT/config.env" ]]; then
    pass "config.env exists"
    # Check key variables
    source "$PROJECT_ROOT/config.env" 2>/dev/null || true
    if [[ -n "${DIGITALOCEAN_ACCESS_TOKEN:-}" ]]; then
        pass "DIGITALOCEAN_ACCESS_TOKEN is set"
    else
        warn "DIGITALOCEAN_ACCESS_TOKEN not set in config.env"
    fi
    if [[ -n "${DO_DROPLET_NAME:-}" ]]; then
        pass "DO_DROPLET_NAME=${DO_DROPLET_NAME}"
    else
        warn "DO_DROPLET_NAME not set in config.env"
    fi
    if [[ -n "${POSEIDON_REPO:-}" ]]; then
        pass "POSEIDON_REPO=${POSEIDON_REPO}"
    else
        warn "POSEIDON_REPO not set in config.env — Poseidon deploy will be skipped"
    fi
else
    fail "config.env missing — run 'opentusk init'"
fi

# ═════════════════════════════════════════════════════════════════════════════
# 2. Scripts
# ═════════════════════════════════════════════════════════════════════════════
printf "\n${_CYAN}── 2. Scripts ──${_NC}\n"

REQUIRED_SCRIPTS=(
    config.sh init.sh
    deploy-do.sh destroy-do.sh upgrade.sh ssh-do.sh
)
scripts_ok=true
for script in "${REQUIRED_SCRIPTS[@]}"; do
    if [[ -f "$PROJECT_ROOT/scripts/$script" ]]; then
        if [[ -x "$PROJECT_ROOT/scripts/$script" || "$script" == "config.sh" ]]; then
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

if [[ -x "$PROJECT_ROOT/opentusk" ]]; then
    pass "opentusk CLI is executable"
else
    fail "opentusk CLI not executable"
    if [[ "$AUTO_FIX" == "true" ]]; then
        chmod +x "$PROJECT_ROOT/opentusk"
        fixed "Made opentusk executable"
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# 3. Remote Droplet
# ═════════════════════════════════════════════════════════════════════════════
printf "\n${_CYAN}── 3. Remote Droplet ──${_NC}\n"

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
        if ssh -o ConnectTimeout=5 -o BatchMode=yes "${DO_SSH_USER}@${DROPLET_IP}" true 2>/dev/null; then
            pass "SSH access OK (${DO_SSH_USER}@${DROPLET_IP})"

            # OpenClaw systemd service
            oc_status=$(ssh "${DO_SSH_USER}@${DROPLET_IP}" \
                'systemctl is-active openclaw 2>/dev/null' 2>/dev/null || true)
            if [[ "$oc_status" == "active" ]]; then
                pass "OpenClaw service: active"
            else
                fail "OpenClaw service: $oc_status"
                if [[ "$AUTO_FIX" == "true" ]]; then
                    ssh "${DO_SSH_USER}@${DROPLET_IP}" \
                        'systemctl restart openclaw && sleep 3 && systemctl is-active openclaw' 2>/dev/null \
                        && fixed "Restarted OpenClaw service" \
                        || fail "Could not restart OpenClaw service"
                fi
            fi

            # Poseidon systemd service
            pos_status=$(ssh "${DO_SSH_USER}@${DROPLET_IP}" \
                'systemctl is-active poseidon 2>/dev/null' 2>/dev/null || true)
            if [[ "$pos_status" == "active" ]]; then
                pass "Poseidon service: active"
            else
                fail "Poseidon service: $pos_status"
                if [[ "$AUTO_FIX" == "true" ]]; then
                    ssh "${DO_SSH_USER}@${DROPLET_IP}" \
                        'systemctl restart poseidon && sleep 2 && systemctl is-active poseidon' 2>/dev/null \
                        && fixed "Restarted Poseidon service" \
                        || fail "Could not restart Poseidon service"
                fi
            fi

            # Poseidon GATEWAY_URL protocol check
            remote_gw_url=$(ssh "${DO_SSH_USER}@${DROPLET_IP}" \
                'grep "^GATEWAY_URL=" /opt/poseidon.env 2>/dev/null | cut -d= -f2-' 2>/dev/null || true)
            if [[ "$remote_gw_url" == ws://* ]]; then
                pass "Poseidon GATEWAY_URL uses ws:// protocol"
            elif [[ -n "$remote_gw_url" ]]; then
                fail "Poseidon GATEWAY_URL=$remote_gw_url (should be ws://)"
                if [[ "$AUTO_FIX" == "true" ]]; then
                    ssh "${DO_SSH_USER}@${DROPLET_IP}" \
                        "sed -i 's|^GATEWAY_URL=http://|GATEWAY_URL=ws://|' /opt/poseidon.env && systemctl restart poseidon" 2>/dev/null \
                        && fixed "Fixed GATEWAY_URL protocol to ws:// and restarted Poseidon" \
                        || fail "Could not fix GATEWAY_URL"
                fi
            fi

            # Gateway HTTP check
            if ssh "${DO_SSH_USER}@${DROPLET_IP}" "curl -sf -o /dev/null http://localhost:${GATEWAY_PORT}" 2>/dev/null; then
                pass "Remote gateway responding on port ${GATEWAY_PORT}"
            else
                fail "Remote gateway not responding"
            fi

            # Poseidon HTTP check
            if ssh "${DO_SSH_USER}@${DROPLET_IP}" "curl -sf -o /dev/null http://localhost:${POSEIDON_PORT}" 2>/dev/null; then
                pass "Remote Poseidon responding on port ${POSEIDON_PORT}"
            else
                fail "Remote Poseidon not responding"
            fi

            # Poseidon deploy key
            if [[ -n "${POSEIDON_REPO:-}" ]]; then
                deploy_key_exists=$(ssh "${DO_SSH_USER}@${DROPLET_IP}" \
                    '[[ -f /root/.ssh/poseidon_deploy_key ]] && echo yes || echo no' 2>/dev/null || echo "no")
                if [[ "$deploy_key_exists" == "yes" ]]; then
                    pass "Deploy key exists on remote"
                else
                    fail "Deploy key missing (/root/.ssh/poseidon_deploy_key)"
                    if [[ "$AUTO_FIX" == "true" ]]; then
                        ssh "${DO_SSH_USER}@${DROPLET_IP}" \
                            'ssh-keygen -t ed25519 -f /root/.ssh/poseidon_deploy_key -N "" -C "opentusk-deploy" >/dev/null 2>&1' 2>/dev/null \
                            && fixed "Generated deploy key on remote" \
                            || fail "Could not generate deploy key"
                        log_warn "Deploy key created but must be added to GitHub as a deploy key."
                        log_warn "Public key: $(ssh "${DO_SSH_USER}@${DROPLET_IP}" 'cat /root/.ssh/poseidon_deploy_key.pub' 2>/dev/null)"
                    fi
                fi

                ssh_config_ok=$(ssh "${DO_SSH_USER}@${DROPLET_IP}" \
                    'grep -q "poseidon_deploy_key" /root/.ssh/config 2>/dev/null && echo yes || echo no' 2>/dev/null || echo "no")
                if [[ "$ssh_config_ok" == "yes" ]]; then
                    pass "SSH config references deploy key for github.com"
                else
                    fail "SSH config missing deploy key entry for github.com"
                    if [[ "$AUTO_FIX" == "true" ]]; then
                        ssh "${DO_SSH_USER}@${DROPLET_IP}" bash <<'FIXSSHCONF'
cat >> /root/.ssh/config <<'SSHCONF'

Host github.com
    IdentityFile /root/.ssh/poseidon_deploy_key
    StrictHostKeyChecking accept-new
SSHCONF
chmod 600 /root/.ssh/config
FIXSSHCONF
                        fixed "Added github.com deploy key entry to SSH config"
                    fi
                fi

                # Poseidon git repo
                pos_is_git=$(ssh "${DO_SSH_USER}@${DROPLET_IP}" \
                    "[[ -d ${REMOTE_POSEIDON_DIR}/.git ]] && echo yes || echo no" 2>/dev/null || echo "no")
                if [[ "$pos_is_git" == "yes" ]]; then
                    pass "Poseidon directory is a git repo"

                    # Check remote URL matches POSEIDON_REPO
                    pos_remote=$(ssh "${DO_SSH_USER}@${DROPLET_IP}" \
                        "git -C ${REMOTE_POSEIDON_DIR} remote get-url origin 2>/dev/null" 2>/dev/null || true)
                    if [[ "$pos_remote" == "$POSEIDON_REPO" ]]; then
                        pass "Poseidon git remote matches POSEIDON_REPO"
                    elif [[ -n "$pos_remote" ]]; then
                        fail "Poseidon git remote=$pos_remote (expected $POSEIDON_REPO)"
                        if [[ "$AUTO_FIX" == "true" ]]; then
                            ssh "${DO_SSH_USER}@${DROPLET_IP}" \
                                "git -C ${REMOTE_POSEIDON_DIR} remote set-url origin '${POSEIDON_REPO}'" 2>/dev/null \
                                && fixed "Updated Poseidon git remote to ${POSEIDON_REPO}" \
                                || fail "Could not update Poseidon git remote"
                        fi
                    fi
                else
                    fail "Poseidon directory is not a git repo (${REMOTE_POSEIDON_DIR}/.git missing)"
                fi
            fi

            # Tailscale
            if [[ "$TAILSCALE_ENABLED" == "true" ]]; then
                ts_installed=$(ssh "${DO_SSH_USER}@${DROPLET_IP}" 'command -v tailscale &>/dev/null && echo yes || echo no' 2>/dev/null || echo "no")
                if [[ "$ts_installed" != "yes" ]]; then
                    fail "Tailscale binary not installed on remote"
                    if [[ "$AUTO_FIX" == "true" ]]; then
                        ssh "${DO_SSH_USER}@${DROPLET_IP}" 'curl -fsSL https://tailscale.com/install.sh | sh' 2>/dev/null \
                            && fixed "Installed Tailscale on remote" \
                            || fail "Could not install Tailscale on remote"
                        log_warn "Tailscale installed but needs manual auth: ssh ${DO_SSH_USER}@${DROPLET_IP} 'tailscale up'"
                    fi
                fi

                ts_status=$( [[ "$ts_installed" == "yes" ]] && ssh "${DO_SSH_USER}@${DROPLET_IP}" 'tailscale status --self --json 2>/dev/null' 2>/dev/null || true)
                if [[ -n "$ts_status" ]]; then
                    ts_name=$(echo "$ts_status" | python3 -c "import json,sys; print(json.load(sys.stdin).get('Self',{}).get('DNSName','').split('.')[0])" 2>/dev/null || true)
                    ts_online=$(echo "$ts_status" | python3 -c "import json,sys; print(json.load(sys.stdin).get('Self',{}).get('Online',False))" 2>/dev/null || true)
                    if [[ "$ts_online" == "True" ]]; then
                        pass "Tailscale online (hostname: $ts_name)"
                    else
                        fail "Tailscale not online"
                    fi

                    # Serve config
                    serve_out=$(ssh "${DO_SSH_USER}@${DROPLET_IP}" 'tailscale serve status 2>&1' 2>/dev/null || true)
                    if echo "$serve_out" | grep -q "localhost:${POSEIDON_PORT}" 2>/dev/null; then
                        pass "Tailscale serve: Poseidon on HTTPS 443"
                    else
                        fail "Tailscale serve not configured for Poseidon"
                        if [[ "$AUTO_FIX" == "true" ]]; then
                            ssh "${DO_SSH_USER}@${DROPLET_IP}" \
                                "tailscale serve --bg --https=443 http://localhost:${POSEIDON_PORT}" 2>/dev/null \
                                && fixed "Re-applied Tailscale serve for Poseidon (HTTPS 443)" \
                                || fail "Could not re-apply Tailscale serve for Poseidon"
                        fi
                    fi
                    if echo "$serve_out" | grep -q "localhost:${GATEWAY_PORT}" 2>/dev/null; then
                        pass "Tailscale serve: Gateway on HTTPS 8443"
                    else
                        fail "Tailscale serve not configured for Gateway"
                        if [[ "$AUTO_FIX" == "true" ]]; then
                            ssh "${DO_SSH_USER}@${DROPLET_IP}" \
                                "tailscale serve --bg --https=8443 http://localhost:${GATEWAY_PORT}" 2>/dev/null \
                                && fixed "Re-applied Tailscale serve for Gateway (HTTPS 8443)" \
                                || fail "Could not re-apply Tailscale serve for Gateway"
                        fi
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
                elif [[ "$ts_installed" == "yes" ]]; then
                    fail "Cannot read Tailscale status"
                fi
            else
                skip "Tailscale checks (TAILSCALE_ENABLED=false)"
            fi
        else
            fail "Cannot SSH to ${DO_SSH_USER}@${DROPLET_IP}"
            skip "Remote service and connectivity checks"
        fi
    fi
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
