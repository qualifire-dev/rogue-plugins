# Auto-update for managed & pre-compiled installs

How to keep the Rogue AIDR plugin current on managed fleets **without making
anyone re-drag or re-upload a zip on every release**.

This is the hub doc. Pick your surface:

| Your users run… | Use | Guide |
| --- | --- | --- |
| **Claude Desktop** and/or **Cowork** | A **private GitHub-synced org marketplace** (claude.ai dashboard) | [desktop-cowork-auto-update.md](desktop-cowork-auto-update.md) |
| **Claude Code CLI** (terminal) on managed Macs/Linux/Windows | **MDM install** from the live public marketplace + our SessionStart updater | [cli-mdm-auto-update.md](cli-mdm-auto-update.md) |

Most orgs run both → set up both tracks; they're independent.

---

## The problem (why the old zip can't auto-update)

The pre-compiled bundle (`scripts/compile-customer-plugin.sh`) bakes the org API
key into an `env` file **inside the plugin directory**. Every auto-update
mechanism *replaces the plugin directory*, which would destroy that key — so the
bundle was deliberately frozen (`ROGUE_AUTO_UPDATE=0`). The result: every
upgrade meant an admin rebuilding and redistributing a zip.

**The fix that unblocks every surface: separate the secret from the plugin.**
The hooks already read credentials from three locations, later wins:

```
${CLAUDE_PLUGIN_ROOT}/env   → /etc/rogue/env (or %ProgramData%\rogue\env) → ~/.rogue-env
   (in the plugin,                 (outside the plugin,                       (outside the plugin,
    wiped on update)                survives updates)                          survives updates)
```

Put the key **outside** the plugin dir and the plugin payload becomes freely
replaceable — i.e. auto-updatable.

## Why the mechanism differs per surface

Claude Code's update behavior is **not uniform** across surfaces (verified June 2026):

- **Desktop / Cowork** are managed **only** through the **claude.ai org
  dashboard**. There:
  - A **manually-uploaded ZIP** updates *only* when an admin uploads a new one.
  - A **GitHub-synced marketplace** auto-updates **"whenever a PR is merged to
    that repo"** — the only hands-off lever. The connected repo **must be
    private/internal** (public repos are rejected for org marketplaces), and
    synced marketplaces only reliably support **relative-path** plugin sources.
  - **Cowork does not fire `SessionStart` hooks**
    ([anthropics/claude-code#47993](https://github.com/anthropics/claude-code/issues/47993)),
    so any in-plugin updater is a no-op there. Updates must be platform-driven.
- **CLI** *does* fire `SessionStart` hooks reliably, but Claude Code only
  auto-pulls **official** marketplaces on startup — **third-party marketplaces
  don't**
  ([#26744](https://github.com/anthropics/claude-code/issues/26744)), and the
  managed-settings `autoUpdate` switch is still an **open, unshipped** request
  ([#51350](https://github.com/anthropics/claude-code/issues/51350)). So on CLI
  we drive the documented update commands ourselves from our SessionStart hook.

## Track A — Desktop / Cowork (platform-driven)

```
Rogue publishes vX.Y.Z (public release)
        │  scripts/sync-org-marketplace.sh  (daily Action or manual)
        ▼
Your PRIVATE marketplace repo: plugins/rogue re-vendored @ vX.Y.Z, org key baked → commit
        │  claude.ai dashboard auto-syncs on merge to the connected repo
        ▼
Every member's Claude Desktop / Cowork installs vX.Y.Z next session (plugin = Required)
```

- **Key**: baked into the *private* repo's `plugins/rogue/env`, or per-user
  `~/.rogue-env` via `/rogue:setup`.
- **No SessionStart hooks involved** — correct for Cowork.
- Full steps: [desktop-cowork-auto-update.md](desktop-cowork-auto-update.md).

## Track B — Claude Code CLI (hook-driven)

```
MDM runs scripts/mdm-install-cli.sh (once / per enforcement cycle):
   ├─ /etc/rogue/env         ← org key + per-user actor (OUTSIDE plugin dir)
   ├─ claude plugin marketplace add + install   (auto-update LEFT ON)
   └─ managed-settings.d/30-rogue.json          (force-register + enable)

Every `claude` launch → SessionStart → auto-update.sh (rate-limited 24h):
   compare plugin.json version vs latest release tag
        │ newer?
        ▼
   claude plugin marketplace update rogue-marketplace
   claude plugin update rogue          (key in /etc/rogue/env untouched)
        ▼
   new version active next session
```

- We use the **explicit** `claude plugin update` commands (which work for
  third-party marketplaces) instead of relying on the broken native
  session-start auto-pull.
- Full steps: [cli-mdm-auto-update.md](cli-mdm-auto-update.md).

## What replaced what

| Old | New |
| --- | --- |
| Rebuild zip + everyone re-drags it | Track A: merge a (bot) PR → dashboard syncs everyone |
| Compiled zip on CLI fleets (frozen) | Track B: `mdm-install-cli.sh` → live marketplace, auto-update on |
| `auto-update.sh` re-runs `install.sh` | `auto-update.sh` calls `claude plugin update` (lighter, native) |
| Key baked in plugin (blocks updates) | Key in `/etc/rogue/env` / private-repo `env` / `~/.rogue-env` |

The static `compile-customer-plugin.sh` bundle still exists for genuinely
one-shot, no-infrastructure handoffs — it just isn't the update vehicle anymore.

## Verifying

See the per-track guides' **Verify** sections. Quick smell tests:

- Track A: bump the vendored version, merge, confirm a test member's Desktop
  shows the new version next session (`/rogue:status`).
- Track B: bump `plugin.json` + tag a release; relaunch `claude` (or clear
  `~/.rogue/.auto-update-check`); check `~/.rogue/auto-update.log` for
  `plugin 'rogue' updated -> vX.Y.Z`.

## Related

- [desktop-cowork-auto-update.md](desktop-cowork-auto-update.md) — Track A
- [cli-mdm-auto-update.md](cli-mdm-auto-update.md) — Track B
- [deployment.md](deployment.md) — full managed-deployment guide
- [auto-update-internals.md](auto-update-internals.md) — for maintainers
