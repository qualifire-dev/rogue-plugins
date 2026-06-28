# Rogue Security — Claude Code Plugin

Real-time AI agent detection and response (AIDR) for [Claude Code](https://claude.com/code).
Observes every prompt, tool call, permission request, and subagent — flags
prompt injections, secret exfiltration, and destructive commands before they
reach production.

## Install

One-line installer (recommended):

**macOS / Linux:**

```bash
curl -fsSL https://raw.githubusercontent.com/qualifire-dev/rogue-plugins/main/install.sh | bash
```

**Windows** (PowerShell 5.1+, run as your normal user):

```powershell
iwr -useb https://raw.githubusercontent.com/qualifire-dev/rogue-plugins/main/install.ps1 | iex
```

Pass credentials via environment variables before the one-liner when running non-interactively:

```powershell
$env:ROGUE_API_KEY='rsk_xxx'; $env:ROGUE_ACTOR_EMAIL='you@co.com'; iwr -useb https://raw.githubusercontent.com/qualifire-dev/rogue-plugins/main/install.ps1 | iex
```

The installer adds the marketplace and installs the plugin via the Claude CLI
(`claude plugin marketplace add` + `claude plugin install`), validates and writes
your API key to `~/.rogue-env` (`%USERPROFILE%\.rogue-env` on Windows), and
confirms your actor identity. On macOS/Linux it also configures a `Rogue Security`
status badge below the prompt (🟢 connected / 🔴 not set up).

Native Windows support requires no WSL or Git Bash: every hook ships both a POSIX
`sh` script and a PowerShell sibling, and exactly one runs per machine.

Manual install (inside Claude Code v2.1+):

```
/plugin marketplace add qualifire-dev/rogue-plugins
/plugin install rogue@rogue-marketplace
/rogue:setup
```

Get an API key at <https://app.rogue.security/settings/api-keys>.

## What it ships

```
.claude-plugin/plugin.json   — plugin manifest
hooks/hooks.json             — 11 lifecycle hooks; each fires an sh + a PowerShell entry
skills/setup/SKILL.md        — /rogue:setup slash command
skills/status/SKILL.md       — /rogue:status slash command
scripts/hook.sh              — POSIX-sh + curl dispatcher (macOS/Linux/WSL)
scripts/hook.ps1             — PowerShell dispatcher (native Windows)
scripts/setup.sh / setup.ps1 — credential storage helpers
```

### Hooks covered

`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
`PostToolUseFailure`, `PermissionRequest`, `Stop`, `SessionEnd`,
`SubagentStart`, `SubagentStop`, `ConfigChange`.

All hooks are `type: "command"`. Each event registers **two** entries — a POSIX
`sh` one (`hook.sh`, for macOS/Linux/WSL) and a PowerShell one (`hook.ps1`, for
native Windows) — and exactly one does real work per machine (`hook.sh` stands
down under Git Bash so the PowerShell entry owns Windows). They resolve
credentials from `${CLAUDE_PLUGIN_ROOT}/env` (bundled), `/etc/rogue/env` /
`C:\ProgramData\rogue\env` (MDM), or `~/.rogue-env` / `%USERPROFILE%\.rogue-env`
(per-user) at runtime, then POST the event payload to
`https://api.rogue.security/api/v1/hooks/claude`.

If `ROGUE_API_KEY` is empty, hooks return `{}` (allow) — fail-open by design,
so Claude Code never hangs on Rogue infrastructure issues.

## Slash commands

| Command | Purpose |
| ------- | ------- |
| `/rogue:setup` | Walks through API-key entry, identity detection, and credential storage |
| `/rogue:status` | Pings the API, fetches active rulesets, shows mode + actor identity |

## Credentials

Credentials live in **one file**: `~/.rogue-env` (mode `600`). Hooks source it
on every fire — no shell-rc patching, no environment leakage to other tools.

```
export ROGUE_API_KEY=rsk_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
export ROGUE_ACTOR_EMAIL=you@company.com
export ROGUE_ACTOR_NAME='Your Name'
```

System-wide MDM deployment can drop the same exports into `/etc/rogue/env` —
hooks check that path first.

To revoke: `rm ~/.rogue-env` (per-user) or `sudo rm /etc/rogue/env` (MDM).

## False positive escape hatch

Prepend `rgx!` to any prompt to allow it through and mark the previous
detection as a false positive in the dashboard. Per-prompt only.

## Dashboard

<https://app.rogue.security/aidr>

## Requirements

- Claude Code v2.1+
- **macOS / Linux / WSL:** POSIX `sh` and `curl` on `PATH` (both present by default)
- **Windows:** PowerShell 5.1+ (built in). No WSL or Git Bash required — the
  PowerShell dispatcher uses `Invoke-WebRequest`. `git` is needed for the
  installer (Claude clones the marketplace).

## License

Proprietary. Copyright © Qualifire, Inc. All rights reserved. See [`LICENSE`](./LICENSE).
