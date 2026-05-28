# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Claude Code **plugin** (not an app) that ships Rogue Security AIDR — it observes every Claude Code lifecycle event and POSTs the payload to `https://api.rogue.security/api/v1/hooks/claude` for prompt-injection / secret-exfil / destructive-command detection.

There is no build step for the plugin itself: it's a directory of JSON + shell scripts loaded by Claude Code at session start. The only "build" is `scripts/build-release.sh`, which tars the plugin tree for GitHub Releases.

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

Every hook command in `hooks.json` is a one-liner with this exact shape:

```sh
[ -r /etc/rogue/env ] && . /etc/rogue/env;
[ -r "$HOME/.rogue-env" ] && . "$HOME/.rogue-env";
[ -n "$ROGUE_API_KEY" ] || { echo '{}'; exit 0; };   # fail-open if unconfigured
curl -sS -X POST ${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/claude \
  -H "x-rogue-api-key: $ROGUE_API_KEY" \
  -H "x-rogue-event: <EventName>" \
  ... --data-binary @- --max-time 10 || echo '{}'
```

Invariants to preserve when editing hooks:

- **Source env files in this precedence order** — `/tmp/.rogue-env` (session-cached resolved actor — written by every API POST hook after resolving), then `${CLAUDE_PLUGIN_ROOT}/env` (bundled defaults for compiled-with-key distributions), then `/etc/rogue/env` (MDM), then `$HOME/.rogue-env` (per-user, written by `/rogue:setup`). Later-sourced files override earlier ones, so `/tmp` must be first (lowest priority — it's a fallback) and `~/.rogue-env` last (highest priority — explicit user intent). Never drop any of the four.
- **Every API POST hook resolves+caches actor** — after sourcing, each hook fills `ROGUE_ACTOR_EMAIL` / `ROGUE_ACTOR_NAME` from (in order) sourced env, `git config --global`, `hostname`/`whoami`, and then writes the resolved pair to `/tmp/.rogue-env` (mode 600, single-quoted, apostrophes stripped). This is what makes the compiled-with-key distribution (which ships only `${CLAUDE_PLUGIN_ROOT}/env` with the API key, no actor) attribute events without a setup step. The first hook to fire bootstraps the cache; subsequent hooks in the session source it for free.
- **Fail-open on missing key and on curl failure** — every command path must end up emitting `{}` so Claude Code is never blocked by Rogue infra. The `|| echo '{}'` at the end of the curl is load-bearing.
- **`x-rogue-event` must match the hook's key** in `hooks.json` (e.g. the `PreToolUse` hook sends `x-rogue-event: PreToolUse`). The server routes on this header.
- `UserPromptSubmit` parses the response itself (`decision == "block"` → fires `security-alert.sh` via osascript/notify-send). Every other hook relays the API response verbatim.
- Timeouts: curl uses `--max-time 10`; hook `timeout` is set 2s higher to give curl room to fail cleanly.

## Releasing

1. Bump `version` in **both** `plugins/rogue/.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` (the marketplace lists the plugin's version too — keep them in sync).
2. Commit, tag `vX.Y.Z`, push the tag. The `release.yml` workflow checks out the tag, runs `scripts/build-release.sh`, and creates the GitHub Release with the tarball.
3. `auto-update.sh` on user machines will pick up the new release on the next `SessionStart` (rate-limited 24h).

## Things that look weird but are intentional

- Hooks are bash one-liners, not script files. This avoids needing to ship executable bits and keeps the manifest self-contained for `/plugin install`.
- The `SessionStart` event has **three separate hook entries** (auto-update kick-off, unconfigured-warning, API POST) rather than one combined command. They run independently so a failure in one doesn't suppress the others.
- `auto-update.sh` uses `nohup ... &` from the `SessionStart` hook with a 2s timeout — the hook returns immediately and the updater runs detached. Don't try to "fix" the short timeout.
- Release tarballs deliberately omit the version from the filename. The `/releases/latest/download/rogue-plugin-claude-darwin.tar.gz` URL is what `install.sh` fetches.
- `rgx!` prompt prefix is a server-side convention (false-positive escape hatch). The plugin itself doesn't parse it — the API does.
