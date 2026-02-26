# MustangClaw

DigitalOcean deployment tool for [OpenClaw](https://github.com/openclaw/openclaw). Provisions droplets, manages remote upgrades, and configures Tailscale for secure access.

## Quick Reference

```
./mustangclaw init            # configure DigitalOcean settings (writes config.env)
./mustangclaw deploy          # create & provision DO droplet
./mustangclaw destroy         # tear down droplet
./mustangclaw upgrade         # upgrade remote droplet
./mustangclaw ssh             # SSH into droplet (--tunnel for port forwarding)
./mustangclaw audit           # sanity check of remote setup (--fix to auto-repair)
```

## Project Structure

```
mustangclaw              # CLI entry point — dispatches subcommands to scripts/
scripts/
  config.sh              # shared variables, colors, helpers (sourced by all scripts)
  init.sh                # interactive wizard for MustangClaw config (DO, Tailscale)
  deploy-do.sh           # provision DigitalOcean droplet
  destroy-do.sh          # tear down droplet
  upgrade.sh             # upgrade remote droplet (OpenClaw + Poseidon)
  ssh-do.sh              # SSH into droplet with optional port forwarding
  audit.sh               # sanity check of config, scripts, and remote droplet
```

## Configuration

**`config.env`** — Written by `mustangclaw init` in the project root. Controls DigitalOcean settings and Tailscale configuration. Sourced by `scripts/config.sh` to override defaults. Git-ignored (contains secrets).

Key variables from `scripts/config.sh`:
- `GATEWAY_PORT` / `POSEIDON_PORT` — port numbers used in remote Tailscale serve checks (18789 / 18791)
- `DO_DROPLET_NAME` / `DO_REGION` / `DO_SIZE` — droplet settings
- `DO_IMAGE` — DigitalOcean marketplace image (`openclaw`)
- `DO_SSH_KEY_FINGERPRINT` — auto-detected or set manually
- `REMOTE_OPENCLAW_HOME` — marketplace user's home on the droplet (`/home/openclaw`)
- `REMOTE_POSEIDON_DIR` — where Poseidon is deployed on the droplet (`/opt/poseidon`)
- `TAILSCALE_ENABLED` — enable Tailscale on deploy (`true`/`false`)
- `TAILSCALE_AUTH_KEY` — reusable auth key (`tskey-auth-...`) for automated deploy
- `TAILSCALE_MODE` — `"serve"` (tailnet-only) or `"funnel"` (public internet)

## DigitalOcean Deployment

```
./mustangclaw init              # set DO token, region, size
./mustangclaw deploy            # create & provision droplet
./mustangclaw ssh --tunnel      # SSH with port forwarding (gateway, poseidon)
./mustangclaw upgrade           # pull latest & rebuild on droplet
./mustangclaw audit             # sanity check of remote setup
./mustangclaw destroy           # tear down droplet
```

Requires `doctl` CLI and `DIGITALOCEAN_ACCESS_TOKEN` (configured via `mustangclaw init`).

### Upgrading

```bash
./mustangclaw upgrade                  # update OpenClaw + Poseidon on remote
./mustangclaw upgrade --ip 1.2.3.4     # target specific droplet
./mustangclaw upgrade --rollback        # revert OpenClaw on remote
```

The remote upgrade uses the marketplace updater for OpenClaw and rsyncs Poseidon source from your local machine (private repo that can't be git-cloned on the remote).

### Deployment Notes

- The `openclaw` DO marketplace image is pre-configured with OpenClaw and systemd services
- The deploy creates a 2GB swap file to prevent OOM on smaller droplets
- The recommended droplet size is `s-4vcpu-8gb`; smaller sizes may OOM during builds
- The gateway takes **~60 seconds** to initialize after starting; smoke tests may show "not responding yet" — this is normal

### Tailscale

When Tailscale is enabled (`mustangclaw init`), the deploy script installs Tailscale and configures `tailscale serve`:
- **Poseidon** (primary): `https://<droplet>.<tailnet>.ts.net` (port 443)
- **Gateway Control**: `https://<droplet>.<tailnet>.ts.net:8443` (port 8443)

The droplet's Tailscale hostname may get a `-N` suffix (e.g., `mustangclaw-1`) if a device with the same name already exists on the tailnet. Check `tailscale status` to see the actual hostname.

If the auth key is invalid or expired, `tailscale up` will fail and the deploy aborts. As a fallback, SSH into the droplet and run `tailscale up` interactively — it will print a browser login URL. Then configure serve manually:

```bash
ssh root@<droplet-ip>
tailscale up                                            # prints browser auth URL
tailscale serve --bg --https=443 http://localhost:18791  # Poseidon
tailscale serve --bg --https=8443 http://localhost:18789 # Gateway
```

## Common Issues

- **Deploy fails at "tailscale up"**: The auth key is invalid or expired. SSH into the droplet as root and run `tailscale up` interactively (browser login), then configure serve manually (see Tailscale section above)
- **Poseidon unreachable over Tailscale**: Check `tailscale serve status` on the droplet. If empty, reconfigure: `tailscale serve --bg --https=443 http://localhost:18791`
- **Tailscale hostname has "-1" suffix**: Another device with the same name exists on your tailnet. Remove the old device from Tailscale admin or use the suffixed name
- **Tailscale serve still uses old hostname after rename**: Run `tailscale serve reset` on the droplet, then reconfigure serve entries
- **Gateway "not responding" right after deploy**: Normal — the gateway takes ~60s to initialize. Wait and retry
