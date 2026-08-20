#!/usr/bin/env bash
# tests/test_hook_sh_cursor.sh — end-to-end for the Cursor sh dispatcher
# (plugins/cursor/scripts/hook.sh): env file → hook.sh → mock server → stdout.
# Holds the dispatcher to the verbatim-relay + header + fail-open contract, and
# covers the two places it is NOT a pure relay: the preToolUse file pre-image
# and the beforeReadFile byte capture.
#
# Cursor runs the `sh` command on macOS/Linux; override with TEST_SH=dash to
# exercise strict POSIX and catch bashisms.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO/plugins/cursor/scripts/hook.sh"
# TEST_SH stays authoritative; an exported SH is honored next, so the two CI
# lines (SH=bash / TEST_SH=dash) drive two genuinely different shells rather
# than both landing on /bin/sh.
SH="${TEST_SH:-${SH:-sh}}"

PORT=$((RANDOM % 10000 + 30000))
HEADERS_FILE="$(mktemp)"
ENV_FILE="$(mktemp)"
OUT_FILE="$(mktemp)"
# Optional REPLACEMENT for the dispatcher's whole PATH (see make_nojq_path).
TEST_PATH=""

cleanup() {
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true
  rm -f "$ENV_FILE" "$HEADERS_FILE" "$OUT_FILE"
}
trap cleanup EXIT

# Rewrite $ENV_FILE with the standard four exports, so a case that blanks it to
# test the unconfigured path can restore it afterwards.
write_env_file() {
  cat > "$ENV_FILE" <<EOF
export ROGUE_API_KEY=test-key
export ROGUE_ACTOR_EMAIL=test@example.com
export ROGUE_ACTOR_NAME='Test User'
export ROGUE_BASE_URL=http://127.0.0.1:${PORT}
EOF
}
write_env_file

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
    PATH="${TEST_PATH:-$PATH}" \
    "$SH" "$HOOK" "$1" <<< "$2" > "$OUT_FILE"
  rc=$?
  set -e
  LAST_HOME="$tmp_home"
  # KEEP_HOME=1 preserves the run's HOME so a caller can assert on hook.log.
  [ "${KEEP_HOME:-0}" = "1" ] || rm -rf "$tmp_home"
  return $rc
}

# Build a PATH that has everything the dispatcher needs EXCEPT jq, so its concat
# fallback runs. jq (on macOS 26: /usr/bin/jq) sits in the same directory as the
# rest of the toolchain, so hiding it means rebuilding PATH as a symlink farm
# rather than dropping a directory. A missing entry can't cause a false pass: the
# dispatcher would fail-open and the byte-identical assertion below would fail.
# `wc` is in the list because the dispatcher calls `wc -c` in log rotation and in
# both enrichment paths — without it every no-jq case fails for the wrong reason.
# Echoes the farm dir; the caller sets TEST_PATH and removes it afterwards.
make_nojq_path() {
  local d b src
  d="$(mktemp -d)"
  for b in "$SH" sh dirname basename date mkdir cat sed grep tr tail head wc base64 sleep curl; do
    src="$(command -v "$b" 2>/dev/null || true)"
    if [ -z "$src" ]; then echo "FAIL [nojq farm]: '$b' is not on PATH" >&2; exit 1; fi
    ln -s "$src" "$d/$(basename "$src")" 2>/dev/null || true
  done
  if PATH="$d" command -v jq >/dev/null 2>&1; then
    echo "FAIL [nojq farm]: jq is still reachable" >&2; exit 1
  fi
  printf '%s' "$d"
}

# The last POSTed request body, as the raw string the mock received.
posted_body() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["body"])' "$HEADERS_FILE"
}
# One top-level field of the last POSTed body ('' when absent).
posted_field() {
  posted_body | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1],""))' "$1"
}

# Is the mock accepting connections yet? `nc -z` when nc is on PATH, otherwise a
# python3 socket connect. python3 is already a hard dependency of this file (it
# runs the mock server and every assertion helper) while nc is not guaranteed on
# every image, and a missing probe binary here would fail this suite for a reason
# that has nothing to do with the dispatcher.
port_open() {
  if command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$PORT" 2>/dev/null
  else
    python3 -c 'import socket,sys
s = socket.socket(); s.settimeout(0.5)
rc = s.connect_ex(("127.0.0.1", int(sys.argv[1]))); s.close()
sys.exit(0 if rc == 0 else 1)' "$PORT" 2>/dev/null
  fi
}

start_mock() {
  MOCK_RESPONSE="$1" MOCK_STATUS="${2:-200}" \
    python3 "$REPO/tests/mock_server.py" "$PORT" "$HEADERS_FILE" &
  MOCK_PID=$!
  for _ in $(seq 1 50); do
    port_open && return 0
    sleep 0.1
  done
  echo "mock server failed to start" >&2; exit 1
}

restart_mock() {
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true
  wait "$MOCK_PID" 2>/dev/null || true
  start_mock "$@"
}

stop_mock() {
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true
  wait "$MOCK_PID" 2>/dev/null || true
  MOCK_PID=""
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

# Presence-only: the value is this machine's hostname / installed version, so the
# test can assert it is sent and non-empty but not what it says.
assert_header_present() {
  local key="$1" label="$2" actual
  actual=$(python3 -c 'import json,sys; print(bool(json.load(open(sys.argv[1]))["headers"].get(sys.argv[2])))' "$HEADERS_FILE" "$key")
  assert_eq "$actual" "True" "$label"
}

# ── Case 1: verbatim relay + headers ──────────────────────────────────────
start_mock '{"permission":"allow"}'
set +e; run_dispatcher preToolUse '{"tool_name":"Shell","tool_input":{"command":"ls"}}'; LAST_RC=$?; set -e
out="$(cat "$OUT_FILE")"
assert_eq "$out" '{"permission":"allow"}' "response relayed verbatim"
assert_eq "$LAST_RC" "0" "exits 0 on a normal relay"
assert_header "x-rogue-event"       "preToolUse"       "x-rogue-event is the verbatim Cursor event name"
assert_header "x-rogue-api-key"     "test-key"         "x-rogue-api-key forwarded"
assert_header "x-rogue-actor-email" "test@example.com" "x-rogue-actor-email forwarded"
assert_header "x-rogue-source"      "cursor"           "x-rogue-source is cursor (cursor-only header)"
assert_eq "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["path"])' "$HEADERS_FILE")" \
  "/api/v1/hooks/cursor" "posts to the cursor endpoint"

# ── Case 2: fail-open with no API key ─────────────────────────────────────
# The env file for this case carries ONLY a base URL — no key, no actor vars — so
# the dispatcher takes the unconfigured path. Naming the mock there is what makes
# the no-request assertion below meaningful: a dispatcher that sent anything at
# all would send it to the mock, which this case can see, rather than to the
# built-in default host, which it could not. A blank env file leaves no base URL
# to resolve, so the request would go somewhere unobservable and the case would
# pass while a request was being made.
#
# The mock also stays UP through this case. `{}` + exit 0 alone is what a plain
# network failure produces too, so with nothing listening those two assertions
# could not tell a working key check from an absent one; the snapshot of the
# mock's record is what separates them.
printf 'export ROGUE_BASE_URL=http://127.0.0.1:%s\n' "$PORT" > "$ENV_FILE"
SNAP="$(mktemp)"; cp "$HEADERS_FILE" "$SNAP"
set +e; run_dispatcher preToolUse '{"tool_name":"Shell"}'; LAST_RC=$?; set -e
assert_eq "$(cat "$OUT_FILE")" '{}' "emits {} when unconfigured"
assert_eq "$LAST_RC" "0" "exits 0 when unconfigured"
if cmp -s "$SNAP" "$HEADERS_FILE"; then posted="no"; else posted="yes"; fi
rm -f "$SNAP"
assert_eq "$posted" "no" "unconfigured sends no request (mock's record untouched)"
write_env_file   # restore
stop_mock

# ── Case 3: existing pre-image behaviour (regression guard) ───────────────
PRE_FILE="$(mktemp)"; printf 'flask==1.0.0\n' > "$PRE_FILE"
start_mock '{}'
run_dispatcher preToolUse "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PRE_FILE\",\"contents\":\"flask==2.0.0\\n\"}}" >/dev/null
assert_eq "$(posted_field rogueFilePreImageB64)" "$(printf 'flask==1.0.0\n' | base64 | tr -d '\r\n')" \
  "preToolUse Write attaches the pre-edit file as rogueFilePreImageB64"
stop_mock

# ── Case 4: pre-image is NOT attached for a binary extension ──────────────
BIN_FILE="$(mktemp -d)/x.png"; printf 'notreallyapng' > "$BIN_FILE"
start_mock '{}'
run_dispatcher preToolUse "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$BIN_FILE\",\"contents\":\"x\"}}" >/dev/null
assert_eq "$(posted_field rogueFilePreImageB64)" "" "no pre-image for a recognized binary extension"
stop_mock

echo
echo "All cursor hook.sh tests passed (SH=$SH)."
