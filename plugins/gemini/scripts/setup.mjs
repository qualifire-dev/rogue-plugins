#!/usr/bin/env node
// Rogue Security — credential storage helper (Gemini CLI).
//
// Called by the /setup command. Writes the shared ~/.rogue-env (mode 600) —
// the SAME file the Claude/Codex/Cursor plugins read — so credentials are
// shared across every Rogue coding-agent integration on this machine.
//
// Usage: node setup.mjs <api-key> <email> <name>
//
// Hooks read credentials from (later wins): <ext>/env → /etc/rogue/env
// (C:\ProgramData\rogue\env on Windows) → ~/.rogue-env (written here).

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const [apiKey, actorEmail = "", actorName = ""] = process.argv.slice(2);
if (!apiKey) {
  process.stderr.write("Usage: setup.mjs <api-key> <email> <name>\n");
  process.exit(1);
}

const HOME = os.homedir() || process.env.HOME || process.env.USERPROFILE || ".";
const ENV_FILE = process.env.ROGUE_ENV_FILE || path.join(HOME, ".rogue-env");

// POSIX single-quote so the value round-trips through both `sh . source` (the
// other plugins) and this repo's Node parser. Escape embedded single quotes.
const q = (s) => `'${String(s).replace(/'/g, "'\\''")}'`;

const contents =
  "# Managed by the rogue Gemini CLI extension. Read by hook subprocesses at runtime.\n" +
  "# Delete this file to revoke credentials.\n" +
  `export ROGUE_API_KEY=${q(apiKey)}\n` +
  `export ROGUE_ACTOR_EMAIL=${q(actorEmail)}\n` +
  `export ROGUE_ACTOR_NAME=${q(actorName)}\n`;

// mode 0o600 on write; chmod again in case the file pre-existed with wider bits.
fs.writeFileSync(ENV_FILE, contents, { mode: 0o600 });
try {
  fs.chmodSync(ENV_FILE, 0o600);
} catch {
  /* Windows: POSIX mode bits are best-effort; the file lands under the user profile. */
}

process.stdout.write("OK\n");
process.stdout.write(`ENV_FILE=${ENV_FILE}\n`);
