#!/usr/bin/env python3
"""
Rogue Security hook dispatcher for Cursor.

Pass-through: every hook in hooks.json calls
    python3 rogue-hook.py <cursorEventName>

The dispatcher reads the Cursor event payload from stdin, POSTs it to
the Rogue AIDR backend, and relays the server's response verbatim to
stdout. The server returns the exact Cursor-native output JSON for that
event (e.g. {permission, user_message} for preToolUse, {continue,
user_message} for beforeSubmitPrompt) — the dispatcher does not reshape.

Credential resolution order (later wins, then process env wins over all):
    1. ${CURSOR_PLUGIN_ROOT}/env  (baked into a compiled customer plugin)
    2. /etc/rogue/env             (MDM-provisioned)
    3. ~/.rogue-env               (user / installer-written)

All policy decisions (allow/ask/deny) are made by the server based on its
own configuration. The dispatcher forwards no client-side preference.

Fail-open: missing API key, network failure, non-200, empty body, or
malformed JSON all result in `{}` on stdout — Cursor must never block
because Rogue infrastructure is unavailable.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import socket
import subprocess
import sys
import urllib.error
import urllib.request

DEFAULT_BASE_URL = "https://api.rogue.security"
TIMEOUT_SECONDS = 10

def _default_cred_files() -> tuple[str, ...]:
    # The compiled-plugin env file lives at the plugin root. Prefer
    # CURSOR_PLUGIN_ROOT (set by Cursor when invoking hooks); fall back to
    # script-relative resolution for direct invocations.
    plugin_root = os.environ.get("CURSOR_PLUGIN_ROOT") or os.path.dirname(
        os.path.dirname(os.path.abspath(__file__))
    )
    return (
        os.path.join(plugin_root, "env"),
        "/etc/rogue/env",
        os.path.expanduser("~/.rogue-env"),
    )


_CRED_FILES = _default_cred_files()
_FORWARDED_ENV_VARS = (
    "ROGUE_API_KEY",
    "ROGUE_ACTOR_EMAIL",
    "ROGUE_ACTOR_NAME",
    "ROGUE_BASE_URL",
)


def _load_creds() -> dict:
    """Parse `export KEY=value` lines from each env file. Process env wins."""
    out: dict[str, str] = {}
    for path in _CRED_FILES:
        if not os.path.isfile(path):
            continue
        try:
            with open(path) as f:
                for line in f:
                    m = re.match(r"\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.+)$", line)
                    if not m:
                        continue
                    key, val = m.group(1), m.group(2).strip()
                    try:
                        parsed = next(iter(shlex.split(val)), val)
                    except ValueError:
                        parsed = val
                    out[key] = parsed
        except OSError:
            pass
    for k in _FORWARDED_ENV_VARS:
        if os.environ.get(k):
            out[k] = os.environ[k]
    return out


def _run_cmd(cmd: list[str]) -> str:
    try:
        return subprocess.run(
            cmd, capture_output=True, text=True, timeout=2
        ).stdout.strip()
    except Exception:
        return ""


def _git_config(key: str) -> str:
    return _run_cmd(["git", "config", "--global", key])


def _whoami() -> str:
    """Username — $USER/$USERNAME first, then the `whoami` command."""
    return (
        os.environ.get("USER")
        or os.environ.get("USERNAME")
        or _run_cmd(["whoami"])
    )


def _hostname() -> str:
    """Hostname — socket.gethostname() first, then the `hostname` command."""
    return socket.gethostname() or _run_cmd(["hostname"])


def _resolve_actor(creds: dict) -> tuple[str, str]:
    """Fallback chain: explicit creds → git config → whoami/hostname."""
    name = (
        creds.get("ROGUE_ACTOR_NAME")
        or _git_config("user.name")
        or _whoami()
    )
    email = creds.get("ROGUE_ACTOR_EMAIL") or _git_config("user.email")
    if not email:
        user, host = _whoami(), _hostname()
        if user and host:
            email = f"{user}@{host}"
        else:
            email = user or host
    return email, name


def _post(url: str, headers: dict, body: bytes) -> bytes:
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS) as resp:
            return resp.read() or b""
    except (
        urllib.error.URLError,
        urllib.error.HTTPError,
        socket.timeout,
        ConnectionError,
        OSError,
    ):
        return b""


def _emit_bytes(data: bytes) -> None:
    """Validate that data is JSON and relay verbatim. Otherwise emit `{}`."""
    if not data:
        sys.stdout.write("{}")
        sys.stdout.flush()
        return
    try:
        json.loads(data)
    except (ValueError, json.JSONDecodeError):
        sys.stdout.write("{}")
        sys.stdout.flush()
        return
    sys.stdout.write(data.decode("utf-8", errors="replace"))
    sys.stdout.flush()


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        sys.stdout.write("{}")
        sys.stdout.flush()
        return 0
    event = argv[1]

    creds = _load_creds()
    api_key = creds.get("ROGUE_API_KEY", "")
    if not api_key:
        if event == "sessionStart":
            sys.stdout.write(
                json.dumps(
                    {
                        "additional_context": "Rogue Security plugin is installed but not configured. "
                        "Run /rogue:setup to connect your API key."
                    }
                )
            )
        else:
            sys.stdout.write("{}")
        sys.stdout.flush()
        return 0

    base_url = creds.get("ROGUE_BASE_URL", DEFAULT_BASE_URL).rstrip("/")
    actor_email, actor_name = _resolve_actor(creds)

    try:
        payload = sys.stdin.read() or "{}"
    except Exception:
        payload = "{}"

    headers = {
        "Content-Type": "application/json",
        "x-rogue-api-key": api_key,
        "x-rogue-event": event,
        "x-rogue-actor-email": actor_email,
        "x-rogue-actor-name": actor_name,
        "x-rogue-source": "cursor",
    }

    url = f"{base_url}/api/v1/hooks/cursor"
    _emit_bytes(_post(url, headers, payload.encode("utf-8")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
