# Rogue Security — Claude Code Plugin

Real-time AI agent detection and response (AIDR) for [Claude Code](https://claude.com/code).
Observes every prompt, tool call, permission request, and subagent — flags
prompt injections, secret exfiltration, and destructive commands before they
reach production.

## Install

One-line installer (recommended):

```bash
curl -fsSL https://raw.githubusercontent.com/qualifire-dev/rogue-plugin-claude/main/install.sh | bash
```

The installer adds the marketplace and installs the plugin via the Claude CLI
(`claude plugin marketplace add` + `claude plugin install`), validates and writes
your API key to `~/.rogue-env`, confirms your actor identity, and configures a
`Rogue Security` status badge below the prompt (🟢 connected / 🔴 not set up).

Manual install (inside Claude Code v2.1+):

```
/plugin marketplace add qualifire-dev/rogue-plugin-claude
/plugin install rogue@rogue-marketplace
/rogue:setup
```

Get an API key at <https://app.rogue.security/settings/api-keys>.

## What it ships

```
.claude-plugin/plugin.json   — plugin manifest
hooks/hooks.json             — 12 command-based lifecycle hooks
commands/setup.md            — /rogue:setup slash command
commands/status.md           — /rogue:status slash command
scripts/setup.sh             — credential storage helper
```

### Hooks covered

`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
`PostToolUseFailure`, `PermissionRequest`, `Stop`, `SessionEnd`,
`SubagentStart`, `SubagentStop`, `InstructionsLoaded`, `ConfigChange`.

All hooks are `type: "command"`. They source credentials from `/etc/rogue/env`
(system-wide, for MDM) or `~/.rogue-env` (per-user) at runtime, then POST the
event payload to `https://api.rogue.security/api/v1/hooks/claude`.

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
- `curl` on `PATH` (every hook uses it)

## License

Proprietary. Copyright © Qualifire, Inc. All rights reserved. See [`LICENSE`](./LICENSE).
