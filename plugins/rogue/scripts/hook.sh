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
sanitize() { printf '%s' "$1" | tr -d '\000-\037\177'; }

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

# Always log the raw response (truncated, control chars stripped) so block-
# detection bugs are diagnosable from ~/.rogue/hook.log without re-instrumenting.
log "raw=$(sanitize "$RESP" | head -c 400)"

# Cover every block-decision shape Claude Code's hook protocol uses:
#   {"decision":"block"|"Block",...}              UserPromptSubmit, Stop, etc.
#   {"continue":false,...}                        legacy block signal
#   {"permissionDecision":"deny"} (top-level)     belt-and-suspenders
#   {"hookSpecificOutput":{"permissionDecision":"deny",...}}        PreToolUse
#   {"hookSpecificOutput":{"decision":"block"|{"behavior":"deny"}}} PostToolUse / PermissionRequest
PYOUT=$(printf '%s' "$RESP" | python3 -c '
import sys, json
try:
    d = json.loads(sys.stdin.read() or "{}")
except Exception:
    print(0); print(""); sys.exit(0)

def is_block(o):
    if not isinstance(o, dict): return False
    dec = o.get("decision")
    if isinstance(dec, str) and dec.lower() == "block": return True
    if isinstance(dec, dict) and str(dec.get("behavior","")).lower() == "deny": return True
    if o.get("continue") is False: return True
    pd = o.get("permissionDecision")
    if isinstance(pd, str) and pd.lower() == "deny": return True
    hso = o.get("hookSpecificOutput")
    if isinstance(hso, dict) and is_block(hso): return True
    return False

def get_reason(o):
    if not isinstance(o, dict): return ""
    for k in ("reason","stopReason","permissionDecisionReason"):
        v = o.get(k)
        if isinstance(v, str) and v: return v
    dec = o.get("decision")
    if isinstance(dec, dict):
        for k in ("message","reason"):
            v = dec.get(k)
            if isinstance(v, str) and v: return v
    hso = o.get("hookSpecificOutput")
    if isinstance(hso, dict): return get_reason(hso)
    return ""

if is_block(d):
    r = (get_reason(d) or "prompt blocked").replace("\n"," ").replace("\r"," ")
    print(1); print(r)
else:
    print(0); print("")
' 2>/dev/null)
BLOCK=$(printf '%s' "$PYOUT" | sed -n '1p')
REASON=$(printf '%s' "$PYOUT" | sed -n '2p')

if [ "${BLOCK:-0}" = "1" ]; then
  log "outcome=block reason=\"$(sanitize "$REASON")\""
  if [ "${CLAUDE_CODE_ENTRYPOINT:-}" != "cli" ]; then
    # Background the alert so hook.sh returns immediately. Capture exit code
    # afterward so TCC denials / osascript errors are visible in the log.
    ( bash "${CLAUDE_PLUGIN_ROOT}/scripts/security-alert.sh" "Rogue Security" "$REASON" critical >/dev/null 2>&1; log "alert_rc=$? entrypoint=${CLAUDE_CODE_ENTRYPOINT:-unset}" ) &
  else
    log "alert_skipped=cli"
  fi
else
  log "outcome=allow"
fi

printf '%s' "$RESP"
