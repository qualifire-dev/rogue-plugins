#!/usr/bin/env bash
# Rogue Security — credential storage helper
# Writes ~/.rogue-env (mode 600). Sourced by the dispatcher at hook fire time.
#
# Usage: setup.sh <api-key> <email> <name>
set -euo pipefail

API_KEY="${1:?Usage: setup.sh <api-key> <email> <name>}"
ACTOR_EMAIL="${2:-}"
ACTOR_NAME="${3:-}"

ENV_FILE="${ROGUE_ENV_FILE:-$HOME/.rogue-env}"

umask 077
: > "$ENV_FILE"
{
  printf '# Managed by the rogue Cursor plugin. Read by hook subprocesses at runtime.\n'
  printf '# Delete this file to revoke credentials.\n'
  printf 'export ROGUE_API_KEY=%q\n' "$API_KEY"
  printf 'export ROGUE_ACTOR_EMAIL=%q\n' "$ACTOR_EMAIL"
  printf 'export ROGUE_ACTOR_NAME=%q\n' "$ACTOR_NAME"
} >> "$ENV_FILE"
chmod 600 "$ENV_FILE"

echo "OK"
echo "ENV_FILE=$ENV_FILE"
