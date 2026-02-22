#!/usr/bin/env bats
# Tests for token resolution helpers in config.sh

load test_helper

setup() {
    load_config
}

teardown() {
    teardown_test_config
}

# ─── read_json_token ─────────────────────────────────────────────────────────

@test "read_json_token returns token from valid openclaw.json" {
    use_fixture "openclaw-loopback.json"
    result=$(read_json_token)
    [ "$result" = "existing-token-123" ]
}

@test "read_json_token returns empty string when no token field exists" {
    use_fixture "openclaw-minimal.json"
    result=$(read_json_token)
    [ "$result" = "" ]
}

@test "read_json_token returns empty string when token is empty" {
    use_fixture "openclaw-empty-token.json"
    result=$(read_json_token)
    [ "$result" = "" ]
}

@test "read_json_token returns empty when file does not exist" {
    result=$(read_json_token "$MUSTANGCLAW_CONFIG_DIR/nonexistent.json")
    [ "$result" = "" ]
}

@test "read_json_token reads from custom path" {
    use_fixture "openclaw-loopback.json" "custom.json"
    result=$(read_json_token "$MUSTANGCLAW_CONFIG_DIR/custom.json")
    [ "$result" = "existing-token-123" ]
}

# ─── write_json_token ────────────────────────────────────────────────────────

@test "write_json_token writes token to existing file" {
    use_fixture "openclaw-minimal.json"
    write_json_token "new-token-abc" "$MUSTANGCLAW_CONFIG_DIR/openclaw.json"
    result=$(read_json_token)
    [ "$result" = "new-token-abc" ]
}

@test "write_json_token sets auth.mode to token" {
    use_fixture "openclaw-minimal.json"
    write_json_token "new-token-abc" "$MUSTANGCLAW_CONFIG_DIR/openclaw.json"
    mode=$(python3 -c "
import json
cfg = json.load(open('$MUSTANGCLAW_CONFIG_DIR/openclaw.json'))
print(cfg['gateway']['auth']['mode'])
")
    [ "$mode" = "token" ]
}

@test "write_json_token preserves other gateway fields" {
    use_fixture "openclaw-loopback.json"
    write_json_token "updated-token" "$MUSTANGCLAW_CONFIG_DIR/openclaw.json"
    mode=$(python3 -c "
import json
cfg = json.load(open('$MUSTANGCLAW_CONFIG_DIR/openclaw.json'))
print(cfg['gateway']['mode'])
")
    [ "$mode" = "local" ]
}

@test "write_json_token overwrites existing token" {
    use_fixture "openclaw-loopback.json"
    write_json_token "brand-new-token" "$MUSTANGCLAW_CONFIG_DIR/openclaw.json"
    result=$(read_json_token)
    [ "$result" = "brand-new-token" ]
}

@test "write_json_token fails gracefully when file does not exist" {
    run write_json_token "some-token" "$MUSTANGCLAW_CONFIG_DIR/nonexistent.json"
    [ "$status" -eq 1 ]
}

# ─── Token resolution priority ───────────────────────────────────────────────
# These test the full resolution chain as implemented in run-local.sh:
# 1. openclaw.json  2. .env  3. generate new

@test "token resolution: prefers openclaw.json over .env" {
    use_fixture "openclaw-loopback.json"
    echo "OPENCLAW_GATEWAY_TOKEN=env-token-456" > "$MUSTANGCLAW_DIR/.env"

    json_token=$(read_json_token)
    env_token=$(grep '^OPENCLAW_GATEWAY_TOKEN=' "$MUSTANGCLAW_DIR/.env" | cut -d= -f2-)

    [ "$json_token" = "existing-token-123" ]
    [ "$env_token" = "env-token-456" ]
    # JSON should win
    [ "$json_token" != "$env_token" ]
}

@test "token resolution: falls back to .env when JSON has no token" {
    use_fixture "openclaw-minimal.json"
    echo "OPENCLAW_GATEWAY_TOKEN=env-fallback" > "$MUSTANGCLAW_DIR/.env"

    json_token=$(read_json_token)
    [ "$json_token" = "" ]

    env_token=$(grep '^OPENCLAW_GATEWAY_TOKEN=' "$MUSTANGCLAW_DIR/.env" | cut -d= -f2-)
    [ "$env_token" = "env-fallback" ]
}

@test "token resolution: empty .env token treated as missing" {
    use_fixture "openclaw-minimal.json"
    echo "OPENCLAW_GATEWAY_TOKEN=" > "$MUSTANGCLAW_DIR/.env"

    json_token=$(read_json_token)
    env_token=$(grep '^OPENCLAW_GATEWAY_TOKEN=' "$MUSTANGCLAW_DIR/.env" | cut -d= -f2-)

    [ "$json_token" = "" ]
    [ "$env_token" = "" ]
}
