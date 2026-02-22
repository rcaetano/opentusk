# OpenClaw Docker Deployment Plan

## Overview

A set of bash scripts to build, run, and deploy an OpenClaw gateway container — locally via Docker or remotely on a DigitalOcean droplet — with secure SSH access and the ability to sync your local `~/.openclaw` configuration.

---

## Architecture

```
Local Machine                        DigitalOcean Droplet
┌─────────────────┐                  ┌──────────────────────────────────────┐
│ ~/.openclaw/     │  rsync/scp       │ /home/openclaw/.openclaw/             │
│  (config, keys,  │ ──────────────► │  (config, keys, memory)               │
│   memory)        │                  │                                       │
│                  │                  │ Docker                                │
│ Docker           │                  │ ┌──────────────────────────────────┐  │
│ ┌──────────────┐ │                  │ │ openclaw-gateway                 │  │
│ │ openclaw:local│ │                  │ │  127.0.0.1:18789 (gateway)      │  │
│ │ :18789       │ │                  │ │  127.0.0.1:18790 (bridge)       │  │
│ └──────────────┘ │                  │ └───────────────┬──────────────────┘  │
└─────────────────┘                  │                  │ localhost only       │
                                     │                  ▼                     │
   SSH Tunnel (admin)                │ ┌──────────────────────────────────┐  │
   ─────────────────────────────────►│ │ tailscaled                       │  │
   ssh -L 18789:localhost:18789      │ │  Serve: tailnet → localhost:18789│  │
                                     │ │  Funnel (optional):              │  │
                                     │ │    internet → localhost:18789    │  │
  Gmail/Telegram webhooks            │ │    https://<name>.ts.net         │  │
  ─────────────────────────────────► │ │    (password auth required)      │  │
  https://<name>.ts.net/webhook/*    │ └──────────────────────────────────┘  │
                                     │                                       │
                                     │ UFW Firewall                          │
                                     │  allow 22/tcp (SSH)                   │
                                     │  deny everything else                 │
                                     │  (Tailscale uses outbound relay —     │
                                     │   no inbound ports needed)            │
                                     └──────────────────────────────────────┘
```

---

## Key Insight: Most Channels Need Zero Inbound Ports

Research into OpenClaw's channel architecture reveals that **most channels use outbound connections**, meaning the gateway does not need to be publicly accessible for them to work:

| Channel | Connection Method | Public Endpoint Needed? |
|---------|------------------|------------------------|
| WhatsApp | Outbound WebSocket via Baileys (WhatsApp Web protocol) | No |
| Telegram | Outbound long-polling via grammY `bot.start()` (default) | No |
| Discord | Outbound WebSocket via discord.js | No |
| Slack | Outbound WebSocket via Bolt SDK Socket Mode | No |
| Signal | Local SSE stream via signal-cli daemon | No |
| iMessage | Local protocol via imsg CLI (macOS only) | No |
| Gmail (push) | Inbound Pub/Sub webhook from Google | **Yes** |
| Telegram (webhook mode) | Inbound HTTPS POST from Telegram | **Yes** (optional) |
| Slack (Events API mode) | Inbound HTTPS POST from Slack | **Yes** (optional) |

**This means for the majority of use cases, we can lock the gateway down completely — SSH-only access, no public ports for 18789/18790.**

### Webhook Strategy: Tailscale Funnel

If you need Gmail push notifications or prefer webhook mode for Telegram/Slack, **Tailscale Funnel** is the cleanest approach. OpenClaw has native Tailscale integration built in.

#### How It Works

1. **Tailscale Serve** (tailnet-only) proxies `https://<droplet-name>.ts.net` → `localhost:18789`. Only devices on your tailnet can reach it. Great for admin access from your own machines without SSH tunnels.

2. **Tailscale Funnel** (public internet) extends Serve to expose the gateway publicly at `https://<droplet-name>.ts.net`. Gmail, Telegram, and other services can POST webhooks to this URL.

Key properties:
- **No inbound firewall ports needed** — Funnel works via outbound Tailscale relay connections. UFW stays SSH-only.
- **Auto HTTPS** — Tailscale provisions and rotates TLS certs automatically. No certbot, no nginx.
- **Password auth enforced** — OpenClaw refuses to start in Funnel mode without password authentication. Every request must authenticate.
- **No custom domain required** — you get `https://<droplet-name>.<tailnet-name>.ts.net` for free.

#### Tradeoff: Port-Level, Not Path-Level

Tailscale Funnel operates at the port level — you can't expose only `/webhook/*` paths. The entire gateway (UI, API, WebSocket, webhooks) is reachable at the public URL. However:

- OpenClaw enforces password auth on all gateway access in Funnel mode
- HTTP API endpoints (`/v1/*`, `/tools/invoke`, `/api/channels/*`) always require token/password even with Tailscale identity auth
- The gateway's own DM pairing and allowlist controls add another layer
- You can still use SSH tunnel for admin work and only enable Funnel when webhooks are needed

If path-level filtering is critical, you can add nginx between Tailscale and the gateway (Tailscale → nginx → gateway), but for most setups the password auth is sufficient.

#### OpenClaw Native Configuration

```json5
{
  gateway: {
    bind: "loopback",
    tailscale: {
      mode: "funnel",           // or "serve" for tailnet-only
      resetOnExit: true         // clean up funnel config on shutdown
    },
    auth: {
      mode: "password",         // required for funnel
      password: "..."           // strong password, set via OPENCLAW_GATEWAY_PASSWORD env
    }
  }
}
```

#### Three Deployment Tiers

| Tier | Tailscale Mode | Who Can Reach Gateway | Webhooks Work? | Use Case |
|------|---------------|----------------------|----------------|----------|
| **Locked down** | Off | SSH tunnel only | No (use polling) | Maximum security, no external deps |
| **Tailnet access** | Serve | Your Tailscale devices only | No | Admin access without SSH tunnels |
| **Public webhooks** | Funnel | Anyone (password required) | Yes | Gmail push, Telegram webhooks, etc. |

You can move between tiers by changing `gateway.tailscale.mode` and restarting — no firewall or infrastructure changes needed.

#### Funnel Constraints

- Requires Tailscale v1.38.3+, MagicDNS enabled, HTTPS enabled for tailnet, and the `funnel` node attribute in your ACL policy
- Funnel only works on ports 443, 8443, or 10000 (Tailscale maps these to your local port)
- Rate limit on Let's Encrypt cert provisioning — avoid frequent enable/disable cycles (34-hour cooldown if rate-limited)

---

## Prerequisites

| Tool | Purpose |
|------|---------|
| `docker` + `docker compose` | Build and run containers locally |
| `doctl` | DigitalOcean CLI for droplet management |
| `rsync` | Sync `.openclaw` config to remote |
| `ssh` / `ssh-keygen` | Secure access to droplets |
| `git` | Clone OpenClaw repo |
| `tailscale` | (Optional) Tailnet access and public webhook endpoint via Funnel |

Accounts/keys needed:
- DigitalOcean API token (set as `DIGITALOCEAN_ACCESS_TOKEN`)
- SSH key registered with DigitalOcean (`doctl compute ssh-key list`)
- LLM provider API key(s) (Anthropic, OpenAI, etc.)
- (Optional) Tailscale account with Funnel enabled in ACL policy

---

## Scripts to Build

### 1. `scripts/config.sh` — Shared Configuration

Centralizes all tunables so every other script sources it.

```bash
OPENCLAW_REPO="https://github.com/openclaw/openclaw.git"
OPENCLAW_DIR="./openclaw"                   # local clone path
OPENCLAW_IMAGE="openclaw:local"
OPENCLAW_CONFIG_DIR="$HOME/.openclaw"
OPENCLAW_WORKSPACE_DIR="$HOME/.openclaw/workspace"

# Docker
GATEWAY_PORT=18789
BRIDGE_PORT=18790

# DigitalOcean
DO_DROPLET_NAME="openclaw-gateway"
DO_REGION="nyc3"                            # pick closest region
DO_SIZE="s-2vcpu-4gb"                       # 4 GB / 2 vCPU — suits personal use
DO_IMAGE="docker-20-04"                     # Ubuntu 20.04 + Docker pre-installed
DO_SSH_KEY_FINGERPRINT=""                   # populated at runtime or set manually
DO_TAG="openclaw"

# Tailscale (optional — for tailnet access and/or public webhooks)
TAILSCALE_ENABLED=false                     # install tailscale on droplet
TAILSCALE_AUTH_KEY=""                        # tskey-auth-... (pre-auth key from Tailscale admin)
TAILSCALE_MODE="serve"                      # "serve" (tailnet-only) or "funnel" (public webhooks)
```

### 2. `scripts/build.sh` — Clone Repo & Build Docker Image

Steps:
1. Clone `openclaw/openclaw` if not already present (or `git pull` to update).
2. Run `docker build -t openclaw:local -f Dockerfile .` from the repo root.
3. Optionally build sandbox images (`scripts/sandbox-setup.sh`).
4. Print image ID and size on completion.

Why build locally instead of pulling a hub image: the official workflow builds from source so you get the latest commit and can set `OPENCLAW_DOCKER_APT_PACKAGES` for custom system deps.

### 3. `scripts/run-local.sh` — Run Container Locally

Steps:
1. Source `config.sh`.
2. Ensure `~/.openclaw` and `~/.openclaw/workspace` directories exist (owned by uid 1000).
3. If no gateway token exists, generate one via `openssl rand -hex 32`.
4. Write/update a `.env` file with token + any provider API keys.
5. Run `docker compose up -d openclaw-gateway` (using the repo's `docker-compose.yml`).
6. Print the gateway URL: `http://localhost:18789?token=<TOKEN>`.

Flags:
- `--rebuild` — force `docker compose build` before starting.
- `--logs` — tail logs after starting.

### 4. `scripts/deploy-do.sh` — Create & Provision a DO Droplet

Steps:
1. Source `config.sh`.
2. Validate `DIGITALOCEAN_ACCESS_TOKEN` is set and `doctl` is authenticated.
3. Resolve SSH key fingerprint (auto-detect from `doctl compute ssh-key list` or use configured value).
4. Create the droplet:
   ```bash
   doctl compute droplet create "$DO_DROPLET_NAME" \
     --image "$DO_IMAGE" \
     --region "$DO_REGION" \
     --size "$DO_SIZE" \
     --ssh-keys "$DO_SSH_KEY_FINGERPRINT" \
     --tag-name "$DO_TAG" \
     --user-data-file scripts/cloud-init.yml \
     --wait
   ```
5. Retrieve the droplet's public IP.
6. Wait for SSH to become available (poll with `ssh -o ConnectTimeout=5`).
7. Run remote provisioning over SSH:
   - Create `openclaw` user (non-root, with docker group membership).
   - Configure UFW firewall:
     - `ufw default deny incoming`
     - `ufw default allow outgoing`
     - `ufw allow 22/tcp` (SSH)
     - **Do NOT open 18789, 18790, or 443** — gateway is loopback-only, Tailscale uses outbound relay
     - `ufw enable`
   - Install `fail2ban` for SSH brute-force protection.
   - Disable root password login (`PermitRootLogin prohibit-password` in sshd_config).
   - Disable mDNS/Bonjour discovery (`OPENCLAW_DISABLE_BONJOUR=1`) to prevent info leakage.
   - Clone OpenClaw repo and build Docker image on the droplet.
   - Configure gateway bind mode to `loopback` (default, most secure).
   - Generate gateway token/password and write `.env`.
   - If `TAILSCALE_ENABLED=true`:
     - Install Tailscale: `curl -fsSL https://tailscale.com/install.sh | sh`
     - Authenticate: `tailscale up --auth-key="$TAILSCALE_AUTH_KEY"`
     - Configure OpenClaw `gateway.tailscale.mode` to `$TAILSCALE_MODE`
     - If Funnel: set `gateway.auth.mode: "password"` (required by OpenClaw)
   - `docker compose up -d openclaw-gateway`.
8. Print connection info:
   ```
   Droplet IP:  <IP>
   SSH:         ssh openclaw@<IP>
   Gateway:     ssh -L 18789:localhost:18789 openclaw@<IP>
                then open http://localhost:18789?token=<TOKEN>
   Tailscale:   https://<droplet-name>.<tailnet>.ts.net  (if enabled)
   ```

### 5. `scripts/cloud-init.yml` — Cloud-Init User Data

A cloud-config YAML passed to the droplet at creation to bootstrap the environment before our SSH provisioning runs. Handles:
- System package updates (`apt update && apt upgrade`).
- Install `fail2ban`, `ufw`, `rsync`.
- Create `openclaw` user with docker group.
- Basic UFW rules (SSH only — the deploy script tightens further).

### 6. `scripts/destroy-do.sh` — Tear Down the Droplet

Steps:
1. Source `config.sh`.
2. Look up droplet ID by name (`doctl compute droplet list --tag-name openclaw --format ID,Name`).
3. Confirm destruction (prompt user unless `--force` flag is passed).
4. `doctl compute droplet delete "$DROPLET_ID" --force`.
5. Optionally clean up DO firewall rules and SSH known_hosts entry.
6. Print confirmation.

### 7. `scripts/sync-config.sh` — Copy Local `.openclaw` to Container

Supports two targets: **local container** and **remote droplet**.

**Local:**
1. `docker cp ~/.openclaw/. openclaw-gateway:/home/node/.openclaw/`
2. Fix ownership: `docker exec openclaw-gateway chown -R 1000:1000 /home/node/.openclaw`
3. Restart gateway: `docker compose restart openclaw-gateway`

**Remote (droplet):**
1. `rsync -avz --progress -e "ssh" ~/.openclaw/ openclaw@<DROPLET_IP>:/home/openclaw/.openclaw/`
2. SSH in and fix ownership + restart:
   ```bash
   ssh openclaw@<DROPLET_IP> '
     sudo chown -R 1000:1000 /home/openclaw/.openclaw
     cd /home/openclaw/openclaw && docker compose restart openclaw-gateway
   '
   ```

Flags:
- `--target local` (default) or `--target remote`
- `--ip <DROPLET_IP>` (for remote; auto-detected from `doctl` if omitted)
- `--dry-run` — show what would be synced without doing it.

### 8. `scripts/upgrade.sh` — Upgrade OpenClaw In-Place

Upgrades the OpenClaw installation inside a running local or remote container without losing configuration.

**Local:**
1. Source `config.sh`.
2. `cd` into the local OpenClaw clone and `git pull origin main`.
3. Rebuild the image: `docker build -t openclaw:local -f Dockerfile .`
4. Restart with new image: `docker compose down && docker compose up -d openclaw-gateway`.
5. Verify health: `docker compose exec openclaw-gateway node dist/index.js health --token "$OPENCLAW_GATEWAY_TOKEN"`
6. Print old and new commit SHAs for confirmation.

**Remote (droplet):**
1. Source `config.sh`.
2. Resolve droplet IP (from `doctl` or `--ip` flag).
3. SSH into the droplet and run:
   ```bash
   ssh openclaw@<DROPLET_IP> '
     cd /home/openclaw/openclaw
     git pull origin main
     docker build -t openclaw:local -f Dockerfile .
     docker compose down
     docker compose up -d openclaw-gateway
   '
   ```
4. Verify health over SSH tunnel.
5. Print old and new commit SHAs.

Flags:
- `--target local` (default) or `--target remote`
- `--ip <DROPLET_IP>` (for remote; auto-detected from `doctl` if omitted)
- `--rollback` — revert to previous git commit + rebuild (if upgrade breaks something).

Safety:
- Pulls latest code but does NOT touch `~/.openclaw` (config/state preserved).
- The `--rollback` flag runs `git checkout HEAD~1` and rebuilds, providing a quick recovery path.
- Health check runs automatically after upgrade; prints warning if it fails.

### 9. `scripts/ssh-do.sh` — Quick SSH into Droplet (convenience)

Two modes:

```bash
# Plain SSH session
./scripts/ssh-do.sh

# SSH with gateway tunnel (access UI from your browser)
./scripts/ssh-do.sh --tunnel
# Opens: ssh -L 18789:localhost:18789 -L 18790:localhost:18790 openclaw@<IP>
```

---

## Security Model

### Network — Droplet

| Layer | Rule | Reason |
|-------|------|--------|
| UFW | Allow TCP 22 | SSH management access |
| UFW | **Block** TCP 443 | Not needed — Tailscale Funnel uses outbound relay |
| UFW | **Block** TCP 18789 | Gateway never exposed publicly |
| UFW | **Block** TCP 18790 | Bridge never exposed publicly |
| UFW | Deny all other incoming | Minimize attack surface |
| Gateway | Bind to `loopback` (127.0.0.1) | Even if UFW misconfigured, gateway won't accept external connections |
| Tailscale | Funnel via outbound relay | Public HTTPS without any inbound port — relay servers proxy traffic through the Tailscale tunnel |
| Tailscale | Password auth enforced | OpenClaw requires password auth in Funnel mode — every request must authenticate |
| Docker | Agent sandbox `network: "none"` | Agent containers have no egress by default |

This is defense-in-depth across four layers:
1. **UFW** blocks all inbound ports except SSH
2. **Gateway** binds to localhost only — can't accept external connections even if UFW fails
3. **Tailscale** handles public access via outbound relay — never opens a listening port on the droplet
4. **OpenClaw** enforces password auth on every request in Funnel mode

### Accessing the Gateway UI

Three options depending on your Tailscale tier:

```bash
# Option 1: SSH tunnel (always works, no Tailscale needed)
ssh -L 18789:localhost:18789 openclaw@<DROPLET_IP>
# then open http://localhost:18789?token=<TOKEN>

# Option 2: Tailscale Serve (tailnet devices only, no password needed if allowTailscale=true)
# open https://<droplet-name>.<tailnet>.ts.net

# Option 3: Tailscale Funnel (public, password required)
# open https://<droplet-name>.<tailnet>.ts.net
```

The `scripts/ssh-do.sh --tunnel` command automates Option 1.

### SSH Hardening

- Key-only auth (password login disabled).
- `fail2ban` monitors `/var/log/auth.log` and bans IPs after 5 failed attempts.
- Non-root `openclaw` user for all operations (root login via password disabled).

### Container Hardening

- Runs as non-root `node` user (uid 1000).
- Agent sandboxes: read-only root fs, all capabilities dropped, 1 GB memory limit, 256 PID limit.
- Gateway token required for all API/UI access.
- mDNS/Bonjour discovery disabled (`OPENCLAW_DISABLE_BONJOUR=1`) to prevent hostname and path leakage.

### Secrets Management

- API keys and gateway token stored in `~/.openclaw/` on host, bind-mounted into container.
- `.env` file (containing tokens) is `.gitignore`d and never committed.
- `rsync` over SSH (encrypted in transit) for config sync to remote.
- File permissions: `600` on config files, `700` on directories.

---

## Outbound Connectivity (Always Needed)

The gateway always needs outbound HTTPS for:
- LLM provider APIs (api.anthropic.com, api.openai.com, etc.)
- Messaging platform APIs (WhatsApp Web servers, Telegram Bot API, Discord API, etc.)

These are outbound connections — they work with `ufw default allow outgoing` and require no inbound port rules. This is why most channels work perfectly with a fully locked-down firewall.

---

## File Structure

```
mustang-bot/
├── scripts/
│   ├── config.sh            # shared variables
│   ├── build.sh             # clone repo + docker build
│   ├── run-local.sh         # docker compose up locally
│   ├── deploy-do.sh         # create + provision DO droplet
│   ├── cloud-init.yml       # droplet bootstrap user-data
│   ├── destroy-do.sh        # tear down DO droplet
│   ├── sync-config.sh       # copy .openclaw to local/remote container
│   ├── upgrade.sh           # pull latest openclaw + rebuild container
│   └── ssh-do.sh            # convenience SSH into droplet (with --tunnel)
└── openclaw-docker-plan.md  # this document
```

---

## Workflow Examples

### First-time local setup
```bash
./scripts/build.sh              # clone + build image
./scripts/run-local.sh          # start gateway locally
# open http://localhost:18789?token=<TOKEN>
# run onboarding, connect channels
```

### Deploy to DigitalOcean
```bash
export DIGITALOCEAN_ACCESS_TOKEN="dop_v1_..."
./scripts/deploy-do.sh                        # creates droplet, provisions, starts gateway
./scripts/sync-config.sh --target remote      # push local config to droplet
./scripts/ssh-do.sh --tunnel                  # access gateway UI via SSH tunnel
```

### Deploy with Tailscale (tailnet access + webhook support)
```bash
# In config.sh, set:
#   TAILSCALE_ENABLED=true
#   TAILSCALE_AUTH_KEY="tskey-auth-..."
#   TAILSCALE_MODE="funnel"                   # or "serve" for tailnet-only
./scripts/deploy-do.sh          # also installs Tailscale, configures Funnel
# Webhook URL: https://<droplet-name>.<tailnet>.ts.net/webhook/...
# Admin UI:    https://<droplet-name>.<tailnet>.ts.net (password required)
```

### Upgrade OpenClaw
```bash
./scripts/upgrade.sh                          # upgrade local
./scripts/upgrade.sh --target remote          # upgrade droplet
./scripts/upgrade.sh --target remote --rollback  # revert if broken
```

### Move to a different droplet
```bash
./scripts/deploy-do.sh          # spin up new droplet (change region in config.sh if desired)
./scripts/sync-config.sh --target remote --ip <NEW_IP>  # push config
./scripts/destroy-do.sh         # tear down old droplet
```

### Tear down
```bash
./scripts/destroy-do.sh         # destroys droplet, cleans up
```

---

## Implementation Notes

- All scripts use `set -euo pipefail` for safe execution.
- All scripts source `config.sh` for consistency.
- Destructive operations (destroy, force-rebuild) require explicit confirmation or `--force`.
- The `.openclaw` directory is the single source of truth for all state — syncing it is equivalent to migrating the entire instance (config, memory, channel sessions, API keys).
- The `docker-20-04` DO image comes with Docker and Docker Compose pre-installed, avoiding manual installation.
- Scripts are idempotent where possible (re-running `deploy-do.sh` checks if droplet already exists).
- The `upgrade.sh` script only touches the OpenClaw code and Docker image — `~/.openclaw` config and state are never modified during upgrades.

---

## Sources

- [OpenClaw Docker Documentation](https://docs.openclaw.ai/install/docker)
- [OpenClaw Official Docs](https://docs.openclaw.ai/)
- [OpenClaw Security Documentation](https://docs.openclaw.ai/gateway/security)
- [OpenClaw Tailscale Integration](https://docs.openclaw.ai/gateway/tailscale)
- [OpenClaw GitHub — docker-compose.yml](https://github.com/openclaw/openclaw/blob/main/docker-compose.yml)
- [OpenClaw GitHub — docker-setup.sh](https://github.com/openclaw/openclaw/blob/main/docker-setup.sh)
- [OpenClaw Channel Architecture](https://deepwiki.com/openclaw/openclaw/8-channels)
- [OpenClaw on DigitalOcean Marketplace](https://docs.digitalocean.com/products/marketplace/catalog/openclaw/)
- [OpenClaw System Architecture Overview](https://ppaolo.substack.com/p/openclaw-system-architecture-overview)
- [Tailscale Funnel Documentation](https://tailscale.com/kb/1223/funnel)
- [Tailscale Funnel Examples](https://tailscale.com/kb/1247/funnel-examples)
- [Tailscale Serve Documentation](https://tailscale.com/kb/1242/tailscale-serve)
- [Developing Webhooks with Tailscale Funnel (Twilio)](https://www.twilio.com/en-us/blog/developers/tutorials/develop-webhooks-locally-using-tailscale-funnel)
- [DigitalOcean — doctl CLI Reference](https://docs.digitalocean.com/reference/doctl/)
- [DigitalOcean — doctl compute droplet create](https://docs.digitalocean.com/reference/doctl/reference/compute/droplet/create/)
- [DigitalOcean — How to Provide User Data](https://docs.digitalocean.com/products/droplets/how-to/provide-user-data/)
