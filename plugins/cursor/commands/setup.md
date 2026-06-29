---
name: setup
description: Set up Rogue Security AIDR integration — configure API key, detect identity, verify connection
---

# Rogue Security Setup

Help the user set up their Rogue Security AIDR integration for Cursor. Follow these steps in order.

## Step 1: Check existing configuration

Check if `~/.rogue-env` exists: `test -f ~/.rogue-env && echo exists || echo missing`.

If it exists, tell the user and ask if they want to reconfigure. If not, continue.

## Step 2: Get the API key

Ask the user for their Rogue Security API key (starts with `rsk_`). If they don't have one, direct them to https://app.rogue.security/settings/api-keys.

## Step 3: Validate the key

Run:
```bash
curl -s -o /dev/null -w "%{http_code}" -H "x-rogue-api-key: <KEY>" https://api.rogue.security/api/v1/hooks/ping
```
Expect `200`. If not, the key is invalid — ask the user to try again.

## Step 4: Detect identity

```bash
git config --global user.email
git config --global user.name
```
Show what was detected and ask if it's correct.

## Step 5: Store credentials

```bash
bash "${CURSOR_PLUGIN_ROOT}/scripts/setup.sh" "<API_KEY>" "<EMAIL>" "<NAME>"
```

## Step 6: Final instructions

Tell the user:

1. Credentials are stored in `~/.rogue-env` (mode 600).
2. **Restart Cursor** (close all windows, reopen) — hooks read credentials at session start.
3. Run `/rogue:status` to verify the connection.
4. AIDR dashboard: https://app.rogue.security/aidr
