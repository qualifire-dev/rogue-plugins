---
description: Check Rogue Security AIDR connection status, active rulesets, and configuration
---

# Rogue Security Status

Check the current status of the Rogue Security AIDR integration. Follow these steps:

## Step 1: Check credentials

Check if `~/.rogue-env` exists:
```bash
test -f ~/.rogue-env && echo "found" || echo "missing"
```

If missing, tell the user to run `/rogue:setup` first and stop.

## Step 2: Test connection

Source the env file and ping:
```bash
. ~/.rogue-env && curl -s -w "\n%{http_code}" -H "x-rogue-api-key: $ROGUE_API_KEY" https://api.rogue.security/api/v1/hooks/ping
```

Report whether the connection succeeded (HTTP 200) or failed. If it failed, suggest running `/rogue:setup` to reconfigure.

## Step 3: Fetch configuration

If the connection succeeded, fetch the config:
```bash
. ~/.rogue-env && curl -s -H "x-rogue-api-key: $ROGUE_API_KEY" https://api.rogue.security/api/v1/hooks/config
```

Parse the JSON response and display in a clear format:

- **Mode**: `settings.mode` (enforce or monitor)
- **Fail-open**: `settings.failOpen`
- **Active rulesets**: For each ruleset in `rulesets`, show name, category, mode (block/monitor), and severity

## Step 4: Show identity

Display the current actor identity:
```bash
. ~/.rogue-env && echo "$ROGUE_ACTOR_EMAIL ($ROGUE_ACTOR_NAME)"
```

## Step 5: Summary

Present a clean summary with connection status, mode, ruleset count, and identity. If everything looks good, confirm the integration is active.

## Step 6: False-positive escape hatch

After the summary, tell the user:

> **Was a prompt blocked by mistake?** Prepend `rgx!` to your next prompt and resubmit. Rogue will allow that one prompt and mark the previous detection as a false positive in your dashboard. The override is per-prompt only — subsequent prompts go through normal evaluation.
