#!/usr/bin/env node
// Rogue Security — Gemini CLI hook dispatcher.
//
// Usage: node hook.mjs <EventName>
//   Reads the Gemini hook JSON payload on stdin, POSTs it to Rogue, and relays
//   the response verbatim on stdout. The backend already emits Gemini's native
//   decision shapes ({"decision":"deny"|"block", "reason":...} / toolConfig), so
//   this dispatcher is a PURE RELAY — Gemini renders the block itself.
//
// One cross-platform script replaces the sh + PowerShell dual-dispatcher used by
// the Claude/Codex/Cursor plugins: Gemini CLI guarantees Node 20+ on PATH (every
// install method requires it; Homebrew declares `node` as a dependency), so we
// use Node built-ins only (global fetch, node:fs/os/path/child_process) — no
// curl, no jq, no dependencies, no build step.
//
// Fail-open by design: any missing key / network error / bad response prints
// "{}" (allow) and exits 0. stdout carries ONLY the final JSON, per the Gemini
// hook contract; everything else goes to the log file.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync, spawn } from "node:child_process";

const EVENT = process.argv[2] || "unknown";

// Surface label stamped on every log line. The hook log (~/.rogue/hook.log) is
// SHARED with the Claude/Codex/Cursor plugins, so this token is what lets you
// tell whose events a line belongs to when reading the merged file.
const PROVIDER = "gemini_cli";

// Extension root: .../<ext>/scripts/hook.mjs → <ext>
const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const EXT_ROOT = path.dirname(SCRIPT_DIR);

const HOME = os.homedir() || process.env.HOME || process.env.USERPROFILE || ".";
const IS_WIN = process.platform === "win32";

// ── Emit + exit ────────────────────────────────────────────────────────────
// stdout must be ONLY the final JSON object. Always exit 0 — a blocking verdict
// is carried in the relayed JSON body, not the exit code.
function emit(obj) {
  process.stdout.write(typeof obj === "string" ? obj : JSON.stringify(obj));
  process.exit(0);
}

// ── Logging (file only; stdout is reserved for Gemini) ───────────────────────
const LOG_FILE =
  process.env.ROGUE_LOG_FILE || path.join(HOME, ".rogue", "hook.log");
// eslint-disable-next-line no-control-regex
const CONTROL_CHARS = /[\x00-\x1f\x7f]/g;
const sanitize = (s) => String(s ?? "").replace(CONTROL_CHARS, "");
function log(msg) {
  try {
    fs.mkdirSync(path.dirname(LOG_FILE), { recursive: true });
    const ts = new Date().toISOString().replace(/\.\d+Z$/, "Z");
    fs.appendFileSync(LOG_FILE, `${ts} provider=${PROVIDER} event=${EVENT} ${msg}\n`);
  } catch {
    /* logging is best-effort */
  }
}

// ── Shell-quoted value decode (round-trips the `export KEY=value` form the other
// plugins write with printf %q / single-quoting). ────────────────────────────
function shellUnquote(raw) {
  let v = raw.trim();
  // strip a trailing inline comment only when unquoted (kept simple: we only
  // write clean single lines, so this is defensive).
  if (v.length >= 2 && v[0] === "'" && v[v.length - 1] === "'") {
    // POSIX single-quote: '...' with '\'' representing a literal quote.
    return v.slice(1, -1).replace(/'\\''/g, "'");
  }
  if (v.length >= 2 && v[0] === '"' && v[v.length - 1] === '"') {
    return v.slice(1, -1).replace(/\\(["\\$`])/g, "$1");
  }
  return v;
}

// ── Credential resolution ────────────────────────────────────────────────────
// Same env-file precedence as the other monorepo plugins (later wins; process
// env wins over all files):
//   <ext>/env (bundled) → /etc/rogue/env (MDM) → ~/.rogue-env (per-user)
function loadEnvFiles() {
  const merged = {};
  const files = [
    path.join(EXT_ROOT, "env"),
    IS_WIN ? "C:\\ProgramData\\rogue\\env" : "/etc/rogue/env",
    path.join(HOME, ".rogue-env"),
  ];
  for (const f of files) {
    let text;
    try {
      text = fs.readFileSync(f, "utf8");
    } catch {
      continue;
    }
    for (const line of text.split(/\r?\n/)) {
      const m = line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
      if (m) merged[m[1]] = shellUnquote(m[2]);
    }
  }
  // Process env wins (explicitly-set ROGUE_* / config knobs).
  for (const k of Object.keys(process.env)) {
    if (k.startsWith("ROGUE_") && process.env[k]) merged[k] = process.env[k];
  }
  return merged;
}

function gitConfig(key) {
  try {
    return execFileSync("git", ["config", "--global", key], {
      timeout: 2000,
      stdio: ["ignore", "pipe", "ignore"],
    })
      .toString()
      .trim();
  } catch {
    return "";
  }
}

// Actor cascade (mirrors scripts/actor.sh): env → git --global → host/user.
function resolveActor(env) {
  const email =
    env.ROGUE_ACTOR_EMAIL ||
    gitConfig("user.email") ||
    os.hostname() ||
    "unknown";
  let name = env.ROGUE_ACTOR_NAME || gitConfig("user.name");
  if (!name) {
    try {
      name = os.userInfo().username;
    } catch {
      name = "unknown";
    }
  }
  return { email, name: name || "unknown" };
}

// ── Detached heartbeat (SessionStart only) ──────────────────────────────────
// Fire-and-forget so it never adds latency to session start.
function fireHeartbeat() {
  try {
    const child = spawn(
      process.execPath,
      [path.join(SCRIPT_DIR, "heartbeat.mjs")],
      { detached: true, stdio: "ignore" },
    );
    child.unref();
  } catch {
    /* best-effort */
  }
}

// ── Block detection (for the log only; the body is relayed verbatim) ─────────
function describeOutcome(bodyText) {
  try {
    const j = JSON.parse(bodyText);
    const decision = j?.decision;
    const toolMode = j?.hookSpecificOutput?.toolConfig?.mode;
    if (decision === "deny" || decision === "block" || toolMode === "NONE") {
      const reason =
        j?.reason ?? j?.systemMessage ?? j?.stopReason ?? "blocked";
      return `outcome=block reason="${sanitize(reason)}"`;
    }
  } catch {
    /* non-JSON / empty → treated as allow */
  }
  return "outcome=allow";
}

// ── Read all of stdin ────────────────────────────────────────────────────────
function readStdin() {
  return new Promise((resolve) => {
    const chunks = [];
    process.stdin.on("data", (c) => chunks.push(c));
    process.stdin.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    process.stdin.on("error", () => resolve(""));
    // If nothing is piped, don't hang.
    if (process.stdin.isTTY) resolve("");
  });
}

async function main() {
  const env = loadEnvFiles();
  const apiKey = env.ROGUE_API_KEY || "";

  // SessionStart: fire the roster heartbeat and emit an unconfigured hint.
  // It is not a monitored event, so we never POST it to /hooks/gemini.
  if (EVENT === "SessionStart") {
    if (apiKey) {
      fireHeartbeat();
      log("outcome=heartbeat");
      return emit({});
    }
    log("outcome=unconfigured");
    return emit({
      systemMessage:
        "[Rogue Security] Not configured. Run /setup to connect your API key.",
    });
  }

  if (!apiKey) {
    log("outcome=unconfigured");
    return emit({});
  }

  const payload = await readStdin();
  const actor = resolveActor(env);
  const base = (env.ROGUE_BASE_URL || "https://api.rogue.security").replace(
    /\/+$/,
    "",
  );
  const url = env.ROGUE_API_URL || `${base}/api/v1/hooks/gemini`;

  let bodyText = "{}";
  try {
    const resp = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-rogue-api-key": apiKey,
        "x-rogue-event": EVENT,
        "x-rogue-actor-email": actor.email,
        "x-rogue-actor-name": actor.name,
      },
      body: payload,
      signal: AbortSignal.timeout(15000),
    });
    if (resp.ok) {
      const text = await resp.text();
      if (text && text.trim()) bodyText = text;
      log(`http=${resp.status} ${describeOutcome(bodyText)}`);
    } else {
      log(`http=${resp.status} outcome=fail-open`);
      bodyText = "{}";
    }
  } catch (e) {
    log(`error="${sanitize(e && e.message)}" outcome=fail-open`);
    bodyText = "{}";
  }

  return emit(bodyText);
}

main().catch((e) => {
  try {
    log(`error="${sanitize(e && e.message)}" outcome=fail-open`);
  } catch {
    /* ignore */
  }
  emit({});
});
