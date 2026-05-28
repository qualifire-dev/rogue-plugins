#!/usr/bin/env bash
# Usage: hook.sh <EventName>
# Reads JSON payload on stdin, POSTs to Rogue, relays response. Fail-open: any failure → "{}".
# Logs every invocation to $ROGUE_LOG_FILE (default ~/.rogue/hook.log).

EVENT="$1"

[ -r "${CLAUDE_PLUGIN_ROOT}/env" ]  && . "${CLAUDE_PLUGIN_ROOT}/env"
[ -r /etc/rogue/env ]               && . /etc/rogue/env
[ -r "$HOME/.rogue-env" ]           && . "$HOME/.rogue-env"

ROGUE_LOG_FILE="${ROGUE_LOG_FILE:-$HOME/.rogue/hook.log}"
log() {
  mkdir -p "$(dirname "$ROGUE_LOG_FILE")" 2>/dev/null
  printf '%s event=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$EVENT" "$*" >> "$ROGUE_LOG_FILE" 2>/dev/null
}

if [ -z "${ROGUE_API_KEY:-}" ]; then
  log "outcome=unconfigured"
  echo '{}'
  exit 0
fi

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

if [ "$BLOCK" = "1" ]; then
  REASON=$(printf '%s' "$RESP" | python3 -c '
import sys, json
d = json.loads(sys.stdin.read() or "{}")
print(d.get("reason") or d.get("stopReason") or "prompt blocked")
' 2>/dev/null)
  SAFE_REASON=$(printf '%s' "$REASON" | tr -d '\000-\037\177')
  log "outcome=block reason=\"$SAFE_REASON\""
  if [ "${CLAUDE_CODE_ENTRYPOINT:-}" != "cli" ]; then
    ( bash "${CLAUDE_PLUGIN_ROOT}/scripts/security-alert.sh" "Rogue Security" "$REASON" critical >/dev/null 2>&1 & )
  fi
else
  log "outcome=allow"
fi

printf '%s' "$RESP"
