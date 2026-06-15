#!/usr/bin/env bash
# Silent plugin auto-updater. Fires from the SessionStart hook in the
# background so it never blocks Claude Code startup. Compares the installed
# plugin version against the latest GitHub release; if newer, asks the Claude
# CLI to update the marketplace + plugin in place. New version takes effect on
# the next session.
#
# WHY THIS EXISTS (and isn't just Claude Code's built-in auto-update):
#   Claude Code only auto-pulls *official* marketplaces on session start;
#   third-party marketplaces like ours do NOT auto-update on their own
#   (anthropics/claude-code#26744, closed "not planned"), and there is no
#   shipped managed-settings switch to force it (anthropics/claude-code#51350,
#   still open). So we drive the *explicit* update commands ourselves from a
#   hook that DOES fire reliably on the CLI:
#       claude plugin marketplace update <marketplace>
#       claude plugin update <plugin>
#   These are the documented, supported update commands — we just invoke them
#   on a schedule instead of waiting for a session-start pull that never comes.
#
#   This path is CLI-only by nature. On Claude Desktop / Cowork the platform
#   (claude.ai org dashboard, GitHub-synced marketplace) owns updates, and
#   Cowork doesn't fire SessionStart hooks at all (anthropics/claude-code#47993)
#   — so the compiled/synced bundle ships with ROGUE_AUTO_UPDATE=0 and this
#   script stands down there. See docs/auto-update.md.
#
# Opt-outs:
#   ROGUE_AUTO_UPDATE=0       — disable entirely (set by compiled bundles)
#   ROGUE_PLUGIN_VERSION=v1.x — pinned, never updates
#
# Runs at most once per 24h (cached in ~/.rogue/.auto-update-check).
# Silent on every failure path. All activity logs to ~/.rogue/auto-update.log
# for diagnostics.

[ -z "${CLAUDE_CODE_ENTRYPOINT:-}" ] && exit 0

set -u

LOG="$HOME/.rogue/auto-update.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || exit 0
exec >>"$LOG" 2>&1
date "+%F %T --- auto-update tick ---"

# Pull creds + flags from the same files the hooks read.
[ -r "${CLAUDE_PLUGIN_ROOT:-}/env" ] && . "${CLAUDE_PLUGIN_ROOT}/env"
[ -r /etc/rogue/env ] && . /etc/rogue/env
[ -r "$HOME/.rogue-env" ] && . "$HOME/.rogue-env"

if [ "${ROGUE_AUTO_UPDATE:-1}" = "0" ]; then
  echo "ROGUE_AUTO_UPDATE=0, skipping (platform-managed or pinned install)"
  exit 0
fi
if [ -n "${ROGUE_PLUGIN_VERSION:-}" ]; then
  echo "ROGUE_PLUGIN_VERSION=$ROGUE_PLUGIN_VERSION pinned, skipping"
  exit 0
fi

# The update commands need the Claude CLI. If it isn't on PATH (e.g. a Desktop
# bundle that somehow reached here), there's nothing we can do — stand down.
if ! command -v claude >/dev/null 2>&1; then
  echo "claude CLI not on PATH, skipping"
  exit 0
fi

# Rate-limit to once per day.
CACHE="$HOME/.rogue/.auto-update-check"
TTL=86400
if [ -f "$CACHE" ]; then
  NOW=$(date +%s 2>/dev/null || echo 0)
  MTIME=$(stat -f %m "$CACHE" 2>/dev/null || stat -c %Y "$CACHE" 2>/dev/null || echo 0)
  if [ $((NOW - MTIME)) -lt "$TTL" ]; then
    echo "checked within TTL, skipping"
    exit 0
  fi
fi
touch "$CACHE" 2>/dev/null

REPO="${ROGUE_PLUGIN_REPO:-qualifire-dev/rogue-plugin-claude}"
MARKETPLACE_NAME="${ROGUE_MARKETPLACE_NAME:-rogue-marketplace}"
PLUGIN_NAME="${ROGUE_PLUGIN_NAME:-rogue}"

# Installed version: prefer the running plugin's manifest. Read WITHOUT python3
# (the /usr/bin/python3 stub fails silently on a fresh macOS — see hook.sh).
PLUGIN_JSON="${CLAUDE_PLUGIN_ROOT:-}/.claude-plugin/plugin.json"
INSTALLED=""
if [ -r "$PLUGIN_JSON" ]; then
  INSTALLED=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9][^"]*"' "$PLUGIN_JSON" \
                | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
fi
if [ -z "$INSTALLED" ]; then
  echo "no installed version found"
  exit 0
fi
INSTALLED_TAG="v${INSTALLED}"

# Latest release tag from GitHub, also without python3.
LATEST=$(curl -fsSL --max-time 5 "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
  | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
  | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+')
if [ -z "$LATEST" ]; then
  echo "could not resolve latest release"
  exit 0
fi
# Normalize to a v-prefixed tag for comparison.
case "$LATEST" in v*) ;; *) LATEST="v${LATEST}" ;; esac

if [ "$LATEST" = "$INSTALLED_TAG" ]; then
  echo "up to date at $INSTALLED_TAG"
  exit 0
fi

echo "upgrade available: $INSTALLED_TAG -> $LATEST, updating via claude CLI"

# Refresh the marketplace catalog, then update the installed plugin. These are
# the documented update commands; driving them explicitly sidesteps the
# third-party "no session-start auto-pull" limitation (#26744). Each step is
# best-effort and logged — a failure just means we retry after the next TTL.
if claude plugin marketplace update "$MARKETPLACE_NAME" 2>&1; then
  echo "marketplace '$MARKETPLACE_NAME' refreshed"
else
  echo "marketplace update failed (continuing to plugin update)"
fi

if claude plugin update "$PLUGIN_NAME" 2>&1; then
  echo "plugin '$PLUGIN_NAME' updated -> $LATEST (active next session)"
else
  echo "plugin update failed; will retry after next TTL"
  # Clear the rate-limit stamp so the next session retries instead of waiting
  # a full day on a transient failure.
  rm -f "$CACHE" 2>/dev/null
fi
