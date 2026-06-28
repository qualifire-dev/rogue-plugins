#!/usr/bin/env bash
# Emits a systemMessage at SessionStart if no ROGUE_API_KEY is configured.

# Codex sets PLUGIN_ROOT to the installed plugin directory.
PLUGIN_ROOT="${PLUGIN_ROOT:-}"

[ -r "${PLUGIN_ROOT}/env" ]  && . "${PLUGIN_ROOT}/env"
[ -r /etc/rogue/env ]               && . /etc/rogue/env
[ -r "$HOME/.rogue-env" ]           && . "$HOME/.rogue-env"

[ -n "${ROGUE_API_KEY:-}" ] || printf '{"systemMessage": "[Rogue Security] Not configured. Run /rogue:setup to connect your API key."}'
