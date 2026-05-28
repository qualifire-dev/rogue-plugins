#!/usr/bin/env bash
# Sourceable. Resolves ROGUE_ACTOR_{EMAIL,NAME}, caches to /tmp/.rogue-env.
# Cascade: env → git --global → CLAUDE_CODE_USER_EMAIL → hostname/whoami.

[ -n "${ROGUE_ACTOR_EMAIL:-}" ] || ROGUE_ACTOR_EMAIL="$(git config --global user.email 2>/dev/null)"
[ -n "${ROGUE_ACTOR_NAME:-}" ]  || ROGUE_ACTOR_NAME="$(git config --global user.name 2>/dev/null)"
[ -n "${ROGUE_ACTOR_EMAIL:-}" ] || ROGUE_ACTOR_EMAIL="${CLAUDE_CODE_USER_EMAIL:-}"
[ -n "${ROGUE_ACTOR_NAME:-}" ]  || ROGUE_ACTOR_NAME="${CLAUDE_CODE_USER_EMAIL%@*}"
[ -n "${ROGUE_ACTOR_EMAIL:-}" ] || ROGUE_ACTOR_EMAIL="$(hostname 2>/dev/null)"
[ -n "${ROGUE_ACTOR_NAME:-}" ]  || ROGUE_ACTOR_NAME="$(whoami 2>/dev/null)"

ROGUE_ACTOR_EMAIL="${ROGUE_ACTOR_EMAIL//\'/}"
ROGUE_ACTOR_NAME="${ROGUE_ACTOR_NAME//\'/}"
export ROGUE_ACTOR_EMAIL ROGUE_ACTOR_NAME

umask 077
{
  printf "export ROGUE_ACTOR_EMAIL='%s'\n" "$ROGUE_ACTOR_EMAIL"
  printf "export ROGUE_ACTOR_NAME='%s'\n"  "$ROGUE_ACTOR_NAME"
} > /tmp/.rogue-env 2>/dev/null || true
