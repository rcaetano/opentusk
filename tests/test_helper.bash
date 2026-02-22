# test_helper.bash — shared setup for bats tests

# Point config to a temp directory so tests don't touch real config
setup_test_config() {
    TEST_TMPDIR="$(mktemp -d)"
    export MUSTANGCLAW_CONFIG_DIR="$TEST_TMPDIR/config"
    export MUSTANGCLAW_WORKSPACE_DIR="$TEST_TMPDIR/workspace"
    export MUSTANGCLAW_DIR="$TEST_TMPDIR/openclaw"
    export HOME="$TEST_TMPDIR"
    mkdir -p "$MUSTANGCLAW_CONFIG_DIR"
    mkdir -p "$MUSTANGCLAW_WORKSPACE_DIR"
    mkdir -p "$MUSTANGCLAW_DIR"
}

teardown_test_config() {
    if [[ -n "${TEST_TMPDIR:-}" && -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

# Source config.sh with test overrides
load_config() {
    local project_root
    project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    # Source config but override paths before the user-override block runs
    setup_test_config
    source "$project_root/scripts/config.sh"
    # Re-apply test paths (config.sh may have reset them from defaults)
    export MUSTANGCLAW_CONFIG_DIR="$TEST_TMPDIR/config"
    export MUSTANGCLAW_WORKSPACE_DIR="$TEST_TMPDIR/workspace"
    export MUSTANGCLAW_DIR="$TEST_TMPDIR/openclaw"
}

# Copy a fixture file to the test config dir
use_fixture() {
    local fixture="$1"
    local dest="${2:-openclaw.json}"
    local project_root
    project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    cp "$project_root/tests/fixtures/$fixture" "$MUSTANGCLAW_CONFIG_DIR/$dest"
}
