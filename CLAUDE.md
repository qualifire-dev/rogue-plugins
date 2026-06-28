# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Claude Code **plugin** (not an app) that ships Rogue Security AIDR — it observes every Claude Code lifecycle event and POSTs the payload to `https://api.rogue.security/api/v1/hooks/claude` for prompt-injection / secret-exfil / destructive-command detection.

There is no build step for the plugin itself: it's a directory of JSON + shell scripts loaded by Claude Code at session start. The only "build" is `scripts/build-release.sh`, which tars the plugin tree for GitHub Releases.

**This repo is now a multi-agent monorepo.** Besides the Claude plugin (`plugins/rogue/`, endpoint `/hooks/claude`) it also ships the **OpenAI Codex** plugin (`plugins/codex/`, endpoint `/hooks/openai`, family `openai`, surface `codex_cli`/`codex_app`) and a **caveman-style multi-agent installer** (`install-all.sh` / `install-all.ps1`) that detects every installed coding agent and installs the matching Rogue plugin into each.

### Codex plugin (`plugins/codex/`)
Mirrors the Claude plugin with three deliberate differences:
- **Manifest is `.codex-plugin/plugin.json`**; the Codex marketplace file is `.agents/plugins/marketplace.json` (kept separate from the Claude `.claude-plugin/marketplace.json` so the same plugin name `rogue` doesn't collide and Codex never falls back to the Claude marketplace). Codex sets both `PLUGIN_ROOT` and `CLAUDE_PLUGIN_ROOT`, so scripts keep using `${CLAUDE_PLUGIN_ROOT}`.
- **`hook.sh`/`hook.ps1` are PURE RELAY** — no block-detection regex, no `security-alert` script. Codex displays the native deny shape itself; the Claude modal exists only because the Claude app hides the block reason. Don't add an alert to Codex.
- **No `auto-update.sh`.** Codex has no documented native plugin auto-update, but the updater is speculative + fragile, so v1 omits it; heartbeat's `update_available` drives the dashboard "outdated" badge instead. Re-add (copy Claude's) only if a confirmed gap needs silent push.
- Codex hooks also drop the `CLAUDE_CODE_ENTRYPOINT` gate that Claude's hooks use (Codex doesn't set that var; the hook only ever fires from Codex's own `hooks.json`).
- **Hook trust**: Codex hashes the whole hook definition and skips untrusted command hooks until reviewed via `/hooks`. Keep `hooks.json` command strings (POSIX `command` + Windows `commandWindows`) **byte-identical forever**; mutate only `scripts/*` so trust survives updates. Setup/status commands document the one-time `/hooks` trust step.

### Multi-agent installer (`install-all.sh` / `install-all.ps1`)
A thin bash/PowerShell dispatcher (no node/python). A `PROVIDERS` table detects agents (`command -v` / `Get-Command` + dir probes). All Rogue plugins **share `~/.rogue-env`**, so it prompts + validates the key via `/hooks/ping` ONCE, writes the shared env, then runs each per-agent install non-interactively (`claude/codex plugin install`, or curls the Cursor installer). Flags mirror caveman: `--only/--skip/--list/--dry-run/--force/--non-interactive/--api-key`. Fail-soft per agent.

## Repo layout (load-bearing pieces)

- `.claude-plugin/marketplace.json` — marketplace manifest. Points at `./plugins/rogue`.
- `plugins/rogue/.claude-plugin/plugin.json` — plugin manifest. **`version` here is the source of truth** — `build-release.sh` reads it, and `auto-update.sh` compares it against the latest GitHub release tag (`v${version}`).
- `plugins/rogue/hooks/hooks.json` — 12 lifecycle hooks, all `type: "command"`, all running inline bash. **Every hook follows the same shape** (see below).
- `plugins/rogue/scripts/setup.sh` — writes `~/.rogue-env` (mode 600) with `ROGUE_API_KEY` / `ROGUE_ACTOR_EMAIL` / `ROGUE_ACTOR_NAME`. Called by `/rogue:setup`.
- `plugins/rogue/scripts/auto-update.sh` — fires from `SessionStart` in the background. Rate-limited to once/24h via `~/.rogue/.auto-update-check`. Logs to `~/.rogue/auto-update.log`. Re-invokes the one-line installer when a newer release tag exists.
- `plugins/rogue/scripts/security-alert.sh` — cross-platform modal alert (osascript on macOS, notify-send on Linux). Used by `UserPromptSubmit` when the API returns `decision: "block"`.
- `plugins/rogue/commands/{setup,status}.md` — slash commands. These are **instructions to Claude**, not scripts — Claude executes the bash inside them step-by-step.
- `scripts/build-release.sh` + `.github/workflows/release.yml` — tag-driven release pipeline. Pushing a `v*` tag builds `dist/rogue-plugin-claude-darwin.tar.gz` and attaches it to the release. The artifact filename intentionally has **no version** so `/latest/` URLs stay stable.

## The hook pattern

Every API-POST entry in `hooks.json` is a thin wrapper around `scripts/hook.sh`:

```json
{ "type": "command",
  "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/hook.sh\" PreToolUse || echo '{}'",
  "timeout": 12 }
```

`scripts/hook.sh <EventName>` is the orchestrator: sources env files, fail-opens on missing API key, sources `scripts/actor.sh` for actor resolution, POSTs stdin to `/api/v1/hooks/claude` with the four `x-rogue-*` headers, parses the response for a block decision, fires `scripts/security-alert.sh` in the background on block (skipped when `CLAUDE_CODE_ENTRYPOINT=cli`), and prints the API response to stdout. Logs every invocation to `$ROGUE_LOG_FILE` (default `~/.rogue/hook.log`); the logged `reason` is sanitized of control characters to prevent log forgery from server-controlled text.

`scripts/warn.sh` is the SessionStart "not configured" nudge. `scripts/auto-update.sh` is the SessionStart background updater. `scripts/heartbeat.sh` is the SessionStart background presence beacon — a fire-and-forget `GET /api/v1/hooks/status` (headers `x-rogue-agent-family: claude` — the fixed enum value — plus `x-rogue-agent` carrying the display label `Claude Code - CLI` / `Claude Code - Desktop` / `Claude Cowork` derived from `$CLAUDE_CODE_ENTRYPOINT`, `x-rogue-agent-version` from `plugin.json` via grep/sed, `x-rogue-host`, and the actor headers) that registers the install in the dashboard's Coding Agents roster and learns `update_available`. Independent of the per-event POSTs to `/api/v1/hooks/claude`. Reads the plugin version without `python3` for the same fresh-macOS reason as `hook.sh`.

Invariants to preserve when editing hooks:

- **Source env files in this precedence order** — `${CLAUDE_PLUGIN_ROOT}/env` (bundled defaults for compiled-with-key distributions), then `/etc/rogue/env` (MDM), then `$HOME/.rogue-env` (per-user, written by `/rogue:setup`). Later-sourced files override earlier ones, so `~/.rogue-env` wins (explicit user intent). Never source from any world-writable path like `/tmp` — that turns the hook into a local code-execution primitive.
- **Actor cascade lives in `scripts/actor.sh`** — sourced by `hook.sh` after the env files. Per-var fallback order: existing env → `git config --global user.{email,name}` → `CLAUDE_CODE_USER_EMAIL` (Claude Code injects this in Cowork and similar remote-VM environments; local-part as name) → `hostname` / `whoami` last-resort. Resolved every hook; no on-disk cache (stale-cache bugs would silently defeat the Cowork identity fix).
- **Fail-open is layered** — `hook.sh` emits `{}` on missing API key or any curl failure, AND every `hooks.json` command is wrapped `bash ... || echo '{}'` so a missing/broken script or absent `bash` still emits `{}` instead of unblocked stdout. Both layers are load-bearing.
- **`x-rogue-event` must match the hook's key** in `hooks.json` (e.g. the `PreToolUse` hook sends `x-rogue-event: PreToolUse`). The server routes on this header.
- `UserPromptSubmit` parses the response itself (`decision == "block"` → fires `security-alert.sh` via osascript/notify-send). Every other hook relays the API response verbatim.
- Timeouts: curl uses `--max-time 10`; hook `timeout` is set 2s higher to give curl room to fail cleanly.

## Releasing

1. Bump `version` in **both** `plugins/rogue/.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` (the marketplace lists the plugin's version too — keep them in sync).
2. Commit, tag `vX.Y.Z`, push the tag. The `release.yml` workflow checks out the tag, runs `scripts/build-release.sh`, and creates the GitHub Release with the tarball.
3. `auto-update.sh` on user machines will pick up the new release on the next `SessionStart` (rate-limited 24h).

## Things that look weird but are intentional

- Hooks are bash one-liners, not script files. This avoids needing to ship executable bits and keeps the manifest self-contained for `/plugin install`.
- The `SessionStart` event has **four separate hook entries** (auto-update kick-off, status-heartbeat kick-off, unconfigured-warning, API POST) rather than one combined command. They run independently so a failure in one doesn't suppress the others.
- `auto-update.sh` uses `nohup ... &` from the `SessionStart` hook with a 2s timeout — the hook returns immediately and the updater runs detached. Don't try to "fix" the short timeout.
- Release tarballs deliberately omit the version from the filename. The `/releases/latest/download/rogue-plugin-claude-darwin.tar.gz` URL is what `install.sh` fetches.
- `rgx!` prompt prefix is a server-side convention (false-positive escape hatch). The plugin itself doesn't parse it — the API does.
