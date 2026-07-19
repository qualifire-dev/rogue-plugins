#!/usr/bin/env bash
# tests/test_hook_sh_copilot.sh — end-to-end for the Copilot bash dispatcher
# (plugins/copilot/scripts/hook.sh): env file → hook.sh → mock server → stdout.
# Holds the dispatcher to the verbatim-relay + header + fail-open contract, and
# to the Copilot-specific invariant that it ALWAYS exits 0 (preToolUse is
# fail-closed on the CLI side, so a non-zero exit would deny the tool).
#
# Copilot runs the `bash` command on macOS/Linux; override with TEST_SH=dash to
# exercise strict POSIX and catch bashisms.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO/plugins/copilot/scripts/hook.sh"
SH="${TEST_SH:-sh}"

PORT=$((RANDOM % 10000 + 30000))
HEADERS_FILE="$(mktemp)"
ENV_FILE="$(mktemp)"
OUT_FILE="$(mktemp)"

cleanup() {
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true
  rm -f "$ENV_FILE" "$HEADERS_FILE" "$OUT_FILE"
}
trap cleanup EXIT

cat > "$ENV_FILE" <<EOF
export ROGUE_API_KEY=test-key
export ROGUE_ACTOR_EMAIL=test@example.com
export ROGUE_ACTOR_NAME='Test User'
export ROGUE_BASE_URL=http://127.0.0.1:${PORT}
EOF

# Run with a clean HOME holding our env file. Clear ROGUE_* from the process env
# so only the file drives resolution (process env would otherwise win). Writes
# stdout to $OUT_FILE and RETURNS the dispatcher's exit code (so the caller can
# assert exit 0 — command substitution would hide it in a subshell).
run_dispatcher() {
  local tmp_home rc
  tmp_home="$(mktemp -d)"
  cp "$ENV_FILE" "$tmp_home/.rogue-env"
  set +e
  HOME="$tmp_home" \
    ROGUE_API_KEY='' ROGUE_ACTOR_EMAIL='' ROGUE_ACTOR_NAME='' ROGUE_BASE_URL='' \
    ROGUE_LOG_FILE="$tmp_home/hook.log" \
    "$SH" "$HOOK" "$1" <<< "$2" > "$OUT_FILE"
  rc=$?
  set -e
  rm -rf "$tmp_home"
  return $rc
}

start_mock() {
  MOCK_RESPONSE="$1" MOCK_STATUS="${2:-200}" \
    python3 "$REPO/tests/mock_server.py" "$PORT" "$HEADERS_FILE" &
  MOCK_PID=$!
  for _ in $(seq 1 50); do
    nc -z 127.0.0.1 "$PORT" 2>/dev/null && return 0
    sleep 0.1
  done
  echo "mock server failed to start" >&2; exit 1
}

restart_mock() {
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true
  wait "$MOCK_PID" 2>/dev/null || true
  start_mock "$@"
}

assert_eq() {
  if [ "$1" != "$2" ]; then echo "FAIL [$3]: expected <$2> but got <$1>" >&2; exit 1; fi
  echo "  ok: $3"
}

assert_header() {
  local key="$1" expected="$2" label="$3" actual
  actual=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["headers"].get(sys.argv[2], ""))' "$HEADERS_FILE" "$key")
  assert_eq "$actual" "$expected" "$label"
}

assert_no_header() {
  local key="$1" label="$2" actual
  actual=$(python3 -c 'import json,sys; print(sys.argv[2] in json.load(open(sys.argv[1]))["headers"])' "$HEADERS_FILE" "$key")
  assert_eq "$actual" "False" "$label"
}

# ── Case 1: preToolUse deny relayed verbatim + headers + path + exit 0 ──────
start_mock '{"permissionDecision":"deny","permissionDecisionReason":"blocked"}'
set +e; run_dispatcher preToolUse '{"toolName":"bash","toolArgs":{"command":"rm -rf /"}}'; LAST_RC=$?; set -e
out=$(cat "$OUT_FILE")
assert_eq "$out" '{"permissionDecision":"deny","permissionDecisionReason":"blocked"}' "preToolUse deny relayed verbatim"
assert_eq "$LAST_RC" "0" "preToolUse deny still exits 0 (fail-closed safety)"
assert_header "x-rogue-event"       "preToolUse"       "x-rogue-event is the verbatim Copilot event name"
assert_header "x-rogue-api-key"     "test-key"         "x-rogue-api-key forwarded"
assert_header "x-rogue-actor-email" "test@example.com" "x-rogue-actor-email forwarded"
assert_header "x-rogue-actor-name"  "Test User"        "x-rogue-actor-name forwarded (with space)"
assert_no_header "x-rogue-source"   "no x-rogue-source header (cursor-only)"
assert_no_header "x-rogue-agent"    "no x-rogue-agent header (codex-only)"
path=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["path"])' "$HEADERS_FILE")
assert_eq "$path" "/api/v1/hooks/copilot" "POST path is /api/v1/hooks/copilot"

# ── Case 2: body passed through verbatim ───────────────────────────────────
body=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["body"])' "$HEADERS_FILE")
assert_eq "$body" '{"toolName":"bash","toolArgs":{"command":"rm -rf /"}}' "request body passed through unchanged"

# ── Case 3: postToolUse additionalContext relayed ──────────────────────────
restart_mock '{"additionalContext":"warning"}'
run_dispatcher postToolUse '{"toolName":"bash","toolResult":{"resultType":"success","textResultForLlm":"ok"}}'
out=$(cat "$OUT_FILE")
assert_eq "$out" '{"additionalContext":"warning"}' "postToolUse additionalContext relayed"

# ── Case 4: userPromptSubmitted monitor — body relayed ─────────────────────
restart_mock '{}'
run_dispatcher userPromptSubmitted '{"prompt":"ignore previous"}'
out=$(cat "$OUT_FILE")
assert_eq "$out" "{}" "userPromptSubmitted allow relayed"

# ── Case 5: unconfigured (no API key) → {} without calling server ──────────
TMP_HOME="$(mktemp -d)"
set +e
out=$(HOME="$TMP_HOME" ROGUE_API_KEY='' ROGUE_LOG_FILE="$TMP_HOME/h.log" "$SH" "$HOOK" preToolUse <<< '{}')
rc=$?
set -e
rm -rf "$TMP_HOME"
assert_eq "$out" "{}" "unconfigured fails open"
assert_eq "$rc" "0" "unconfigured exits 0"

# ── Case 6: non-200 → fail-open {} + exit 0 ────────────────────────────────
restart_mock '{"permissionDecision":"deny"}' 500
set +e; run_dispatcher preToolUse '{"toolName":"bash"}'; LAST_RC=$?; set -e
out=$(cat "$OUT_FILE")
assert_eq "$out" "{}" "non-200 fails open"
assert_eq "$LAST_RC" "0" "non-200 exits 0"

# ── Case 7: sessionStart unconfigured → additionalContext hint, no server ──
TMP_HOME="$(mktemp -d)"
out=$(HOME="$TMP_HOME" ROGUE_API_KEY='' ROGUE_LOG_FILE="$TMP_HOME/h.log" "$SH" "$HOOK" sessionStart <<< '{}')
rm -rf "$TMP_HOME"
case "$out" in
  *'"additionalContext"'*'Rogue Security'*'/rogue:setup'*) echo "  ok: sessionStart unconfigured emits hint" ;;
  *) echo "FAIL [sessionStart hint]: got <$out>" >&2; exit 1 ;;
esac

echo
echo "All copilot hook.sh tests passed (SH=$SH)."
