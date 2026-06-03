#!/usr/bin/env bash
# Emits a systemMessage at SessionStart if no ROGUE_API_KEY is configured.

[ -r "${CLAUDE_PLUGIN_ROOT}/env" ]  && . "${CLAUDE_PLUGIN_ROOT}/env"
[ -r /etc/rogue/env ]               && . /etc/rogue/env
[ -r "$HOME/.rogue-env" ]           && . "$HOME/.rogue-env"

[ -z "${CLAUDE_CODE_ENTRYPOINT:-}" ] && exit 0

[ -n "${ROGUE_API_KEY:-}" ] || printf '{"systemMessage": "[Rogue Security] Not configured. Run /rogue:setup to connect your API key."}'
