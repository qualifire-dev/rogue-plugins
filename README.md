# Rogue Security — Claude Code Plugin

Real-time AI agent detection and response (AIDR) for [Claude Code](https://claude.com/code).
Observes every prompt, tool call, permission request, and subagent — flags
prompt injections, secret exfiltration, and destructive commands before they
reach production.

## Install

One-line installer (recommended):

```bash
curl -fsSL https://raw.githubusercontent.com/qualifire-dev/rogue-install/main/install.sh | bash
```

The installer downloads this plugin into Claude Code's plugin cache, enables it
in `~/.claude/settings.json`, and writes credentials to `~/.rogue-env`.

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

## Tool-call enforcement mode

By default, when Rogue flags a tool call (`PreToolUse`), the plugin routes
the detection through Claude Code's permission prompt instead of hard-
blocking — you see the reason and decide. Override in `~/.rogue-env`:

```
export ROGUE_PRETOOLUSE_ON_BLOCK=ask    # default — surface as a permission prompt
export ROGUE_PRETOOLUSE_ON_BLOCK=block  # legacy hard-block, no user prompt
```

Only `PreToolUse` is affected — `UserPromptSubmit` blocks remain hard
blocks (no permission UI applies to prompt submission).

## Dashboard

<https://app.rogue.security/aidr>

## Requirements

- Claude Code v2.1+
- `curl` on `PATH` (every hook uses it)

## License

Proprietary. Copyright © Qualifire, Inc. All rights reserved. See [`LICENSE`](./LICENSE).
