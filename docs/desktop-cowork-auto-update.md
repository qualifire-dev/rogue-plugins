# Auto-updating Rogue AIDR on Claude Desktop & Cowork

**Goal:** every org member's Claude Desktop / Cowork stays on the latest Rogue
AIDR version automatically — no zip re-upload, no per-user steps.

**Mechanism:** a **private GitHub repository** connected to your **claude.ai org
dashboard** as a *GitHub-synced* marketplace. Synced marketplaces auto-update
**"whenever a PR is merged to that repo."** A small script (or a scheduled
GitHub Action) keeps that repo loaded with the latest Rogue release.

> This is the only hands-off path on Desktop/Cowork. A **manually uploaded ZIP
> only updates when an admin re-uploads it**, and **Cowork doesn't fire
> SessionStart hooks**, so an in-plugin updater can't help here.

---

## Prerequisites

- A **Team or Enterprise** claude.ai org with admin/owner access to plugin
  management.
- Ability to create a **private or internal** GitHub repo in your org
  (public repos are rejected for org marketplaces).
- Your org **Rogue API key** (`rsk_…`) from the
  [dashboard](https://app.rogue.security/settings/api-keys).

## Architecture

```
┌──────────────────────────┐
│ Rogue public repo        │  publishes release vX.Y.Z
│ qualifire-dev/...        │  (plugin.json version bumped)
└────────────┬─────────────┘
             │  sync-org-marketplace.sh  (daily Action, or run by hand)
             ▼
┌──────────────────────────┐
│ YOUR private marketplace │  plugins/rogue/ vendored @ vX.Y.Z
│ repo (github.com)        │  plugins/rogue/env  ← org key baked (mode 600)
│  .claude-plugin/         │  .claude-plugin/marketplace.json (source: ./plugins/rogue)
│  marketplace.json        │  commit pushed to main
└────────────┬─────────────┘
             │  claude.ai dashboard: "Sync automatically" → re-sync on merge
             ▼
┌──────────────────────────┐
│ Every org member         │  Claude Desktop / Cowork installs vX.Y.Z
│ (plugin = Required)       │  next session — key rides in the vendored env
└──────────────────────────┘
```

## Step 1 — Create the private marketplace repo

Use the template in this repo at [`templates/org-marketplace/`](../templates/org-marketplace).
Copy its contents into a **new private repo**, then:

1. Edit `.claude-plugin/marketplace.json`:
   - `name`: a unique kebab-case id (e.g. `acme-security`). Avoid Anthropic's
     reserved names.
   - `owner`: your team name + contact email.
2. Commit.

## Step 2 — Vendor the plugin + bake your key

Run once locally to populate `plugins/rogue/`:

```bash
curl -fsSL https://raw.githubusercontent.com/qualifire-dev/rogue-plugin-claude/main/scripts/sync-org-marketplace.sh \
  | bash -s -- --repo-dir . --key rsk_YOUR_ORG_KEY --mode ask --commit
git push
```

This downloads the latest Rogue release, copies the plugin tree to
`plugins/rogue/`, bakes your key into `plugins/rogue/env` (mode 600), strips
hook events Cowork doesn't allow, and commits.

| Flag | Default | Purpose |
| --- | --- | --- |
| `--repo-dir DIR` | `.` | Your marketplace repo working copy |
| `--key KEY` | required | Org API key to bake |
| `--mode ask\|block` | `ask` | PreToolUse enforcement mode |
| `--from vX.Y.Z` | latest | Pin to a specific Rogue release |
| `--commit` | off | Commit after vendoring (the Action commits itself) |

## Step 3 — Automate the sync (recommended)

The template ships `.github/workflows/sync-rogue.yml`. Enable it so you never
hand-sync:

1. Repo **Settings → Secrets and variables → Actions** → add secret
   `ROGUE_API_KEY` = your `rsk_…` key.
2. (optional) **Variables** → `ROGUE_MODE` = `ask` or `block`.
3. **Settings → Actions → General → Workflow permissions** → **Read and write**.

It runs daily (and on demand via **Run workflow**), pulls the latest Rogue
release, re-bakes the key, and pushes a `chore: sync Rogue AIDR plugin to vX.Y.Z`
commit when there's a new version.

> Prefer PRs into `main`? Swap the `push` step for an open-PR action; the
> dashboard syncs when the PR **merges**.

## Step 4 — Connect it in the claude.ai dashboard

In your org's admin settings (Plugins / Marketplaces):

1. **Add a marketplace** → connect your **private** GitHub repo.
2. Toggle **Sync automatically** **ON** (this is what makes merges propagate).
3. Set the `rogue` plugin's install preference:
   - **Required** — force-installed for everyone, can't be removed (recommended
     for security tooling), or
   - **Installed by default** — installed but removable.

## Step 5 — Verify

1. On a test member's machine, open **Claude Desktop** (and a **Cowork**
   session). The Rogue plugin should appear installed.
2. Run `/rogue:status` — confirm it reports connected, the right mode, and your
   org.
3. **Update test**: bump the vendored version (let the Action run, or
   `--from` a newer release), merge to `main`, then reopen Desktop/Cowork on the
   test machine and confirm `/rogue:status` shows the new version — with no
   re-upload and no user action.

## Key rotation

1. Revoke the old key in the [Rogue dashboard](https://app.rogue.security/settings/api-keys).
2. Update the `ROGUE_API_KEY` Action secret (or re-run `sync-org-marketplace.sh`
   with the new `--key`).
3. Run the workflow / commit. Members pick up the new key on next sync.

## Security notes

- The org API key sits in `plugins/rogue/env` **inside this private repo**, in
  plaintext. **Keep the repo private/internal.** Anyone with repo read access can
  read the key.
- Don't want a key in git at all? Skip the bake and have users run `/rogue:setup`
  once (writes `~/.rogue-env`, which overrides the plugin env). Auto-update still
  works; only credential delivery changes.
- Per-user attribution comes from actor identity resolved at hook-fire time
  (git config / `$USER`), not from per-user keys.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Dashboard rejects the repo | Repo is public | Make it private or internal |
| Plugin installs but no updates arrive | "Sync automatically" off, or you pushed to a non-default branch | Toggle Sync automatically on; sync triggers on merge to the connected branch |
| `/rogue:status` says "not configured" | `plugins/rogue/env` missing or key not baked | Re-run `sync-org-marketplace.sh --key …`; confirm `plugins/rogue/env` exists and is committed |
| Plugin won't load in Cowork | A hook event outside Cowork's allow-list | Re-run the sync — it strips unsupported events; ensure you're on a current Rogue release |
| Sync Action fails to push | Workflow permissions read-only | Settings → Actions → General → Read and write permissions |

## Related

- Hub: [auto-update.md](auto-update.md)
- CLI fleets: [cli-mdm-auto-update.md](cli-mdm-auto-update.md)
- Template: [`templates/org-marketplace/`](../templates/org-marketplace)
