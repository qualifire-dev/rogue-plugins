#!/usr/bin/env bash
# PreToolUse hook handler.
#
# POSTs the event to the Rogue API, then optionally rewrites a "block"
# decision into Claude Code's "ask" permission flow so the user gets a
# prompt instead of a hard block.
#
# Config (read from /etc/rogue/env or ~/.rogue-env, same as creds):
#   ROGUE_PRETOOLUSE_ON_BLOCK=ask    (default) — translate block → ask
#   ROGUE_PRETOOLUSE_ON_BLOCK=block             — pass through verbatim
#                                                  (legacy hard-block)
#
# Fail-open everywhere: missing key, curl failure, malformed JSON, or
# python parse failure all emit `{}` so Claude Code is never stuck on
# Rogue infra.

set -u

[ -r "${CLAUDE_PLUGIN_ROOT}/env" ] && . "${CLAUDE_PLUGIN_ROOT}/env"
[ -r /etc/rogue/env ] && . /etc/rogue/env
[ -r "$HOME/.rogue-env" ] && . "$HOME/.rogue-env"

if [ -z "${ROGUE_API_KEY:-}" ]; then
  echo '{}'
  exit 0
fi

BASE_URL="${ROGUE_BASE_URL:-https://api.rogue.security}"

RESP=$(curl -sS -X POST "$BASE_URL/api/v1/hooks/claude" \
  -H "x-rogue-api-key: $ROGUE_API_KEY" \
  -H "x-rogue-event: PreToolUse" \
  -H "x-rogue-actor-email: ${ROGUE_ACTOR_EMAIL:-}" \
  -H "x-rogue-actor-name: ${ROGUE_ACTOR_NAME:-}" \
  -H 'Content-Type: application/json' \
  --data-binary @- --max-time 10 2>/dev/null) || RESP=''

[ -z "$RESP" ] && RESP='{}'

printf '%s' "$RESP" | ROGUE_PRETOOLUSE_ON_BLOCK="${ROGUE_PRETOOLUSE_ON_BLOCK:-ask}" python3 -c '
import json, os, sys

# Only the exact string "block" opts back into legacy hard-block.
# Anything else (including unset, typos, "Ask", "") → ask mode.
mode = (os.environ.get("ROGUE_PRETOOLUSE_ON_BLOCK") or "ask").strip().lower()
translate = (mode != "block")

raw = sys.stdin.read() or "{}"
try:
    data = json.loads(raw)
except Exception:
    sys.stdout.write("{}")
    sys.exit(0)

if not isinstance(data, dict):
    sys.stdout.write(raw)
    sys.exit(0)

is_block = (data.get("decision") == "block") or (data.get("continue") is False)

if translate and is_block:
    reason = (
        data.get("reason")
        or data.get("stopReason")
        or "Rogue Security flagged this tool call"
    )
    # Strip legacy hard-block fields and route via the permission system.
    out = {k: v for k, v in data.items() if k not in ("decision", "continue", "stopReason")}
    out["hookSpecificOutput"] = {
        "hookEventName": "PreToolUse",
        "permissionDecision": "ask",
        "permissionDecisionReason": reason,
    }
    sys.stdout.write(json.dumps(out))
else:
    sys.stdout.write(raw)
' 2>/dev/null || printf '%s' "$RESP"
