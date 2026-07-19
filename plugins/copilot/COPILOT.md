# Rogue Security AIDR

This project is protected by **Rogue Security AIDR** for GitHub Copilot CLI.
Every lifecycle event (prompts, tool calls, tool results, MCP calls) is observed
in real time; risky tool calls are evaluated and can be **denied** before they run.

- `/rogue:setup` — connect your Rogue API key and confirm your identity.
- `/rogue:status` — check connection, active rulesets, and configuration.
- **False positive?** Prepend `rgx!` to your next prompt to allow it once and
  mark the previous detection as a false positive (per-prompt only).

Dashboard: https://app.rogue.security/aidr
