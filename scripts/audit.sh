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
    if [[ -n "${DO_SSH_KEY_FILE:-}" ]]; then
        if [[ -f "$DO_SSH_KEY_FILE" ]]; then
            pass "DO_SSH_KEY_FILE exists ($DO_SSH_KEY_FILE)"
        else
            fail "DO_SSH_KEY_FILE not found: $DO_SSH_KEY_FILE"
        fi
    else
        skip "DO_SSH_KEY_FILE not configured (using ssh-agent default)"
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
        if remote_exec "$DROPLET_IP" true 2>/dev/null; then
            pass "SSH access OK (${DO_SSH_USER}@${DROPLET_IP})"

            # Gather all remote state in a single SSH session
            REMOTE_STATE=$(remote_exec "$DROPLET_IP" bash -s \
                "$REMOTE_OPENCLAW_HOME" "$REMOTE_POSEIDON_DIR" \
                "${POSEIDON_REPO:-}" "$POSEIDON_PORT" "$GATEWAY_PORT" <<'AUDIT_GATHER'
OC_HOME="$1"; POS_DIR="$2"; POS_REPO="$3"; POS_PORT="$4"; GW_PORT="$5"

# Services
echo "OC_STATUS=$(systemctl is-active openclaw 2>/dev/null || echo unknown)"
echo "POS_STATUS=$(systemctl is-active poseidon 2>/dev/null || echo unknown)"

# Poseidon GATEWAY_URL
gw_url=$(grep "^GATEWAY_URL=" /opt/poseidon.env 2>/dev/null | cut -d= -f2- || true)
echo "GW_URL=$gw_url"

# Gateway HTTP
if curl -sf -o /dev/null "http://localhost:${GW_PORT}" 2>/dev/null; then
    echo "GW_HTTP=ok"
else
    echo "GW_HTTP=fail"
fi

# Poseidon HTTP
if curl -sf -o /dev/null "http://localhost:${POS_PORT}" 2>/dev/null; then
    echo "POS_HTTP=ok"
else
    echo "POS_HTTP=fail"
fi

# Deploy key
if [[ -f /root/.ssh/do_proxy_ed25519 ]]; then
    echo "DEPLOY_KEY=yes"
else
    echo "DEPLOY_KEY=no"
fi

# SSH config
if grep -q "do_proxy_ed25519" /root/.ssh/config 2>/dev/null; then
    echo "SSH_CONFIG=yes"
else
    echo "SSH_CONFIG=no"
fi

# Poseidon git repo
if [[ -d "$POS_DIR/.git" ]]; then
    echo "POS_GIT=yes"
    echo "POS_REMOTE=$(git -C "$POS_DIR" remote get-url origin 2>/dev/null || true)"
else
    echo "POS_GIT=no"
    echo "POS_REMOTE="
fi

# UFW
echo "UFW_STATUS=$(ufw status | head -1 2>/dev/null || echo unknown)"

# CORS_ORIGINS from poseidon.env
echo "CORS_ORIGINS=$(grep '^CORS_ORIGINS=' /opt/poseidon.env 2>/dev/null | cut -d= -f2- || true)"

# Gateway controlUi.allowedOrigins
gw_origins=$(python3 -c "import json; print(','.join(json.load(open('${OC_HOME}/.openclaw/openclaw.json')).get('gateway',{}).get('controlUi',{}).get('allowedOrigins',[])))" 2>/dev/null || true)
echo "GW_ALLOWED_ORIGINS=$gw_origins"

# Tailscale
if command -v tailscale &>/dev/null; then
    echo "TS_INSTALLED=yes"
    ts_json=$(tailscale status --self --json 2>/dev/null || true)
    if [[ -n "$ts_json" ]]; then
        ts_name=$(echo "$ts_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('Self',{}).get('DNSName','').split('.')[0])" 2>/dev/null || true)
        ts_online=$(echo "$ts_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('Self',{}).get('Online',False))" 2>/dev/null || true)
        ts_fqdn=$(echo "$ts_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('Self',{}).get('DNSName','').rstrip('.'))" 2>/dev/null || true)
        echo "TS_NAME=$ts_name"
        echo "TS_ONLINE=$ts_online"
        echo "TS_FQDN=$ts_fqdn"
    else
        echo "TS_NAME="
        echo "TS_ONLINE=False"
        echo "TS_FQDN="
    fi
    serve_out=$(tailscale serve status 2>&1 || true)
    echo "$serve_out" | grep -q "localhost:${POS_PORT}" && echo "TS_SERVE_POS=yes" || echo "TS_SERVE_POS=no"
    echo "$serve_out" | grep -q "localhost:${GW_PORT}" && echo "TS_SERVE_GW=yes" || echo "TS_SERVE_GW=no"
else
    echo "TS_INSTALLED=no"
    echo "TS_NAME="
    echo "TS_ONLINE=False"
    echo "TS_FQDN="
    echo "TS_SERVE_POS=no"
    echo "TS_SERVE_GW=no"
fi
AUDIT_GATHER
            )

            # Parse remote state into local variables
            get_val() { echo "$REMOTE_STATE" | grep "^${1}=" | head -1 | cut -d= -f2-; }

            # ── OpenClaw service ──
            oc_status=$(get_val OC_STATUS)
            if [[ "$oc_status" == "active" ]]; then
                pass "OpenClaw service: active"
            else
                fail "OpenClaw service: $oc_status"
                if [[ "$AUTO_FIX" == "true" ]]; then
                    remote_exec "$DROPLET_IP" 'systemctl restart openclaw && sleep 3 && systemctl is-active openclaw' 2>/dev/null \
                        && fixed "Restarted OpenClaw service" \
                        || fail "Could not restart OpenClaw service"
                fi
            fi

            # ── Poseidon service ──
            pos_status=$(get_val POS_STATUS)
            if [[ "$pos_status" == "active" ]]; then
                pass "Poseidon service: active"
            else
                fail "Poseidon service: $pos_status"
                if [[ "$AUTO_FIX" == "true" ]]; then
                    remote_exec "$DROPLET_IP" 'systemctl restart poseidon && sleep 2 && systemctl is-active poseidon' 2>/dev/null \
                        && fixed "Restarted Poseidon service" \
                        || fail "Could not restart Poseidon service"
                fi
            fi

            # ── Poseidon GATEWAY_URL ──
            remote_gw_url=$(get_val GW_URL)
            if [[ "$remote_gw_url" == ws://* ]]; then
                pass "Poseidon GATEWAY_URL uses ws:// protocol"
            elif [[ -n "$remote_gw_url" ]]; then
                fail "Poseidon GATEWAY_URL=$remote_gw_url (should be ws://)"
                if [[ "$AUTO_FIX" == "true" ]]; then
                    remote_exec "$DROPLET_IP" \
                        "sed -i 's|^GATEWAY_URL=http://|GATEWAY_URL=ws://|' /opt/poseidon.env && systemctl restart poseidon" 2>/dev/null \
                        && fixed "Fixed GATEWAY_URL protocol to ws:// and restarted Poseidon" \
                        || fail "Could not fix GATEWAY_URL"
                fi
            fi

            # ── Gateway HTTP ──
            if [[ "$(get_val GW_HTTP)" == "ok" ]]; then
                pass "Remote gateway responding on port ${GATEWAY_PORT}"
            else
                fail "Remote gateway not responding"
            fi

            # ── Poseidon HTTP ──
            if [[ "$(get_val POS_HTTP)" == "ok" ]]; then
                pass "Remote Poseidon responding on port ${POSEIDON_PORT}"
            else
                fail "Remote Poseidon not responding"
            fi

            # ── Deploy key ──
            if [[ -n "${POSEIDON_REPO:-}" ]]; then
                if [[ "$(get_val DEPLOY_KEY)" == "yes" ]]; then
                    pass "Deploy key exists on remote"
                else
                    fail "Deploy key missing (/root/.ssh/do_proxy_ed25519)"
                    if [[ "$AUTO_FIX" == "true" ]]; then
                        remote_exec "$DROPLET_IP" \
                            'ssh-keygen -t ed25519 -f /root/.ssh/do_proxy_ed25519 -N "" -C "opentusk-deploy" >/dev/null 2>&1' 2>/dev/null \
                            && fixed "Generated deploy key on remote" \
                            || fail "Could not generate deploy key"
                        log_warn "Deploy key created but must be added to GitHub as a deploy key."
                        log_warn "Public key: $(remote_exec "$DROPLET_IP" 'cat /root/.ssh/do_proxy_ed25519.pub' 2>/dev/null)"
                    fi
                fi

                if [[ "$(get_val SSH_CONFIG)" == "yes" ]]; then
                    pass "SSH config references deploy key for github.com"
                else
                    fail "SSH config missing deploy key entry for github.com"
                    if [[ "$AUTO_FIX" == "true" ]]; then
                        remote_exec "$DROPLET_IP" <<'FIXSSHCONF'
cat >> /root/.ssh/config <<'SSHCONF'

Host github.com
    IdentityFile /root/.ssh/do_proxy_ed25519
    StrictHostKeyChecking accept-new
SSHCONF
chmod 600 /root/.ssh/config
FIXSSHCONF
                        fixed "Added github.com deploy key entry to SSH config"
                    fi
                fi

                # Poseidon git repo
                if [[ "$(get_val POS_GIT)" == "yes" ]]; then
                    pass "Poseidon directory is a git repo"

                    pos_remote=$(get_val POS_REMOTE)
                    if [[ "$pos_remote" == "$POSEIDON_REPO" ]]; then
                        pass "Poseidon git remote matches POSEIDON_REPO"
                    elif [[ -n "$pos_remote" ]]; then
                        fail "Poseidon git remote=$pos_remote (expected $POSEIDON_REPO)"
                        if [[ "$AUTO_FIX" == "true" ]]; then
                            remote_exec "$DROPLET_IP" \
                                "git -C ${REMOTE_POSEIDON_DIR} remote set-url origin '${POSEIDON_REPO}'" 2>/dev/null \
                                && fixed "Updated Poseidon git remote to ${POSEIDON_REPO}" \
                                || fail "Could not update Poseidon git remote"
                        fi
                    fi
                else
                    fail "Poseidon directory is not a git repo (${REMOTE_POSEIDON_DIR}/.git missing)"
                fi
            fi

            # ── Tailscale ──
            if [[ "$TAILSCALE_ENABLED" == "true" ]]; then
                if [[ "$(get_val TS_INSTALLED)" != "yes" ]]; then
                    fail "Tailscale binary not installed on remote"
                    if [[ "$AUTO_FIX" == "true" ]]; then
                        remote_exec "$DROPLET_IP" 'curl -fsSL https://tailscale.com/install.sh | sh' 2>/dev/null \
                            && fixed "Installed Tailscale on remote" \
                            || fail "Could not install Tailscale on remote"
                        log_warn "Tailscale installed but needs manual auth: ssh ${DO_SSH_USER}@${DROPLET_IP} 'tailscale up'"
                    fi
                fi

                ts_online=$(get_val TS_ONLINE)
                ts_name=$(get_val TS_NAME)
                if [[ "$ts_online" == "True" ]]; then
                    pass "Tailscale online (hostname: $ts_name)"
                elif [[ "$(get_val TS_INSTALLED)" == "yes" ]]; then
                    fail "Tailscale not online"
                fi

                if [[ "$(get_val TS_SERVE_POS)" == "yes" ]]; then
                    pass "Tailscale serve: Poseidon on HTTPS 443"
                else
                    fail "Tailscale serve not configured for Poseidon"
                    if [[ "$AUTO_FIX" == "true" ]]; then
                        remote_exec "$DROPLET_IP" \
                            "tailscale serve --bg --https=443 http://localhost:${POSEIDON_PORT}" 2>/dev/null \
                            && fixed "Re-applied Tailscale serve for Poseidon (HTTPS 443)" \
                            || fail "Could not re-apply Tailscale serve for Poseidon"
                    fi
                fi
                if [[ "$(get_val TS_SERVE_GW)" == "yes" ]]; then
                    pass "Tailscale serve: Gateway on HTTPS 8443"
                else
                    fail "Tailscale serve not configured for Gateway"
                    if [[ "$AUTO_FIX" == "true" ]]; then
                        remote_exec "$DROPLET_IP" \
                            "tailscale serve --bg --https=8443 http://localhost:${GATEWAY_PORT}" 2>/dev/null \
                            && fixed "Re-applied Tailscale serve for Gateway (HTTPS 8443)" \
                            || fail "Could not re-apply Tailscale serve for Gateway"
                    fi
                fi

                # End-to-end HTTPS check (runs locally)
                ts_fqdn=$(get_val TS_FQDN)
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
                skip "Tailscale checks (TAILSCALE_ENABLED=false)"
            fi

            # ── UFW firewall ──
            ufw_status=$(get_val UFW_STATUS)
            if echo "$ufw_status" | grep -q "active"; then
                pass "UFW firewall: active"
            else
                fail "UFW firewall: ${ufw_status:-not active}"
                if [[ "$AUTO_FIX" == "true" ]]; then
                    remote_exec "$DROPLET_IP" \
                        'ufw default deny incoming && ufw default allow outgoing && ufw allow 22/tcp && ufw allow 41641/udp && ufw --force enable' 2>/dev/null \
                        && fixed "Enabled UFW firewall (SSH + Tailscale only)" \
                        || fail "Could not enable UFW firewall"
                fi
            fi

            # ── CORS_ORIGINS ──
            cors_val=$(get_val CORS_ORIGINS)
            ts_fqdn=$(get_val TS_FQDN)
            if [[ -z "$cors_val" ]]; then
                fail "CORS_ORIGINS not set in /opt/poseidon.env"
                if [[ "$AUTO_FIX" == "true" && -n "$ts_fqdn" ]]; then
                    remote_exec "$DROPLET_IP" \
                        "echo 'CORS_ORIGINS=https://${ts_fqdn},http://localhost:5173,http://127.0.0.1:5173' >> /opt/poseidon.env && systemctl restart poseidon" 2>/dev/null \
                        && fixed "Added CORS_ORIGINS with Tailscale FQDN" \
                        || fail "Could not add CORS_ORIGINS"
                fi
            elif [[ -n "$ts_fqdn" ]] && echo "$cors_val" | grep -q "$ts_fqdn"; then
                pass "CORS_ORIGINS includes Tailscale FQDN ($ts_fqdn)"
            elif [[ -n "$ts_fqdn" ]]; then
                warn "CORS_ORIGINS missing Tailscale FQDN ($ts_fqdn)"
                if [[ "$AUTO_FIX" == "true" ]]; then
                    remote_exec "$DROPLET_IP" \
                        "sed -i 's|^CORS_ORIGINS=.*|CORS_ORIGINS=https://${ts_fqdn},http://localhost:5173,http://127.0.0.1:5173|' /opt/poseidon.env && systemctl restart poseidon" 2>/dev/null \
                        && fixed "Updated CORS_ORIGINS with Tailscale FQDN" \
                        || fail "Could not update CORS_ORIGINS"
                fi
            else
                pass "CORS_ORIGINS is set (no Tailscale FQDN to verify against)"
            fi

            # ── Gateway allowedOrigins ──
            gw_origins=$(get_val GW_ALLOWED_ORIGINS)
            if [[ -n "$ts_fqdn" ]] && echo "$gw_origins" | grep -q "$ts_fqdn"; then
                pass "Gateway allowedOrigins includes Tailscale FQDN ($ts_fqdn)"
            elif [[ -n "$ts_fqdn" ]]; then
                warn "Gateway allowedOrigins missing Tailscale FQDN ($ts_fqdn)"
                if [[ "$AUTO_FIX" == "true" ]]; then
                    remote_exec "$DROPLET_IP" bash -s "$REMOTE_OPENCLAW_HOME" "$ts_fqdn" <<'FIXGWORIGINS'
set -euo pipefail
OC_CONFIG="$1/.openclaw/openclaw.json"
TS_FQDN="$2"
python3 -c "
import json
with open('$OC_CONFIG') as f:
    cfg = json.load(f)
origins = cfg.setdefault('gateway', {}).setdefault('controlUi', {}).setdefault('allowedOrigins', [])
for o in ['https://${TS_FQDN}', 'https://${TS_FQDN}:8443']:
    if o not in origins:
        origins.append(o)
with open('$OC_CONFIG', 'w') as f:
    json.dump(cfg, f, indent=2)
"
chown openclaw:openclaw "$OC_CONFIG"
systemctl restart openclaw
FIXGWORIGINS
                    fixed "Updated gateway allowedOrigins with Tailscale FQDN" \
                        || fail "Could not update gateway allowedOrigins"
                fi
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
