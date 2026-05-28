#!/usr/bin/env bash
# Usage: hook.sh <EventName>
# Reads JSON payload on stdin, POSTs to Rogue, relays response. Fail-open: any failure → "{}".

EVENT="$1"

[ -r /tmp/.rogue-env ]              && . /tmp/.rogue-env
[ -r "${CLAUDE_PLUGIN_ROOT}/env" ]  && . "${CLAUDE_PLUGIN_ROOT}/env"
[ -r /etc/rogue/env ]               && . /etc/rogue/env
[ -r "$HOME/.rogue-env" ]           && . "$HOME/.rogue-env"

[ -n "${ROGUE_API_KEY:-}" ] || { echo '{}'; exit 0; }

. "${CLAUDE_PLUGIN_ROOT}/scripts/actor.sh"

RESP=$(curl -sS -X POST "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/claude" \
  -H "x-rogue-api-key: $ROGUE_API_KEY" \
  -H "x-rogue-event: $EVENT" \
  -H "x-rogue-actor-email: $ROGUE_ACTOR_EMAIL" \
  -H "x-rogue-actor-name: $ROGUE_ACTOR_NAME" \
  -H 'Content-Type: application/json' \
  --data-binary @- --max-time 10 || echo '{}')

BLOCK=$(printf '%s' "$RESP" | python3 -c '
import sys, json
d = json.loads(sys.stdin.read() or "{}")
print(1 if d.get("decision") == "block" or d.get("continue") is False else 0)
' 2>/dev/null || echo 0)

if [ "$BLOCK" = "1" ] && [ "${CLAUDE_CODE_ENTRYPOINT:-}" != "cli" ]; then
  REASON=$(printf '%s' "$RESP" | python3 -c '
import sys, json
d = json.loads(sys.stdin.read() or "{}")
print(d.get("reason") or d.get("stopReason") or "prompt blocked")
' 2>/dev/null)
  ( bash "${CLAUDE_PLUGIN_ROOT}/scripts/security-alert.sh" "Rogue Security" "$REASON" critical >/dev/null 2>&1 & )
fi

printf '%s' "$RESP"
