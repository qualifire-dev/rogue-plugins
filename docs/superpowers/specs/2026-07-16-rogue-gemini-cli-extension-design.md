# Rogue Security AIDR — Gemini CLI extension (design)

Date: 2026-07-16
Status: design approved pending user review
Author: Yuval + Claude

## 1. Goal

Ship a native **Gemini CLI extension** that gives Gemini CLI the same Rogue
Security AIDR coverage the Claude, Codex, and Cursor plugins already provide:
every meaningful lifecycle event is POSTed to the Rogue backend, and events that
carry evaluable content (user prompt, tool calls incl. MCP, tool responses incl.
MCP, final model response) are evaluated by the evaluations-api and **blocked**
when a ruleset flags them. It ships `/setup` and `/status` like the other
plugins. Windows and macOS are both first-class.

This is not greenfield. An older `qualifire-dev/rogue-plugin-gemini` already
exists as a `~/.gemini/settings.json`-injection approach with bash+PowerShell
hook scripts (`curl`+`jq`). This design **replaces that approach** with a native
Gemini extension living in this monorepo at `plugins/gemini/`.

## 2. Decisions (locked)

| # | Decision | Choice | Why |
|---|----------|--------|-----|
| D1 | Hook runtime | **Single Node ESM `.mjs`**, node builtins only (global `fetch`, `node:fs/os/child_process/path`). Zero deps, zero build step. | Node is guaranteed present on any Gemini CLI host (see §3). One cross-platform script replaces the sh+PowerShell lockstep and drops `curl`/`jq`. |
| D2 | Distribution | **Monorepo `plugins/gemini/`**, published as a release archive; one-liner installer downloads+extracts+`gemini extensions install <local-dir>`. | User choice. Keeps single-repo maintenance. See §8 for the native-auto-update caveat this creates. |
| D3 | Eval/block coverage | **Backend's canonical `gemini_cli` set**: monitor `BeforeAgent, BeforeModel, AfterAgent, BeforeTool, AfterTool`; block on `BeforeAgent, AfterAgent, BeforeTool, AfterTool`. | This is what `parseGemini` / `/config` already implement. `AfterModel`/`BeforeToolSelection` are deliberately excluded (see §6). |
| D4 | `/setup` vs `/status` | `/setup` = user-invoked TOML **command**; `/status` = model-invocable **skill** (`SKILL.md`). | Mirrors the Claude plugin's `disable-model-invocation` split within Gemini's own surface conventions. |
| D5 | Credentials | Shared **`~/.rogue-env`** (mode 600), read from disk each invocation, using the **exact env-file precedence chain the other monorepo plugins use** — no legacy `~/.rogue/.api-key`/`env.sh` fallback. | Genuinely shares creds with the other three plugins; one credential model across all four. |

## 3. Node availability — grounding for D1

It is not generally safe to assume a CLI's host has `node`. For Gemini CLI
specifically, it is guaranteed:

- Every documented install method requires **Node.js 20+ on PATH** (npm, npx,
  MacPorts, Anaconda, Docker, from-source) — `docs/get-started/installation`.
- The **Homebrew formula declares `node` as a hard `depends_on`** — `brew install
  gemini-cli` installs node and puts it on PATH.
- There is **no self-contained / single-executable / bundled-runtime build**.
  Gemini CLI *is* run by node, and the extension model launches MCP servers with
  `command: "node"` — the ecosystem assumes `node` is resolvable.
- Gemini's hook/extension **env sanitization preserves `PATH`, `HOME`, `TMPDIR`**,
  so the hook subprocess can both resolve `node` and read `~/.rogue-env` from disk.

Node 20 provides global `fetch` and `JSON.parse`, so the hook needs no npm
dependencies and no `curl`/`jq`.

## 4. Gemini extension mechanics (facts we rely on)

- Extensions load from `~/.gemini/extensions/<name>/`; each needs
  `gemini-extension.json` at its root.
- **Hooks are defined in `hooks/hooks.json`** inside the extension (NOT in the
  manifest). Variable substitution `${extensionPath}`, `${workspacePath}`,
  `${/}` (platform path separator) works there.
- Hook input arrives on **stdin as JSON**; output must be **only JSON on stdout**
  (logs → stderr). Base fields: `session_id, transcript_path, cwd,
  hook_event_name, timestamp`. Default hook timeout **60000ms**; hooks run
  synchronously (the CLI waits) — this is what makes blocking possible.
- Block/allow is via **exit 0 + structured JSON** on stdout. Native shapes:
  - `BeforeAgent`/`AfterAgent`: `{"decision":"block","reason":...}`
  - `BeforeTool`/`AfterTool`/`BeforeModel`/`AfterModel`: `{"decision":"deny","reason":...}`
  - allow: `{}`
  The Rogue backend's `formatGeminiResponse` already emits these — the hook
  relays the server body verbatim.
- **Hook trust/fingerprinting:** Gemini hashes the hook `command`; changing it
  requires re-approval via `/hooks`. So the `command` string in `hooks.json`
  stays byte-stable forever; only `hook.mjs` changes. `/setup` documents the
  one-time trust step (as the Codex plugin does).
- `settings[]` in the manifest injects env into MCP servers and prompts a
  keychain entry on install — we deliberately **omit it**; creds come from
  `~/.rogue-env`, read from disk.
- Custom commands are TOML under `commands/`; skills are `SKILL.md` under
  `skills/`. Both may be bundled by an extension.

## 5. Backend — already implemented

No server code change is required for the core path. Already present:

- `POST /api/v1/hooks/gemini` → `handleGemini` (`family:"gemini"`,
  `modelProvider:"google"`), in `rogue-aidr-api/src/routers/hooks.ts`.
- `gemini` in the `agent_family` enum → `/status` accepts it
  (`coding-agent-versions.ts`).
- `parseGemini` (`evaluation-core/.../hook-parsers/gemini-hook-parser.ts`) +
  `formatGeminiResponse` (`.../hook-formatters/gemini-hook-formatter.ts`).
- `/config` declares the `gemini_cli` monitored/blocking event set (§6).
- Caddy wildcard-proxies `/api/v1/hooks/*` → aidr (no change).
- `/api/v1/evaluate` (evaluations-api) is model-agnostic (no change).

### The one backend change (from D2 monorepo choice)

`coding-agent-versions.ts` maps `gemini_cli → "qualifire-dev/rogue-plugin-gemini"`.
Because we publish from this monorepo, repoint it to
**`qualifire-dev/rogue-plugins`** so the dashboard "update_available" badge
resolves against the repo we actually release from. (Cosmetic-only: the badge is
derived from the heartbeat's version vs. the repo's latest release tag; a wrong
value is harmless but should be correct.)

### Backend verification pass (no code, before release)

1. `/config` `gemini_cli.monitoredEvents/blockingEvents` match the events we
   register (§6).
2. `parseGemini` maps our exact `x-rogue-event` values (it does today).
3. End-to-end: a blocking ruleset produces a Gemini-honored `decision:deny` /
   `decision:block` through `formatGeminiResponse`.
4. `/status` upsert works with `agent_family:"gemini"`, `agent:"gemini_cli"`.

## 6. Events & data flow

Registered in `hooks/hooks.json` (matcher `.*` on tool events; none on the rest):

| Event | Registered | Blocks? | Content evaluated | Notes |
|-------|-----------|---------|-------------------|-------|
| `BeforeAgent` | ✅ | ✅ | user prompt (`payload.prompt`) | primary prompt gate |
| `BeforeTool` | ✅ | ✅ | `tool_name`+`tool_input` | **MCP calls ride here** (`mcp_` prefix → `mcp` category) |
| `AfterTool` | ✅ | ✅ | `tool_response` | **MCP responses ride here** |
| `AfterAgent` | ✅ | ✅ | final response (`prompt_response`) | "model response" gate |
| `BeforeModel` | ✅ | ❌ (monitor) | none (metadata) | captures `llm_request.model` for the dashboard; no message content |
| `SessionStart` | ✅ | n/a | none | fires the detached heartbeat only |

**Why not `AfterModel` (despite the "full blocking set" preference):**
`parseGemini` intentionally drops `AfterModel`/`BeforeToolSelection` to avoid
double-counting the prompt and streamed response chunks — model identity comes
from `BeforeModel`, the final response from `AfterAgent`. Registering
`AfterModel` would send duplicate/streamed content the server discards. "Model
thinking" is therefore not a separate eval in v1; it is subsumed by the
`BeforeModel`+`AfterAgent` pair. (Override only if we deliberately want raw
streamed-response eval and accept the server-side dedup change.)

Flow: `Gemini event → hook.mjs (stdin) → POST /api/v1/hooks/gemini → eval
pipeline → JSON verdict → hook relays verbatim to stdout → Gemini honors
decision`. Fail-open at every step (`{}` on missing key / network error / bad
response).

## 7. Component design (`plugins/gemini/`)

```
plugins/gemini/
├── .gemini-plugin/plugin.json      # optional monorepo-parity manifest (version bookkeeping)
├── gemini-extension.json           # the real Gemini manifest (name:"rogue", version, contextFileName)
├── hooks/hooks.json                # 5 events + SessionStart heartbeat
├── scripts/
│   ├── hook.mjs                    # the single cross-platform dispatcher
│   ├── setup.mjs                   # writes ~/.rogue-env (mode 600); called by /setup
│   └── heartbeat.mjs               # detached POST /status on SessionStart
├── commands/setup.toml             # user-invoked /setup
├── skills/status/SKILL.md          # model-invocable read-only /status
├── GEMINI.md                       # minimal extension context
└── README.md
```

`gemini-extension.json` (shape):
```json
{
  "name": "rogue",
  "version": "<monorepo release tag>",
  "description": "Rogue Security AIDR for Gemini CLI",
  "contextFileName": "GEMINI.md"
}
```

`hooks/hooks.json` command (byte-stable, per D-trust):
```json
{ "hooks": { "BeforeTool": [ { "matcher": ".*", "hooks": [
  { "type": "command",
    "command": "node \"${extensionPath}${/}scripts${/}hook.mjs\" BeforeTool",
    "timeout": 60000 } ] } ] } }
```
One identical shape per event; `SessionStart` additionally runs
`heartbeat.mjs` (detached). `${extensionPath}${/}` makes the same string work on
Windows and macOS — no OS-specific entries, no polyglot tricks.

### `hook.mjs` responsibilities
1. `event = process.argv[2]`; read all of stdin.
2. Resolve creds via the **same env-file chain as the other monorepo plugins**
   (later wins; process env wins over all files):
   `${extensionPath}/env` (bundled defaults) → `/etc/rogue/env` (MDM;
   `C:\ProgramData\rogue\env` on Windows) → `$HOME/.rogue-env`
   (`%USERPROFILE%\.rogue-env`). Parse `export KEY=value` and shell-unquote so
   values round-trip identically to the sh-sourced form. Actor cascade: env →
   `git config --global user.{email,name}` → hostname/whoami. **No `~/.rogue/.api-key`
   or `env.sh` fallback.**
3. Fail-open `{}` + exit 0 if no API key (log `unconfigured`).
4. Resolve actor (email/name) via the shared cascade.
5. `fetch` POST to `${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/gemini`
   with headers `x-rogue-api-key`, `x-rogue-event`, `x-rogue-actor-email`,
   `x-rogue-actor-name`, `Content-Type: application/json`; body = raw stdin;
   `AbortSignal.timeout(15000)` (inside the 60s hook budget).
6. On any error/non-200/empty → `{}` (fail-open).
7. Relay the server JSON verbatim to stdout; **exit 0 always** (block is carried
   in the relayed JSON per Gemini's structured contract).
8. Log one line per invocation to `${ROGUE_LOG_FILE:-~/.rogue/hook.log}`, with
   server-controlled text sanitized of control chars (log-forgery guard).
   No client-side block-detection modal — Gemini renders the block natively
   (pure-relay, like Codex/Cursor).

### `setup.mjs`
Writes `~/.rogue-env` (mode 600, `export KEY=value` with shell-safe quoting)
containing `ROGUE_API_KEY`, `ROGUE_ACTOR_EMAIL`, `ROGUE_ACTOR_NAME` — identical
format to the other plugins so the file round-trips across all four.

### `heartbeat.mjs`
Detached (`child_process.spawn(..., {detached:true, stdio:'ignore'}).unref()`),
POST `/api/v1/hooks/status` with `{agent_family:"gemini", agent:"gemini_cli",
version, host, actor_email, actor_name}`. Short timeout; never blocks
SessionStart. No custom auto-updater.

### `commands/setup.toml` / `skills/status/SKILL.md`
Port the existing `commands/setup.md` / `commands/status.md` steps: check
`~/.rogue-env`, prompt for `rsk_` key, validate via `GET /api/v1/hooks/ping`,
detect git identity, run `node scripts/setup.mjs`, document the one-time
`/hooks` trust step + session restart. `/status` reads creds, pings, GETs
`/api/v1/hooks/config`, prints mode/rulesets/identity + a `~/.rogue/hook.log`
tail. Both carry macOS and Windows command variants.

## 8. Distribution, install, release (D2 consequences)

- **Release:** extend `scripts/build-release.sh` + `.github/workflows/release.yml`
  to also build `plugins/gemini/` into a **`rogue-plugin-gemini.tar.gz`** whose
  archive **root is the extension** (`gemini-extension.json` at top level) and
  attach it to the same `v*` release.
- **Install (one-liner):** add Gemini detection (`have_cmd gemini`) and a
  `gemini_install_extension` step to `install.sh`/`install.ps1`. Because the
  monorepo root has no `gemini-extension.json`, the installer **downloads +
  extracts** the archive to a temp dir and runs `gemini extensions install
  <dir>` (Gemini makes its own managed copy). This mirrors the Cursor
  copy-based install already in the repo.
- **Auto-update caveat (important):** installing from a local extracted dir
  means Gemini's **native `gemini extensions update` won't auto-track** the
  monorepo's GitHub releases (native tracking wants a repo/release source whose
  root is the extension). **Upgrades = re-run the one-liner**, exactly like the
  Cursor plugin. The dashboard's outdated badge still works via the heartbeat +
  the repointed version map (§5). If we later want native Gemini auto-update
  and gallery discovery, the path is a dedicated `qualifire-dev/rogue-plugin-gemini`
  repo (manifest at root, `gemini-cli-extension` topic) — recorded here as the
  known upgrade path, not built in v1.
- **Version/tag note:** monorepo `v*` tags are currently driven by the Claude
  plugin's version. The Gemini `gemini-extension.json` version will follow the
  monorepo release tag it ships in (shared cadence), so the plugin's version can
  jump with unrelated Claude releases. Accepted for v1 as a cosmetic quirk.

## 9. Testing

- **`hook.mjs` unit tests** (node built-in test runner, no deps): feed captured
  Gemini payloads for each event on stdin, assert the POST body/headers (mock
  `fetch`), assert verbatim relay, assert fail-open `{}` on missing key / network
  error / non-200 / malformed response. Reuse the existing plugin's
  `ROGUE_CAPTURE`-style raw payloads as fixtures.
- **`hooks.json` lint:** valid JSON; command strings byte-stable; every event's
  `command` resolves to `hook.mjs`; `timeout` = 60000.
- **Cross-platform path check:** `${extensionPath}${/}scripts${/}hook.mjs`
  renders correctly on both separators.
- **End-to-end (manual, pre-release):** install into a real Gemini CLI on macOS
  and Windows; run `/setup`, `/status`; trigger a blocking ruleset and confirm
  Gemini honors `decision:deny`/`block`; confirm the dashboard roster shows the
  install.
- **Backend verification pass** (§5) before flipping the version map.

## 10. Out of scope (v1 / YAGNI)

- `AfterModel` streamed-response eval / thinking-specific eval (server dedups it).
- Custom auto-updater (Gemini has native; monorepo install upgrades via re-run).
- `BeforeToolSelection` tool-filtering enforcement (monitor only; server supports
  the shape but it's not in the canonical set).
- Statusline badge (Claude-only nicety).
- Gallery listing / dedicated repo (documented upgrade path in §8).

## 11. Open items to confirm during implementation

- Exact `x-rogue-*` header set `handleGemini`/`enrichFromHeaders` reads (email,
  name, event, model) — confirmed present; verify no `x-rogue-source` needed
  (family is route-bound).
- Whether `gemini extensions install <local-dir>` is the smoothest managed
  install vs. copying into `~/.gemini/extensions/rogue/` directly.
- Confirm the `~/.rogue-env` `export KEY=value` quoting matches the other
  plugins' `printf %q` output so the node parser and the sh `source` path
  produce identical values.
