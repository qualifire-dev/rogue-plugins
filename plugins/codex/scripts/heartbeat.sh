#!/usr/bin/env bash
# Rogue presence heartbeat (Codex plugin). Fired from SessionStart in the background.
#
# POSTs /api/v1/hooks/status so this install shows up in the dashboard's Coding
# Agents roster (Connected / version / host / user) and so the org learns which
# plugin version is running (drives the "outdated" badge). Fire-and-forget: never
# blocks Codex, never affects allow/deny, exits 0 on every path.
set -u

# Codex sets PLUGIN_ROOT to the installed plugin directory.
PLUGIN_ROOT="${PLUGIN_ROOT:-}"

# Same env precedence as hook.sh (later wins): bundled → MDM → per-user.
[ -r "${PLUGIN_ROOT}/env" ] && . "${PLUGIN_ROOT}/env"
[ -r /etc/rogue/env ]                && . /etc/rogue/env
[ -r "$HOME/.rogue-env" ]            && . "$HOME/.rogue-env"

# Not configured → no-op (mirrors hook.sh fail-open on missing key).
[ -n "${ROGUE_API_KEY:-}" ] || exit 0

[ -r "${PLUGIN_ROOT}/scripts/actor.sh" ] && . "${PLUGIN_ROOT}/scripts/actor.sh"

# Plugin version from the manifest WITHOUT python3 (the /usr/bin/python3 stub
# fails silently on a fresh macOS). grep/sed are always present.
VER="unknown"
PJ="${PLUGIN_ROOT}/.codex-plugin/plugin.json"
if [ -r "$PJ" ]; then
  v=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9][^"]*"' "$PJ" \
        | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  [ -n "$v" ] && VER="$v"
fi

# Family is the fixed enum "openai"; surface (codex_app|codex_cli) rides the
# agent field. Installer pins ROGUE_CODEX_SURFACE; default codex_cli.
AGENT="${ROGUE_CODEX_SURFACE:-codex_cli}"

HOST=$(hostname 2>/dev/null || echo unknown)
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
BODY=$(printf '{"agent_family":"openai","agent":"%s","version":"%s","host":"%s","actor_email":"%s","actor_name":"%s"}' \
  "$(esc "$AGENT")" "$(esc "$VER")" "$(esc "$HOST")" \
  "$(esc "${ROGUE_ACTOR_EMAIL:-}")" "$(esc "${ROGUE_ACTOR_NAME:-}")")

curl -sS --max-time 10 -X POST \
  "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/status" \
  -H "x-rogue-api-key: $ROGUE_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$BODY" \
  >/dev/null 2>&1 || true

exit 0
