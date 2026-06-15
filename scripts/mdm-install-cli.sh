#!/usr/bin/env bash
# Rogue Security — MDM installer for Claude Code CLI fleets (macOS / Linux).
#
# This is the AUTO-UPDATING alternative to the compiled drag-drop zip, for the
# *CLI* surface. Instead of shipping a frozen bundle that an admin must rebuild
# and re-upload on every release, this installs the plugin from the live public
# marketplace (which our SessionStart updater keeps current) and provisions the
# org API key + per-user identity OUTSIDE the plugin directory so updates never
# clobber credentials.
#
# What it does (all idempotent — safe to re-run every MDM enforcement cycle):
#   1. Writes /etc/rogue/env (org API key, enforcement mode, per-user actor)
#      via the same logic as mdm-provision-actor.sh. Lives outside the plugin
#      cache, so `claude plugin update` never destroys it.
#   2. Registers the public marketplace + installs the plugin through the
#      Claude CLI, leaving auto-update ENABLED (ROGUE_AUTO_UPDATE is NOT set to
#      0 on this path — that flag is only for the platform-managed Desktop/
#      Cowork bundle).
#   3. Writes a managed-settings drop-in fragment so the marketplace is
#      force-registered + the plugin force-enabled org-wide, surviving a user
#      who pokes at `/plugin`.
#
# Why not rely on Claude Code's own marketplace auto-update? Because it only
# fires for *official* marketplaces (anthropics/claude-code#26744), and the
# managed-settings `autoUpdate` switch is still an open feature request
# (anthropics/claude-code#51350). Our plugins/rogue/scripts/auto-update.sh hook
# drives the explicit `claude plugin update` instead. See docs/cli-mdm-auto-update.md.
#
# Usage — env vars (recommended for MDM payloads):
#   ROGUE_API_KEY="rsk_xxx" \
#   ROGUE_ACTOR_EMAIL="$USER_EMAIL" \
#   ROGUE_ACTOR_NAME="$USER_FULL_NAME" \
#     sudo -E bash mdm-install-cli.sh
#
# Usage — CLI args:
#   sudo bash mdm-install-cli.sh \
#     --key rsk_xxx --email alice@example.com --name "Alice Smith" --mode ask
#
# Flags / env (CLI flag wins over env):
#   --key       / ROGUE_API_KEY             org API key (required)
#   --email     / ROGUE_ACTOR_EMAIL         per-user actor email (required)
#   --name      / ROGUE_ACTOR_NAME          per-user actor display name (required)
#   --mode      / ROGUE_PRETOOLUSE_ON_BLOCK "ask" (default) | "block"
#   --base-url  / ROGUE_BASE_URL            custom Rogue endpoint (rare)
#   --repo      / ROGUE_PLUGIN_REPO         marketplace repo (default below)
#   --no-managed-settings                   skip the managed-settings fragment
#                                           (register marketplace only)
#   --run-as USER                           user to run `claude plugin ...` as
#                                           (defaults to the console/SUDO_USER)
#   -h | --help                             print this and exit
#
# Must run as root (writes /etc/rogue/env and the managed-settings fragment).

set -euo pipefail

REPO="${ROGUE_PLUGIN_REPO:-qualifire-dev/rogue-plugin-claude}"
MARKETPLACE_NAME="rogue-marketplace"
PLUGIN_NAME="rogue"

KEY="${ROGUE_API_KEY:-}"
EMAIL="${ROGUE_ACTOR_EMAIL:-}"
NAME="${ROGUE_ACTOR_NAME:-}"
MODE="${ROGUE_PRETOOLUSE_ON_BLOCK:-}"
BASE_URL="${ROGUE_BASE_URL:-}"
WRITE_MANAGED=1
RUN_AS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --key)      KEY="$2"; shift 2 ;;
    --email)    EMAIL="$2"; shift 2 ;;
    --name)     NAME="$2"; shift 2 ;;
    --mode)     MODE="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    --repo)     REPO="$2"; shift 2 ;;
    --run-as)   RUN_AS="$2"; shift 2 ;;
    --no-managed-settings) WRITE_MANAGED=0; shift ;;
    -h|--help)  sed -n '2,56p' "$0" 2>/dev/null; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$KEY" ]   || { echo "ROGUE_API_KEY (or --key) required" >&2; exit 2; }
[ -n "$EMAIL" ] || { echo "ROGUE_ACTOR_EMAIL (or --email) required" >&2; exit 2; }
[ -n "$NAME" ]  || { echo "ROGUE_ACTOR_NAME (or --name) required" >&2; exit 2; }
case "$MODE" in ""|ask|block) ;; *) echo "Bad --mode: $MODE (expected ask|block)" >&2; exit 2 ;; esac
MODE="${MODE:-ask}"

[ "$(id -u)" -eq 0 ] || { echo "must run as root (writes /etc/rogue/env)" >&2; exit 1; }

# ── 1. Provision /etc/rogue/env (key + actor + mode) ──────────────────────────
# Same on-disk format the hooks source. Atomic write, root-owned.
mkdir -p /etc/rogue
TMP=$(mktemp /etc/rogue/.env.XXXXXX)
trap 'rm -f "$TMP"' EXIT
{
  echo "# Provisioned by mdm-install-cli.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'export ROGUE_API_KEY=%q\n'             "$KEY"
  printf 'export ROGUE_ACTOR_EMAIL=%q\n'         "$EMAIL"
  printf 'export ROGUE_ACTOR_NAME=%q\n'          "$NAME"
  printf 'export ROGUE_PRETOOLUSE_ON_BLOCK=%q\n' "$MODE"
  [ -n "$BASE_URL" ] && printf 'export ROGUE_BASE_URL=%q\n' "$BASE_URL"
} > "$TMP"
# Contains the API key → tighten to 0640 root:wheel (vs the actor-only file's
# 0644). Per-user hooks still read it as long as users are in the owning group,
# or relax to 0644 if your environment needs world-read.
chmod 0640 "$TMP"
chown root:wheel "$TMP" 2>/dev/null || chown root:root "$TMP" 2>/dev/null || true
mv -f "$TMP" /etc/rogue/env
trap - EXIT
echo "wrote /etc/rogue/env  actor=$EMAIL  mode=$MODE  key=...${KEY: -4}"

# ── 2. Register marketplace + install plugin (as the real user) ───────────────
# `claude plugin ...` writes to ~/.claude, so run it as the logged-in user, not
# root. Resolve that user from --run-as, SUDO_USER, or the macOS console user.
if [ -z "$RUN_AS" ]; then
  RUN_AS="${SUDO_USER:-}"
fi
if [ -z "$RUN_AS" ] && command -v stat >/dev/null 2>&1; then
  RUN_AS=$(stat -f%Su /dev/console 2>/dev/null || true)   # macOS console user
fi

run_as_user() { # run_as_user <cmd...>
  if [ -n "$RUN_AS" ] && [ "$RUN_AS" != "root" ]; then
    sudo -u "$RUN_AS" -H "$@"
  else
    "$@"
  fi
}

if run_as_user command -v claude >/dev/null 2>&1; then
  echo "registering marketplace + installing plugin as user '${RUN_AS:-root}'"
  run_as_user claude plugin marketplace add "$REPO" 2>&1 \
    || run_as_user claude plugin marketplace update "$MARKETPLACE_NAME" 2>&1 \
    || echo "marketplace add/update reported an error (may already be present)"
  run_as_user claude plugin install "${PLUGIN_NAME}@${MARKETPLACE_NAME}" 2>&1 \
    || run_as_user claude plugin update "$PLUGIN_NAME" 2>&1 \
    || echo "plugin install/update reported an error"
else
  echo "claude CLI not found for user '${RUN_AS:-root}' — skipping live install."
  echo "The managed-settings fragment below will force-register on next launch."
fi

# ── 3. Managed-settings drop-in (force-register org-wide) ─────────────────────
# Force-registers the marketplace and force-enables the plugin so it survives a
# user toggling /plugin. We do NOT set autoUpdate here — that managed-settings
# field is not shipped yet (#51350); our SessionStart hook drives updates.
if [ "$WRITE_MANAGED" = "1" ]; then
  case "$(uname -s 2>/dev/null)" in
    Darwin) MS_DIR="/Library/Application Support/ClaudeCode/managed-settings.d" ;;
    *)      MS_DIR="/etc/claude-code/managed-settings.d" ;;
  esac
  mkdir -p "$MS_DIR"
  FRAG="$MS_DIR/30-rogue.json"
  cat > "$FRAG" <<JSON
{
  "extraKnownMarketplaces": {
    "${MARKETPLACE_NAME}": {
      "source": { "source": "github", "repo": "${REPO}" }
    }
  },
  "enabledPlugins": {
    "${PLUGIN_NAME}@${MARKETPLACE_NAME}": true
  }
}
JSON
  chmod 0644 "$FRAG"
  echo "wrote managed-settings fragment $FRAG"
else
  echo "--no-managed-settings: skipped managed-settings fragment"
fi

echo "OK  Rogue CLI install complete for '${RUN_AS:-root}'. Auto-update is ON (SessionStart hook)."
