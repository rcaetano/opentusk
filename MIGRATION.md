# OpenClaw Migration Guide

Migrate config, workspace, and sessions from an existing OpenClaw instance (e.g. `~/.openclaw-mustang/`) into a MustangClaw Docker container.

## What Gets Migrated

| Component | Path | Priority |
|-----------|------|----------|
| Agent workspace | `workspace/` | Critical |
| Main config | `openclaw.json` | Critical (merge carefully) |
| Conversation sessions | `sessions/` | Optional |
| Logs | `logs/` | Skip |

---

## Step 1 — Inspect the Old Instance

```bash
ls -la ~/.openclaw-mustang/
cat ~/.openclaw-mustang/openclaw.json
ls -la ~/.openclaw-mustang/workspace/
```

Note these from `openclaw.json`:
- **`auth.profiles`** — API keys
- **`channels`** — Telegram, Discord, Signal tokens
- **`agents.defaults`** — model preferences
- **`gateway`** — port, bind, auth settings

---

## Step 2 — Find the Container's Config Path

```bash
docker exec mustangclaw sh -c 'echo $OPENCLAW_CONFIG_DIR'
# Default: /home/node/.openclaw/
```

---

## Step 3 — Copy the Workspace

```bash
docker cp ~/.openclaw-mustang/workspace/. mustangclaw:/home/node/.openclaw/workspace/
```

For selective copy (preserve parts of the new instance's workspace):

```bash
docker cp ~/.openclaw-mustang/workspace/SOUL.md mustangclaw:/home/node/.openclaw/workspace/SOUL.md
docker cp ~/.openclaw-mustang/workspace/MEMORY.md mustangclaw:/home/node/.openclaw/workspace/MEMORY.md
docker cp ~/.openclaw-mustang/workspace/memory/. mustangclaw:/home/node/.openclaw/workspace/memory/
docker cp ~/.openclaw-mustang/workspace/skills/. mustangclaw:/home/node/.openclaw/workspace/skills/
```

---

## Step 4 — Merge the Config (Don't Overwrite)

Cherry-pick from your old `openclaw.json` into the new one.

**Copy these:**
- `auth.profiles` — API keys
- `channels` — Telegram, Discord, Signal tokens
- `agents.defaults` — model preferences

**Leave alone on the new instance:**
- `gateway` — port, bind, auth token
- `meta` / `wizard` — version metadata

Backup first, then edit:

```bash
docker exec mustangclaw cp /home/node/.openclaw/openclaw.json /home/node/.openclaw/openclaw.json.bak
docker exec -it mustangclaw sh
vi /home/node/.openclaw/openclaw.json
```

---

## Step 5 — Copy Sessions (Optional)

```bash
docker cp ~/.openclaw-mustang/sessions/. mustangclaw:/home/node/.openclaw/sessions/
```

Skip this if you want a clean slate — your agent identity/memory is in the workspace, not here.

---

## Step 6 — Run Doctor

```bash
docker exec mustangclaw node dist/index.js doctor
# Fix any issues:
docker exec mustangclaw node dist/index.js doctor --repair
```

---

## Step 7 — Restart

```bash
./mustangclaw restart
```

---

## Step 8 — Verify

```bash
docker exec mustangclaw node dist/index.js gateway status
docker exec mustangclaw node dist/index.js channels status
docker exec mustangclaw ls /home/node/.openclaw/workspace/
```

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Agent has no memory | Check `workspace/memory/` was copied: `docker exec mustangclaw ls /home/node/.openclaw/workspace/memory/` |
| Channel not connecting | Token missing from `openclaw.json`. Re-check the `channels` section. |
| Config version warnings | Run `docker exec mustangclaw node dist/index.js doctor --repair` |
| Gateway auth issues | If you copied the old gateway token, update your clients to match — or revert to the new instance's token |

---

## Pro Tip — Use a Volume Instead

For long-term setups, mount your workspace as a Docker volume so you never need `docker cp` again:

```bash
export OPENCLAW_EXTRA_MOUNTS="$HOME/.openclaw-mustang/workspace:/home/node/.openclaw/workspace:rw"
./mustangclaw run
```

Then your workspace lives on the host and the container uses it directly.
