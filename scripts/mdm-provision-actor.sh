#!/usr/bin/env bash
# Provision /etc/rogue/env with end-user identity for MDM-managed machines.
#
# Why: the compiled plugin's bundled env can't reliably derive end-user
# identity on managed/ephemeral machines (e.g. Cowork VMs) where hostname is
# random and git config is empty. The MDM (Kandji, Jamf, Intune, Workspace
# ONE, etc.) knows the assigned user — push that knowledge into
# /etc/rogue/env so the hook layer picks it up at runtime.
#
# Plugin hook source order (later wins):
#   ${CLAUDE_PLUGIN_ROOT}/env  — bundled defaults (API key, mode)
#   /etc/rogue/env             — this file, MDM-deployed identity
#   ~/.rogue-env               — per-user override
#
# Usage — env vars (recommended for MDM payloads that substitute their own
# placeholders for the assigned user):
#
#   # Kandji Custom Script body example:
#   ROGUE_ACTOR_EMAIL="$USER_EMAIL" \
#   ROGUE_ACTOR_NAME="$USER_FULL_NAME" \
#     bash mdm-provision-actor.sh
#
# Usage — CLI args (handy for manual testing):
#
#   sudo bash mdm-provision-actor.sh \
#     --email alice@example.com \
#     --name "Alice Smith"
#
# Optional flags / env vars (all override values previously written):
#   --key       / ROGUE_API_KEY               override the bundled API key
#   --mode      / ROGUE_PRETOOLUSE_ON_BLOCK   "ask" (default) or "block"
#   --base-url  / ROGUE_BASE_URL              custom Rogue endpoint
#
# Required: actor email + name. Must run as root (writes to /etc/rogue/env).

set -euo pipefail

EMAIL="${ROGUE_ACTOR_EMAIL:-}"
NAME="${ROGUE_ACTOR_NAME:-}"
KEY="${ROGUE_API_KEY:-}"
MODE="${ROGUE_PRETOOLUSE_ON_BLOCK:-}"
BASE_URL="${ROGUE_BASE_URL:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --email)    EMAIL="$2"; shift 2 ;;
    --name)     NAME="$2"; shift 2 ;;
    --key)      KEY="$2"; shift 2 ;;
    --mode)     MODE="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,32p' "$0" 2>/dev/null
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$EMAIL" ] || { echo "ROGUE_ACTOR_EMAIL (or --email) required" >&2; exit 2; }
[ -n "$NAME" ]  || { echo "ROGUE_ACTOR_NAME (or --name) required" >&2; exit 2; }

case "$MODE" in
  ""|ask|block) ;;
  *) echo "Bad --mode: $MODE (expected: ask|block)" >&2; exit 2 ;;
esac

[ "$(id -u)" -eq 0 ] || {
  echo "must run as root (writes /etc/rogue/env)" >&2
  exit 1
}

mkdir -p /etc/rogue
TMP=$(mktemp /etc/rogue/.env.XXXXXX)
trap 'rm -f "$TMP"' EXIT

{
  echo "# Provisioned by mdm-provision-actor.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'export ROGUE_ACTOR_EMAIL=%q\n' "$EMAIL"
  printf 'export ROGUE_ACTOR_NAME=%q\n'  "$NAME"
  [ -n "$KEY" ]      && printf 'export ROGUE_API_KEY=%q\n' "$KEY"
  [ -n "$MODE" ]     && printf 'export ROGUE_PRETOOLUSE_ON_BLOCK=%q\n' "$MODE"
  [ -n "$BASE_URL" ] && printf 'export ROGUE_BASE_URL=%q\n' "$BASE_URL"
} > "$TMP"

# /etc convention: root-owned, world-readable so per-user hooks can source it.
# If the API key is included, treat the file as sensitive — tighten to 0640
# under a group the user belongs to if needed in your environment.
chmod 0644 "$TMP"
chown root:wheel "$TMP" 2>/dev/null || chown root:root "$TMP" 2>/dev/null || true
mv -f "$TMP" /etc/rogue/env
trap - EXIT

echo "wrote /etc/rogue/env  actor=$EMAIL ($NAME)"
