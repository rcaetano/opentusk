#!/usr/bin/env bats
# Tests for patch_json_for_docker in config.sh
# Verifies both the Python (host-side) and Node.js (container-side) implementations
# produce consistent results.

load test_helper

setup() {
    load_config
}

teardown() {
    teardown_test_config
}

# ─── Python implementation (patch_json_for_docker from config.sh) ─────────────

@test "patch_json_for_docker: sets bind=lan when bind=loopback" {
    use_fixture "openclaw-loopback.json"
    patch_json_for_docker "$MUSTANGCLAW_CONFIG_DIR/openclaw.json"
    bind=$(python3 -c "
import json
cfg = json.load(open('$MUSTANGCLAW_CONFIG_DIR/openclaw.json'))
print(cfg['gateway']['bind'])
")
    [ "$bind" = "lan" ]
}

@test "patch_json_for_docker: removes tailscale config" {
    use_fixture "openclaw-loopback.json"
    patch_json_for_docker "$MUSTANGCLAW_CONFIG_DIR/openclaw.json"
    has_tailscale=$(python3 -c "
import json
cfg = json.load(open('$MUSTANGCLAW_CONFIG_DIR/openclaw.json'))
print('tailscale' in cfg.get('gateway', {}))
")
    [ "$has_tailscale" = "False" ]
}

@test "patch_json_for_docker: returns 0 (success) when changes made" {
    use_fixture "openclaw-loopback.json"
    run patch_json_for_docker "$MUSTANGCLAW_CONFIG_DIR/openclaw.json"
    [ "$status" -eq 0 ]
}

@test "patch_json_for_docker: returns 1 when already correct" {
    use_fixture "openclaw-already-patched.json"
    run patch_json_for_docker "$MUSTANGCLAW_CONFIG_DIR/openclaw.json"
    [ "$status" -eq 1 ]
}

@test "patch_json_for_docker: preserves auth config" {
    use_fixture "openclaw-loopback.json"
    patch_json_for_docker "$MUSTANGCLAW_CONFIG_DIR/openclaw.json"
    token=$(python3 -c "
import json
cfg = json.load(open('$MUSTANGCLAW_CONFIG_DIR/openclaw.json'))
print(cfg['gateway']['auth']['token'])
")
    [ "$token" = "existing-token-123" ]
}

@test "patch_json_for_docker: handles minimal config (no bind, no tailscale)" {
    use_fixture "openclaw-minimal.json"
    # Should set bind=lan since it's not already lan
    run patch_json_for_docker "$MUSTANGCLAW_CONFIG_DIR/openclaw.json"
    [ "$status" -eq 0 ]
    bind=$(python3 -c "
import json
cfg = json.load(open('$MUSTANGCLAW_CONFIG_DIR/openclaw.json'))
print(cfg['gateway']['bind'])
")
    [ "$bind" = "lan" ]
}

@test "patch_json_for_docker: returns 1 for nonexistent file" {
    run patch_json_for_docker "$MUSTANGCLAW_CONFIG_DIR/nonexistent.json"
    [ "$status" -eq 1 ]
}

# ─── Node.js implementation (docker-entrypoint.sh) ────────────────────────────
# We test the Node.js patching logic in isolation to verify it matches Python.

node_patch() {
    local config="$1"
    node -e "
const fs = require('fs');
const cfg = JSON.parse(fs.readFileSync('$config', 'utf8'));
const gw = cfg.gateway || {};
gw.bind = 'lan';
delete gw.tailscale;
cfg.gateway = gw;
fs.writeFileSync('$config', JSON.stringify(cfg, null, 2) + '\n');
" 2>/dev/null
}

@test "node patching: produces same bind=lan result as python" {
    # Python version
    use_fixture "openclaw-loopback.json" "python-result.json"
    patch_json_for_docker "$MUSTANGCLAW_CONFIG_DIR/python-result.json"

    # Node version
    use_fixture "openclaw-loopback.json" "node-result.json"
    node_patch "$MUSTANGCLAW_CONFIG_DIR/node-result.json"

    py_bind=$(python3 -c "import json; print(json.load(open('$MUSTANGCLAW_CONFIG_DIR/python-result.json'))['gateway']['bind'])")
    node_bind=$(python3 -c "import json; print(json.load(open('$MUSTANGCLAW_CONFIG_DIR/node-result.json'))['gateway']['bind'])")
    [ "$py_bind" = "$node_bind" ]
}

@test "node patching: removes tailscale just like python" {
    # Python version
    use_fixture "openclaw-loopback.json" "python-result.json"
    patch_json_for_docker "$MUSTANGCLAW_CONFIG_DIR/python-result.json"

    # Node version
    use_fixture "openclaw-loopback.json" "node-result.json"
    node_patch "$MUSTANGCLAW_CONFIG_DIR/node-result.json"

    py_has=$(python3 -c "import json; print('tailscale' in json.load(open('$MUSTANGCLAW_CONFIG_DIR/python-result.json')).get('gateway',{}))")
    node_has=$(python3 -c "import json; print('tailscale' in json.load(open('$MUSTANGCLAW_CONFIG_DIR/node-result.json')).get('gateway',{}))")
    [ "$py_has" = "False" ]
    [ "$node_has" = "False" ]
}

@test "node patching: preserves token just like python" {
    # Python version
    use_fixture "openclaw-loopback.json" "python-result.json"
    patch_json_for_docker "$MUSTANGCLAW_CONFIG_DIR/python-result.json"

    # Node version
    use_fixture "openclaw-loopback.json" "node-result.json"
    node_patch "$MUSTANGCLAW_CONFIG_DIR/node-result.json"

    py_token=$(python3 -c "import json; print(json.load(open('$MUSTANGCLAW_CONFIG_DIR/python-result.json'))['gateway']['auth']['token'])")
    node_token=$(python3 -c "import json; print(json.load(open('$MUSTANGCLAW_CONFIG_DIR/node-result.json'))['gateway']['auth']['token'])")
    [ "$py_token" = "$node_token" ]
    [ "$py_token" = "existing-token-123" ]
}
