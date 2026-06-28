#!/usr/bin/env bash
# Rogue Security AIDR — one-liner multi-agent installer (caveman-style).
#
#   curl -fsSL https://raw.githubusercontent.com/qualifire-dev/rogue-plugin-claude/main/install-all.sh | bash
#
# Detects every supported coding agent on this machine and installs the matching
# Rogue plugin into each. Credentials live in the SHARED ~/.rogue-env, so we
# prompt + validate ONCE, write it, then run each per-agent install
# non-interactively. Fail-soft per agent: one failure logs and we continue.
#
# Flags:
#   --only a,b      install only these agent ids (claude,codex,cursor)
#   --skip a,b      skip these agent ids
#   --list          detect + show status, install nothing
#   --dry-run       print what would happen, change nothing
#   --force         ignore the on-disk key and re-collect credentials; the
#                   per-agent install (marketplace add/update + install) always
#                   re-runs and is idempotent, so this also refreshes the plugin
#   --non-interactive   never prompt (requires key in env/file)
#   --api-key K --actor-email E --actor-name N --base-url U
set -u

REPO="${ROGUE_REPO:-qualifire-dev/rogue-plugin-claude}"
BASE_URL="${ROGUE_BASE_URL:-https://api.rogue.security}"
ENV_FILE="${ROGUE_ENV_FILE:-$HOME/.rogue-env}"
CURSOR_INSTALLER="${ROGUE_CURSOR_INSTALLER_URL:-https://raw.githubusercontent.com/qualifire-dev/rogue-plugin-cursor/main/install.sh}"

ONLY=""; SKIP=""; LIST=0; DRY=0; FORCE=0; NONINT="${ROGUE_NON_INTERACTIVE:-0}"
API_KEY="${ROGUE_API_KEY:-}"; ACTOR_EMAIL="${ROGUE_ACTOR_EMAIL:-}"; ACTOR_NAME="${ROGUE_ACTOR_NAME:-}"

need_value() { [ $# -ge 2 ] || { echo "missing value for $1" >&2; exit 2; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --only) need_value "$@"; ONLY="$2"; shift 2 ;;
    --skip) need_value "$@"; SKIP="$2"; shift 2 ;;
    --list) LIST=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --force) FORCE=1; shift ;;
    --non-interactive) NONINT=1; shift ;;
    --api-key) need_value "$@"; API_KEY="$2"; shift 2 ;;
    --actor-email) need_value "$@"; ACTOR_EMAIL="$2"; shift 2 ;;
    --actor-name) need_value "$@"; ACTOR_NAME="$2"; shift 2 ;;
    --base-url) need_value "$@"; BASE_URL="$2"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
run()  { if [ "$DRY" = 1 ]; then say "  [dry-run] $*"; else eval "$*"; fi; }

# ── detection ──────────────────────────────────────────────────────────────
# Provider rows: "id|label|detect-expr". detect-expr is eval'd; 0 = present.
PROVIDERS="
claude|Claude Code|command -v claude >/dev/null 2>&1
codex|OpenAI Codex|command -v codex >/dev/null 2>&1
cursor|Cursor|command -v cursor >/dev/null 2>&1 || [ -d \"\$HOME/.cursor\" ] || [ -d \"/Applications/Cursor.app\" ]
"

in_csv() { case ",$1," in *",$2,"*) return 0 ;; *) return 1 ;; esac; }

detected() {  # id -> echoes "yes"/"no"
  local expr="$1"
  if eval "$expr"; then echo yes; else echo no; fi
}

selected() {  # id -> 0 if should act on it
  local id="$1"
  [ -n "$ONLY" ] && { in_csv "$ONLY" "$id" || return 1; }
  [ -n "$SKIP" ] && { in_csv "$SKIP" "$id" && return 1; }
  return 0
}

# Build the active list (detected ∧ selected).
ACTIVE=""
say "Rogue AIDR — detecting coding agents:"
printf '%s\n' "$PROVIDERS" | while IFS='|' read -r id label expr; do
  [ -z "$id" ] && continue
  d=$(detected "$expr")
  mark="—"; [ "$d" = yes ] && mark="✓"
  sel="";  if [ "$d" = yes ] && selected "$id"; then sel=" (will install)"; fi
  printf '  %s %-14s %s%s\n' "$mark" "$label" "$d" "$sel"
done
# (subshell above is display-only; recompute ACTIVE in this shell)
while IFS='|' read -r id label expr; do
  [ -z "$id" ] && continue
  if [ "$(detected "$expr")" = yes ] && selected "$id"; then
    ACTIVE="$ACTIVE $id"
  fi
done <<EOF
$(printf '%s\n' "$PROVIDERS")
EOF

if [ "$LIST" = 1 ]; then exit 0; fi
if [ -z "${ACTIVE// /}" ]; then say "No supported agents selected. Nothing to do."; exit 0; fi

# ── credentials (collect ONCE; shared ~/.rogue-env) ────────────────────────
# Reuse an existing key on disk unless --force (which forces a credential refresh).
if [ -z "$API_KEY" ] && [ "$FORCE" != 1 ] && [ -r "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE" 2>/dev/null || true
  API_KEY="${ROGUE_API_KEY:-$API_KEY}"
  ACTOR_EMAIL="${ROGUE_ACTOR_EMAIL:-$ACTOR_EMAIL}"
  ACTOR_NAME="${ROGUE_ACTOR_NAME:-$ACTOR_NAME}"
fi

[ -n "$ACTOR_EMAIL" ] || ACTOR_EMAIL="$(git config --global user.email 2>/dev/null)"
[ -n "$ACTOR_NAME" ]  || ACTOR_NAME="$(git config --global user.name 2>/dev/null)"

if [ -z "$API_KEY" ]; then
  # Probe /dev/tty, not stdin: the documented `curl … | bash` one-liner pipes the
  # script into stdin, so `-t 0` is always false and would wrongly abort even when
  # a terminal is attached.
  if [ "$NONINT" = 1 ] || ! [ -r /dev/tty ]; then
    say "✗ No API key (set ROGUE_API_KEY or --api-key). Aborting." >&2; exit 1
  fi
  printf 'Rogue API key (rsk_...): ' >&2
  read -r -s API_KEY < /dev/tty; echo >&2
fi

# Validate the key (fail loud at install time — unlike the fail-open hooks).
if [ "$DRY" != 1 ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -H "x-rogue-api-key: $API_KEY" "$BASE_URL/api/v1/hooks/ping" || echo 000)
  if [ "$code" != "200" ]; then
    say "✗ API key validation failed (HTTP $code) against $BASE_URL/api/v1/hooks/ping" >&2; exit 1
  fi
  say "✓ API key valid"
fi

# Write the shared env file once (same %q format the plugin scripts expect).
write_env() {
  umask 077
  : > "$ENV_FILE"
  {
    printf '# Managed by the rogue multi-agent installer. Read by hook subprocesses at runtime.\n'
    printf '# Delete this file to revoke credentials.\n'
    printf 'export ROGUE_API_KEY=%q\n' "$API_KEY"
    printf 'export ROGUE_ACTOR_EMAIL=%q\n' "$ACTOR_EMAIL"
    printf 'export ROGUE_ACTOR_NAME=%q\n' "$ACTOR_NAME"
    printf 'export ROGUE_CODEX_SURFACE=%q\n' "${ROGUE_CODEX_SURFACE:-codex_cli}"
    [ "$BASE_URL" != "https://api.rogue.security" ] && printf 'export ROGUE_BASE_URL=%q\n' "$BASE_URL"
  } >> "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}
if [ "$DRY" = 1 ]; then say "  [dry-run] write $ENV_FILE (mode 600)"; else write_env; say "✓ wrote $ENV_FILE"; fi

# ── per-agent install (fail-soft) ──────────────────────────────────────────
install_claude() {
  command -v claude >/dev/null 2>&1 || { say "  claude CLI not found; skipping"; return 1; }
  run "claude plugin marketplace add $REPO 2>/dev/null || claude plugin marketplace update $REPO 2>/dev/null || true"
  run "claude plugin install rogue@rogue-marketplace"
}
install_codex() {
  command -v codex >/dev/null 2>&1 || { say "  codex CLI not found; skipping"; return 1; }
  run "codex plugin marketplace add $REPO 2>/dev/null || codex plugin marketplace update $REPO 2>/dev/null || true"
  run "codex plugin install rogue@rogue-marketplace"
  say "  ⚠ Codex skips untrusted hooks — open /hooks in Codex and trust the Rogue entries once."
}
install_cursor() {
  run "curl -fsSL '$CURSOR_INSTALLER' | ROGUE_NON_INTERACTIVE=1 bash"
}

say ""
say "Installing into:${ACTIVE}"
rc=0
for id in $ACTIVE; do
  say "→ $id"
  case "$id" in
    claude) install_claude || rc=1 ;;
    codex)  install_codex  || rc=1 ;;
    cursor) install_cursor || rc=1 ;;
  esac
done

say ""
if [ "$rc" = 0 ]; then say "✓ Done. Restart each agent to load the plugin."; else say "⚠ Done with some failures — see above."; fi
exit $rc
