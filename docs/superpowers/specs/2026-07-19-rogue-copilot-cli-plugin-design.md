# Rogue Security AIDR — GitHub Copilot CLI plugin (design)

Date: 2026-07-19
Status: design — pending user review (do NOT commit this doc)
Author: Yuval + Claude
Branch (at implementation): `feature/fire-XXXX-copilot-cli-plugin` (substitute the real FIRE ticket)

## 1. Goal

Ship a native **GitHub Copilot CLI plugin** that gives Copilot CLI the same Rogue
Security AIDR coverage the Claude, Codex, Cursor, and Gemini plugins already
provide: every meaningful lifecycle event is POSTed to the Rogue backend
(`POST /api/v1/hooks/copilot`), and events that carry evaluable content go through
the evaluations-api and **deny the action when a ruleset flags it**. It ships
`/setup` and `/status` like the other plugins, reuses the shared `~/.rogue-env`
credential model, and is first-class on both **macOS/Linux and Windows**.

The work spans two repos with **separate commits/PRs**:
- `rogue-plugins` — the new `plugins/copilot/` plugin, installer/build/CI wiring.
- `qualifire` — corrections to the *already-present-but-drifted* Copilot backend
  (route, parser, formatter, `/config`, version map, docs, dashboard).

## 2. Decisions (locked)

| # | Decision | Choice | Why |
|---|----------|--------|-----|
| D1 | Hook runtime | **sh/bash + PowerShell dual-dispatcher** (`hook.sh` + `hook.ps1`), like Claude/Codex/Cursor — **NOT** the Gemini single-Node model. | Copilot CLI is a **compiled binary distributed by GitHub; Node is NOT guaranteed on PATH.** Its hooks natively run `bash` (macOS/Linux) and `powershell`/`pwsh` (Windows). See §3. |
| D2 | Distribution | **Native Copilot marketplace CLI** (`copilot plugin marketplace add` + `copilot plugin install rogue@<marketplace>`) against this monorepo, like Claude/Codex — **not** the Gemini/Cursor tarball copy. | Copilot has a first-class plugin CLI and a `marketplace.json` that supports monorepo subdirs (`source: "./plugins/copilot"`). See §8. |
| D3 | Eval/block coverage | **`preToolUse` is the hard-block gate** (tool calls incl. MCP, bash, edit, fetch). `userPromptSubmitted` = monitor-only (Copilot ignores its output). `postToolUse` = monitor + optional `additionalContext` warning. `sessionStart` = heartbeat only. | Grounded in the Copilot hook contract: **only `preToolUse`/`permissionRequest` can deny; `userPromptSubmitted` is observe-only.** See §4/§5. |
| D4 | `/setup` vs `/status` | `/setup` = user-invoked **command** (`commands/setup.md`, writes creds). `/status` = model-invocable **skill** (`skills/status/SKILL.md`, read-only). | Mirrors the Claude/Gemini split (`disable-model-invocation` intent) within Copilot's own `commands/` + `skills/` surfaces. |
| D5 | Credentials | Shared **`~/.rogue-env`** (mode 600), read from disk each invocation, using the **exact env-file precedence + quoting the other four plugins use**. | One credential model across all five agents; the file round-trips between the sh `source` path and the parser path. |
| D6 | Response handling | **Pure relay** (like Codex/Cursor): the backend emits Copilot-native per-event decision JSON; the dispatcher relays it verbatim and **always exits 0**. No local modal. | Copilot renders blocks natively. **Critically, `preToolUse` is fail-CLOSED** — a non-zero exit *denies* the tool — so "always exit 0" is a safety invariant, not a nicety. See §9. |

## 3. Runtime grounding — why dual-dispatcher, not Node (D1)

Unlike Gemini CLI (which guarantees Node 20+ on PATH — every install method
requires it), **GitHub Copilot CLI ships as a GitHub-distributed compiled binary
(`copilot` / `gh copilot`) and makes no guarantee that `node` is on PATH.** So the
Gemini "one `.mjs` for everything" approach is off the table. Instead Copilot's own
hook contract tells us exactly which runtimes ARE guaranteed:

- Copilot hook entries carry a **`bash` field (script for Linux/macOS)** and a
  **`powershell` field (script for Windows)**; the CLI selects the platform-
  appropriate one and runs the command **"in the same shell as the CLI."** (There
  is also a cross-platform `command` fallback copied to both when absent.)
- On **Windows**, Copilot prefers **PowerShell 7+ (`pwsh`)** but **falls back to
  Windows PowerShell 5.1 (`powershell.exe`)** (`powershellFlags` default
  `["-NoProfile","-NoLogo"]`). ⇒ **`hook.ps1` must stay PowerShell-5.1-compatible**,
  exactly like the Claude/Codex/Cursor `hook.ps1`. Do not use pwsh-7-only syntax.
- On **macOS/Linux**, `bash` is the runtime. We keep `hook.sh` POSIX-clean (as the
  Claude one is, tested under `dash`) so it runs identically under bash and dash.

**Big simplification vs. Claude:** Copilot dispatches bash-vs-powershell
**natively per OS** — it does *not* run every entry under every shell. So the
Copilot plugin needs **none** of the Claude "exactly-one-runs" arbitration: no
`; exit 0` polyglot to survive the wrong shell, no dollar-free PowerShell, no Git
Bash `uname` stand-down. Each platform runs exactly one script chosen by Copilot.
(We still append `; exit 0` to the command string — but for a *different* reason:
the fail-closed-preToolUse safety net in §9, not shell arbitration.)

**`bash` is required, not `sh`.** Copilot's field is literally `bash`; bash is
present on macOS (3.2 at `/bin/bash`) and effectively all Linux. Keeping the
script POSIX-clean means it also survives if Copilot ever execs it via `sh`.

## 4. Copilot plugin/hook mechanics (facts we rely on)

Sourced from GitHub Copilot docs (hooks-configuration reference, hooks reference,
use-hooks how-to, cli-plugin-reference, plugins-marketplace, cli-config-dir).

**Plugin layout & manifest**
- A plugin is a directory with a **`plugin.json` manifest at its root** (required
  field: `name`, kebab-case, ≤64 chars; optional `version`, `description`,
  `author{name,email,url}`, `license`, `keywords`, `homepage`, `repository`).
- Component path fields in `plugin.json` (all optional, string or string[]):
  `agents`, `skills`, `commands`, `hooks`, `mcpServers`, `lspServers`,
  `extensions`. Example from the reference: `"hooks": "hooks.json"`,
  `"skills": ["skills/"]`.
- Hooks live in **`hooks.json` at the plugin root, or in `hooks/`** (both work;
  the `hooks` field in `plugin.json` points at the file).
- Skills: `skills/<name>/SKILL.md`. Commands: `commands/` directory (exact
  per-file command format = **open item §12** — mirror Cursor's `commands/*.md`).
- Config dir `~/.copilot` (override `COPILOT_HOME`); plugin cache
  `~/Library/Caches/copilot` / `~/.cache/copilot` / `%LOCALAPPDATA%/copilot`
  (override `COPILOT_CACHE_HOME`). User hooks: `~/.copilot/hooks/`.

**hooks.json shape** (`version: 1`; per-event array; each entry `type:"command"`):
```json
{
  "version": 1,
  "hooks": {
    "preToolUse": [
      { "type": "command",
        "bash": "BASH_COMMAND",
        "powershell": "POWERSHELL_COMMAND",
        "matcher": "REGEX",
        "timeoutSec": 30 }
    ]
  }
}
```
- `matcher` regex is compiled `^(?:PATTERN)$` and must match the **entire tool
  name**. Use `.*` to match all tools on `preToolUse`/`postToolUse`.
- `timeoutSec` (seconds; default 30). We use **30**; the HTTP client times out at
  **15s** so a slow request fails *inside* the budget (clean fail-open).

**Events + block capability** (camelCase / PascalCase both accepted):

| Event | Fires | Can block? | Output contract |
|-------|-------|-----------|-----------------|
| `sessionStart` | new/resume session | no (can inject context) | `{additionalContext?}` |
| `userPromptSubmitted` | user submits a prompt | **NO — observe-only, output ignored** | (none) |
| `userPromptTransformed` | after prompt→model content | rewrite only | `{modifiedTransformedPrompt?}` |
| `preToolUse` | before each tool runs | **YES — deny/allow/ask** | `{"permissionDecision":"allow"\|"deny"\|"ask","permissionDecisionReason":"…","modifiedArgs?":{}}` |
| `postToolUse` | after a tool succeeds | no (modify/inject) | `{"modifiedResult?":{…},"additionalContext?":"…"}` |
| `postToolUseFailure` | after a tool fails | no (recovery ctx) | exit 2 ⇒ stdout appended as context |
| `permissionRequest` | before permission service | **YES (CLI only)** | `{"behavior":"allow"\|"deny","message?":"…","interrupt?":true}` |
| `agentStop`/`Stop` | main agent finishes a turn | **block ⇒ force another turn** | `{"decision":"block"\|"allow","reason":"…"}` |
| `subagentStop` | subagent completes | block ⇒ force turn | `{"decision":…,"reason":…}` |
| `sessionEnd`,`errorOccurred`,`preCompact`,`notification`,`subagentStart` | — | no | fire-and-forget |

**Input payloads (camelCase — Copilot CLI native default):**
- `sessionStart`: `{sessionId, timestamp(number ms), cwd, source:"startup"|"resume"|"new", initialPrompt?}`
- `userPromptSubmitted`: `{sessionId, timestamp, cwd, prompt}`
- `preToolUse`: `{sessionId, timestamp, cwd, toolName, toolArgs}` (`toolArgs` is the tool's args object)
- `postToolUse`: `{sessionId, timestamp, cwd, toolName, toolArgs, toolResult:{resultType:"success", textResultForLlm}}`
- `postToolUseFailure`: `{…, toolName, toolArgs, error}`
- `agentStop`: `{sessionId, timestamp, cwd, transcriptPath, stopReason:"end_turn"}`
- VS Code compat: PascalCase event name + snake_case fields + `hook_event_name`
  (`tool_name`, `tool_input`, `tool_result`, `text_result_for_llm`,
  `transcript_path`). **We ship camelCase**; the parser must read camelCase and
  should also tolerate the snake_case fallbacks.

**Exit-code semantics (⚠ read §9):**
- exit `0`: stdout parsed as decision JSON (empty ⇒ allow).
- exit `2`: for `preToolUse`/`permissionRequest` ⇒ **deny** (even if stdout says
  allow); other events ⇒ warning/context.
- other non-zero: logged; run continues (fail-open) — **EXCEPTION: `preToolUse`
  is fail-CLOSED**, a non-zero exit denies the tool call.
- timeout: **fail-open for every event including `preToolUse`.**

**Install / marketplace**
- `copilot plugin marketplace add OWNER/REPO`; `copilot plugin install NAME@MARKETPLACE`;
  `copilot plugin update NAME`. Also `/plugin install …` slash commands and a
  declarative `enabledPlugins: Record<string,boolean>` in `~/.copilot/settings.json`.
- Marketplace manifest (`.github/plugin/marketplace.json`, and Copilot **also
  reads `.claude-plugin/marketplace.json`** — see §8 collision note):
```json
{ "name": "…", "owner": {"name":"…","email":"…"},
  "metadata": {"description":"…","version":"…"},
  "plugins": [ { "name":"…","description":"…","version":"…","source":"./plugins/copilot" } ] }
```
- Plugin-root reference inside hook commands: **`${PLUGIN_ROOT}`** substitution
  token (documented for hook commands + MCP configs). Exact env-var name at hook
  runtime (`COPILOT_PLUGIN_ROOT` / `CLAUDE_PLUGIN_ROOT` alias / `COPILOT_PLUGIN_DATA`)
  is **open item §12** — the scripts therefore **self-locate from their own path**
  and use `${PLUGIN_ROOT}` only in the (byte-stable) command string.

## 5. Events & data flow (the Copilot plugin)

Registered in `plugins/copilot/hooks.json`:

| Event | Registered | Blocks? | Content evaluated | Notes |
|-------|-----------|---------|-------------------|-------|
| `preToolUse` | ✅ (`matcher:".*"`) | ✅ **deny** | `toolName` + `toolArgs` | **Primary gate.** MCP tool calls ride here (see MCP note). Destructive-cmd / secret-exfil / injected-action detection. |
| `postToolUse` | ✅ (`matcher:".*"`) | ➖ soft | `toolResult.textResultForLlm` | Monitor; on flag emit `{additionalContext:"⚠ …"}` (cannot hard-deny). MCP responses ride here. |
| `userPromptSubmitted` | ✅ | ❌ monitor | `prompt` | POSTed for audit/flagging + dashboard; **Copilot ignores the output** so it cannot deny the prompt. Emit `{}`. |
| `sessionStart` | ✅ | n/a | none | Fires detached heartbeat; emits `{}` (or an unconfigured hint). Not POSTed to `/hooks/copilot`. |

Flow: `Copilot event → hook.sh|hook.ps1 (stdin JSON) → POST /api/v1/hooks/copilot
(headers: x-rogue-api-key, x-rogue-event, x-rogue-actor-email, x-rogue-actor-name)
→ parseCopilot → evaluateCanonicalEvent → evaluations-api → formatCopilotResponse
(native per-event shape) → hook relays verbatim to stdout → exit 0 → Copilot
honors the decision.` Fail-open at every step (`{}` + exit 0).

**Why the prompt gate is monitor-only (deliberate, docs-grounded):** Copilot's
`userPromptSubmitted` is observe-only. Prompt-injection is therefore caught at the
**action** it induces (`preToolUse` deny) — the industry-standard enforcement
point — not at prompt submission. This is the honest analog of the Gemini design's
"AfterModel is subsumed" call. (Future: `userPromptTransformed` could *rewrite* a
malicious prompt into a refusal — out of scope v1, §11.)

**Why no model-response / thinking eval in v1:** Copilot exposes the final
response only via `agentStop.transcriptPath` (no inline text; `postToolUse` carries
tool output, not the assistant message). Evaluating the model response/thinking
would require reading + parsing the transcript file — deferred to v2 (§11). v1
protects **prompt (monitor) + tool actions (BLOCK) + tool results (soft)**.

**MCP note:** Copilot supports MCP servers (plugin `mcpServers`/`.mcp.json`); MCP
tool calls surface through `preToolUse`/`postToolUse` `toolName`. The **exact
`toolName` convention for MCP tools is open item §12** (capture a real payload).
The parser must detect it (prefix match, likely `mcp`-style) and route to the
`mcp` eventCategory so MCP-governance rulesets fire.

## 6. Backend (qualifire) — audit + required changes

**The Copilot backend already exists but was written against a *guessed* schema
and has drifted from the real Copilot hook contract.** Verdicts below are from the
live tree (`rogue-ui/apps/rogue-aidr-api`, `rogue-ui/packages/evaluation-core`);
worktrees under `.claude/worktrees/**` are stale — ignore them.

**Naming (coherent, keep both):** family = **`copilot`** (route `/copilot`, enum,
`resolveHookWorkspaceRulesets` family arg); surface/agent = **`github_copilot`**
(parser `tool`, `/config` key, icon/label maps, heartbeat `agent`, `PLUGIN_REPOS`
key). No `copilot_cli` key exists anywhere — do not introduce one.

### 6.1 `routers/hooks.ts`
- Route `POST /api/v1/hooks/copilot` → `handleCopilot` — **EXISTS.** Uses
  `parseCopilot`, `enrichFromHeaders`, `evaluateCanonicalEvent`,
  `formatCopilotResponse`; `family:"copilot"`, no `modelProvider` (intentional —
  Copilot proxies multiple providers, like Cursor). ✅ keep.
- **DRIFT — fail-open shape:** the `catch` returns `{ blocked: false }`. Every
  other agent returns `{}`. **Fix:** return `{}` (native allow) once the formatter
  is native (below).
- **DRIFT — formatter call signature:** calls `formatCopilotResponse(result)` with
  **no eventType**. Copilot's decision shape is **per-event**. **Fix:** pass
  `canonical.eventType` → `formatCopilotResponse(result, canonical.eventType)`.
- `/status`, `/config`, `/ping` routes — EXIST; `/status` accepts `copilot`. ✅
- Headers read via `enrichFromHeaders`: `x-rogue-actor-email/-name/-model`; event
  via `x-rogue-event`; api-key via auth middleware. **No `x-rogue-source`** (that's
  Cursor-only) — the plugin must NOT send it. ✅

### 6.2 `hook-formatters/copilot-hook-formatter.ts` — **DRIFTED, rewrite**
Current output is a Rogue-invented, event-agnostic `{ blocked, reason }` — **not a
Copilot-native shape.** Rewrite to emit the real per-event contract:
```ts
export function formatCopilotResponse(result: EvalResult, eventType?: string): unknown {
  const allow = result.decision === "allow";
  const reason = result.reason ?? result.findings[0]?.explanation ?? "Blocked by Rogue Security";
  switch (eventType) {
    case "preToolUse":
    case "permissionRequest":
      return allow ? {} : { permissionDecision: "deny", permissionDecisionReason: reason };
    case "agentStop":
    case "subagentStop":
      return allow ? {} : { decision: "block", reason };
    case "postToolUse":
      return allow ? {} : { additionalContext: `⚠ Rogue Security: ${reason}` };
    default: // userPromptSubmitted, sessionStart, … — output ignored/observe-only
      return {};
  }
}
```
Add a `copilot-hook-formatter.test.ts` (peers all have one).

### 6.3 `hook-parsers/copilot-hook-parser.ts` — **DRIFTED, correct field names + MCP**
- **DRIFT — wrong prompt field:** reads `payload.userPrompt`; the real field is
  **`prompt`** (`userPromptSubmitted`). **Fix.**
- **DRIFT — tool fields:** reads `payload.toolName` / `payload.toolArgs` ✅ (these
  are correct), but **`postToolUse` result is not extracted.** Add
  `payload.toolResult?.textResultForLlm` (camelCase) / `tool_result.text_result_for_llm`
  (snake_case) as the tool-response content.
- **DRIFT — event names:** `classifyCopilotEvent` maps `userPromptSubmitted,
  sessionStart, sessionEnd, preToolUse, postToolUse, errorOccurred` — these happen
  to match the real camelCase events ✅, but were unsourced. Confirm + add
  `postToolUseFailure` (→ tool_call, audit) and tolerate PascalCase + `hook_event_name`.
- **DRIFT — no MCP:** classifier never returns `mcp`, no `mcp_context`. **Fix:**
  detect MCP `toolName` (§12 convention) and route to `mcp` so `isMcpEvent`
  triggers MCP-governance eval. Mirror `gemini-hook-parser`'s `mcp` handling.
- **DRIFT — header-only eventType:** falls back to `"unknown"` if header absent.
  Add body-`hook_event_name` fallback (as Gemini/OpenAI parsers do).
- Minor: remove the unused `safeObj` import.
- Add Copilot cases to `hook-parsers.test.ts` (currently none).

### 6.4 `/config` `github_copilot` block (`hooks.ts` `getConfig`) — **DRIFTED**
Current: `blockingEvents:["userPromptSubmitted","preToolUse"]`. **`userPromptSubmitted`
cannot block in Copilot.** Target:
```ts
github_copilot: {
  enabled: true,
  monitoredEvents: ["sessionStart","userPromptSubmitted","preToolUse","postToolUse"],
  blockingEvents: ["preToolUse"],
  evaluationTimeoutMs: 3000,
},
```
And in `hook-event-classification.ts`, **explicitly register Copilot's events**
(`preToolUse` → BLOCKING; `userPromptSubmitted` → PROMPT_SUBMIT/audit; `postToolUse`
→ evaluated + AUDIT_ONLY_EVAL so it yields `additionalContext`, never a hard deny).
Today Copilot's `preToolUse`/`postToolUse` only "work" by string-collision with
Cursor's identically-named events — make it explicit, not incidental.

### 6.5 `services/coding-agent-versions.ts`
- `CODING_AGENT_FAMILIES` includes `"copilot"` ✅.
- **MISSING — `PLUGIN_REPOS` has no `github_copilot` key** ⇒ Copilot never shows
  "outdated" (`getLatestPluginVersion` returns null). **Fix:** add
  `github_copilot: "qualifire-dev/rogue-plugins"`.

### 6.6 Docs — `docs-content/.../coding-agents/github-copilot.mdx` — **DRIFTED (thin)**
Exists + registered in `meta.json`, but documents a **generic curl/exit-code
bridge** (`ROGUE_HOOK_TOOL=copilot`, `ROGUE_API_URL`) — not the native plugin.
Rewrite to the native-plugin install (`copilot plugin marketplace add …`), the
event table (§5), `/setup` + `/status`, the one-time hook-trust step (§12), and the
`rgx!` false-positive escape hatch — matching the Gemini/Cursor mdx style.

### 6.7 Dashboard — `agent-icons.tsx` + `coding-agent-status.tsx` — **CORRECT**
`CopilotIcon`, `AGENT_ICON_KINDS["github_copilot"]`, `FAMILY_ICON_KINDS["copilot"]`,
`AGENT_FAMILY_LABELS["copilot"]="Copilot"`, `AGENT_LABELS["github_copilot"]="GitHub
Copilot"` all wired ✅. (Outdated badge starts working once 6.5 lands.) No change.

### 6.8 Untouched (agent-agnostic) — verify only
`hook-evaluator.ts` (`enrichFromHeaders`, `evaluateCanonicalEvent`, the
`POST ${EVALUATIONS_API_URL}/api/v1/evaluate` call), Caddy `/api/v1/hooks/*`
wildcard, `/api/v1/evaluate` — all model-agnostic. No change; confirm end-to-end.

## 7. Plugin component design (`plugins/copilot/`)

```
plugins/copilot/
├── plugin.json                 # Copilot manifest (name:"rogue", version = source of truth,
│                               #   hooks/commands/skills paths). NO CLAUDE_* refs.
├── hooks.json                  # 4 events; bash + powershell keys → hook.sh / hook.ps1
├── scripts/
│   ├── hook.sh                 # bash/POSIX dispatcher (pure relay, always exit 0)
│   ├── hook.ps1                # PowerShell 5.1-compatible dispatcher (mirror of hook.sh)
│   ├── actor.sh                # actor cascade (sh); inlined in hook.ps1 for Windows
│   ├── setup.sh / setup.ps1    # write ~/.rogue-env (mode 600 / ACL)
│   └── heartbeat.sh / heartbeat.ps1  # detached SessionStart presence beacon
├── commands/
│   └── setup.md                # user-invoked /setup (Copilot command format — §12)
├── skills/
│   └── status/SKILL.md         # model-invocable /status (read-only)
├── COPILOT.md                  # short context file (protected by Rogue; /status,/setup,rgx!)
└── README.md
```

`plugin.json` (shape):
```json
{
  "name": "rogue",
  "version": "<monorepo release version>",
  "description": "Rogue Security AIDR — real-time AI agent detection and response for GitHub Copilot CLI",
  "author": { "name": "Rogue Security", "email": "support@rogue.security" },
  "license": "MIT",
  "hooks": "hooks.json",
  "commands": "commands/",
  "skills": ["skills/"]
}
```

`hooks.json` — one entry per event; **command strings are byte-stable forever**
(hook-trust §12); only `scripts/*` change. Native per-OS dispatch, plus the
`; exit 0` fail-closed safety net (§9):
```json
{
  "version": 1,
  "hooks": {
    "preToolUse": [
      { "type": "command", "matcher": ".*", "timeoutSec": 30,
        "bash": "bash \"${PLUGIN_ROOT}/scripts/hook.sh\" preToolUse ; exit 0",
        "powershell": "& ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path '${PLUGIN_ROOT}' 'scripts/hook.ps1')))) preToolUse ; exit 0" }
    ],
    "postToolUse": [
      { "type": "command", "matcher": ".*", "timeoutSec": 30,
        "bash": "bash \"${PLUGIN_ROOT}/scripts/hook.sh\" postToolUse ; exit 0",
        "powershell": "& ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path '${PLUGIN_ROOT}' 'scripts/hook.ps1')))) postToolUse ; exit 0" }
    ],
    "userPromptSubmitted": [
      { "type": "command", "timeoutSec": 30,
        "bash": "bash \"${PLUGIN_ROOT}/scripts/hook.sh\" userPromptSubmitted ; exit 0",
        "powershell": "& ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path '${PLUGIN_ROOT}' 'scripts/hook.ps1')))) userPromptSubmitted ; exit 0" }
    ],
    "sessionStart": [
      { "type": "command", "timeoutSec": 30,
        "bash": "bash \"${PLUGIN_ROOT}/scripts/hook.sh\" sessionStart ; exit 0",
        "powershell": "& ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path '${PLUGIN_ROOT}' 'scripts/hook.ps1')))) sessionStart ; exit 0" }
    ]
  }
}
```
- The `powershell` value uses the **`[scriptblock]::Create((Get-Content …))`
  loader** (not `-File`) to dodge ExecutionPolicy/GPO — proven in the Claude
  plugin — and works under both pwsh 7 and Windows PowerShell 5.1.
- `${PLUGIN_ROOT}` is Copilot's documented command substitution token. The scripts
  *also* self-locate from `$0` / `$PSCommandPath` so they don't hard-depend on the
  exact runtime env-var name (§12).

### `hook.sh` / `hook.ps1` responsibilities (kept in lockstep — mirror Codex's pure relay)
1. `EVENT=$1` (`preToolUse` | `postToolUse` | `userPromptSubmitted` | `sessionStart`).
2. Resolve env files, **same precedence as the other plugins** (later wins; process
   env beats files): `<plugin-root>/env` → `/etc/rogue/env`
   (`C:\ProgramData\rogue\env`) → `$HOME/.rogue-env` (`%USERPROFILE%\.rogue-env`).
   `hook.sh` `source`s them; `hook.ps1` regex-parses `export KEY=value` and
   shell-unquotes (reuse the Claude `ConvertFrom-ShellQuoted`). Never source a
   world-writable path.
3. **Fail-open on missing key:** emit `{}` (for `sessionStart`, an unconfigured
   hint), `exit 0`.
4. `sessionStart`: fire `heartbeat.{sh,ps1}` detached; emit `{}`; `exit 0`
   (never POST the event).
5. Resolve actor (email/name): env → `git config --global user.{email,name}` →
   hostname/whoami (`actor.sh` / inlined in ps1).
6. POST raw stdin to `${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/copilot`
   (override via `ROGUE_API_URL`) with headers `x-rogue-api-key`, `x-rogue-event`
   (= `$EVENT`), `x-rogue-actor-email`, `x-rogue-actor-name`, `Content-Type`.
   Client timeout **15s** (`curl --max-time 15` / `Invoke-WebRequest -TimeoutSec 15`).
   **No `x-rogue-source`.**
7. On any error / non-200 / empty body → `{}` (fail-open).
8. **Relay the server body verbatim** to stdout; **`exit 0` always** (block is
   carried in the relayed JSON, never the exit code).
9. Log one line per invocation to `${ROGUE_LOG_FILE:-~/.rogue/hook.log}` (shared),
   `provider=github_copilot event=$EVENT outcome=…`, with server text sanitized of
   control chars (log-forgery guard). Block detection is **log-only** — no local
   modal (Copilot renders natively).

### `setup.sh` / `setup.ps1`
Write `~/.rogue-env` (mode 600 / ACL) with `export ROGUE_API_KEY=…`,
`ROGUE_ACTOR_EMAIL=…`, `ROGUE_ACTOR_NAME=…` — **identical POSIX-single-quote
format** the other plugins use, so the file round-trips across all five.

### `heartbeat.sh` / `heartbeat.ps1`
Detached; `POST /api/v1/hooks/status` with
`{agent_family:"copilot", agent:"github_copilot", version, host, actor_email,
actor_name}`. Version read from `plugin.json` without `python3` (grep/sed / regex).
Short timeout; never blocks the session. No custom auto-updater (Copilot has
`copilot plugin update`; monorepo installs upgrade via re-run).

### `commands/setup.md` / `skills/status/SKILL.md`
Port the Gemini/Cursor `/setup` + `/status` steps: check `~/.rogue-env`, prompt for
the `rsk_` key, validate via `GET /api/v1/hooks/ping`, detect git identity, write
creds via `setup.{sh,ps1}`, document the one-time **hook-trust** step (§12) +
session restart. `/status` reads creds, POSTs `/status`, GETs
`/api/v1/hooks/config` (reads `settings.mode`, `tools.github_copilot.monitoredEvents`,
`…blockingEvents`), prints mode/rulesets/identity + a `~/.rogue/hook.log` tail.
Both carry macOS/Linux **and** Windows command variants. `/status` is
model-invocable; `/setup` is user-invoked only (writes creds).

## 8. Distribution, install, release

**Marketplace manifest — collision-safe (like Codex).** All five plugins are named
`rogue`. Copilot reads **both** `.github/plugin/marketplace.json` (native) **and**
`.claude-plugin/marketplace.json` (which points at the *Claude* plugin
`./plugins/rogue`). To stop Copilot resolving `rogue` to the Claude plugin, create a
**dedicated Copilot marketplace with a distinct `name`** so `install
rogue@<copilot-marketplace>` is unambiguous:
```
.github/plugin/marketplace.json  → name:"rogue-copilot", plugins:[{name:"rogue",
                                    version:<match plugin.json>, source:"./plugins/copilot"}]
```
(Which manifest wins when a repo has both, and whether `marketplace add` registers
one or both, is **open item §12** — the distinct marketplace name is the safeguard.)

**Install (one-liner).** Add Copilot to `install.sh` / `install.ps1` mirroring the
**Claude/Codex native-CLI path** (NOT the Gemini/Cursor tarball copy):
- Detect: `have_cmd copilot && agents="$agents copilot"` (sh);
  `Get-Command copilot` (ps1). Add `--copilot` / `-Copilot` flag + guard.
- `install_copilot`: `copilot plugin marketplace add qualifire-dev/rogue-plugins`
  then `copilot plugin install rogue@rogue-copilot` (idempotent; re-run upgrades).
  Non-fatal. Print the one-time hook-trust reminder (like Codex/Gemini).
- `configure_credentials` already writes the shared `~/.rogue-env` once — reused
  verbatim; no Copilot-specific credential code.

**Build/release.** Add a `plugins/copilot` section to `scripts/build-release.sh`
producing **`rogue-plugin-copilot.tar.gz`** for MDM/`compile-customer-plugin.sh`
parity (stage `plugins/copilot/` + `.github/plugin/marketplace.json`, like the
Claude/Codex tarballs — **not** the Gemini "archive-root-is-the-plugin" layout).
`release.yml` uploads all `dist/*.tar.gz` automatically — no change. **Normal
install uses the marketplace CLI (git clone), not the tarball** (mirrors Claude).

**CI (`validate.yml`).** Add one version-sync row:
`plugins/copilot/plugin.json | .github/plugin/marketplace.json | ./plugins/copilot`.
The shell-lint glob `plugins/**/scripts/*.sh` already covers the new `.sh` scripts
(`bash -n` / `dash -n`). `.ps1` is not linted in CI today (unchanged; covered by
`tests/test_hook_ps1.ps1` locally).

**Updates.** `copilot plugin update rogue` (native) or re-run the one-liner. The
dashboard "outdated" badge works via heartbeat + the `PLUGIN_REPOS` entry (6.5).

## 9. Fail-open / fail-closed (safety-critical — Copilot-specific)

Every other Rogue plugin is uniformly fail-open. **Copilot's `preToolUse` is
fail-CLOSED**: a non-zero hook exit (or `exit 2`) *denies* the tool call, which
would break the user's workflow whenever the backend is unreachable. Invariants:
- `hook.sh`/`hook.ps1` **always `exit 0`** and emit `{}` on missing key, network
  error, non-200, or empty body — never let `curl`/`Invoke-WebRequest` failure
  propagate a non-zero exit. **Do NOT `set -e`** in `hook.sh`.
- The command string ends `; exit 0` as a belt-and-suspenders net: if the script
  is missing/crashes before printing, the command still exits 0 (empty stdout ⇒
  allow ⇒ fail-open) instead of fail-closed deny.
- HTTP client timeout (15s) < `timeoutSec` (30s): a slow backend fails cleanly
  *inside* the hook (empty `{}`, exit 0). If the whole hook times out, Copilot
  treats `preToolUse` as **fail-open** anyway — but the 15<30 margin keeps us in
  the clean path.
- A genuine block is `exit 0` **with** the native deny JSON on stdout — verified in
  tests to survive the `; exit 0` suffix (stdout is already written).

## 10. Testing

- **`tests/test_hook_sh_copilot.sh`** (or extend `test_hook_sh.sh`): env file →
  hook → mock server → stdout. Assert per-event: correct endpoint `/hooks/copilot`,
  headers (`x-rogue-event` = event name, api-key, actor email/name), **body passed
  through verbatim**, verbatim relay of the server decision, and **fail-open `{}` +
  exit 0** on missing key / non-200 / unreachable. Explicitly assert a
  `preToolUse` deny relays as `{permissionDecision:"deny",…}` with exit 0.
- **`tests/test_hooks_json_copilot.sh`**: `hooks.json` valid JSON; the 4 expected
  events present; each entry has `bash` + `powershell` keys; command strings
  byte-stable + resolve to `hook.sh`/`hook.ps1`; `timeoutSec:30`; every command
  ends `; exit 0`; `preToolUse`/`postToolUse` carry `matcher:".*"`.
- **`tests/test_hook_ps1.ps1`**: extend the existing `ConvertFrom-ShellQuoted`
  round-trip coverage for the Copilot `hook.ps1`.
- **Backend:** add Copilot cases to `hook-parsers.test.ts` (real captured payloads
  per event, incl. MCP once the convention is known) and a new
  `copilot-hook-formatter.test.ts` (native per-event shapes; allow ⇒ `{}`).
  `bun test` in `evaluation-core`.
- **End-to-end (manual, pre-release):** install into real Copilot CLI on macOS +
  Windows; run `/setup`, `/status`; trigger a blocking ruleset and confirm Copilot
  **denies the tool** via `preToolUse`; confirm the dashboard roster shows the
  install and (post-6.5) the version badge.

## 11. Out of scope (v1 / YAGNI)

- Model-response / thinking evaluation (needs `agentStop.transcriptPath` parsing).
- `userPromptTransformed` prompt-rewrite/neutralization (monitor-only prompt in v1).
- `agentStop`/`subagentStop` force-continue enforcement (formatter supports the
  shape; not registered in the plugin v1).
- `permissionRequest` as a second block gate (redundant with `preToolUse` v1).
- `postToolUse` hard blocking (Copilot can't; soft `additionalContext` only).
- Custom auto-updater (Copilot has `copilot plugin update`).
- Statusline badge (Claude-only nicety).

## 12. Open items to confirm during implementation

1. **Command file format** for `/setup` (`commands/*.md` frontmatter fields, or
   another format) — verify against the plugin reference; fall back to mirroring
   Cursor `commands/*.md`.
2. **MCP `toolName` convention** in `preToolUse`/`postToolUse` — capture a real
   payload; wire the parser's `mcp` detection to it (6.3).
3. **Hook-trust / consent step** — does Copilot fingerprint plugin hook commands
   (like Codex/Gemini) and require a one-time `/hooks` (or install `--consent`)
   approval? If so, document it in `/setup` and keep command strings byte-stable
   (already designed for this).
4. **Plugin-root env var at hook runtime** — confirm `${PLUGIN_ROOT}` substitution
   works in the `bash`/`powershell` command values, and the exact process env-var
   name (`COPILOT_PLUGIN_ROOT` / `CLAUDE_PLUGIN_ROOT` alias / `COPILOT_PLUGIN_DATA`).
   Scripts self-locate as the safeguard.
5. **Marketplace precedence/collision** — with both `.github/plugin/marketplace.json`
   and `.claude-plugin/marketplace.json` in the repo, confirm `copilot plugin
   marketplace add qualifire-dev/rogue-plugins` + `install rogue@rogue-copilot`
   resolves to `./plugins/copilot`, not the Claude plugin.
6. **camelCase vs snake_case payloads** — confirm Copilot CLI emits camelCase by
   default (our assumption); parser tolerates both regardless.
7. **`x-rogue-*` header set** `handleCopilot`/`enrichFromHeaders` actually read —
   confirmed email/name/event/model; verify no extra header is required.
8. **`~/.rogue-env` quoting parity** — confirm the sh `source` path and the
   `hook.ps1` decoder produce identical values for the shared file.

## 13. Work breakdown (two repos, separate PRs, branch `feature/fire-XXXX-copilot-cli-plugin`)

**Repo A — `rogue-plugins`** (plugin + install/build/CI):
- A1. `plugins/copilot/` scaffold: `plugin.json`, `hooks.json`, `COPILOT.md`, `README.md`.
- A2. `scripts/hook.sh` + `scripts/actor.sh` + `tests/test_hook_sh_copilot.sh` (TDD).
- A3. `scripts/hook.ps1` (5.1-compatible) + `tests/test_hook_ps1.ps1` extension.
- A4. `scripts/setup.sh|ps1`, `scripts/heartbeat.sh|ps1`.
- A5. `commands/setup.md`, `skills/status/SKILL.md`.
- A6. `tests/test_hooks_json_copilot.sh` (byte-stability + fail-closed `; exit 0` lint).
- A7. `.github/plugin/marketplace.json`; `validate.yml` version-sync row.
- A8. `install.sh` / `install.ps1` Copilot detection + `install_copilot` + trust reminder.
- A9. `scripts/build-release.sh` Copilot tarball section.
- A10. `CLAUDE.md` — add a "GitHub Copilot CLI plugin" section (conventions, D1/D6
  rationale, fail-closed note).

**Repo B — `qualifire`** (backend corrections, all against the *real* schema):
- B1. `copilot-hook-formatter.ts` → native per-event shapes + `.test.ts` (6.2).
- B2. `copilot-hook-parser.ts` → `prompt` field, `toolResult` extraction, MCP,
  event fallback, drop `safeObj` + `hook-parsers.test.ts` cases (6.3).
- B3. `hooks.ts` → `formatCopilotResponse(result, eventType)`, catch → `{}` (6.1).
- B4. `hooks.ts` `/config` `github_copilot` block + `hook-event-classification.ts`
  explicit Copilot events (6.4).
- B5. `coding-agent-versions.ts` → `PLUGIN_REPOS.github_copilot` (6.5).
- B6. `github-copilot.mdx` rewrite to native plugin (6.6).
- B7. End-to-end verification pass (6.8, §10) before release.

**Release:** bump `plugins/copilot/plugin.json` + `.github/plugin/marketplace.json`
in lockstep; tag `vX.Y.Z`; `release.yml` ships `rogue-plugin-copilot.tar.gz`. Land
B before/with A so the endpoint honors the plugin correctly on first install.
