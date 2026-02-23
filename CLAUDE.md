# MustangClaw

Wrapper project for deploying [OpenClaw](https://github.com/openclaw/openclaw) locally via Docker or remotely on DigitalOcean.

## Quick Reference

```
./mustangclaw init      # configure ports & DigitalOcean (writes ~/.mustangclaw/config.env)
./mustangclaw build     # clone openclaw repo & build Docker image (mustangclaw:local)
./mustangclaw run       # start gateway container locally
./mustangclaw setup     # run OpenClaw's onboarding wizard (API keys, models, auth)
./mustangclaw dashboard # open OpenClaw Control in browser (auto-approves device pairing)
./mustangclaw poseidon  # open Poseidon dashboard in browser
./mustangclaw tui       # launch TUI client (gateway must be running)
./mustangclaw token     # print the gateway token (for scripts or manual use)
./mustangclaw restart   # restart the gateway container
./mustangclaw logs      # tail gateway container logs (--lines N)
./mustangclaw save      # export Docker image to mustangclaw-local.tar.gz
./mustangclaw load FILE # import Docker image from archive
./mustangclaw status    # show local container & remote droplet status
./mustangclaw status --health  # include application-level gateway health check
./mustangclaw run --stop  # stop the gateway
```

## Project Structure

```
mustangclaw              # CLI entry point — dispatches subcommands to scripts/
scripts/
  config.sh              # shared variables, colors, helpers (sourced by all scripts)
  init.sh                # interactive wizard for MustangClaw config
  build.sh               # git clone + docker build (supports --browser, --apt)
  run-local.sh           # docker compose up (seeds openclaw.json, patches for Docker)
  docker-entrypoint.sh   # container entrypoint — patches openclaw.json on every start
  sandbox-build.sh       # build sandbox images for agent tool isolation
  save.sh                # export Docker image to tar.gz archive
  load.sh                # import Docker image from tar/tar.gz archive
  rotate-tokens.sh       # rotate device tokens with full scope set
  deploy-do.sh           # provision DigitalOcean droplet
  destroy-do.sh          # tear down droplet
  sync-config.sh         # rsync ~/.mustangclaw to local container or remote
  upgrade.sh             # git pull + rebuild (local or remote)
  ssh-do.sh              # SSH into droplet with optional port forwarding
  cloud-init.yml         # cloud-init user data for droplet bootstrap
Dockerfile.poseidon      # multi-stage build: Poseidon overlay onto mustangclaw:local
openclaw/                # upstream openclaw repo (git-ignored, created by build)
poseidon/                # upstream poseidon repo (git-ignored, created by build)
```

## Configuration

There are two layers of config:

### 1. MustangClaw config (`~/.mustangclaw/config.env`)
Written by `mustangclaw init`. Controls ports, DigitalOcean settings. Sourced by `scripts/config.sh` to override defaults.

### 2. OpenClaw config (`~/.mustangclaw/openclaw.json`)
Written by `mustangclaw setup` (OpenClaw's onboarding wizard). Controls API keys, models, gateway auth. Mounted into the Docker container at `/home/node/.openclaw/`.

Key variables from `scripts/config.sh`:
- `MUSTANGCLAW_REPO` — upstream git URL
- `MUSTANGCLAW_DIR` — local clone path (`./openclaw`)
- `MUSTANGCLAW_IMAGE` — Docker image name (`mustangclaw:local`)
- `MUSTANGCLAW_CONFIG_DIR` — user config dir (`~/.mustangclaw`)
- `GATEWAY_PORT` / `BRIDGE_PORT` / `POSEIDON_PORT` — Docker port mappings (18789 / 18790 / 18791)
- `POSEIDON_REPO` — Poseidon git URL
- `POSEIDON_DIR` — local Poseidon clone path (`./poseidon`)

## Poseidon Dev Mode

When developing the Poseidon frontend locally against a Docker-hosted API:

```bash
cd poseidon && pnpm dev:web    # start Vite dev server on port 5173
```

The Vite dev server proxies `/api` and `/ws` requests to the Poseidon API inside Docker (port 18791 by default). Override with `VITE_API_TARGET`:

```bash
VITE_API_TARGET=http://localhost:3001 pnpm dev:web   # target a local API instead
```

The Docker entrypoint (`scripts/docker-entrypoint.sh`) includes `http://localhost:5173` in `CORS_ORIGINS` so the Vite dev server origin is accepted.

## Docker Architecture

- The upstream `openclaw/docker-compose.yml` defines services `openclaw-gateway` and `openclaw-cli`
- The `.env` file at `openclaw/.env` bridges our `MUSTANGCLAW_*` variables to the `OPENCLAW_*` names that docker-compose expects (including `OPENCLAW_GATEWAY_BIND=lan`)
- `mustangclaw run` patches `openclaw.json` on each start: sets `gateway.bind=lan` and removes `tailscale` config (these conflict with Docker networking)
- A `docker-compose.override.yml` is generated to mount `scripts/docker-entrypoint.sh` as the container entrypoint — this re-applies the same patch on every container restart, preventing the setup wizard's hot-reload from re-introducing incompatible config
- `mustangclaw tui` shares the gateway container's network namespace (`--network container:`) so `127.0.0.1` reaches the gateway (required by OpenClaw's loopback security check)
- The gateway token (`OPENCLAW_GATEWAY_TOKEN`) is the API/device pairing token stored in `openclaw/.env` and passed to the container as an env var. This is separate from user-facing auth in `openclaw.json` (which may use `auth.mode: "password"` or `auth.mode: "token"`). `mustangclaw run` resolves the token from `openclaw.json` first, then `.env`, then generates a new one
- Browser devices connecting to the dashboard must be **paired** (approved). `mustangclaw dashboard` handles this automatically. Device pairings are stored in `~/.mustangclaw/devices/` and go stale on gateway restarts
- The dashboard URL uses a **hash fragment** (`/#token=...`), not a query parameter
- **Poseidon** (agent dashboard) is bundled into the image via `Dockerfile.poseidon` — a multi-stage overlay that builds the Vite frontend and copies the Bun API + static files into `/poseidon`. The entrypoint starts Poseidon in the background on `POSEIDON_PORT` (default 18791) before launching the gateway. When Poseidon is not bundled, the entrypoint skips it gracefully

## Build Options

```
./mustangclaw build                     # standard build
./mustangclaw build --browser           # pre-install Chromium/Playwright (~300MB extra)
./mustangclaw build --apt "ffmpeg"      # install extra system packages in image
./mustangclaw build --no-pull           # skip git pull, build from existing checkout
```

Environment variables `OPENCLAW_DOCKER_APT_PACKAGES` and `OPENCLAW_INSTALL_BROWSER=1` are also supported.

## Extra Mounts & Volumes

Expose host directories or persist `/home/node` across container restarts:

```bash
# Bind-mount host paths into the container (comma-separated, no spaces)
export OPENCLAW_EXTRA_MOUNTS="$HOME/.ssh:/home/node/.ssh:ro,$HOME/data:/home/node/data:rw"
./mustangclaw run

# Persist /home/node in a named Docker volume
export OPENCLAW_HOME_VOLUME="openclaw_home"
./mustangclaw run
```

## Agent Sandboxing

Sandbox images isolate agent tool execution in separate containers with network isolation, resource limits, and read-only root filesystems.

```
./mustangclaw sandbox              # build base sandbox image
./mustangclaw sandbox --common     # also build extended tooling image
./mustangclaw sandbox --browser    # also build browser automation image
./mustangclaw sandbox --all        # build all sandbox images
```

After building, configure sandboxing in `~/.mustangclaw/openclaw.json`:

```json
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
```

## Common Issues

- **Gateway crash-loop with "Missing config"**: Run `mustangclaw run` — it seeds `openclaw.json` if missing
- **Gateway crash-loop with "tailscale serve/funnel requires bind=loopback"**: Run `mustangclaw run` — it auto-patches this
- **Dashboard "pairing required"**: Run `mustangclaw dashboard` — it auto-approves device pairing. If it persists, clear browser localStorage for `localhost:18789` and retry
- **Dashboard "device token mismatch"**: Clear `~/.mustangclaw/devices/`, restart gateway (`mustangclaw run --stop && mustangclaw run`), and clear browser localStorage for `localhost:18789`
- **Dashboard "gateway token missing"**: The token wasn't passed via the URL. Use `mustangclaw dashboard` or paste the token (from `mustangclaw token`) into Control UI settings
- **TUI "device token mismatch"**: `mustangclaw tui` auto-clears device tokens; if it persists, run `mustangclaw run --stop && mustangclaw run`
- **TUI "gateway not connected"**: Ensure gateway is running (`mustangclaw status`), then clear `~/.mustangclaw/devices/` and retry
- **"session file locked" in dashboard chat**: Stale lock file from unclean shutdown. Remove it: `docker exec mustangclaw rm /home/node/.openclaw/agents/main/sessions/*.lock`
- **Token mismatch between .env and openclaw.json**: `mustangclaw run` reads the token from `openclaw.json` to keep them aligned
- **Gateway unhealthy but container running**: Run `mustangclaw status --health` to check application-level health

## DigitalOcean Deployment

```
./mustangclaw init              # set DO token, region, size
./mustangclaw deploy            # create & provision droplet
./mustangclaw sync              # push ~/.mustangclaw config to remote
./mustangclaw ssh --tunnel      # SSH with port forwarding (gateway, bridge, poseidon)
./mustangclaw upgrade --target remote  # pull latest & rebuild on droplet
./mustangclaw destroy           # tear down droplet
```

Requires `doctl` CLI and `DIGITALOCEAN_ACCESS_TOKEN` (configured via `mustangclaw init`).
