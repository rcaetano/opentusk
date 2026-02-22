# MustangClaw

Wrapper project for deploying [OpenClaw](https://github.com/openclaw/openclaw) locally via Docker or remotely on DigitalOcean.

## Quick Reference

```
./mustangclaw init      # configure ports & DigitalOcean (writes ~/.mustangclaw/config.env)
./mustangclaw build     # clone openclaw repo & build Docker image (mustangclaw:local)
./mustangclaw run       # start gateway container locally
./mustangclaw setup     # run OpenClaw's onboarding wizard (API keys, models, auth)
./mustangclaw tui       # launch TUI client (gateway must be running)
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
  deploy-do.sh           # provision DigitalOcean droplet
  destroy-do.sh          # tear down droplet
  sync-config.sh         # rsync ~/.mustangclaw to local container or remote
  upgrade.sh             # git pull + rebuild (local or remote)
  ssh-do.sh              # SSH into droplet with optional port forwarding
  cloud-init.yml         # cloud-init user data for droplet bootstrap
openclaw/                # upstream openclaw repo (git-ignored, created by build)
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
- `GATEWAY_PORT` / `BRIDGE_PORT` — Docker port mappings (18789 / 18790)

## Docker Architecture

- The upstream `openclaw/docker-compose.yml` defines services `openclaw-gateway` and `openclaw-cli`
- The `.env` file at `openclaw/.env` bridges our `MUSTANGCLAW_*` variables to the `OPENCLAW_*` names that docker-compose expects (including `OPENCLAW_GATEWAY_BIND=lan`)
- `mustangclaw run` patches `openclaw.json` on each start: sets `gateway.bind=lan` and removes `tailscale` config (these conflict with Docker networking)
- A `docker-compose.override.yml` is generated to mount `scripts/docker-entrypoint.sh` as the container entrypoint — this re-applies the same patch on every container restart, preventing the setup wizard's hot-reload from re-introducing incompatible config
- `mustangclaw tui` shares the gateway container's network namespace (`--network container:`) so `127.0.0.1` reaches the gateway (required by OpenClaw's loopback security check)
- The gateway token is read from `openclaw.json` (set by `mustangclaw setup`) to stay in sync

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
- **TUI "device token mismatch"**: Clear `~/.mustangclaw/devices/` and restart gateway
- **TUI "gateway not connected"**: Ensure gateway is running (`mustangclaw status`), then clear `~/.mustangclaw/devices/` and retry
- **Token mismatch between .env and openclaw.json**: `mustangclaw run` reads the token from `openclaw.json` to keep them aligned
- **Gateway unhealthy but container running**: Run `mustangclaw status --health` to check application-level health

## DigitalOcean Deployment

```
./mustangclaw init              # set DO token, region, size
./mustangclaw deploy            # create & provision droplet
./mustangclaw sync              # push ~/.mustangclaw config to remote
./mustangclaw ssh --tunnel      # SSH with port forwarding for gateway UI
./mustangclaw upgrade --target remote  # pull latest & rebuild on droplet
./mustangclaw destroy           # tear down droplet
```

Requires `doctl` CLI and `DIGITALOCEAN_ACCESS_TOKEN` (configured via `mustangclaw init`).
