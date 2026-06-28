#!/usr/bin/env bash
# Usage: hook.sh <EventName>
# Reads one Codex hook event JSON on stdin, POSTs it to the rogue-api
# /hooks/openai route, relays the native Codex response verbatim on stdout.
# Fail-open: any failure → "{}". Logs every invocation to $ROGUE_LOG_FILE.
#
# Unlike the Claude bridge this is a PURE RELAY: no block-detection regex and no
# security-alert modal. Codex surfaces the native deny shape itself (the Claude
# modal exists only because the Claude app doesn't display the block reason).

EVENT="$1"

# Env precedence (later wins): bundled → MDM → per-user. Codex sets both
# PLUGIN_ROOT and CLAUDE_PLUGIN_ROOT; we use CLAUDE_PLUGIN_ROOT so the scripts
# stay close to the Claude variants.
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

# Surface label (codex_app | codex_cli). Codex sets no app/cli entrypoint var, so
# the installer pins ROGUE_CODEX_SURFACE per surface; default to codex_cli.
SURFACE="${ROGUE_CODEX_SURFACE:-codex_cli}"

URL="${ROGUE_API_URL:-${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/openai}"

RESP=$(curl -sS -X POST "$URL" \
  -H "x-rogue-api-key: $ROGUE_API_KEY" \
  -H "x-rogue-event: $EVENT" \
  -H "x-rogue-agent: $SURFACE" \
  -H "x-rogue-actor-email: $ROGUE_ACTOR_EMAIL" \
  -H "x-rogue-actor-name: $ROGUE_ACTOR_NAME" \
  -H 'Content-Type: application/json' \
  --data-binary @- --max-time 8 || echo '{}')

log "raw=$(sanitize "$RESP" | head -c 400)"

# Fail-open: never break a Codex session on a transport error.
if [ -z "$RESP" ]; then
  log "outcome=allow empty"
  echo '{}'
  exit 0
fi

# rogue-api already returns the correct native Codex shape; relay it verbatim.
printf '%s' "$RESP"
