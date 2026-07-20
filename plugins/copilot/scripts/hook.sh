#!/usr/bin/env bash
# Rogue Security hook bridge for GitHub Copilot CLI — bash implementation.
# Usage: hook.sh <eventName>   (any of Copilot's 14 hook events)
#
# Reads one Copilot hook event JSON on stdin, POSTs it to the rogue-api
# /hooks/copilot route, and relays the native Copilot decision verbatim on
# stdout. PURE RELAY: no block-detection regex, no local modal — Copilot renders
# the native deny shape ({"permissionDecision":"deny",...}) itself. The only
# stdin enrichment is agentStop/subagentStop, which append the transcript tail
# (see augment_with_transcript) so the backend can read the final message.
#
# Copilot selects the `bash` command on macOS/Linux and the `powershell` command
# on Windows (see hooks.json), so — unlike the Claude bridge — there is no
# exactly-one-runs arbitration and no Git-Bash stand-down: exactly one script
# runs per platform, chosen by Copilot.
#
# FAIL-OPEN IS SAFETY-CRITICAL HERE. Copilot's preToolUse hook is fail-CLOSED: a
# non-zero exit (or exit 2) DENIES the tool call. So this script MUST always
# `exit 0` and emit `{}` on any error (missing key, network failure, non-200,
# empty body). Never `set -e`; never let curl propagate a non-zero exit. A block
# is carried in the relayed JSON body on stdout, never via the exit code.
#
# Credential resolution (later file wins; process env wins over all):
#   1. ${PLUGIN_ROOT}/env        (baked into a compiled customer plugin)
#   2. /etc/rogue/env            (MDM-provisioned)
#   3. $HOME/.rogue-env          (per-user / installer-written)

EVENT="$1"

# Self-locate the plugin root from $0 (the path Copilot invoked us with:
# <root>/scripts/hook.sh). Fall back to the env token if that ever fails.
PLUGIN_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd)"
[ -n "$PLUGIN_ROOT" ] || PLUGIN_ROOT="${COPILOT_PLUGIN_ROOT:-${PLUGIN_ROOT:-.}}"

# Env precedence (later wins): bundled → MDM → per-user.
[ -r "${PLUGIN_ROOT}/env" ] && . "${PLUGIN_ROOT}/env"
[ -r /etc/rogue/env ]       && . /etc/rogue/env
[ -r "$HOME/.rogue-env" ]   && . "$HOME/.rogue-env"

ROGUE_LOG_FILE="${ROGUE_LOG_FILE:-$HOME/.rogue/hook.log}"
log() {
  mkdir -p "$(dirname "$ROGUE_LOG_FILE")" 2>/dev/null
  printf '%s provider=github_copilot event=%s %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$EVENT" "$*" >> "$ROGUE_LOG_FILE" 2>/dev/null
}
sanitize() { printf '%s' "$1" | tr -d '\000-\037\177'; }

# agentStop / subagentStop carry no message content inline — only a
# transcriptPath pointing at the session's events.jsonl. Append the last ~256KB
# of that file, base64-encoded, as "transcriptTailB64" so the backend can extract
# the final assistant reply / subagent message. base64 output has no JSON-special
# characters, so appending it by re-closing the object is safe. Fail-open: any
# problem (no path, unreadable, empty) returns the body unchanged.
# $1 = original JSON body; echoes the (possibly augmented) body.
# The agentStop/subagentStop hook fires as soon as Copilot decides the turn
# ended, which can be BEFORE it has flushed the turn's final assistant.message
# line to events.jsonl (observed ~5-50ms lag). A naive tail then captures a
# stale transcript missing the very reply we need to evaluate — the reply is
# silently dropped. File appends are ordered, so once the turn's closing
# "assistant.turn_end" line is on disk, every earlier line of the turn (incl.
# the final assistant.message) is too. Poll (bounded) until the last non-hook
# line is an assistant.turn_end. Our own agentStop hook.start/hook.end lines are
# excluded so they can't be mistaken for the turn boundary. Fail-open: on
# timeout we proceed with whatever is on disk.
# $1 = transcript path.
wait_for_transcript_flush() {
  _wtp="$1"
  _n=0
  # ~5s cap (50 * 0.1s), well inside the 30s hook budget. This covers the disk
  # FLUSH lag between Copilot writing the completed assistant.message line and
  # our read (~5-64ms observed) — NOT streaming time: agentStop fires only after
  # the turn completes, so the message is already written when we poll. The gap
  # is generous purely for slow/loaded disks. ROGUE_FLUSH_WAIT_ITERS overrides
  # the count (tests set it low to exercise the fail-open path).
  _max=${ROGUE_FLUSH_WAIT_ITERS:-50}
  while [ "$_n" -lt "$_max" ]; do   # the happy path returns in 0-1 iters
    _last=$(tail -c 262144 "$_wtp" 2>/dev/null | grep -v '"hook\.' | grep -v '^[[:space:]]*$' | tail -1)
    case "$_last" in
      *'"assistant.turn_end"'*) return 0 ;;
    esac
    sleep 0.1
    _n=$((_n + 1))
  done
  return 0
}

augment_with_transcript() {
  _body="$1"
  _tp=$(printf '%s' "$_body" | sed -n 's/.*"transcriptPath":"\([^"]*\)".*/\1/p')
  [ -n "$_tp" ] || { printf '%s' "$_body"; return; }
  [ -r "$_tp" ] || { printf '%s' "$_body"; return; }
  wait_for_transcript_flush "$_tp"
  _b64=$(tail -c 262144 "$_tp" 2>/dev/null | base64 2>/dev/null | tr -d '\r\n')
  [ -n "$_b64" ] || { printf '%s' "$_body"; return; }
  printf '%s,"transcriptTailB64":"%s"}' "${_body%\}}" "$_b64"
}

# Not configured: emit the SessionStart hint (so the user knows to run setup) or a
# clean allow for every other event. Never POST without a key.
if [ -z "${ROGUE_API_KEY:-}" ]; then
  log "outcome=unconfigured"
  if [ "$EVENT" = "sessionStart" ]; then
    printf '{"additionalContext":"[Rogue Security] Not configured. Run /rogue:setup to connect your API key."}'
  else
    echo '{}'
  fi
  exit 0
fi

[ -r "${PLUGIN_ROOT}/scripts/actor.sh" ] && . "${PLUGIN_ROOT}/scripts/actor.sh"

URL="${ROGUE_API_URL:-${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/copilot}"

# Buffer stdin so we can enrich it (agentStop/subagentStop) before POSTing.
BODY="$(cat)"
case "$EVENT" in
  agentStop|subagentStop) BODY="$(augment_with_transcript "$BODY")" ;;
esac

# Capture body + HTTP status. -w appends a final line "<code>"; on any transport
# failure curl exits non-zero and the code is 000. Relay the body ONLY on a clean
# HTTP 200 so an error page (401/404/500) is never handed to Copilot as a decision.
RAW=$(printf '%s' "$BODY" | curl -sS -X POST "$URL" \
  -H "x-rogue-api-key: $ROGUE_API_KEY" \
  -H "x-rogue-event: $EVENT" \
  -H "x-rogue-actor-email: $ROGUE_ACTOR_EMAIL" \
  -H "x-rogue-actor-name: $ROGUE_ACTOR_NAME" \
  -H 'Content-Type: application/json' \
  --data-binary @- --max-time 15 -w '\n%{http_code}')
RC=$?
CODE=$(printf '%s' "$RAW" | tail -n1)
BODY=$(printf '%s' "$RAW" | sed '$d')

log "http=$CODE rc=$RC raw=$(sanitize "$BODY" | head -c 400)"

# Fail-open on transport error or any non-200: emit a clean allow.
if [ "$RC" -ne 0 ] || [ "$CODE" != "200" ] || [ -z "$BODY" ]; then
  log "outcome=allow http=$CODE rc=$RC"
  echo '{}'
  exit 0
fi

# rogue-api already returns the correct native Copilot shape (allow "{}" for
# audit-only events like sessionStart); relay it verbatim.
printf '%s' "$BODY"
exit 0
