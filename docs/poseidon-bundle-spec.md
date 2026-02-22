# Technical Spec: Bundle Poseidon UX into MustangClaw Container

**Status:** Draft
**Date:** 2026-02-22
**Author:** rcaetano

---

## 1. Overview

[Poseidon](https://github.com/rcaetano/poseidon) is a full-stack React + Bun/Hono dashboard for monitoring and interacting with OpenClaw agents. It currently runs as a standalone development setup (Vite dev server + Bun API server). This spec describes how to bundle Poseidon into the MustangClaw Docker container so it starts automatically alongside the gateway, accessible on a single dedicated port.

### Goals

- **Zero extra setup** — `mustangclaw build && mustangclaw run` bundles and starts Poseidon automatically
- **Single port** — Poseidon API serves both REST/WebSocket routes and the built Vite frontend on port 18791
- **Backward-compatible** — existing MustangClaw images without Poseidon continue to work; the entrypoint gracefully skips Poseidon when it's not present
- **No upstream changes to OpenClaw** — Poseidon is layered on top via a multi-stage Docker build

### Non-Goals

- Running Poseidon as a separate Docker service/container
- Replacing the existing OpenClaw Control dashboard (port 18789)
- Modifying the upstream OpenClaw Docker image or compose file

---

## 2. Architecture

```
Host                              Docker Container (mustangclaw)
                                  ┌─────────────────────────────────────────┐
                                  │  docker-entrypoint.sh                   │
                                  │    ├── gateway (node dist/index.js)     │
localhost:18789 ◄─── port 18789 ──┤    │    port 18789 internal             │
localhost:18790 ◄─── port 18790 ──┤    │                                    │
                                  │    └── poseidon (bun index.ts)          │
localhost:18791 ◄─── port 18791 ──┤         port 18791 internal             │
                                  │         connects to gateway via         │
                                  │         ws://127.0.0.1:18789            │
                                  └─────────────────────────────────────────┘
```

### How it works

1. **Build time** — A multi-stage `Dockerfile.poseidon` builds the Vite frontend and installs API dependencies, then overlays the result onto the existing `mustangclaw:local` image at `/poseidon`.
2. **Run time** — The existing `docker-entrypoint.sh` detects `/poseidon` and starts `bun /poseidon/apps/api/src/index.ts` in the background before launching the gateway.
3. **Networking** — Poseidon's API connects to the gateway at `ws://127.0.0.1:18789` (loopback within the container). The host accesses Poseidon on `localhost:18791` via Docker port mapping.
4. **Static serving** — When `POSEIDON_STATIC_DIR` is set, the Hono API serves the built Vite frontend files for non-API/non-WebSocket routes, with SPA fallback to `index.html`. In development (env var unset), Vite's dev server handles static files as usual.

### Port allocation

| Port  | Service            | Description                           |
|-------|--------------------|---------------------------------------|
| 18789 | OpenClaw Gateway   | Gateway API, WebSocket, Control UI    |
| 18790 | OpenClaw Bridge    | Bridge protocol                       |
| 18791 | Poseidon           | Poseidon API + frontend (new)         |

---

## 3. Poseidon Project Context

Poseidon is a pnpm monorepo with two packages:

| Package            | Runtime | Port (dev) | Description                              |
|--------------------|---------|------------|------------------------------------------|
| `@poseidon/web`    | Vite    | 5173       | React 19 + TailwindCSS frontend          |
| `@poseidon/api`    | Bun     | 3001       | Hono HTTP/WebSocket server, gateway bridge |

### Key environment variables (API)

| Variable           | Default                      | In-container value                     |
|--------------------|------------------------------|----------------------------------------|
| `PORT`             | `3001`                       | `18791`                                |
| `GATEWAY_URL`      | `ws://127.0.0.1:18789`       | `ws://127.0.0.1:18789` (same)          |
| `GATEWAY_TOKEN`    | (empty)                      | `$OPENCLAW_GATEWAY_TOKEN` from env     |
| `OPENCLAW_SOURCE`  | `local`                      | `local` (reads from container FS)      |
| `CORS_ORIGINS`     | `http://localhost:5173,...`   | `http://localhost:18791`               |
| `POSEIDON_STATIC_DIR` | (unset)                   | `/poseidon/apps/web/dist`              |

### Vite proxy configuration (dev only)

In development, the Vite dev server proxies `/api/*` and `/ws` to the API. In production (bundled), the API serves static files directly — no proxy needed.

---

## 4. Implementation Details

### 4.1 Static file serving in Poseidon API

**File:** `poseidon/apps/api/src/index.ts`
**Change:** Additive — env-var-gated, no effect on dev mode

When `POSEIDON_STATIC_DIR` is set:
1. Import `serveStatic` from `hono/bun`
2. Add a catch-all middleware *after* all API routes that serves static files from the directory
3. Add SPA fallback: if no static file matches, serve `index.html`

```typescript
import { serveStatic } from "hono/bun";

// After all API routes...
if (process.env.POSEIDON_STATIC_DIR) {
  const staticDir = process.env.POSEIDON_STATIC_DIR;

  app.use("/*", serveStatic({ root: staticDir }));

  // SPA fallback — serve index.html for unmatched routes
  app.get("/*", serveStatic({ root: staticDir, path: "index.html" }));
}
```

This is guarded by the env var so development mode (where Vite serves files on port 5173) is unaffected.

### 4.2 MustangClaw config variables

**File:** `scripts/config.sh`
**Change:** Add three variables after `BRIDGE_PORT`

```bash
# ─── Poseidon ──────────────────────────────────────────────────────────────
POSEIDON_REPO="https://github.com/rcaetano/poseidon.git"
POSEIDON_DIR="./poseidon"
POSEIDON_PORT=18791
```

These follow the same pattern as `MUSTANGCLAW_REPO`/`MUSTANGCLAW_DIR`. The port is overridable via `config.env` (sourced after defaults).

### 4.3 `.gitignore`

**Change:** Add `poseidon/` (same pattern as `openclaw/`)

### 4.4 `Dockerfile.poseidon`

**File (new):** `Dockerfile.poseidon`

Multi-stage build:

```dockerfile
# Stage 1: Build Poseidon
FROM oven/bun:1 AS builder

WORKDIR /build
COPY poseidon/ .

# Install pnpm (Poseidon uses pnpm workspaces)
RUN npm install -g pnpm

# Install dependencies
RUN pnpm install --frozen-lockfile

# Build the Vite frontend
RUN pnpm --filter @poseidon/web build

# Stage 2: Overlay onto MustangClaw image
FROM mustangclaw:local

USER root

# Copy the entire Poseidon app (API source + built frontend)
COPY --from=builder /build /poseidon

# Ensure bun is available on PATH for the node user
# (oven/bun image puts it in /usr/local/bin, but we need it in the final image)
COPY --from=builder /usr/local/bin/bun /usr/local/bin/bun
COPY --from=builder /usr/local/bin/bunx /usr/local/bin/bunx

# Expose Poseidon port
EXPOSE 18791

USER node
```

**Key decisions:**
- The `FROM mustangclaw:local` base means this Dockerfile must be built *after* the base OpenClaw image. `build.sh` enforces this ordering.
- The final image retains the `mustangclaw:local` tag so all downstream scripts (compose, run, tui, etc.) work unchanged.
- Bun binary is copied from the builder stage since it's not in the base OpenClaw image (which is Node-based).

### 4.5 Docker entrypoint

**File:** `scripts/docker-entrypoint.sh`
**Change:** Conditionally start Poseidon before `exec "$@"`

```sh
# ─── Start Poseidon if bundled ────────────────────────────────────────────
if [ -d "/poseidon" ] && command -v bun >/dev/null 2>&1; then
    export PORT="${POSEIDON_PORT:-18791}"
    export GATEWAY_URL="ws://127.0.0.1:${OPENCLAW_GATEWAY_PORT:-18789}"
    export GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"
    export OPENCLAW_SOURCE="local"
    export POSEIDON_STATIC_DIR="/poseidon/apps/web/dist"
    export CORS_ORIGINS="http://localhost:${PORT}"

    echo "[entrypoint] Starting Poseidon on port $PORT..."
    bun /poseidon/apps/api/src/index.ts &
fi
```

This is placed after the `openclaw.json` patch and before `exec "$@"`. When Poseidon is not bundled (base image without overlay), the `/poseidon` directory doesn't exist and the block is skipped.

### 4.6 Build script

**File:** `scripts/build.sh`
**Change:** After building the base OpenClaw image, clone Poseidon and build the overlay

After line 78 (`docker build ... "$MUSTANGCLAW_DIR"`):

```bash
# ─── Clone or update Poseidon ──────────────────────────────────────────────
if [[ ! -d "$POSEIDON_DIR" ]]; then
    log_info "Cloning Poseidon repository..."
    git clone "$POSEIDON_REPO" "$POSEIDON_DIR"
elif [[ "$NO_PULL" == "false" ]]; then
    log_info "Updating Poseidon repository..."
    git -C "$POSEIDON_DIR" pull
else
    log_info "Skipping Poseidon git pull (--no-pull)."
fi

# ─── Build Poseidon overlay image ──────────────────────────────────────────
log_info "Building Poseidon overlay onto $MUSTANGCLAW_IMAGE..."
docker build -f "$PROJECT_ROOT/Dockerfile.poseidon" -t "$MUSTANGCLAW_IMAGE" "$PROJECT_ROOT"
```

The overlay build uses the project root as context (needs both `poseidon/` and the Dockerfile). The final `docker build -t "$MUSTANGCLAW_IMAGE"` overwrites the same tag — downstream scripts see a single image.

### 4.7 Run script

**File:** `scripts/run-local.sh`
**Three changes:**

1. **`.env` generation (~line 174):** Add `POSEIDON_PORT`

```bash
POSEIDON_PORT=$POSEIDON_PORT
```

2. **`docker-compose.override.yml` generation (~line 218):** Add port mapping and env var

```yaml
    ports:
      - "${POSEIDON_PORT}:${POSEIDON_PORT}"
    environment:
      - POSEIDON_PORT=${POSEIDON_PORT}
```

3. **Connection info (~line 250):** Print Poseidon URL

```bash
log_info "  Poseidon: http://localhost:${POSEIDON_PORT}"
```

### 4.8 CLI subcommand

**File:** `mustangclaw`
**Change:** Add `cmd_poseidon()` function and dispatch entry

```bash
cmd_poseidon() {
    require_cmd docker

    local gw_container
    gw_container=$(docker ps --filter "name=^mustangclaw$" \
        --filter "status=running" --format '{{.Names}}' | head -1)
    if [[ -z "$gw_container" ]]; then
        log_error "Gateway container is not running. Start it with 'mustangclaw run'."
        exit 1
    fi

    local url="http://localhost:${POSEIDON_PORT}"
    log_info "Opening Poseidon: $url"

    if command -v open &>/dev/null; then
        open "$url"
    elif command -v xdg-open &>/dev/null; then
        xdg-open "$url"
    elif command -v wslview &>/dev/null; then
        wslview "$url"
    else
        log_warn "Could not detect a browser opener. Open this URL manually:"
        echo "$url"
    fi
}
```

Dispatch: `poseidon) cmd_poseidon ;;`

Usage update: `poseidon  Open Poseidon dashboard in the browser`

### 4.9 Init wizard

**File:** `scripts/init.sh`
**Change:** Add `POSEIDON_PORT` to the Ports section

```bash
ask _POSEIDON_PORT "Poseidon port" "$POSEIDON_PORT"
```

And write it to `config.env`:

```bash
POSEIDON_PORT=$_POSEIDON_PORT
```

### 4.10 Upgrade script

**File:** `scripts/upgrade.sh`
**Change:** After OpenClaw git pull + docker build, also update Poseidon

```bash
# ─── Update Poseidon ──────────────────────────────────────────────────
if [[ -d "$POSEIDON_DIR" ]]; then
    if [[ "$ROLLBACK" == "true" ]]; then
        git -C "$POSEIDON_DIR" checkout HEAD~1
    else
        log_info "Pulling latest Poseidon changes..."
        git -C "$POSEIDON_DIR" pull
    fi
    log_info "Rebuilding Poseidon overlay..."
    docker build -f "$PROJECT_ROOT/Dockerfile.poseidon" -t "$MUSTANGCLAW_IMAGE" "$PROJECT_ROOT"
fi
```

### 4.11 SSH tunnel

**File:** `scripts/ssh-do.sh`
**Change:** Add `POSEIDON_PORT` to tunnel forwarding

```bash
exec ssh -L "${GATEWAY_PORT}:localhost:${GATEWAY_PORT}" \
         -L "${BRIDGE_PORT}:localhost:${BRIDGE_PORT}" \
         -L "${POSEIDON_PORT}:localhost:${POSEIDON_PORT}" \
         "mustangclaw@${IP}"
```

Update the log message to mention the Poseidon port.

---

## 5. Files Changed

| File | Action | Lines Changed (est.) |
|------|--------|---------------------|
| `scripts/config.sh` | Modify | +4 |
| `.gitignore` | Modify | +1 |
| `Dockerfile.poseidon` | **Create** | ~25 |
| `scripts/docker-entrypoint.sh` | Modify | +12 |
| `scripts/build.sh` | Modify | +15 |
| `scripts/run-local.sh` | Modify | +8 |
| `mustangclaw` | Modify | +25 |
| `scripts/init.sh` | Modify | +4 |
| `scripts/upgrade.sh` | Modify | +10 |
| `scripts/ssh-do.sh` | Modify | +3 |
| `CLAUDE.md` | Modify | +15 |
| *Poseidon:* `apps/api/src/index.ts` | Modify | +8 |

**Total:** 11 existing files modified, 1 new file created, ~130 lines added.

---

## 6. Data Flow

### Build-time flow

```
mustangclaw build
  │
  ├── git clone/pull openclaw → ./openclaw/
  ├── docker build -t mustangclaw:local ./openclaw/    (base image)
  │
  ├── git clone/pull poseidon → ./poseidon/
  └── docker build -f Dockerfile.poseidon -t mustangclaw:local .
        │
        ├── Stage 1 (oven/bun:1):
        │     pnpm install → pnpm --filter @poseidon/web build
        │     Output: /build/apps/web/dist/  (static files)
        │
        └── Stage 2 (FROM mustangclaw:local):
              COPY /build → /poseidon
              COPY bun binary → /usr/local/bin/bun
              (overwrites mustangclaw:local tag)
```

### Run-time flow

```
docker-entrypoint.sh
  │
  ├── Patch openclaw.json (existing behavior)
  │
  ├── if /poseidon exists:
  │     export PORT=18791, GATEWAY_URL, GATEWAY_TOKEN, POSEIDON_STATIC_DIR
  │     bun /poseidon/apps/api/src/index.ts &   (background)
  │
  └── exec node dist/index.js   (gateway — foreground, PID 1)
```

### Request flow (browser → Poseidon)

```
Browser (localhost:18791)
  │
  ├── GET /api/agents → Hono route → bridge → ws://127.0.0.1:18789 (gateway)
  ├── WS  /ws         → Bun WebSocket → broadcasts creature/chat updates
  └── GET /anything   → serveStatic(POSEIDON_STATIC_DIR) → index.html (SPA)
```

---

## 7. Environment Variables Reference

### Passed to Poseidon inside the container

| Variable              | Value                             | Source                       |
|-----------------------|-----------------------------------|------------------------------|
| `PORT`                | `$POSEIDON_PORT` (default 18791)  | entrypoint                   |
| `GATEWAY_URL`         | `ws://127.0.0.1:18789`           | entrypoint                   |
| `GATEWAY_TOKEN`       | `$OPENCLAW_GATEWAY_TOKEN`         | docker-compose env           |
| `OPENCLAW_SOURCE`     | `local`                           | entrypoint                   |
| `POSEIDON_STATIC_DIR` | `/poseidon/apps/web/dist`         | entrypoint                   |
| `CORS_ORIGINS`        | `http://localhost:$PORT`          | entrypoint                   |

### MustangClaw config variables

| Variable         | Default                                     | Set in         |
|------------------|---------------------------------------------|----------------|
| `POSEIDON_REPO`  | `https://github.com/rcaetano/poseidon.git`  | `config.sh`    |
| `POSEIDON_DIR`   | `./poseidon`                                | `config.sh`    |
| `POSEIDON_PORT`  | `18791`                                     | `config.sh` / `config.env` |

---

## 8. Backward Compatibility

| Scenario | Behavior |
|----------|----------|
| Base image without Poseidon overlay | Entrypoint skips Poseidon (`/poseidon` doesn't exist) — no changes to existing behavior |
| Existing `config.env` without `POSEIDON_PORT` | Falls back to default `18791` from `config.sh` |
| Remote deployment (DigitalOcean) | SSH tunnel includes Poseidon port; `sync-config.sh` and `upgrade.sh` handle Poseidon automatically |
| `mustangclaw run --stop` | `docker compose down` stops the entire container including Poseidon — no special handling needed |

---

## 9. Verification Plan

| # | Test | Expected Result |
|---|------|-----------------|
| 1 | `./mustangclaw build` | Clones both repos, produces single Docker image with `/poseidon` directory |
| 2 | `./mustangclaw run` | Gateway on 18789, Poseidon on 18791 (visible in `docker logs mustangclaw`) |
| 3 | `curl http://localhost:18791` | Returns Poseidon frontend HTML |
| 4 | `curl http://localhost:18791/api/agents` | Returns JSON agent data from Poseidon API |
| 5 | `wscat -c ws://localhost:18791/ws` | WebSocket connects, receives `init` message with creatures/health |
| 6 | `./mustangclaw poseidon` | Opens browser to `http://localhost:18791` |
| 7 | `./mustangclaw status --health` | Shows both gateway and container status |
| 8 | `./mustangclaw logs` | Shows interleaved gateway + Poseidon output |
| 9 | Build base image only (skip overlay) | Entrypoint logs nothing about Poseidon, gateway works normally |
| 10 | `./mustangclaw upgrade` | Pulls both repos, rebuilds overlay image, restarts |

---

## 10. Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Poseidon crash takes down the container | Gateway stops if PID 1 exits | Poseidon runs as a background process, not PID 1. Gateway (`exec node`) is PID 1. A Poseidon crash leaves the gateway running. |
| Port 18791 conflict on host | Poseidon inaccessible | Port is configurable via `mustangclaw init` / `POSEIDON_PORT` in `config.env` |
| Bun binary incompatibility with base image OS | Poseidon fails to start | Both `oven/bun:1` and OpenClaw use Debian-based images — binary compatible |
| `pnpm install --frozen-lockfile` fails in CI | Build fails | Poseidon lockfile is committed; `--frozen-lockfile` ensures reproducible builds |
| Stale Poseidon process after gateway restart | Orphan bun process | `docker restart` restarts the whole container (new PID namespace). `docker compose down` kills all processes. |
| Large image size increase | Longer pulls/deploys | Bun binary ~90MB + node_modules + static assets. Acceptable tradeoff for single-container simplicity. |

---

## 11. Future Considerations

- **Health check endpoint** — Add Poseidon to `mustangclaw status --health` by hitting `http://localhost:18791/` inside the container
- **Process supervisor** — If reliability requirements increase, consider `supervisord` or `s6-overlay` instead of backgrounding with `&`
- **Poseidon-specific logs** — Could add `mustangclaw poseidon --logs` to filter Poseidon output from container logs
- **Separate build flag** — `mustangclaw build --no-poseidon` to skip the overlay for minimal images
