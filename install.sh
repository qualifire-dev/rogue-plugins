#!/usr/bin/env bash
#
# Rogue Security — one-line installer for Claude Code.
#
#   curl -fsSL https://raw.githubusercontent.com/qualifire-dev/rogue-plugin-claude/main/install.sh | bash
#
# Installs the Rogue Security AIDR plugin through the official Claude CLI
# (marketplace add + plugin install), validates and stores your API key,
# confirms your actor identity, and configures a status badge below the prompt.
#
# Unlike the runtime hooks (which fail OPEN so Claude Code never hangs on Rogue
# infrastructure), this installer fails LOUD: it is a deliberate user action and
# a half-finished install should be visible, not silent.
#
# Env knobs:
#   ROGUE_NON_INTERACTIVE=1   no prompts (used by auto-update.sh re-invocation)
#   ROGUE_API_KEY=...         pre-seed the API key (skips the prompt)
#   ROGUE_ACTOR_EMAIL=...     pre-seed actor identity
#   ROGUE_ACTOR_NAME=...
#   ROGUE_PLUGIN_REPO=...     marketplace source (default below)
#   ROGUE_BASE_URL=...        API base for key validation (default below)
#   ROGUE_NO_STATUSLINE=1     skip the status-badge setup
#   NO_COLOR=1                disable ANSI color
#
set -u

# ── Config ──────────────────────────────────────────────────────────────────
ROGUE_PLUGIN_REPO="${ROGUE_PLUGIN_REPO:-qualifire-dev/rogue-plugin-claude}"
ROGUE_BASE_URL="${ROGUE_BASE_URL:-https://api.rogue.security}"
MARKETPLACE_NAME="rogue-marketplace"
PLUGIN_NAME="rogue"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
STATUSLINE_PATH="$CONFIG_DIR/hooks/rogue-statusline.sh"
SETTINGS_PATH="$CONFIG_DIR/settings.json"
ENV_FILE="${ROGUE_ENV_FILE:-$HOME/.rogue-env}"

NON_INTERACTIVE="${ROGUE_NON_INTERACTIVE:-0}"
# Bind the controlling terminal to fd 3 once, so prompts work even under
# `curl | bash` (where stdin is the script, not the keyboard). If /dev/tty
# can't be opened (no terminal, or a sandbox that reports "Device not
# configured"), fall back to non-interactive instead of crashing.
if { exec 3</dev/tty; } 2>/dev/null; then
  HAVE_TTY=1
else
  HAVE_TTY=0
  NON_INTERACTIVE=1
fi

# ── Colors / log helpers ──────────────────────────────────────────────────────
if [ -n "${NO_COLOR:-}" ] || [ ! -t 2 ]; then
  C_RESET=''; C_TEAL=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_DIM=''
else
  C_RESET=$'\033[0m'; C_TEAL=$'\033[38;2;74;176;227m'; C_GREEN=$'\033[38;5;40m'
  C_YELLOW=$'\033[38;5;220m'; C_RED=$'\033[38;5;196m'; C_DIM=$'\033[2m'
fi

ok()   { printf '%s✓%s %s\n'  "$C_GREEN"  "$C_RESET" "$*" >&2; }
note() { printf '%s•%s %s\n'  "$C_DIM"    "$C_RESET" "$*" >&2; }
warn() { printf '%s!%s %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s✗ %s%s\n'  "$C_RED"    "$*" "$C_RESET" >&2; exit 1; }

# Prompt on the terminal (fd 3) and read one line. We print the prompt ourselves
# to stderr (NOT via `read -p`, whose prompt would be swallowed by stderr
# redirection) so it's always visible. Returns non-zero when there's no terminal
# (HAVE_TTY=0) or on EOF — callers must fall back rather than loop.
ask() { # ask <varname> <prompt> [-s]
  local __var="$1" __prompt="$2" __silent="${3:-}"
  [ "$HAVE_TTY" = "1" ] || return 1
  printf '%s' "$__prompt" >&2
  if [ "$__silent" = "-s" ]; then
    read -r -s "$__var" <&3 || return 1
    printf '\n' >&2
  else
    read -r "$__var" <&3 || return 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# ── Agent detection (extensible probe) ────────────────────────────────────────
# Mirrors caveman's provider matrix. Each agent: a `command:<bin>` probe and an
# installer function. Only `claude` is wired today; the rest are placeholders so
# a future maintainer adds a row + a function and nothing else moves.
#
#   id        label          detect             installer
#   ────────  ─────────────  ─────────────────  ──────────────
#   claude    Claude Code    command:claude     install_claude   ← implemented
#   gemini    Gemini CLI     command:gemini     install_gemini   (not yet)
#   cursor    Cursor         command:cursor     install_cursor   (not yet)
#   codex     Codex CLI      command:codex      install_codex    (not yet)
#
# When generalizing, drop the `-claude` suffix from the repo name and add the
# rows above; all Claude-specific paths key off $CONFIG_DIR already.

# ── Marketplace + plugin install (Claude) ─────────────────────────────────────
claude_install_plugin() {
  note "Adding marketplace ${C_DIM}$ROGUE_PLUGIN_REPO${C_RESET}"
  # Capture stderr so a real failure (e.g. missing git, clone error) is surfaced
  # instead of swallowed — otherwise it resurfaces later as a misleading
  # "plugin not found" from the install step.
  local add_err
  if add_err="$(claude plugin marketplace add "$ROGUE_PLUGIN_REPO" 2>&1)"; then
    ok "Marketplace added"
  else
    # Already present (or transient) — refresh from source instead.
    if claude plugin marketplace update "$MARKETPLACE_NAME" >/dev/null 2>&1; then
      ok "Marketplace updated"
    else
      warn "Could not add or update marketplace (continuing — it may already be present)"
      [ -n "$add_err" ] && note "${C_DIM}${add_err}${C_RESET}"
    fi
  fi

  note "Installing plugin ${C_DIM}${PLUGIN_NAME}@${MARKETPLACE_NAME}${C_RESET}"
  if claude plugin install "${PLUGIN_NAME}@${MARKETPLACE_NAME}" >/dev/null 2>&1; then
    ok "Plugin installed"
  elif claude plugin update "$PLUGIN_NAME" >/dev/null 2>&1; then
    ok "Plugin updated"
  else
    die "claude plugin install failed. Run 'claude plugin install ${PLUGIN_NAME}@${MARKETPLACE_NAME}' to see the error."
  fi
}

# ── Credentials ───────────────────────────────────────────────────────────────
# Validate the key AND register this install via /api/v1/hooks/status (the same
# heartbeat the SessionStart hook calls). Echoes the HTTP status code (empty on
# transport failure). On 200, also populates STATUS_ORG / STATUS_UPDATE for the
# caller to surface. Sending a stable host + actor-email keeps the dashboard
# roster row deduped with the later heartbeats.
STATUS_ORG=""
STATUS_UPDATE=""
status_check() { # status_check <api-key> <actor-email>
  have_cmd curl || { printf ''; return; }
  local resp code body
  resp=$(curl -s -w $'\n%{http_code}' --max-time 10 \
    "$ROGUE_BASE_URL/api/v1/hooks/status" \
    -H "x-rogue-api-key: $1" \
    -H "x-rogue-agent-family: claude" \
    -H "x-rogue-agent: Claude Code - CLI" \
    -H "x-rogue-host: $(hostname 2>/dev/null || echo unknown)" \
    -H "x-rogue-actor-email: ${2:-}" 2>/dev/null) || { printf ''; return; }
  code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  if [ "$code" = "200" ]; then
    STATUS_ORG=$(printf '%s' "$body" | sed -E -n 's/.*"name"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1)
    printf '%s' "$body" | grep -qE '"update_available"[[:space:]]*:[[:space:]]*true' && STATUS_UPDATE=1
  fi
  printf '%s' "$code"
}

# Mask an API key for display: show the first 8 chars, hide the rest.
key_hint() { # key_hint <key>
  local k="$1"
  if [ "${#k}" -le 8 ]; then printf '%s' "$k"; else printf '%s…' "${k:0:8}"; fi
}

configure_credentials() {
  # Pull anything already on disk / in env into scope.
  [ -r /etc/rogue/env ] && . /etc/rogue/env
  [ -r "$ENV_FILE" ]    && . "$ENV_FILE"

  local cur_key="${ROGUE_API_KEY:-}"

  # Resolve actor defaults up front (same cascade as plugins/rogue/scripts/actor.sh)
  # so key validation can register the roster row under the real email, deduped
  # with the later SessionStart heartbeats.
  local def_email def_name
  def_email="${ROGUE_ACTOR_EMAIL:-$(git config --global user.email 2>/dev/null)}"
  def_name="${ROGUE_ACTOR_NAME:-$(git config --global user.name 2>/dev/null)}"
  [ -n "$def_email" ] || def_email="${CLAUDE_CODE_USER_EMAIL:-}"
  [ -n "$def_name" ]  || def_name="${CLAUDE_CODE_USER_EMAIL%@*}"
  [ -n "$def_email" ] || def_email="$(hostname 2>/dev/null)"
  [ -n "$def_name" ]  || def_name="$(whoami 2>/dev/null)"

  # Non-interactive: keep whatever is configured, or nudge if nothing is.
  if [ "$NON_INTERACTIVE" = "1" ]; then
    if [ -n "$cur_key" ]; then
      note "API key already configured (${C_DIM}$(key_hint "$cur_key")${C_RESET}) — leaving credentials as-is"
    else
      note "No API key set and running non-interactively — skipping."
      note "Run ${C_DIM}/rogue:setup${C_RESET} inside Claude Code to connect your key."
    fi
    return
  fi

  # --- API key (interactive). Show a hint of the current key; Enter keeps it. ---
  local key code tries=0 prompt
  if [ -n "$cur_key" ]; then
    prompt="Rogue API key [current: $(key_hint "$cur_key"), Enter to keep]: "
  else
    prompt="Rogue API key: "
  fi
  while :; do
    if ! ask key "$prompt" -s; then
      # No usable terminal — fall back instead of looping.
      if [ -n "$cur_key" ]; then key="$cur_key"; note "No TTY — keeping existing key"; break; fi
      note "No TTY for input — skipping. Run ${C_DIM}/rogue:setup${C_RESET} later."; return
    fi
    if [ -z "$key" ]; then
      [ -n "$cur_key" ] && { key="$cur_key"; note "Keeping existing key"; break; }
      warn "Empty — paste your key from https://app.rogue.security/settings/api-keys"; continue
    fi
    code="$(status_check "$key" "$def_email")"
    case "$code" in
      200)        ok "Key validated${STATUS_ORG:+ — org: $STATUS_ORG}"
                  [ -n "$STATUS_UPDATE" ] && note "A newer plugin version is available (auto-update will pick it up)."
                  break ;;
      401|403)    tries=$((tries+1)); warn "Invalid key (HTTP $code)."
                  if [ "$tries" -ge 3 ]; then
                    local yn=""; ask yn "Save it anyway? [y/N]: " || yn=""
                    case "$yn" in [Yy]*) warn "Saving unvalidated key"; break ;; *) die "Aborted." ;; esac
                  fi ;;
      '')         warn "Could not reach $ROGUE_BASE_URL to validate — saving without verification."; break ;;
      *)          warn "Unexpected response (HTTP $code) — saving without verification."; break ;;
    esac
  done
  ROGUE_API_KEY="$key"

  # --- Actor identity (gh-CLI style: show full current/detected, Enter to keep) ---
  # Defaults (def_email/def_name) were resolved above, before key validation.
  local in_email="" in_name=""
  ask in_email "Actor email [${def_email:-none}, Enter to keep]: " || in_email=""
  ask in_name  "Actor name  [${def_name:-none}, Enter to keep]: "  || in_name=""
  ROGUE_ACTOR_EMAIL="${in_email:-$def_email}"
  ROGUE_ACTOR_NAME="${in_name:-$def_name}"

  # --- Write ~/.rogue-env (mode 600), same format as setup.sh ---
  umask 077
  : > "$ENV_FILE"
  {
    printf '# Managed by the rogue Claude plugin. Read by hook subprocesses at runtime.\n'
    printf '# Delete this file to revoke credentials.\n'
    printf 'export ROGUE_API_KEY=%q\n' "$ROGUE_API_KEY"
    printf 'export ROGUE_ACTOR_EMAIL=%q\n' "$ROGUE_ACTOR_EMAIL"
    printf 'export ROGUE_ACTOR_NAME=%q\n' "$ROGUE_ACTOR_NAME"
  } >> "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  ok "Credentials written to ${C_DIM}$ENV_FILE${C_RESET} (mode 600)"
}

# ── Status badge ──────────────────────────────────────────────────────────────
write_statusline_script() {
  mkdir -p "$(dirname "$STATUSLINE_PATH")" 2>/dev/null
  # Body kept byte-identical with plugins/rogue/scripts/statusline.sh.
  cat > "$STATUSLINE_PATH" <<'BADGE'
#!/usr/bin/env bash
# Rogue Security status badge (installed by install.sh). Status circle then
# teal bracketed label: 🟢 [Rogue Security] configured, 🔴 [Rogue Security] not.
set -u
for f in /etc/rogue/env "$HOME/.rogue-env"; do
  [ -r "$f" ] && . "$f"
done
if [ -n "${ROGUE_API_KEY:-}" ]; then
  dot='🟢'
else
  dot='🔴'
fi
printf '%s \033[38;2;74;176;227m[Rogue Security]\033[0m' "$dot"
BADGE
  chmod 755 "$STATUSLINE_PATH"
}

# Merge the statusLine into settings.json without clobbering other keys.
# Uses node (Claude Code ships it) — avoids jq/python3 which may be absent.
# Exit codes: 0 set, 10 already ours, 20 foreign statusLine exists.
apply_statusline_setting() {
  local sl_cmd="bash \"$STATUSLINE_PATH\""
  node - "$SETTINGS_PATH" "$sl_cmd" "$STATUSLINE_PATH" "$1" <<'NODE'
const fs = require('fs');
const [file, slCmd, slPath, overwrite] = process.argv.slice(2);
let s = {};
try { s = JSON.parse(fs.readFileSync(file, 'utf8') || '{}'); } catch (_) {}
const cur = s.statusLine;
const isOurs = cur && typeof cur.command === 'string' && cur.command.includes(slPath);
if (cur && !isOurs && overwrite !== 'yes') process.exit(20);  // foreign — let caller decide
s.statusLine = { type: 'command', command: slCmd };
fs.mkdirSync(require('path').dirname(file), { recursive: true });
fs.writeFileSync(file, JSON.stringify(s, null, 2) + '\n');
process.exit(isOurs ? 10 : 0);
NODE
}

configure_statusline() {
  if [ "${ROGUE_NO_STATUSLINE:-0}" = "1" ]; then
    note "ROGUE_NO_STATUSLINE=1 — skipping status badge"
    return
  fi
  have_cmd node || { warn "node not found — skipping status badge"; return; }

  write_statusline_script

  apply_statusline_setting "no"
  case "$?" in
    0)  ok "Status badge enabled" ;;
    10) ok "Status badge already configured" ;;
    20)
      if [ "$NON_INTERACTIVE" = "1" ]; then
        warn "An existing statusLine is configured — leaving it untouched."
        note "To use the Rogue badge, set settings.json statusLine.command to: bash \"$STATUSLINE_PATH\""
      else
        local yn; ask yn "A statusLine is already configured. Overwrite it with the Rogue badge? [y/N]: "
        case "$yn" in
          [Yy]*) apply_statusline_setting "yes" && ok "Status badge enabled (replaced existing)" ;;
          *)     note "Kept your existing statusLine. Badge script left at $STATUSLINE_PATH" ;;
        esac
      fi
      ;;
    *)  warn "Could not update settings.json — skipping status badge" ;;
  esac
}

# ── Claude installer (the one implemented agent) ──────────────────────────────
install_claude() {
  printf '\n%sRogue Security%s — Claude Code\n' "$C_TEAL" "$C_RESET" >&2
  have_cmd claude || die "Claude Code CLI not found on PATH. Install it from https://claude.com/code first."
  # Claude Code shells out to system git to clone the marketplace. A fresh
  # machine without git makes the clone fail — name it here instead of letting
  # it surface later as a misleading "plugin not found". Hint per-OS.
  if ! have_cmd git; then
    case "$(uname -s 2>/dev/null)" in
      Darwin) die "git not found. Install the Command Line Tools first: xcode-select --install" ;;
      *)      die "git not found. Install it via your package manager (e.g. apt install git, or dnf install git)." ;;
    esac
  fi
  claude_install_plugin
  configure_credentials
  configure_statusline

  printf '\n' >&2
  ok "Done. ${C_TEAL}Rogue Security${C_RESET} 🟢"
  note "Open a new Claude Code session, then run ${C_DIM}/rogue:status${C_RESET} to verify."
}

# ── Dispatch: detect installed agents, install for each ───────────────────────
main() {
  local found=0
  # Only `claude` is wired today. Future: loop the AGENTS matrix above.
  if have_cmd claude; then
    found=1
    install_claude
  fi

  if [ "$found" = "0" ]; then
    die "No supported coding agent found on PATH (looked for: claude). Install Claude Code first: https://claude.com/code"
  fi
}

main "$@"
