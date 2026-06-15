# Rogue AIDR — private org marketplace (template)

This is a **starter for the private GitHub repository** you connect to the
**claude.ai org admin dashboard** as a *GitHub-synced* plugin marketplace. Once
connected with **Sync automatically** on, every merge to this repo pushes the
new Rogue AIDR version to all org members' **Claude Desktop** and **Cowork** —
**no zip re-upload, no per-user action**.

> Why a private repo and not just point at Rogue's public repo? The claude.ai
> org dashboard only accepts **private/internal** GitHub repos for org
> marketplaces, and synced marketplaces only reliably support **relative-path**
> plugin sources. So this repo *vendors* the Rogue plugin under
> `plugins/rogue/` and references it with `"source": "./plugins/rogue"`.

## Layout

```
.
├── .claude-plugin/
│   └── marketplace.json          ← edit: unique 'name' + your org owner
├── plugins/
│   └── rogue/                    ← VENDORED by the sync script (don't hand-edit)
│       ├── .claude-plugin/plugin.json
│       ├── hooks/  scripts/  skills/ ...
│       └── env                   ← baked org API key (mode 600)
└── .github/workflows/sync-rogue.yml   ← daily auto-sync (optional but recommended)
```

## One-time setup

1. **Create a private repo** in your org from this template (or copy these files
   in). It **must be private or internal** — the dashboard rejects public repos.
2. **Edit `.claude-plugin/marketplace.json`**: set a unique `name`
   (kebab-case, not a reserved Anthropic name) and your `owner`.
3. **First vendor + key bake** — run locally once, or let the Action do it:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/qualifire-dev/rogue-plugin-claude/main/scripts/sync-org-marketplace.sh \
     | bash -s -- --repo-dir . --key rsk_YOUR_ORG_KEY --mode ask --commit
   git push
   ```
4. **Enable the auto-sync Action** (`.github/workflows/sync-rogue.yml`):
   - Repo **Settings → Secrets and variables → Actions** → add `ROGUE_API_KEY`.
   - (optional) **Variables** → `ROGUE_MODE` = `ask` | `block`.
   - **Settings → Actions → General → Workflow permissions** → *Read and write*.
5. **Connect in the claude.ai dashboard**: org admin settings → Plugins /
   Marketplaces → add this private repo as a marketplace → toggle
   **Sync automatically** ON → set the `rogue` plugin to **Required**
   (or *Installed by default*).

Done. Org members get Rogue on next session; future versions arrive on merge.

## How updates flow

```
Rogue publishes vX.Y.Z (public repo release)
        │  sync-rogue.yml (daily) or manual sync-org-marketplace.sh
        ▼
plugins/rogue/ re-vendored at vX.Y.Z, org key re-baked → commit pushed to main
        │  claude.ai dashboard auto-syncs "on PR merge to the connected repo"
        ▼
Every org member's Claude Desktop / Cowork pulls vX.Y.Z on next session
(plugin is Required → installed automatically; key rides in the vendored env)
```

## Key handling & rotation

- The org API key is baked into `plugins/rogue/env` (mode 600) inside **this
  private repo**. Treat the repo as a secret store — keep it private/internal.
- **Rotate**: revoke the old key in the Rogue dashboard, re-run the sync with the
  new `--key` (or update the `ROGUE_API_KEY` Action secret and re-run the
  workflow), commit. Members pick up the new key on next sync.
- **Don't want a key in git?** Omit the bake and instead have users run
  `/rogue:setup` once (writes `~/.rogue-env`, which overrides the plugin env).
  The plugin still auto-updates; only the credential delivery changes.

## Notes

- **Don't hand-edit `plugins/rogue/`** — the sync overwrites it. Change behavior
  through `--mode`, the key, or `~/.rogue-env`.
- Updates here are **platform-driven**; the plugin's in-session `auto-update.sh`
  is intentionally disabled in the vendored `env` (`ROGUE_AUTO_UPDATE=0`).
  Cowork doesn't fire SessionStart hooks anyway — the dashboard sync is the
  mechanism.
