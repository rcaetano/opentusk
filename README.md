# OpenTusk

DigitalOcean deployment tool for [OpenClaw](https://github.com/openclaw/openclaw). Provisions droplets, manages remote upgrades, and configures Tailscale for secure access.

## Prerequisites

- `doctl` CLI (DigitalOcean)
- `ssh` and `rsync`
- `python3` (for Tailscale status parsing)

## Getting Started

```bash
./opentusk init      # configure DigitalOcean settings (writes config.env)
./opentusk deploy    # create & provision droplet
./opentusk ssh       # SSH into the droplet
```

## Commands

| Command | Description |
|---------|-------------|
| `opentusk init` | Configure DigitalOcean & Tailscale settings |
| `opentusk deploy` | Create & provision DigitalOcean droplet |
| `opentusk destroy` | Tear down droplet |
| `opentusk upgrade` | Upgrade remote droplet (OpenClaw + Poseidon) |
| `opentusk ssh` | SSH into droplet (`--tunnel` for port forwarding) |
| `opentusk audit` | Sanity check of config & remote droplet (`--fix`) |

Run `opentusk <command> --help` for detailed usage of any command.

## Upgrading

```bash
./opentusk upgrade                  # update OpenClaw + Poseidon on remote
./opentusk upgrade --ip 1.2.3.4     # target specific droplet
./opentusk upgrade --rollback        # revert OpenClaw on remote
```

The remote upgrade uses the marketplace updater for OpenClaw and rsyncs Poseidon source from your local machine (private repo).

## Audit

```bash
./opentusk audit         # check config, scripts, and remote droplet health
./opentusk audit --fix   # attempt to auto-fix common issues
```

## Tailscale

`opentusk init` optionally configures Tailscale for remote access. When enabled, the deploy script installs Tailscale on the droplet and exposes services via HTTPS:

- **Poseidon**: `https://<droplet>.<tailnet>.ts.net` (port 443)
- **Gateway Control**: `https://<droplet>.<tailnet>.ts.net:8443` (port 8443)

Requires a Tailscale auth key (`tskey-auth-...`) from the [Tailscale admin console](https://login.tailscale.com/admin/settings/keys). If the key is invalid, SSH into the droplet and run `tailscale up` for interactive browser login.

## Configuration

**`config.env`** — Written by `opentusk init` in the project root. Controls DigitalOcean settings and Tailscale configuration. Git-ignored (contains secrets).

Key variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `DIGITALOCEAN_ACCESS_TOKEN` | DO API token | — |
| `DO_DROPLET_NAME` | Droplet name | `opentusk` |
| `DO_REGION` | DO region | `fra1` |
| `DO_SIZE` | Droplet size | `s-2vcpu-4gb` |
| `DO_SSH_KEY_FINGERPRINT` | SSH key (blank = auto-detect) | — |
| `TAILSCALE_ENABLED` | Enable Tailscale on deploy | `false` |
| `TAILSCALE_AUTH_KEY` | Reusable auth key | — |
| `TAILSCALE_MODE` | `serve` (tailnet) or `funnel` (public) | `serve` |
