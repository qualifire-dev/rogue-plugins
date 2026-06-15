# Auto-updating Rogue AIDR on Claude Code CLI fleets (MDM)

**Goal:** managed terminal/CLI machines run the latest Rogue AIDR automatically,
with the org key provisioned centrally and per-user attribution intact.

**Mechanism:** install the plugin from the **live public marketplace** (not a
frozen zip) and provision the key into `/etc/rogue/env` — **outside** the plugin
directory, so updates never destroy it. The plugin's `SessionStart` hook
(`auto-update.sh`) then keeps it current by driving `claude plugin update`.

> Why not rely on Claude Code's own auto-update? It only auto-pulls **official**
> marketplaces on session start; third-party ones don't
> ([#26744](https://github.com/anthropics/claude-code/issues/26744)), and a
> managed-settings `autoUpdate` switch isn't shipped
> ([#51350](https://github.com/anthropics/claude-code/issues/51350)). The CLI
> *does* fire SessionStart hooks, so we drive the documented update commands
> ourselves.

---

## Prerequisites

- Managed macOS / Linux (Windows: use `scripts/mdm-install-cli.ps1`).
- Claude Code CLI installed on devices (`claude` on PATH for the user).
- Org **Rogue API key** (`rsk_…`).
- An MDM that can run a root script and substitute per-user identity
  (Kandji, Jamf, Intune, Workspace ONE, …).

## What the installer does

`scripts/mdm-install-cli.sh` (idempotent — safe every enforcement cycle):

1. Writes **`/etc/rogue/env`** with the org key, enforcement mode, and the
   per-user actor identity. Mode `0640`, root-owned. *Outside* the plugin cache,
   so `claude plugin update` never clobbers it.
2. Registers the **public marketplace** and installs the plugin via the Claude
   CLI, leaving **auto-update ON** (it does **not** set `ROGUE_AUTO_UPDATE=0` —
   that flag is only for the platform-managed Desktop/Cowork bundle).
3. Writes a **managed-settings drop-in** (`…/ClaudeCode/managed-settings.d/30-rogue.json`)
   that force-registers the marketplace and force-enables the plugin org-wide,
   so a user poking at `/plugin` can't drift off it.

## Quickstart

```bash
# As root on a device (or via your MDM, env-substituted):
ROGUE_API_KEY="rsk_xxx" \
ROGUE_ACTOR_EMAIL="$USER_EMAIL" \
ROGUE_ACTOR_NAME="$USER_FULL_NAME" \
  sudo -E bash <(curl -fsSL https://raw.githubusercontent.com/qualifire-dev/rogue-plugin-claude/main/scripts/mdm-install-cli.sh)
```

| Flag / env | Default | Purpose |
| --- | --- | --- |
| `--key` / `ROGUE_API_KEY` | required | Org API key |
| `--email` / `ROGUE_ACTOR_EMAIL` | required | Per-user actor email |
| `--name` / `ROGUE_ACTOR_NAME` | required | Per-user actor name |
| `--mode` / `ROGUE_PRETOOLUSE_ON_BLOCK` | `ask` | `ask` or `block` |
| `--repo` / `ROGUE_PLUGIN_REPO` | `qualifire-dev/rogue-plugin-claude` | Marketplace repo |
| `--run-as USER` | console/`SUDO_USER` | User to run `claude plugin …` as |
| `--no-managed-settings` | — | Register marketplace only, skip the policy fragment |

## MDM examples

### Kandji (Custom Script, every enforcement cycle)

```bash
#!/usr/bin/env bash
set -e
[ -n "$USER_EMAIL" ] && [ -n "$USER_FULL_NAME" ] || exit 0
ROGUE_API_KEY="rsk_xxx" \
ROGUE_ACTOR_EMAIL="$USER_EMAIL" \
ROGUE_ACTOR_NAME="$USER_FULL_NAME" \
  bash <(curl -fsSL https://raw.githubusercontent.com/qualifire-dev/rogue-plugin-claude/main/scripts/mdm-install-cli.sh)
```

Store the key in a Kandji secret/variable rather than inline if your tenant
supports it.

### Jamf Pro (Policy script, parameters 4/5/6)

```bash
#!/usr/bin/env bash
set -e
KEY="$4"; EMAIL="$5"; NAME="$6"
[ -n "$KEY" ] && [ -n "$EMAIL" ] && [ -n "$NAME" ] || exit 0
bash <(curl -fsSL https://raw.githubusercontent.com/qualifire-dev/rogue-plugin-claude/main/scripts/mdm-install-cli.sh) \
  --key "$KEY" --email "$EMAIL" --name "$NAME"
```

### Windows (Intune / admin shell)

```powershell
.\mdm-install-cli.ps1 -Key rsk_xxx -Email alice@corp.com -Name "Alice Smith" -Mode ask
```

Writes `%ProgramData%\rogue\env` and
`%ProgramFiles%\ClaudeCode\managed-settings.d\30-rogue.json`. (Native-Windows
runtime hooks require the PowerShell hook dispatcher from the windows-support
build.)

## How updates happen after install

```
user runs `claude`
   └─ SessionStart → auto-update.sh (detached, rate-limited 24h)
        ├─ ROGUE_AUTO_UPDATE=0 or ROGUE_PLUGIN_VERSION set? → stand down
        ├─ compare installed plugin.json version vs latest GitHub release tag
        └─ newer? →  claude plugin marketplace update rogue-marketplace
                     claude plugin update rogue
                     (key in /etc/rogue/env is untouched)
   next session: new version active
```

Logs: `~/.rogue/auto-update.log`. Rate-limit stamp: `~/.rogue/.auto-update-check`
(delete it to force a check on next launch).

## Pinning / opting out

- **Pin a version**: set `ROGUE_PLUGIN_VERSION=v1.2.3` in `/etc/rogue/env` — the
  updater stands down.
- **Disable updates**: set `ROGUE_AUTO_UPDATE=0` in `/etc/rogue/env`.

## Verify

```bash
# Key provisioned, outside the plugin:
ls -l /etc/rogue/env                      # -rw-r----- root wheel
grep -c ROGUE_API_KEY /etc/rogue/env      # 1

# Plugin installed from the live marketplace:
claude plugin list                        # rogue@rogue-marketplace, enabled

# Update path works:
rm -f ~/.rogue/.auto-update-check         # clear rate-limit
claude                                    # launch; then in another shell:
tail ~/.rogue/auto-update.log             # expect "up to date" or "updated -> vX.Y.Z"
```

Inside a session: `/rogue:status` should show connected + the resolved actor
identity from `/etc/rogue/env`.

## Key rotation

- **Standard**: push a new `--key` through the MDM script; `/etc/rogue/env` is
  rewritten atomically. Revoke the old key in the dashboard afterward.
- The plugin itself is keyless, so rotation never touches the marketplace
  install.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `/rogue:status` "not configured" | `/etc/rogue/env` missing or unreadable by the user | Re-run installer; check file perms (`0640`, user in owning group) |
| Plugin not installed | `claude` not on PATH for the target user at install time | Re-run with `--run-as <user>`; the managed-settings fragment force-registers on next launch regardless |
| No updates after a release | rate-limited (<24h) or pinned | `rm ~/.rogue/.auto-update-check`; check `ROGUE_PLUGIN_VERSION` not set |
| `auto-update.log` shows "claude CLI not on PATH" | hook ran in a context without `claude` | Ensure the CLI is installed for the user; this path no-ops safely |
| User disabled the plugin via `/plugin` | drift | The managed-settings `enabledPlugins` fragment re-enables it; confirm the fragment landed |

## Related

- Hub: [auto-update.md](auto-update.md)
- Desktop/Cowork: [desktop-cowork-auto-update.md](desktop-cowork-auto-update.md)
- Identity provisioning details: [deployment.md](deployment.md)
