# MustangClaw

Wrapper project for deploying [OpenClaw](https://github.com/openclaw/openclaw) locally via Docker or remotely on DigitalOcean.

## Prerequisites

- Docker Desktop/Engine + Docker Compose v2
- `python3` (for config management)
- `git`

## Getting Started

```bash
./mustangclaw init      # configure ports & DigitalOcean (writes ~/.mustangclaw/config.env)
./mustangclaw build     # clone openclaw repo & build Docker image (mustangclaw:local)
./mustangclaw run       # start gateway container locally
./mustangclaw setup     # run OpenClaw's onboarding wizard (API keys, models, auth)
```

After setup, access the dashboard at `http://localhost:18789/?token=<your-token>`.

## Commands

| Command | Description |
|---------|-------------|
| `mustangclaw init` | Configure ports & DigitalOcean settings |
| `mustangclaw build` | Clone repo & build Docker image |
| `mustangclaw run` | Start gateway container locally |
| `mustangclaw setup` | Run OpenClaw onboarding wizard |
| `mustangclaw tui` | Launch interactive TUI client |
| `mustangclaw status` | Show container & droplet status |
| `mustangclaw sandbox` | Build sandbox images for agent isolation |
| `mustangclaw docker` | Open a shell inside the gateway container |
| `mustangclaw deploy` | Create & provision DigitalOcean droplet |
| `mustangclaw destroy` | Tear down droplet |
| `mustangclaw sync` | Push config to local container or remote |
| `mustangclaw upgrade` | Pull latest & rebuild (local or remote) |
| `mustangclaw ssh` | SSH into droplet |

Run `mustangclaw <command> --help` for detailed usage of any command.

## Build Options

```bash
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

```bash
./mustangclaw sandbox              # build base sandbox image
./mustangclaw sandbox --common     # also build extended tooling image
./mustangclaw sandbox --browser    # also build browser automation image
./mustangclaw sandbox --all        # build all sandbox images
```

After building, enable sandboxing in `~/.mustangclaw/openclaw.json`:

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

## Health Check

```bash
./mustangclaw status            # container-level status
./mustangclaw status --health   # also run application-level gateway health check
```

## DigitalOcean Deployment

```bash
./mustangclaw init              # set DO token, region, size
./mustangclaw deploy            # create & provision droplet
./mustangclaw sync              # push ~/.mustangclaw config to remote
./mustangclaw ssh --tunnel      # SSH with port forwarding for gateway UI
./mustangclaw upgrade --target remote  # pull latest & rebuild on droplet
./mustangclaw destroy           # tear down droplet
```

Requires `doctl` CLI and `DIGITALOCEAN_ACCESS_TOKEN` (configured via `mustangclaw init`).

## Configuration

Two layers of config:

- **`~/.mustangclaw/config.env`** — Written by `mustangclaw init`. Controls ports, DigitalOcean settings.
- **`~/.mustangclaw/openclaw.json`** — Written by `mustangclaw setup`. Controls API keys, models, gateway auth. Mounted into the Docker container at `/home/node/.openclaw/`.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Gateway crash-loop with "Missing config" | Run `mustangclaw run` — it seeds `openclaw.json` if missing |
| Gateway crash-loop with "tailscale serve/funnel requires bind=loopback" | Run `mustangclaw run` — it auto-patches this |
| TUI "device token mismatch" | Clear `~/.mustangclaw/devices/` and restart gateway |
| TUI "gateway not connected" | Ensure gateway is running (`mustangclaw status`), then clear `~/.mustangclaw/devices/` |
| Token mismatch between .env and openclaw.json | `mustangclaw run` reads the token from `openclaw.json` to keep them aligned |
| Gateway unhealthy but container running | Run `mustangclaw status --health` for application-level diagnostics |
