---
description: Set up Rogue Security AIDR integration — configure API key, detect identity, and verify connection
---

# Rogue Security Setup (Codex)

Help the user set up their Rogue Security AIDR integration for OpenAI Codex. Follow these steps in order:

## Step 1: Check existing configuration

Check if `~/.rogue-env` exists with `test -f ~/.rogue-env && echo "exists" || echo "not found"`.

If already configured, tell the user and ask if they want to reconfigure. If not, continue.

## Step 2: Get the API key

Ask the user for their Rogue Security API key. It should start with `rsk_`.

If they don't have one, direct them to generate one at: https://app.rogue.security/settings/api-keys

## Step 3: Validate the API key

Read the key into a shell variable first (don't paste the literal key into the
command — it would leak into shell history and process listings), then validate:
```bash
read -rs ROGUE_API_KEY   # paste the key at the prompt; not echoed, not in history
curl -s -o /dev/null -w "%{http_code}" -H "x-rogue-api-key: $ROGUE_API_KEY" https://api.rogue.security/api/v1/hooks/ping
```

If the response is not `200`, tell the user the key is invalid and ask them to try again.

## Step 4: Detect identity

Run `git config user.email` and `git config user.name` to detect the user's git identity. Show what was detected and ask if it's correct.

## Step 5: Store credentials

Run the setup script with the API key, email, name, and surface. Use `codex_app` if
running inside the Codex desktop app, otherwise `codex_cli`:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" "<API_KEY>" "<EMAIL>" "<NAME>" "codex_cli"
```

This writes `~/.rogue-env` (mode 600). Hooks source this file at runtime — no shell profile changes needed.

## Step 6: Trust the hooks (REQUIRED for Codex)

Codex **skips command hooks until they are trusted**. Tell the user:

1. Open `/hooks` in Codex
2. Review and **trust** the Rogue Security hook entries

Until this is done, no events are sent. (Trust is recorded against the hook
definition; script-only plugin updates keep the same hook definition, so this is
a one-time step.)

## Step 7: Final instructions

Tell the user:

1. Credentials are stored in `~/.rogue-env` with restricted permissions (mode 600)
2. **Restart Codex** so the plugin loads the credentials
3. After restarting (and trusting via `/hooks`), run `/rogue:status` to verify
4. The AIDR dashboard is at https://app.rogue.security/aidr
