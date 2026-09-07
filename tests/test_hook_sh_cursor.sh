#!/usr/bin/env bash
# End-to-end for the Cursor sh dispatcher (plugins/cursor/scripts/hook.sh):
# env file, hook.sh, mock server, stdout.
#
# Cursor runs the `sh` command on macOS/Linux. TEST_SH=dash exercises strict
# POSIX and catches bashisms.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO/plugins/cursor/scripts/hook.sh"
# TEST_SH wins, then an exported SH, so the two CI lines drive two shells.
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
  # Fixtures appear as the cases run, so each needs a :- guard for an earlier
  # exit. Case 10's over-cap file alone is 1 MiB.
  [ -n "${PDF_DIR:-}" ] && rm -rf "$PDF_DIR" || true
  [ -n "${BIN_DIR:-}" ] && rm -rf "$BIN_DIR" || true
  [ -n "${PRE_FILE:-}" ] && rm -f "$PRE_FILE" || true
}
trap cleanup EXIT

# Case 2 blanks $ENV_FILE to test the unconfigured path, then restores it.
write_env_file() {
  cat > "$ENV_FILE" <<EOF
export ROGUE_API_KEY=test-key
export ROGUE_ACTOR_EMAIL=test@example.com
export ROGUE_ACTOR_NAME='Test User'
export ROGUE_BASE_URL=http://127.0.0.1:${PORT}
EOF
}
write_env_file

# Run with a clean HOME holding our env file, and ROGUE_* cleared from the
# process env so only the file drives resolution. Writes stdout to $OUT_FILE and
# RETURNS the exit code; command substitution would hide it in a subshell.
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

# A PATH with everything the dispatcher needs except jq, so its concat fallback
# runs. jq sits in the same directory as the rest of the toolchain, so hiding it
# means a symlink farm rather than dropping a directory. `wc` is listed because
# the dispatcher calls `wc -c` in log rotation and both enrichments. Echoes the
# farm dir; the caller sets TEST_PATH and removes it afterwards.
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
# Is a top-level field PRESENT ('yes'/'no')? Absence assertions need this:
# posted_field answers '' both for an absent key and for an empty value, so it
# cannot fail against a dispatcher that attaches an empty one.
posted_has_field() {
  posted_body | python3 -c 'import json,sys; print("yes" if sys.argv[1] in json.load(sys.stdin) else "no")' "$1"
}

# Is the mock accepting connections yet? nc when it is on PATH, else a python3
# socket connect. python3 is already a hard dependency here, nc is not.
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

# Presence-only: the value is this machine's hostname or installed version.
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
# The env file carries ONLY a base URL, so a dispatcher that sent anything would
# send it to the mock, where this case can see it. A blank file leaves no base
# URL and the request would go somewhere unobservable. The mock also stays up:
# `{}` + exit 0 is what a network failure produces too, so only the snapshot
# separates a working key check from an absent one.
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
BIN_DIR="$(mktemp -d)"; BIN_FILE="$BIN_DIR/x.png"; printf 'notreallyapng' > "$BIN_FILE"
start_mock '{}'
run_dispatcher preToolUse "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$BIN_FILE\",\"contents\":\"x\"}}" >/dev/null
assert_eq "$(posted_field rogueFilePreImageB64)" "" "no pre-image for a recognized binary extension"
stop_mock

# ── Case 5: beforeReadFile with empty content attaches the file bytes ─────
PDF_DIR="$(mktemp -d)"; PDF_FILE="$PDF_DIR/spec.pdf"
printf '%%PDF-1.4 hello pdf bytes\n' > "$PDF_FILE"
start_mock '{}'
run_dispatcher beforeReadFile "{\"content\":\"\",\"file_path\":\"$PDF_FILE\",\"attachments\":[]}" >/dev/null
assert_eq "$(posted_field rogueFileReadB64)" "$(base64 < "$PDF_FILE" | tr -d '\r\n')" \
  "beforeReadFile with empty content attaches the pdf bytes"
stop_mock

# ── Case 6: an svg is captured too ────────────────────────────────────────
SVG_FILE="$PDF_DIR/logo.svg"; printf '<svg><desc>hi</desc></svg>\n' > "$SVG_FILE"
start_mock '{}'
run_dispatcher beforeReadFile "{\"content\":\"\",\"file_path\":\"$SVG_FILE\"}" >/dev/null
assert_eq "$(posted_field rogueFileReadB64)" "$(base64 < "$SVG_FILE" | tr -d '\r\n')" \
  "an svg read is captured"
stop_mock

# ── Case 7: the extension match is case-insensitive ──────────────────────
# Nothing else here exercises the lowercasing: with only lowercase fixtures,
# deleting the `tr` would leave every other case green. The name differs from
# Case 5's so the two cannot alias on a case-insensitive filesystem.
UPPER_FILE="$PDF_DIR/SHOUTY.PDF"; printf '%%PDF-1.4 uppercase extension\n' > "$UPPER_FILE"
start_mock '{}'
run_dispatcher beforeReadFile "{\"content\":\"\",\"file_path\":\"$UPPER_FILE\"}" >/dev/null
assert_eq "$(posted_field rogueFileReadB64)" "$(base64 < "$UPPER_FILE" | tr -d '\r\n')" \
  "an uppercase .PDF is captured (extension match is case-insensitive)"
stop_mock

# ── Case 8: NON-empty content is left alone ──────────────────────────────
# The extension is one the capture covers, so the content is the only thing
# that can stop it. With a skipped extension the case would pin nothing.
BUSY_FILE="$PDF_DIR/busy.pdf"; printf '%%PDF-1.4 already sent\n' > "$BUSY_FILE"
start_mock '{}'
run_dispatcher beforeReadFile "{\"content\":\"%PDF-1.4 already sent\\n\",\"file_path\":\"$BUSY_FILE\"}" >/dev/null
assert_eq "$(posted_has_field rogueFileReadB64)" "no" \
  "no capture when Cursor already sent content"
stop_mock

# ── Case 9: an extension outside the allowlist is left alone ─────────────
PNG_FILE="$PDF_DIR/i.png"; printf 'pngbytes' > "$PNG_FILE"
start_mock '{}'
run_dispatcher beforeReadFile "{\"content\":\"\",\"file_path\":\"$PNG_FILE\"}" >/dev/null
assert_eq "$(posted_has_field rogueFileReadB64)" "no" "no capture for an extension outside the allowlist"
stop_mock

# ── Case 10: over-cap file is TRUNCATED to the cap, not skipped ──────────
BIG_FILE="$PDF_DIR/big.pdf"
# 1 MiB of 'a' plus a tail that must NOT survive.
awk 'BEGIN{while(i++<1048576)printf "a"}' > "$BIG_FILE"
printf 'TAILMARKER' >> "$BIG_FILE"
start_mock '{}'
run_dispatcher beforeReadFile "{\"content\":\"\",\"file_path\":\"$BIG_FILE\"}" >/dev/null
got="$(posted_field rogueFileReadB64)"
assert_eq "$(printf '%s' "$got" | base64 -d 2>/dev/null | wc -c | tr -d ' ')" "1048576" \
  "over-cap file is truncated to exactly the cap"
assert_eq "$(printf '%s' "$got" | base64 -d 2>/dev/null | grep -c TAILMARKER || true)" "0" \
  "bytes past the cap are not sent"
stop_mock

# ── Case 11: fail-open cases leave the body untouched ────────────────────
start_mock '{}'
run_dispatcher beforeReadFile "{\"content\":\"\",\"file_path\":\"$PDF_DIR/missing.pdf\"}" >/dev/null
assert_eq "$(posted_has_field rogueFileReadB64)" "no" "a missing file attaches nothing"
stop_mock
start_mock '{}'
run_dispatcher beforeReadFile '{"content":"","file_path":"relative/x.pdf"}' >/dev/null
assert_eq "$(posted_has_field rogueFileReadB64)" "no" "a relative path attaches nothing"
stop_mock
start_mock '{}'
EMPTY_PDF="$PDF_DIR/empty.pdf"; : > "$EMPTY_PDF"
run_dispatcher beforeReadFile "{\"content\":\"\",\"file_path\":\"$EMPTY_PDF\"}" >/dev/null
assert_eq "$(posted_has_field rogueFileReadB64)" "no" "a zero-byte file attaches nothing"
stop_mock

# ── Case 12: capture does not fire on other events ──────────────────────
start_mock '{}'
run_dispatcher postToolUse "{\"tool_name\":\"Read\",\"content\":\"\",\"file_path\":\"$PDF_FILE\"}" >/dev/null
assert_eq "$(posted_has_field rogueFileReadB64)" "no" "capture is beforeReadFile-only"
stop_mock

# ── Case 13: jq path and no-jq path produce byte-identical bodies ────────
start_mock '{}'
run_dispatcher beforeReadFile "{\"content\":\"\",\"file_path\":\"$PDF_FILE\"}" >/dev/null
with_jq="$(posted_body)"
stop_mock
start_mock '{}'
NOJQ_DIR="$(make_nojq_path)"
TEST_PATH="$NOJQ_DIR"
# The mock rewrites $HEADERS_FILE only when a request lands, so a no-jq run that
# posted nothing would leave the jq run's record and match it against itself.
: > "$HEADERS_FILE"
run_dispatcher beforeReadFile "{\"content\":\"\",\"file_path\":\"$PDF_FILE\"}" >/dev/null
TEST_PATH=""
rm -rf "$NOJQ_DIR"
stop_mock
if [ -s "$HEADERS_FILE" ]; then nojq_posted="yes"; else nojq_posted="no"; fi
assert_eq "$nojq_posted" "yes" "the no-jq run posts a request of its own"
without_jq="$(posted_body)"
# The payload is compact, so jq's reserialization is a no-op. Only one path ever
# runs on a given machine, which is why they are pinned to each other here.
assert_eq "$with_jq" "$without_jq" "jq and string-concat paths produce identical bodies"

# ── Case 14: a backslash in the path attaches nothing ────────────────────
# A deliberate divergence from hook.ps1, which unescapes and carries on. The
# fixture exists and its extension is in the list, so the backslash is the only
# thing that can stop the capture.
BSLASH_FILE="$PDF_DIR/we\\ird.pdf"; printf '%%PDF-1.4 backslash\n' > "$BSLASH_FILE"
start_mock '{}'
run_dispatcher beforeReadFile "{\"content\":\"\",\"file_path\":\"$PDF_DIR/we\\\\ird.pdf\"}" >/dev/null
assert_eq "$(posted_has_field rogueFileReadB64)" "no" "a backslash in the path attaches nothing"
stop_mock

echo
echo "All cursor hook.sh tests passed (SH=$SH)."
