#!/usr/bin/env node
// Rogue Security — Gemini CLI presence heartbeat.
//
// Spawned detached by hook.mjs on SessionStart. POSTs /api/v1/hooks/status so
// this install shows up in the dashboard's Coding Agents roster (Connected /
// version / host / user) and the org learns which plugin version runs. Pure
// side-effect: fire-and-forget, never blocks Gemini, exits 0 on every path.
//
// The roster dedups one row per (host | actor-email | family | agent), so we
// always send a stable host + actor-email. Family is the fixed enum "gemini";
// the surface rides `agent` as "gemini_cli" (drives the dashboard version badge).

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const EXT_ROOT = path.dirname(SCRIPT_DIR);
const HOME = os.homedir() || process.env.HOME || process.env.USERPROFILE || ".";
const IS_WIN = process.platform === "win32";

function shellUnquote(raw) {
  const v = raw.trim();
  if (v.length >= 2 && v[0] === "'" && v[v.length - 1] === "'") {
    return v.slice(1, -1).replace(/'\\''/g, "'");
  }
  if (v.length >= 2 && v[0] === '"' && v[v.length - 1] === '"') {
    return v.slice(1, -1).replace(/\\(["\\$`])/g, "$1");
  }
  return v;
}

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

// Read the extension version from the manifest (source of truth).
function readVersion() {
  try {
    const m = JSON.parse(
      fs.readFileSync(path.join(EXT_ROOT, "gemini-extension.json"), "utf8"),
    );
    return typeof m.version === "string" ? m.version : "unknown";
  } catch {
    return "unknown";
  }
}

async function main() {
  const env = loadEnvFiles();
  const apiKey = env.ROGUE_API_KEY || "";
  if (!apiKey) return; // not configured → no-op

  const email =
    env.ROGUE_ACTOR_EMAIL || gitConfig("user.email") || os.hostname() || "";
  let name = env.ROGUE_ACTOR_NAME || gitConfig("user.name");
  if (!name) {
    try {
      name = os.userInfo().username;
    } catch {
      name = "";
    }
  }

  const base = (env.ROGUE_BASE_URL || "https://api.rogue.security").replace(
    /\/+$/,
    "",
  );
  const body = JSON.stringify({
    agent_family: "gemini",
    agent: "gemini_cli",
    version: readVersion(),
    host: os.hostname() || "unknown",
    actor_email: email,
    actor_name: name || "",
  });

  try {
    await fetch(`${base}/api/v1/hooks/status`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-rogue-api-key": apiKey,
      },
      body,
      signal: AbortSignal.timeout(10000),
    });
  } catch {
    /* fire-and-forget */
  }
}

main().finally(() => process.exit(0));
