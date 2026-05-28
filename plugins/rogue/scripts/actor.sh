#!/usr/bin/env bash
# Rogue Security — actor identity resolver.
#
# Resolves ROGUE_ACTOR_EMAIL and ROGUE_ACTOR_NAME, then caches them to
# /tmp/.rogue-env so subsequent hooks in the session can source the values
# without re-running git / hostname / whoami.
#
# Sourceable from a parent shell:
#     . "${CLAUDE_PLUGIN_ROOT}/scripts/actor.sh"
# After sourcing, ROGUE_ACTOR_EMAIL and ROGUE_ACTOR_NAME are exported in the
# caller's shell.
#
# Idempotent: if either var is already set (e.g. from a prior source of
# /tmp/.rogue-env or ~/.rogue-env), that value wins. The cache file is
# refreshed regardless so it reflects the most recently resolved pair.
#
# Resolution precedence (highest → lowest), per var:
#   1. Already set in env (from prior sourced env file)
#   2. git config --global user.{email,name}
#   3. hostname (email) / whoami (name)
#
# Single quotes are stripped from values before writing — the cache file
# wraps values in single quotes, and embedded apostrophes would break
# sourcing. Edge case for git names like "O'Brien"; accepted.
#
# Fail-safe: if the cache write fails (disk full, /tmp not writable),
# the vars are still set in the caller's shell — no caller-visible error.

# --- resolve ROGUE_ACTOR_EMAIL --------------------------------------------
# 1. env → 2. git --global user.email → 3. hostname

# --- resolve ROGUE_ACTOR_NAME ---------------------------------------------
# 1. env → 2. git --global user.name → 3. whoami

# --- sanitize -------------------------------------------------------------
# strip single quotes from both values (tr -d "'")

# --- export ---------------------------------------------------------------
# export ROGUE_ACTOR_EMAIL ROGUE_ACTOR_NAME

# --- cache to /tmp/.rogue-env (mode 600, single-quoted) -------------------
# umask 077; write two `export VAR='value'` lines; redirect errors to /dev/null
