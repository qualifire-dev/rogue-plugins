#!/usr/bin/env bash
# Rogue Security — generic hook runner.
#
# Called from every API-POST entry in hooks.json. Reads the hook event JSON
# payload from stdin, POSTs it to the Rogue API, surfaces a desktop alert
# if the response signals a block, and relays the API response verbatim
# on stdout so Claude Code can act on `decision` / `systemMessage` fields.
#
# Usage:
#     bash "${CLAUDE_PLUGIN_ROOT}/scripts/hook.sh" <EventName>
#
# Example hooks.json entry:
#     {
#       "type": "command",
#       "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/hook.sh\" PreToolUse",
#       "timeout": 12
#     }
#
# Fail-open invariant: every code path must end with `{}` (or the API
# response) on stdout so Claude Code is never blocked by Rogue infra
# being unreachable, misconfigured, or slow.
#
# Env file precedence (low → high, later sources override earlier ones):
#   1. /tmp/.rogue-env             (session-cached actor — actor.sh writes this)
#   2. ${CLAUDE_PLUGIN_ROOT}/env   (bundled defaults for compiled distributions)
#   3. /etc/rogue/env              (MDM / system-wide)
#   4. $HOME/.rogue-env            (per-user, written by /rogue:setup)

# --- arg parse ------------------------------------------------------------
# EVENT="${1:?Usage: hook.sh <EventName>}"

# --- source env files in precedence order ---------------------------------
# /tmp/.rogue-env → ${CLAUDE_PLUGIN_ROOT}/env → /etc/rogue/env → ~/.rogue-env

# --- fail-open if unconfigured --------------------------------------------
# [ -n "${ROGUE_API_KEY:-}" ] || { echo '{}'; exit 0; }

# --- resolve + cache actor -------------------------------------------------
# . "${CLAUDE_PLUGIN_ROOT}/scripts/actor.sh"

# --- POST event to API -----------------------------------------------------
# curl -sS -X POST $base/api/v1/hooks/claude
#   -H x-rogue-api-key       -H x-rogue-event
#   -H x-rogue-actor-email   -H x-rogue-actor-name
#   --data-binary @-  --max-time 10
# Capture into $RESP; fail-open via `|| echo '{}'`.

# --- detect block decision -------------------------------------------------
# Parse $RESP with python3:
#   block iff d.get("decision") == "block" OR d.get("continue") is False

# --- on block: fire desktop alert (background, non-blocking) --------------
# Extract REASON (d.get("reason") or d.get("stopReason") or "prompt blocked").
# Skip alert when CLAUDE_CODE_ENTRYPOINT == "cli" (terminal sessions get
# the reason via the response body, no modal needed).
# Delegate to security-alert.sh in the background:
#   bash "${CLAUDE_PLUGIN_ROOT}/scripts/security-alert.sh" \
#     "Rogue Security" "$REASON" critical &

# --- emit response ---------------------------------------------------------
# printf '%s' "$RESP"
