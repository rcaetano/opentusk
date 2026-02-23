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
./mustangclaw dashboard # open OpenClaw Control in browser
```

After setup, run `mustangclaw dashboard` to open OpenClaw Control. It auto-approves device pairing and passes the gateway token.

## Commands

| Command | Description |
|---------|-------------|
| `mustangclaw init` | Configure ports & DigitalOcean settings |
| `mustangclaw build` | Clone repo & build Docker image |
| `mustangclaw run` | Start gateway container locally |
| `mustangclaw setup` | Run OpenClaw onboarding wizard |
| `mustangclaw dashboard` | Open OpenClaw Control in browser (auto-approves device pairing) |
| `mustangclaw tui` | Launch interactive TUI client |
| `mustangclaw token` | Print the current gateway token |
| `mustangclaw restart` | Restart the gateway container |
| `mustangclaw logs` | Tail gateway container logs (`--lines N`) |
| `mustangclaw status` | Show container & droplet status |
| `mustangclaw sandbox` | Build sandbox images for agent isolation |
| `mustangclaw docker` | Open a shell inside the gateway container |
| `mustangclaw rotate-tokens` | Rotate device tokens with full scope set |
| `mustangclaw poseidon` | Open Poseidon agent dashboard in browser |
| `mustangclaw exec CMD` | Run an OpenClaw CLI command in the gateway (e.g. `exec health`) |
| `mustangclaw save` | Export Docker image to `mustangclaw-local.tar.gz` |
| `mustangclaw load FILE` | Import Docker image from archive |
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

## Poseidon (Agent Dashboard)

```bash
./mustangclaw poseidon        # open Poseidon dashboard in browser (port 18791)
```

### Dev Mode

To develop the Poseidon frontend locally with hot-reload while the API runs inside Docker:

```bash
cd poseidon && pnpm dev:web   # Vite dev server on port 5173, proxies to Docker API on 18791
```

Override the proxy target with `VITE_API_TARGET`:

```bash
VITE_API_TARGET=http://localhost:3001 pnpm dev:web   # target a local API instead
```

## Dashboard & Device Pairing

```bash
./mustangclaw dashboard    # open OpenClaw Control in browser
./mustangclaw token        # print gateway token for manual use
```

The dashboard command clears stale device tokens, opens the browser with the correct `/#token=` URL, then auto-approves the browser's device pairing request. If you still see "pairing required" or "device token mismatch", clear your browser's localStorage for `localhost:18789` and run `mustangclaw dashboard` again.

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

### Tailscale

`mustangclaw init` optionally configures Tailscale for remote access. When enabled, the deploy script installs Tailscale on the droplet and exposes services via HTTPS:

- **Poseidon**: `https://<droplet>.<tailnet>.ts.net` (port 443)
- **Gateway Control**: `https://<droplet>.<tailnet>.ts.net:8443` (port 8443)

Requires a Tailscale auth key (`tskey-auth-...`) from the [Tailscale admin console](https://login.tailscale.com/admin/settings/keys). If the key is invalid, SSH into the droplet and run `tailscale up` for interactive browser login.

## Configuration

Two layers of config:

- **`~/.mustangclaw/config.env`** — Written by `mustangclaw init`. Controls ports, DigitalOcean settings.
- **`~/.mustangclaw/openclaw.json`** — Written by `mustangclaw setup`. Controls API keys, models, gateway auth (may use `auth.mode: "password"` or `auth.mode: "token"`). Mounted into the Docker container at `/home/node/.openclaw/`.
- **`~/.mustangclaw/devices/`** — Device pairing state (paired.json, pending.json). Goes stale on gateway restarts. Auto-cleared by `mustangclaw run`, `tui`, and `dashboard`.
- **`openclaw/.env`** — Generated by `mustangclaw run`. Contains `OPENCLAW_GATEWAY_TOKEN` (the API/device pairing token, separate from user-facing auth in openclaw.json).

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Gateway crash-loop with "Missing config" | Run `mustangclaw run` — it seeds `openclaw.json` if missing |
| Gateway crash-loop with "tailscale serve/funnel requires bind=loopback" | Run `mustangclaw run` — it auto-patches this |
| Dashboard "pairing required" | Run `mustangclaw dashboard` — it auto-approves device pairing. If it persists, clear browser localStorage for `localhost:18789` |
| Dashboard "device token mismatch" | Clear `~/.mustangclaw/devices/`, restart gateway, and clear browser localStorage for `localhost:18789` |
| Dashboard "gateway token missing" | Use `mustangclaw dashboard` or paste token (`mustangclaw token`) into Control UI settings |
| "session file locked" in dashboard chat | Stale lock from unclean shutdown: `docker exec mustangclaw rm /home/node/.openclaw/agents/main/sessions/*.lock` |
| TUI "device token mismatch" | `mustangclaw tui` auto-clears; if it persists, restart gateway with `mustangclaw run --stop && mustangclaw run` |
| TUI "gateway not connected" | Ensure gateway is running (`mustangclaw status`), then clear `~/.mustangclaw/devices/` |
| Token mismatch between .env and openclaw.json | `mustangclaw run` reads the token from `openclaw.json` to keep them aligned |
| Gateway unhealthy but container running | Run `mustangclaw status --health` for application-level diagnostics |
| Gateway "not responding" right after deploy | Normal — the gateway takes ~60s to initialize. Wait and retry |
| Deploy fails at "tailscale up" | Auth key is invalid/expired. SSH in as root, run `tailscale up` interactively |
| Poseidon unreachable over Tailscale | Run `tailscale serve status` on droplet; reconfigure if empty |
