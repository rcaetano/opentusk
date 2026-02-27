# OpenTusk

DigitalOcean deployment tool for [OpenClaw](https://github.com/openclaw/openclaw). Provisions droplets, manages remote upgrades, and configures Tailscale for secure access.

## Quick Reference

```
./opentusk init            # configure DigitalOcean settings (writes config.env)
./opentusk deploy          # create & provision DO droplet
./opentusk destroy         # tear down droplet
./opentusk upgrade         # upgrade remote droplet
./opentusk ssh             # SSH into droplet (--tunnel for port forwarding)
./opentusk audit           # sanity check of remote setup (--fix to auto-repair)
```

## Project Structure

```
opentusk                 # CLI entry point — dispatches subcommands to scripts/
scripts/
  config.sh              # shared variables, colors, helpers (sourced by all scripts)
  init.sh                # interactive wizard for OpenTusk config (DO, Tailscale, webhook)
  deploy-do.sh           # provision DigitalOcean droplet
  destroy-do.sh          # tear down droplet
  upgrade.sh             # upgrade remote droplet (OpenClaw + Poseidon)
  ssh-do.sh              # SSH into droplet with optional port forwarding
  audit.sh               # sanity check of config, scripts, and remote droplet
  files/
    poseidon-update.sh   # standalone Poseidon build script (deployed to droplet)
    webhook.ts           # bun HTTP server for GitHub webhook (deployed to droplet)
```

## Configuration

**`config.env`** — Written by `opentusk init` in the project root. Controls DigitalOcean settings and Tailscale configuration. Sourced by `scripts/config.sh` to override defaults. Git-ignored (contains secrets).

Key variables from `scripts/config.sh`:
- `GATEWAY_PORT` / `POSEIDON_PORT` — port numbers used in remote Tailscale serve checks (18789 / 18791)
- `DO_DROPLET_NAME` / `DO_REGION` / `DO_SIZE` — droplet settings
- `DO_IMAGE` — DigitalOcean marketplace image (`openclaw`)
- `DO_SSH_KEY_FINGERPRINT` — auto-detected or set manually
- `REMOTE_OPENCLAW_HOME` — marketplace user's home on the droplet (`/home/openclaw`)
- `REMOTE_POSEIDON_DIR` — where Poseidon is deployed on the droplet (`/opt/poseidon`)
- `POSEIDON_REPO` — Git SSH URL for the Poseidon repo (`git@github.com:rcaetano/poseidon.git`)
- `POSEIDON_BRANCH` — branch to clone/pull (`main`)
- `TAILSCALE_ENABLED` — enable Tailscale on deploy (`true`/`false`)
- `TAILSCALE_AUTH_KEY` — reusable auth key (`tskey-auth-...`) for automated deploy
- `TAILSCALE_MODE` — `"serve"` (tailnet-only) or `"funnel"` (public internet)
- `WEBHOOK_ENABLED` — enable auto-update webhook on deploy (`true`/`false`)
- `WEBHOOK_PORT` — port for the webhook listener (18792)
- `WEBHOOK_SECRET` — HMAC-SHA256 secret shared with GitHub

## DigitalOcean Deployment

```
./opentusk init              # set DO token, region, size
./opentusk deploy            # create & provision droplet
./opentusk ssh --tunnel      # SSH with port forwarding (gateway, poseidon)
./opentusk upgrade           # pull latest & rebuild on droplet
./opentusk audit             # sanity check of remote setup
./opentusk destroy           # tear down droplet
```

Requires `doctl` CLI and `DIGITALOCEAN_ACCESS_TOKEN` (configured via `opentusk init`).

### Upgrading

```bash
./opentusk upgrade                  # update OpenClaw + Poseidon on remote
./opentusk upgrade --ip 1.2.3.4     # target specific droplet
./opentusk upgrade --rollback        # revert OpenClaw on remote
```

The remote upgrade uses the marketplace updater for OpenClaw and pulls the latest Poseidon source via `git pull` on the remote (using a deploy key set up during the initial deploy).

### Deployment Notes

- The `openclaw` DO marketplace image is pre-configured with OpenClaw and systemd services
- **Deploy is resumable** — if it fails partway through, re-running `./opentusk deploy` detects the existing droplet and picks up where it left off (skips creation, recovers the gateway token from the remote, restarts services idempotently, skips Tailscale auth/serve if already configured)
- On first deploy, the marketplace image has an interactive AI provider selector; the script detects this and prompts you to complete it via `./opentusk ssh` in another terminal before continuing
- The deploy creates a 2GB swap file to prevent OOM on smaller droplets
- The recommended droplet size is `s-4vcpu-8gb`; smaller sizes may OOM during builds
- The gateway takes **~60 seconds** to initialize after starting; smoke tests may show "not responding yet" — this is normal
- Poseidon is cloned via a deploy key generated on the droplet during first deploy. If `gh` CLI is authenticated locally, the key is added to GitHub automatically; otherwise you'll be prompted to add it manually
- Credentials (`~/.openclaw/remote-credentials`) are written immediately after token resolution, before Poseidon/Tailscale phases — so they persist even if a later phase fails

### Webhook (Auto-update)

When the webhook is enabled (`opentusk init`), the deploy installs a bun HTTP server on the droplet that listens for GitHub push events and automatically rebuilds Poseidon:
- Listens on port 18792 (plain HTTP, HMAC-protected)
- Validates `X-Hub-Signature-256` against the shared secret
- Only triggers on pushes to the configured branch
- Uses `flock` to prevent concurrent builds
- Deployed to `/opt/poseidon-webhook/` with a systemd service (`poseidon-webhook`)
- Build logs written to `/var/log/poseidon-update.log`

After deploy, configure the webhook in the Poseidon GitHub repo:
- **URL**: `http://<droplet-ip>:18792/webhook`
- **Content type**: `application/json`
- **Secret**: the `WEBHOOK_SECRET` from `config.env`
- **Events**: Just the push event

`opentusk upgrade` re-syncs the webhook files and restarts the service.

### Tailscale

When Tailscale is enabled (`opentusk init`), the deploy script installs Tailscale and configures `tailscale serve`:
- **Poseidon** (primary): `https://<droplet>.<tailnet>.ts.net` (port 443)
- **Gateway Control**: `https://<droplet>.<tailnet>.ts.net:8443` (port 8443)

The droplet's Tailscale hostname may get a `-N` suffix (e.g., `opentusk-1`) if a device with the same name already exists on the tailnet. Check `tailscale status` to see the actual hostname.

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
- **Deploy fails with "Connection refused" after cloud-init**: The marketplace image's first-login AI provider selector can interfere with scripted SSH. Re-run `./opentusk deploy` — it will detect the pending setup and prompt you to complete it
- **Gateway "not responding" right after deploy**: Normal — the gateway takes ~60s to initialize. Wait and retry
- **Webhook not triggering builds**: Check `systemctl status poseidon-webhook` on the droplet. Verify the secret matches between `config.env` and the GitHub webhook settings. Check `/var/log/poseidon-update.log` for build output
- **Concurrent webhook requests**: The build script uses `flock` — only one build runs at a time, subsequent pushes during a build are skipped
