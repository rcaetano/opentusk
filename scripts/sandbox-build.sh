#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ─── Help ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Build sandbox Docker images for agent tool execution isolation.

Sandbox images run alongside the gateway and provide isolated environments
for agents to execute code safely — with network isolation, resource limits,
read-only root filesystems, and a non-root user.

Options:
  --browser   Also build the browser sandbox image (Chromium/Playwright)
  --common    Also build the common sandbox image (extended tooling)
  --all       Build all sandbox images (base + common + browser)
  --help      Show this help message

Images built:
  openclaw-sandbox:bookworm-slim           Base sandbox (bash, git, python3, jq, ripgrep)
  openclaw-sandbox-common:bookworm-slim    Extended tooling (Node, pnpm, Bun, dev tools)
  openclaw-sandbox-browser:bookworm-slim   Browser automation (Chromium, Playwright)

After building, configure sandboxing in ~/.mustangclaw/openclaw.json:

  {
    "agents": {
      "defaults": {
        "sandbox": {
          "mode": "non-main",
          "scope": "agent",
          "docker": {
            "image": "openclaw-sandbox:bookworm-slim",
            "readOnlyRoot": true,
            "network": "none",
            "user": "1000:1000",
            "memory": "1g",
            "cpus": 1
          }
        }
      }
    }
  }

EOF
    exit 0
}

# ─── Parse flags ─────────────────────────────────────────────────────────────
BUILD_BROWSER=false
BUILD_COMMON=false
for arg in "$@"; do
    case "$arg" in
        --browser) BUILD_BROWSER=true ;;
        --common)  BUILD_COMMON=true ;;
        --all)     BUILD_BROWSER=true; BUILD_COMMON=true ;;
        --help|-h) usage ;;
        *) log_error "Unknown option: $arg"; usage ;;
    esac
done

# ─── Prerequisites ───────────────────────────────────────────────────────────
require_cmd docker

cd "$PROJECT_ROOT"

if [[ ! -d "$MUSTANGCLAW_DIR" ]]; then
    log_error "MustangClaw repo not found at $MUSTANGCLAW_DIR. Run 'mustangclaw build' first."
    exit 1
fi

# ─── Build base sandbox ─────────────────────────────────────────────────────
BASE_IMAGE="openclaw-sandbox:bookworm-slim"
log_info "Building base sandbox image: $BASE_IMAGE ..."

if [[ -f "$MUSTANGCLAW_DIR/Dockerfile.sandbox" ]]; then
    docker build -t "$BASE_IMAGE" -f "$MUSTANGCLAW_DIR/Dockerfile.sandbox" "$MUSTANGCLAW_DIR"
    log_info "Built $BASE_IMAGE"
else
    log_error "Dockerfile.sandbox not found in $MUSTANGCLAW_DIR"
    log_error "Make sure the upstream repo is up to date: mustangclaw build"
    exit 1
fi

# ─── Build common sandbox (extended tooling) ────────────────────────────────
if [[ "$BUILD_COMMON" == "true" ]]; then
    COMMON_IMAGE="openclaw-sandbox-common:bookworm-slim"
    if [[ -f "$MUSTANGCLAW_DIR/Dockerfile.sandbox-common" ]]; then
        log_info "Building common sandbox image: $COMMON_IMAGE ..."
        docker build -t "$COMMON_IMAGE" -f "$MUSTANGCLAW_DIR/Dockerfile.sandbox-common" "$MUSTANGCLAW_DIR"
        log_info "Built $COMMON_IMAGE"
    elif [[ -f "$MUSTANGCLAW_DIR/scripts/sandbox-common-setup.sh" ]]; then
        log_info "Building common sandbox via upstream script..."
        bash "$MUSTANGCLAW_DIR/scripts/sandbox-common-setup.sh"
    else
        log_warn "Dockerfile.sandbox-common not found — skipping common sandbox."
    fi
fi

# ─── Build browser sandbox ──────────────────────────────────────────────────
if [[ "$BUILD_BROWSER" == "true" ]]; then
    BROWSER_IMAGE="openclaw-sandbox-browser:bookworm-slim"
    if [[ -f "$MUSTANGCLAW_DIR/Dockerfile.sandbox-browser" ]]; then
        log_info "Building browser sandbox image: $BROWSER_IMAGE ..."
        docker build -t "$BROWSER_IMAGE" -f "$MUSTANGCLAW_DIR/Dockerfile.sandbox-browser" "$MUSTANGCLAW_DIR"
        log_info "Built $BROWSER_IMAGE"
    elif [[ -f "$MUSTANGCLAW_DIR/scripts/sandbox-browser-setup.sh" ]]; then
        log_info "Building browser sandbox via upstream script..."
        bash "$MUSTANGCLAW_DIR/scripts/sandbox-browser-setup.sh"
    else
        log_warn "Dockerfile.sandbox-browser not found — skipping browser sandbox."
    fi
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
log_info "Sandbox images built. To enable sandboxing, add to ~/.mustangclaw/openclaw.json:"
echo ""
echo '  "agents": {'
echo '    "defaults": {'
echo '      "sandbox": {'
echo '        "mode": "non-main",'
echo '        "scope": "agent",'
echo '        "docker": {'
echo "          \"image\": \"$BASE_IMAGE\","
echo '          "readOnlyRoot": true,'
echo '          "network": "none",'
echo '          "user": "1000:1000",'
echo '          "memory": "1g",'
echo '          "cpus": 1'
echo '        }'
echo '      }'
echo '    }'
echo '  }'
echo ""
