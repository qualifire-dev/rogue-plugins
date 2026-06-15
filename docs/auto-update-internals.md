# Auto-update internals (for maintainers)

How the auto-update machinery works under the hood, why it's split by surface,
and the platform facts that constrain it. Customer-facing guides:
[auto-update.md](auto-update.md), [desktop-cowork-auto-update.md](desktop-cowork-auto-update.md),
[cli-mdm-auto-update.md](cli-mdm-auto-update.md).

## The core constraint

The org API key was baked into `${CLAUDE_PLUGIN_ROOT}/env` *inside the plugin*.
Every update mechanism replaces the plugin directory (the versioned cache at
`~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`), which would wipe
the key. That's why compiled bundles set `ROGUE_AUTO_UPDATE=0`.

**Invariant going forward:** for any auto-updating install, the key lives
*outside* the plugin dir. Precedence (later wins), unchanged in `hook.sh` /
`heartbeat.sh` / `auto-update.sh`:

```
${CLAUDE_PLUGIN_ROOT}/env  →  /etc/rogue/env (|| %ProgramData%\rogue\env)  →  ~/.rogue-env
```

`/etc/rogue/env` and `~/.rogue-env` survive plugin updates; the first does not.

## Platform facts (verified June 2026 — re-verify before relying)

Sources: code.claude.com/docs (plugins, plugin-marketplaces, discover-plugins,
settings, plugins-reference); support.claude.com org-plugin articles; the GitHub
issues cited inline.

- **On-disk:** plugin code copied to `~/.claude/plugins/cache/<mkt>/<plugin>/<ver>/`
  (versioned, replaced on update). Persistent per-plugin state at
  `~/.claude/plugins/data/{id}/` = `${CLAUDE_PLUGIN_DATA}` (survives updates).
  Marketplace registry: `~/.claude/plugins/known_marketplaces.json`.
- **Version resolution:** `plugin.json` `version` → marketplace-entry `version`
  → git commit SHA. We bump `plugin.json` per release (source of truth) — never
  set `version` in both `plugin.json` and the marketplace entry (plugin.json
  wins silently). The vendored org-marketplace entry deliberately omits
  `version` so the vendored `plugin.json` is authoritative.
- **CLI auto-update:** only **official** marketplaces auto-pull on session start;
  third-party do **not** ([#26744], closed not-planned). Managed-settings
  `autoUpdate` is **unshipped** ([#51350]). Explicit `claude plugin marketplace
  update` + `claude plugin update` *do* work for third-party → that's what our
  hook calls.
- **Desktop/Cowork:** managed only via the claude.ai org dashboard.
  GitHub-synced marketplaces auto-update **on PR merge to the connected repo**;
  manual ZIP uploads update only on re-upload. Connected repo **must be
  private/internal**; synced marketplaces support a **narrower** source set
  (relative paths reliable; `github`/`url`/`git-subdir` only if target public;
  `npm`/`pip` unsupported). **Cowork does not fire SessionStart hooks** ([#47993]).
- **managed-settings.json** paths: macOS `/Library/Application Support/ClaudeCode/`,
  Linux `/etc/claude-code/`, Windows `C:\Program Files\ClaudeCode\` — plus a
  `managed-settings.d/` drop-in dir merged alphabetically.

[#26744]: https://github.com/anthropics/claude-code/issues/26744
[#51350]: https://github.com/anthropics/claude-code/issues/51350
[#47993]: https://github.com/anthropics/claude-code/issues/47993

## Components

| File | Surface | Role |
| --- | --- | --- |
| `scripts/sync-org-marketplace.sh` | Desktop/Cowork | Vendor latest release into a customer **private** marketplace repo, bake org key (`env`, `ROGUE_AUTO_UPDATE=0`), strip Cowork-unsupported hooks, optional commit. |
| `templates/org-marketplace/` | Desktop/Cowork | Starter for the customer's private synced repo (`marketplace.json`, `sync-rogue.yml` Action, README). |
| `scripts/mdm-install-cli.sh` / `.ps1` | CLI | Write `/etc/rogue/env` (key+actor), live public-marketplace install (auto-update left on), managed-settings drop-in fragment. |
| `plugins/rogue/scripts/auto-update.sh` | CLI | SessionStart-driven updater. Compares `plugin.json` vs latest release tag; runs `claude plugin marketplace update` + `claude plugin update`. 24h rate-limit; honors `ROGUE_AUTO_UPDATE=0` / `ROGUE_PLUGIN_VERSION`. |
| `scripts/compile-customer-plugin.sh` | static | Unchanged behavior: frozen drag-drop bundle (`ROGUE_AUTO_UPDATE=0`). Now documented as the one-shot, non-updating option. |

## Why `auto-update.sh` no longer re-runs `install.sh`

The old updater piped `install.sh | bash`, which re-cloned the marketplace and
re-ran statusline/credential setup — heavy, and it would have clobbered a baked
key (the reason for the freeze). Now that the key is out of the plugin, the
lighter, supported path is the two native commands. `install.sh` remains the
interactive first-time installer; `auto-update.sh` is the steady-state updater.

`auto-update.sh` reads `plugin.json` and the GitHub release tag **without
python3** (the `/usr/bin/python3` stub fails silently on a fresh macOS — same
reason as `hook.sh`/`heartbeat.sh`). On a plugin-update failure it clears the
rate-limit stamp so the next session retries instead of waiting a full day.

## `ROGUE_AUTO_UPDATE` matrix

| Install path | `ROGUE_AUTO_UPDATE` | Update driver |
| --- | --- | --- |
| Public marketplace (`install.sh`) | unset → defaults `1` | `auto-update.sh` (CLI SessionStart) |
| MDM CLI (`mdm-install-cli.sh`) | unset → `1` | `auto-update.sh` |
| Private synced marketplace (`sync-org-marketplace.sh`) | `0` (baked) | claude.ai dashboard sync on merge |
| Static compiled zip (`compile-customer-plugin.sh`) | `0` (baked) | none (admin rebuilds) |

The `0` cases are correct: on Desktop/Cowork the platform owns updates and the
SessionStart hook can't run in Cowork anyway, so the in-plugin updater must
stand down.

## Release flow (unchanged, still the source of truth)

1. Bump `version` in `plugins/rogue/.claude-plugin/plugin.json` **and**
   `.claude-plugin/marketplace.json`.
2. Commit, tag `vX.Y.Z`, push the tag → `release.yml` builds the tarball +
   GitHub Release.
3. Propagation:
   - Public-marketplace / CLI users: `auto-update.sh` picks it up next session
     (24h rate-limit).
   - Desktop/Cowork orgs: their `sync-rogue.yml` Action (or a manual
     `sync-org-marketplace.sh`) vendors it and the dashboard syncs on merge.

## Keeping siblings in lockstep

Per the dual-dispatcher rule (CLAUDE.md): the CLI updater and any Windows
counterpart must move together. `mdm-install-cli.sh` ↔ `mdm-install-cli.ps1`,
and `auto-update.sh` ↔ `auto-update.ps1` (on the windows-support track) must
stay behavior-equivalent.

## Test ideas (not yet automated)

- `sync-org-marketplace.sh` against a throwaway dir + a real release tag → assert
  `plugins/rogue/.claude-plugin/plugin.json` version, `env` mode 600 + key tail,
  Cowork hook events stripped.
- `auto-update.sh` version-compare unit: stub `plugin.json` + a fake
  `releases/latest` and assert the equal/newer branches and rate-limit gate.
- `bash -n` / `dash -n` lint on all `.sh`; `mdm-install-cli.sh` dry-run with a
  fake `claude` on PATH.
