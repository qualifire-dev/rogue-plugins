# Rogue Security AIDR

This project is protected by the Rogue Security AIDR extension. Gemini CLI hook
events (prompts, tool calls, tool results, and the final model response) are
evaluated in real time against your organization's security rulesets, and
flagged events are blocked.

- Check status, rulesets, and identity any time with `/status`.
- Configure or update your API key with `/setup`.
- **False positive?** If a prompt was blocked by mistake, prepend `rgx!` to your
  next prompt and resubmit — Rogue allows that one prompt and records the prior
  detection as a false positive.
