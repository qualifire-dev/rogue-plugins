# Full GitHub Copilot CLI Hook-Event Coverage — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Send ALL 14 GitHub Copilot CLI hook events to the Rogue backend, with enforcement on `preToolUse`, `postToolUse`, `agentStop`, `subagentStop`, and (forward-compat) `userPromptTransformed`; audit/persist the rest.

**Architecture:** Two repos change together. The **plugin** (`rogue-plugins/plugins/copilot`) registers the 10 missing events in `hooks.json` and, for `agentStop`/`subagentStop`, augments the POST body with a base64 tail of the session `events.jsonl` transcript. The **backend** (`qualifire-fire-1678-copilot/rogue-ui`) parses/classifies/formats the new events, extracts the final assistant message from the transcript tail, and exposes them via the hooks config endpoint.

**Tech Stack:** POSIX `sh` + `curl` and PowerShell 5.1 (`Invoke-WebRequest`) dispatchers; TypeScript on Bun (backend, `bun test`); Python-based shell lint tests.

## Global Constraints

- Copilot CLI reference version validated: **v1.0.71**. Transcript path: `~/.copilot/session-state/<sessionId>/events.jsonl`.
- **Fail-open is safety-critical.** Every `hooks.json` command ends `; exit 0`. `preToolUse` is fail-CLOSED (non-zero exit denies), so dispatchers NEVER `set -e` and ALWAYS `exit 0`.
- `bash`/`powershell` command strings in `hooks.json` are **byte-stable forever** (hook trust). Behavior changes go in `scripts/*` only.
- Register **`agentStop`** (camelCase) only — NOT `Stop` (both fire; registering both double-POSTs).
- Enforcement decision shapes (backend emits, dispatcher relays verbatim): `preToolUse`→`{"permissionDecision":"deny","permissionDecisionReason":R}`; `postToolUse`→`{"modifiedResult":{"resultType":"success","textResultForLlm":R}}`; `agentStop`/`subagentStop`→`{"decision":"block","reason":R}`; `userPromptTransformed`→`{"modifiedTransformedPrompt":R}`; allow→`{}`. `R` = `result.reason` (findings text + `rgx!` guidance).
- Headers unchanged: `x-rogue-api-key`, `x-rogue-event` (camelCase event = `hooks.json` key), `x-rogue-actor-email`, `x-rogue-actor-name`. No `x-rogue-source`, no `x-rogue-agent`.
- Subagent lifecycle hooks arrive with `sessionId = toolu_bdrk_…` (NOT a UUID); backend must not assume UUID. Subagent `agentStop` has empty `transcriptPath`.
- Dispatch: sync for decision-returning events (`preToolUse`, `postToolUse`, `agentStop`, `subagentStop`, `userPromptTransformed`) + `sessionStart`; detached (`( nohup … & )` / `Start-Process -WindowStyle Hidden`) for audit-only events.
- Timeouts: sync events `timeoutSec` 30; detached events `timeoutSec` 5; HTTP client 15s (inside the sync budget).
- Backend: events NOT in `BLOCKING_EVENTS` are still persisted for audit (`hook-evaluator.ts:497`), so audit-only events need only be POSTed + parsed without error.

**Backend repo root:** `/Users/yuval/work/qualifire-fire-1678-copilot/rogue-ui`
**Plugin repo root:** `/Users/yuval/work/rogue-plugins`
**Backend test command:** from `packages/evaluation-core`, `bun test <file>`.

---

## File Structure

**Backend (`qualifire-fire-1678-copilot/rogue-ui/packages/evaluation-core/src/lib`):**
- `hook-parsers/copilot-hook-parser.ts` — aliases, classification, transcript-tail extraction, `userPromptTransformed` content.
- `hook-parsers/hook-parsers.test.ts` — parser unit tests (copilot lives here).
- `hook-formatters/copilot-hook-formatter.ts` — `userPromptTransformed` shape; `postToolUse` standard reason.
- `hook-formatters/copilot-hook-formatter.test.ts` — formatter unit tests.
- `hook-event-classification.ts` — set memberships for `agentStop`/`subagentStop`/`userPromptTransformed`.
- `hook-event-classification.test.ts` — classification unit tests.

**Backend (`.../apps/rogue-aidr-api/src/routers`):**
- `hooks.ts` — `getConfig().tools.github_copilot` monitored/blocking events.

**Backend docs:** `packages/docs-content/docs/integrations/coding-agents/github-copilot.mdx`; repo `CLAUDE.md`.

**Plugin (`rogue-plugins/plugins/copilot`):**
- `hooks.json` — 14 events.
- `scripts/hook.sh`, `scripts/hook.ps1` — sessionStart audit POST + transcript-tail augmentation.
- `plugin.json` + repo `.github/plugin/marketplace.json` — version bump.

**Plugin tests (`rogue-plugins/tests`):**
- `test_hooks_json_copilot.sh` — lint (expected event set + matchers).
- `test_hook_sh_copilot.sh` — dispatcher e2e.

**Plugin docs:** repo `CLAUDE.md` Copilot section.

---

## PHASE A — Backend

### Task A1: Parser — aliases + classification for all new events

**Files:**
- Modify: `packages/evaluation-core/src/lib/hook-parsers/copilot-hook-parser.ts`
- Test: `packages/evaluation-core/src/lib/hook-parsers/hook-parsers.test.ts`

**Interfaces:**
- Produces: `parseCopilot(body, eventType)` returns `CanonicalHookEvent` with `eventType` normalized and `eventCategory` set for `userPromptTransformed`, `permissionRequest`, `subagentStart`, `subagentStop`, `preCompact`, `notification`.

- [ ] **Step 1: Write the failing tests** — append to `hook-parsers.test.ts`:

```ts
  test("parseCopilot normalizes new PascalCase aliases", () => {
    const cases: Array<[string, string]> = [
      ["PermissionRequest", "permissionRequest"],
      ["SubagentStart", "subagentStart"],
      ["SubagentStop", "subagentStop"],
      ["PreCompact", "preCompact"],
      ["Notification", "notification"],
      ["UserPromptTransformed", "userPromptTransformed"],
    ];
    for (const [raw, expected] of cases) {
      const parsed = parseCopilot({ sessionId: "s1" }, raw);
      expect(parsed.eventType).toBe(expected);
    }
  });

  test("parseCopilot classifies permissionRequest by toolName like preToolUse", () => {
    const parsed = parseCopilot(
      { sessionId: "s", toolName: "bash", toolArgs: { command: "ls" } },
      "permissionRequest",
    );
    expect(parsed.eventCategory).toBe("shell_cmd");
  });

  test("parseCopilot classifies subagent/preCompact/notification as non-crashing", () => {
    for (const ev of ["subagentStart", "subagentStop", "preCompact", "notification", "sessionEnd"]) {
      const parsed = parseCopilot({ sessionId: "s" }, ev);
      expect(parsed.tool).toBe("github_copilot");
      expect(parsed.eventType).toBe(ev);
    }
  });

  test("parseCopilot accepts a toolu_bdrk_ subagent sessionId", () => {
    const parsed = parseCopilot(
      { sessionId: "toolu_bdrk_01ABC", toolName: "bash", toolArgs: { command: "echo hi" } },
      "preToolUse",
    );
    expect(parsed.sessionId).toBe("toolu_bdrk_01ABC");
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/yuval/work/qualifire-fire-1678-copilot/rogue-ui/packages/evaluation-core && bun test src/lib/hook-parsers/hook-parsers.test.ts`
Expected: FAIL (aliases not mapped; `permissionRequest` classified as `other`).

- [ ] **Step 3: Add aliases** — in `copilot-hook-parser.ts`, extend `EVENT_ALIASES`:

```ts
const EVENT_ALIASES: Record<string, string> = {
  PreToolUse: "preToolUse",
  PostToolUse: "postToolUse",
  PostToolUseFailure: "postToolUseFailure",
  UserPromptSubmit: "userPromptSubmitted",
  UserPromptTransformed: "userPromptTransformed",
  PermissionRequest: "permissionRequest",
  SessionStart: "sessionStart",
  SessionEnd: "sessionEnd",
  Stop: "agentStop",
  SubagentStart: "subagentStart",
  SubagentStop: "subagentStop",
  PreCompact: "preCompact",
  Notification: "notification",
  ErrorOccurred: "errorOccurred",
};
```

- [ ] **Step 4: Extend classification** — replace `classifyCopilotEvent` body:

```ts
function classifyCopilotEvent(
  eventType: string,
  toolName?: string,
): CanonicalHookEvent["eventCategory"] {
  if (eventType === "userPromptSubmitted" || eventType === "userPromptTransformed") return "prompt";
  if (
    eventType === "sessionStart" ||
    eventType === "sessionEnd" ||
    eventType === "subagentStart" ||
    eventType === "subagentStop"
  ) {
    return "session";
  }
  if (eventType === "errorOccurred" || eventType === "preCompact" || eventType === "notification") {
    return "other";
  }
  if (
    eventType === "preToolUse" ||
    eventType === "postToolUse" ||
    eventType === "postToolUseFailure" ||
    eventType === "permissionRequest"
  ) {
    if (toolName && /^mcp__?/i.test(toolName)) return "mcp";
    if (toolName && /bash|shell|terminal|exec|run/i.test(toolName)) return "shell_cmd";
    if (toolName && /file|edit|read|write|replace|create|view/i.test(toolName)) return "file_op";
    return "tool_call";
  }
  return "other";
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bun test src/lib/hook-parsers/hook-parsers.test.ts`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/yuval/work/qualifire-fire-1678-copilot
git add rogue-ui/packages/evaluation-core/src/lib/hook-parsers/copilot-hook-parser.ts \
        rogue-ui/packages/evaluation-core/src/lib/hook-parsers/hook-parsers.test.ts
git commit -m "feat(copilot): parse+classify all Copilot hook events (FIRE-1678)"
```

---

### Task A2: Parser — transcript-tail extraction + userPromptTransformed content

**Files:**
- Modify: `packages/evaluation-core/src/lib/hook-parsers/copilot-hook-parser.ts`
- Test: `packages/evaluation-core/src/lib/hook-parsers/hook-parsers.test.ts`

**Interfaces:**
- Consumes: `payload.transcriptTailB64` (base64 of the last ~256 KB of `events.jsonl`), `payload.timestamp` (epoch-ms number for turn-end events).
- Produces: for `agentStop`, `canonicalMessages` = `[{role:"assistant", content:<main final reply>}]`; for `subagentStop`, the subagent's last message; for `userPromptTransformed`, `content` = `transformedPrompt`.

- [ ] **Step 1: Write the failing tests** — append to `hook-parsers.test.ts`:

```ts
  const b64 = (s: string) => Buffer.from(s, "utf8").toString("base64");
  const jsonl = (rows: unknown[]) => rows.map((r) => JSON.stringify(r)).join("\n");

  test("parseCopilot agentStop extracts the main final assistant.message ≤ timestamp", () => {
    const tail = jsonl([
      { type: "user.message", timestamp: "2026-07-20T09:00:00.000Z", data: { content: "hi", interactionId: "main-1" } },
      { type: "assistant.message", timestamp: "2026-07-20T09:00:01.000Z", data: { content: "SUB reply", interactionId: "sub-1" } },
      { type: "assistant.message", timestamp: "2026-07-20T09:00:02.000Z", data: { content: "MAIN final", interactionId: "main-1" } },
      { type: "assistant.message", timestamp: "2026-07-20T09:00:09.000Z", data: { content: "FUTURE", interactionId: "main-1" } },
    ]);
    const parsed = parseCopilot(
      { sessionId: "u1", timestamp: 1784538002000, stopReason: "end_turn", transcriptTailB64: b64(tail) },
      "agentStop",
    );
    expect(parsed.content).toBe("MAIN final"); // FUTURE excluded by ts; SUB excluded as non-main
    expect(parsed.canonicalMessages.at(-1)).toEqual({ role: "assistant", content: "MAIN final" });
  });

  test("parseCopilot subagentStop extracts a non-main assistant.message", () => {
    const tail = jsonl([
      { type: "user.message", timestamp: "2026-07-20T09:00:00.000Z", data: { content: "hi", interactionId: "main-1" } },
      { type: "assistant.message", timestamp: "2026-07-20T09:00:01.000Z", data: { content: "worker done", interactionId: "sub-9" } },
      { type: "assistant.message", timestamp: "2026-07-20T09:00:02.000Z", data: { content: "main talking", interactionId: "main-1" } },
    ]);
    const parsed = parseCopilot(
      { sessionId: "u1", timestamp: 1784538002000, agentName: "worker", stopReason: "end_turn", transcriptTailB64: b64(tail) },
      "subagentStop",
    );
    expect(parsed.content).toBe("worker done");
  });

  test("parseCopilot agentStop with empty/absent transcript is audit-safe", () => {
    const parsed = parseCopilot({ sessionId: "toolu_bdrk_1", timestamp: 1, stopReason: "end_turn" }, "agentStop");
    expect(parsed.eventType).toBe("agentStop");
    expect(parsed.canonicalMessages.length).toBe(0);
  });

  test("parseCopilot userPromptTransformed uses transformedPrompt", () => {
    const parsed = parseCopilot(
      { sessionId: "u1", prompt: "orig", transformedPrompt: "TRANSFORMED text" },
      "userPromptTransformed",
    );
    expect(parsed.content).toBe("TRANSFORMED text");
    expect(parsed.canonicalMessages.at(-1)).toEqual({ role: "user", content: "TRANSFORMED text" });
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bun test src/lib/hook-parsers/hook-parsers.test.ts`
Expected: FAIL (no transcript extraction; `content` undefined for these events).

- [ ] **Step 3: Add helpers** — near the top of `copilot-hook-parser.ts` (after imports):

```ts
function toEpochMs(ts: unknown): number {
  if (typeof ts === "number" && Number.isFinite(ts)) return ts;
  if (typeof ts === "string") {
    const n = Date.parse(ts);
    if (!Number.isNaN(n)) return n;
    const asNum = Number(ts);
    if (Number.isFinite(asNum)) return asNum;
  }
  return NaN;
}

interface TranscriptLine {
  type?: string;
  timestamp?: unknown;
  data?: { content?: unknown; interactionId?: unknown } | undefined;
}

// Extract the final assistant reply from a base64 events.jsonl tail.
// wantSubagent=false → main agent's reply (prefer main interactionId);
// wantSubagent=true  → a subagent's reply (interactionId ≠ main).
// Race-safe: only lines with timestamp ≤ maxTs are considered.
function extractAssistantReply(
  tailB64: string,
  maxTs: number,
  wantSubagent: boolean,
): string | undefined {
  let text: string;
  try {
    text = Buffer.from(tailB64, "base64").toString("utf8");
  } catch {
    return undefined;
  }
  const lines: TranscriptLine[] = [];
  for (const raw of text.split("\n")) {
    const s = raw.trim();
    if (!s) continue;
    try {
      lines.push(JSON.parse(s) as TranscriptLine);
    } catch {
      // Partial first line from a mid-object tail cut — skip it.
    }
  }
  // Main interactionId = the latest real (non system_notification) user.message.
  let mainIid: string | undefined;
  for (const l of lines) {
    if (l.type !== "user.message") continue;
    const c = typeof l.data?.content === "string" ? l.data.content : "";
    if (c.startsWith("<system_notification>")) continue;
    const iid = typeof l.data?.interactionId === "string" ? l.data.interactionId : undefined;
    if (iid) mainIid = iid;
  }
  const ceil = Number.isNaN(maxTs) ? Infinity : maxTs;
  let chosen: string | undefined;
  for (const l of lines) {
    if (l.type !== "assistant.message") continue;
    if (toEpochMs(l.timestamp) > ceil) continue;
    const content = typeof l.data?.content === "string" ? l.data.content : "";
    if (!content) continue;
    const iid = typeof l.data?.interactionId === "string" ? l.data.interactionId : undefined;
    if (wantSubagent && mainIid && iid === mainIid) continue;
    if (!wantSubagent && mainIid && iid !== mainIid) {
      // still allow (fallback) but prefer main below
    }
    chosen = content; // keep last matching (lines are chronological)
  }
  return chosen;
}
```

- [ ] **Step 4: Wire extraction into `parseCopilot`** — before the `const prompt = …` line, add transformed-prompt handling, and in the message-building `if/else` chain add branches. Replace the prompt/content lines:

```ts
  const prompt = safeStr(payload.prompt) ?? safeStr(payload.userPrompt);
  const transformedPrompt = safeStr(payload.transformedPrompt);
  let content: string | undefined = prompt ?? command;

  if (event === "userPromptTransformed") {
    content = transformedPrompt ?? prompt ?? content;
  }

  const tailB64 = safeStr(payload.transcriptTailB64);
  let assistantReply: string | undefined;
  if ((event === "agentStop" || event === "subagentStop") && tailB64) {
    assistantReply = extractAssistantReply(
      tailB64,
      toEpochMs(payload.timestamp),
      event === "subagentStop",
    );
    if (assistantReply) content = assistantReply;
  }
```

Then in the `canonicalMessages` `if/else` chain, add these branches BEFORE the final `else if (content)`:

```ts
  } else if (event === "userPromptTransformed" && content) {
    canonicalMessages.push({ role: "user", content });
  } else if ((event === "agentStop" || event === "subagentStop") && assistantReply) {
    canonicalMessages.push({ role: "assistant", content: assistantReply });
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bun test src/lib/hook-parsers/hook-parsers.test.ts`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/yuval/work/qualifire-fire-1678-copilot
git add rogue-ui/packages/evaluation-core/src/lib/hook-parsers/copilot-hook-parser.ts \
        rogue-ui/packages/evaluation-core/src/lib/hook-parsers/hook-parsers.test.ts
git commit -m "feat(copilot): extract final assistant reply from transcript tail for agentStop/subagentStop (FIRE-1678)"
```

---

### Task A3: Formatter — userPromptTransformed shape + postToolUse standard reason

**Files:**
- Modify: `packages/evaluation-core/src/lib/hook-formatters/copilot-hook-formatter.ts`
- Test: `packages/evaluation-core/src/lib/hook-formatters/copilot-hook-formatter.test.ts`

**Interfaces:**
- Produces: `formatCopilotResponse(result, eventType)` returns `{modifiedTransformedPrompt}` for `userPromptTransformed` block; `{modifiedResult:{resultType:"success",textResultForLlm:reason}}` (reason, not a "withheld" wrapper) for `postToolUse` block.

- [ ] **Step 1: Write the failing tests** — append to `copilot-hook-formatter.test.ts`:

```ts
describe("formatCopilotResponse — new/changed shapes", () => {
  test("userPromptTransformed block returns modifiedTransformedPrompt with the reason", () => {
    const out = formatCopilotResponse(block, "userPromptTransformed") as {
      modifiedTransformedPrompt: string;
    };
    expect(out.modifiedTransformedPrompt).toBe(block.reason);
  });

  test("postToolUse block uses the standard reason (no 'withheld' wrapper)", () => {
    const out = formatCopilotResponse(block, "postToolUse") as {
      modifiedResult: { resultType: string; textResultForLlm: string };
    };
    expect(out.modifiedResult.resultType).toBe("success");
    expect(out.modifiedResult.textResultForLlm).toBe(block.reason);
    expect(out.modifiedResult.textResultForLlm).not.toContain("withheld");
  });

  test("userPromptTransformed allow returns {}", () => {
    expect(formatCopilotResponse(allow, "userPromptTransformed")).toEqual({});
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/yuval/work/qualifire-fire-1678-copilot/rogue-ui/packages/evaluation-core && bun test src/lib/hook-formatters/copilot-hook-formatter.test.ts`
Expected: FAIL (no `userPromptTransformed` case; postToolUse still wraps with "withheld").

- [ ] **Step 3: Update the formatter** — in `copilot-hook-formatter.ts`, replace the `switch` cases for `postToolUse` and add `userPromptTransformed`:

```ts
  switch (eventType) {
    case "preToolUse":
    case "permissionRequest":
      return { permissionDecision: "deny", permissionDecisionReason: reason };

    case "agentStop":
    case "subagentStop":
      return { decision: "block", reason };

    case "userPromptTransformed":
      // Only enforceable prompt-stage lever (userPromptSubmitted output is
      // ignored by Copilot). Replace the model-facing prompt with the standard
      // block message so the model never receives the malicious prompt.
      return { modifiedTransformedPrompt: reason };

    case "postToolUse":
      // Replace the flagged tool result with the standard block message
      // (incl. the rgx! override hint) — same text users see on a deny.
      return {
        modifiedResult: {
          resultType: "success",
          textResultForLlm: reason,
        },
      };

    default:
      return {};
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bun test src/lib/hook-formatters/copilot-hook-formatter.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/yuval/work/qualifire-fire-1678-copilot
git add rogue-ui/packages/evaluation-core/src/lib/hook-formatters/copilot-hook-formatter.ts \
        rogue-ui/packages/evaluation-core/src/lib/hook-formatters/copilot-hook-formatter.test.ts
git commit -m "feat(copilot): userPromptTransformed block + standard postToolUse reason (FIRE-1678)"
```

---

### Task A4: Classification — set memberships for enforced events

**Files:**
- Modify: `packages/evaluation-core/src/lib/hook-event-classification.ts`
- Test: `packages/evaluation-core/src/lib/hook-event-classification.test.ts`

**Interfaces:**
- Produces: `isBlockingEvent("agentStop"|"subagentStop"|"userPromptTransformed") === true`; `FULL_EVAL_EVENTS` includes `agentStop`,`subagentStop`; `ASSISTANT_RESPONSE_EVENTS` includes `agentStop`; `ASSISTANT_DIRECTION_EVENTS` includes `agentStop`,`subagentStop`.

- [ ] **Step 1: Write the failing tests** — append to `hook-event-classification.test.ts`:

```ts
  test("Copilot enforced events are blocking + fully evaluated", () => {
    for (const ev of ["agentStop", "subagentStop", "userPromptTransformed"]) {
      expect(isBlockingEvent(ev)).toBe(true);
    }
    expect(FULL_EVAL_EVENTS.has("agentStop")).toBe(true);
    expect(FULL_EVAL_EVENTS.has("subagentStop")).toBe(true);
  });

  test("Copilot agentStop is an assistant-response + assistant-direction event", () => {
    expect(ASSISTANT_RESPONSE_EVENTS.has("agentStop")).toBe(true);
    expect(isAssistantDirectionEvent({ eventType: "agentStop" })).toBe(true);
    expect(isAssistantDirectionEvent({ eventType: "subagentStop" })).toBe(true);
  });

  test("Copilot audit-only events are NOT blocking", () => {
    for (const ev of ["subagentStart", "sessionEnd", "permissionRequest", "preCompact", "notification", "postToolUseFailure", "errorOccurred"]) {
      expect(isBlockingEvent(ev)).toBe(false);
    }
  });
```

Ensure the test file imports `FULL_EVAL_EVENTS`, `ASSISTANT_RESPONSE_EVENTS`, `isAssistantDirectionEvent`, `isBlockingEvent` (add any missing to the existing import from `./hook-event-classification`).

- [ ] **Step 2: Run tests to verify they fail**

Run: `bun test src/lib/hook-event-classification.test.ts`
Expected: FAIL (`agentStop`/`subagentStop`/`userPromptTransformed` not yet in sets).

- [ ] **Step 3: Update the sets** in `hook-event-classification.ts`:

In `BLOCKING_EVENTS`, extend the GitHub Copilot block:

```ts
  // GitHub Copilot — userPromptSubmitted is Copilot-only; preToolUse/postToolUse
  // are shared with Cursor. agentStop/subagentStop enforce on the final reply /
  // subagent message; userPromptTransformed is the only enforceable prompt lever.
  "userPromptSubmitted", "agentStop", "subagentStop", "userPromptTransformed",
```

In `ASSISTANT_RESPONSE_EVENTS`, add:

```ts
  "agentStop",          // GitHub Copilot (final reply via transcript tail)
```

In `FULL_EVAL_EVENTS`, add:

```ts
  "agentStop", "subagentStop", // GitHub Copilot final reply / subagent message
```

In `ASSISTANT_DIRECTION_EVENTS`, add:

```ts
  // GitHub Copilot (assistant-authored content)
  "agentStop", "subagentStop",
```

(Do NOT add `userPromptTransformed` to `ASSISTANT_DIRECTION_EVENTS` — it is user-derived and classified as a `prompt`.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `bun test src/lib/hook-event-classification.test.ts`
Expected: PASS.

- [ ] **Step 5: Run the whole evaluation-core suite** (regression)

Run: `bun test src/`
Expected: PASS (no regressions in hook-evaluator/formatters/parsers).

- [ ] **Step 6: Commit**

```bash
cd /Users/yuval/work/qualifire-fire-1678-copilot
git add rogue-ui/packages/evaluation-core/src/lib/hook-event-classification.ts \
        rogue-ui/packages/evaluation-core/src/lib/hook-event-classification.test.ts
git commit -m "feat(copilot): classify agentStop/subagentStop/userPromptTransformed as enforced (FIRE-1678)"
```

---

### Task A5: Config endpoint — expose all Copilot events

**Files:**
- Modify: `apps/rogue-aidr-api/src/routers/hooks.ts` (the `github_copilot` block, ~lines 147-158)

**Interfaces:**
- Produces: `GET /hooks/config` `tools.github_copilot.monitoredEvents` lists all 14; `blockingEvents` = enforced set.

- [ ] **Step 1: Update the config block** — replace the `github_copilot` object:

```ts
      github_copilot: {
        enabled: true,
        monitoredEvents: [
          "sessionStart", "sessionEnd", "userPromptSubmitted", "userPromptTransformed",
          "preToolUse", "postToolUse", "postToolUseFailure", "permissionRequest",
          "agentStop", "subagentStart", "subagentStop", "preCompact",
          "errorOccurred", "notification",
        ],
        // preToolUse hard-denies; postToolUse replaces the result; agentStop and
        // subagentStop block on the final reply / subagent message (transcript
        // tail); userPromptTransformed rewrites a malicious prompt (dormant until
        // Copilot emits the event). Everything else is audit-only (persisted).
        blockingEvents: [
          "userPromptTransformed", "preToolUse", "postToolUse", "agentStop", "subagentStop",
        ],
        evaluationTimeoutMs: 3000,
      },
```

- [ ] **Step 2: Type-check the API app**

Run: `cd /Users/yuval/work/qualifire-fire-1678-copilot/rogue-ui && bun run --filter rogue-aidr-api typecheck 2>/dev/null || (cd apps/rogue-aidr-api && bunx tsc --noEmit)`
Expected: no new type errors in `hooks.ts`.

- [ ] **Step 3: Commit**

```bash
cd /Users/yuval/work/qualifire-fire-1678-copilot
git add rogue-ui/apps/rogue-aidr-api/src/routers/hooks.ts
git commit -m "feat(copilot): advertise all 14 hook events in hooks config (FIRE-1678)"
```

---

### Task A6: Backend docs + CLAUDE.md

**Files:**
- Modify: `packages/docs-content/docs/integrations/coding-agents/github-copilot.mdx`
- Modify: `/Users/yuval/work/qualifire-fire-1678-copilot/CLAUDE.md` (Copilot section, if present)

- [ ] **Step 1: Update the events table** in `github-copilot.mdx` to list all 14 events with their treatment (mirror the plan's Global Constraints decision shapes and the audit/enforce split). Include the note that `userPromptTransformed` is not emitted by Copilot ≤ v1.0.71 (forward-compatible), and that subagent lifecycle hooks carry `sessionId=toolu_bdrk_…`.

- [ ] **Step 2: Update `CLAUDE.md`** Copilot section with: the full event list; agentStop/subagentStop transcript-tail read (`transcriptTailB64`); the `toolu_bdrk_…` subagent-sessionId + empty-transcriptPath facts; best-effort concurrent-subagent attribution limitation.

- [ ] **Step 3: Commit**

```bash
cd /Users/yuval/work/qualifire-fire-1678-copilot
git add rogue-ui/packages/docs-content/docs/integrations/coding-agents/github-copilot.mdx CLAUDE.md
git commit -m "docs(copilot): document full hook-event coverage (FIRE-1678)"
```

---

## PHASE B — Plugin

### Task B1: hooks.json — register all 14 events

**Files:**
- Modify: `plugins/copilot/hooks.json`

**Interfaces:**
- Produces: `hooks.json` with 14 event keys. Sync events call `hook.sh`/`hook.ps1 <event>`; detached audit events use the nohup/Start-Process pattern; `sessionStart` keeps its heartbeat entry + the hook.sh entry.

- [ ] **Step 1: Replace `plugins/copilot/hooks.json`** with the full 14-event file. Sync entry template (per event `E` with `timeoutSec` T):

```
"bash": "bash \"${PLUGIN_ROOT}/scripts/hook.sh\" E ; exit 0",
"powershell": "try { & ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path '${PLUGIN_ROOT}' 'scripts/hook.ps1')))) E '${PLUGIN_ROOT}' } catch { '{}' } ; exit 0",
"timeoutSec": T
```

Detached audit entry template (per event `E`):

```
"bash": "( nohup bash \"${PLUGIN_ROOT}/scripts/hook.sh\" E >/dev/null 2>&1 & ) ; exit 0",
"powershell": "Start-Process -FilePath 'powershell' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-Command',(\"& ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path '${PLUGIN_ROOT}' 'scripts/hook.ps1')))) E '${PLUGIN_ROOT}'\") -WindowStyle Hidden ; exit 0",
"timeoutSec": 5
```

Apply per event:
- `sessionStart`: keep the existing 2 entries (heartbeat detached `timeoutSec` 5; hook.sh sync `timeoutSec` 10).
- SYNC, `timeoutSec` 30, WITH `"matcher": ".*"`: `preToolUse`, `postToolUse`, `permissionRequest`, `subagentStop`.
- SYNC, `timeoutSec` 30, NO matcher: `userPromptTransformed`, `agentStop`.
- DETACHED audit, `timeoutSec` 5, WITH `"matcher": ".*"`: `postToolUseFailure`, `subagentStart`, `preCompact`, `notification`.
- DETACHED audit, `timeoutSec` 5, NO matcher: `userPromptSubmitted`, `sessionEnd`.

> Note: `subagentStop` is SYNC (it enforces) but also carries a `matcher`. `permissionRequest` is audit-only yet SYNC — it sits on the permission gate; the dispatcher returns `{}` so it never blocks, but running it sync keeps the timing correct. Do NOT register `Stop`.

- [ ] **Step 2: Validate JSON**

Run: `python3 -c "import json;d=json.load(open('/Users/yuval/work/rogue-plugins/plugins/copilot/hooks.json'));print(sorted(d['hooks']))"`
Expected: all 14 event names printed.

- [ ] **Step 3: Commit**

```bash
cd /Users/yuval/work/rogue-plugins
git add plugins/copilot/hooks.json
git commit -m "feat(copilot): register all 14 Copilot hook events (FIRE-1678)"
```

---

### Task B2: Update hooks.json lint test

**Files:**
- Modify: `tests/test_hooks_json_copilot.sh`

**Interfaces:**
- Consumes: `plugins/copilot/hooks.json` from Task B1.
- Produces: lint asserting the new expected event set + matcher rules.

- [ ] **Step 1: Update the expected-event assertions** in `test_hooks_json_copilot.sh`. Replace the `expected_events` set and `matcher_required`:

```python
expected_events = {
    "sessionStart", "sessionEnd", "userPromptSubmitted", "userPromptTransformed",
    "preToolUse", "postToolUse", "postToolUseFailure", "permissionRequest",
    "agentStop", "subagentStart", "subagentStop", "preCompact",
    "errorOccurred", "notification",
}
```

```python
matcher_required = {
    "preToolUse", "postToolUse", "postToolUseFailure", "permissionRequest",
    "subagentStart", "subagentStop", "preCompact", "notification",
}
```

Also add an assertion that `Stop` is NOT present (guards the double-POST regression):

```python
if "Stop" in hooks:
    errors.append("event 'Stop' must not be registered (agentStop already fires)")
```

- [ ] **Step 2: Run the lint to verify it passes against B1**

Run: `bash /Users/yuval/work/rogue-plugins/tests/test_hooks_json_copilot.sh`
Expected: exits 0 (all invariants hold: 14 events, `; exit 0`, `${PLUGIN_ROOT}`, matchers, positive timeouts).

- [ ] **Step 3: Commit**

```bash
cd /Users/yuval/work/rogue-plugins
git add tests/test_hooks_json_copilot.sh
git commit -m "test(copilot): lint the full 14-event hooks.json (FIRE-1678)"
```

---

### Task B3: hook.sh — sessionStart audit POST + transcript-tail augmentation

**Files:**
- Modify: `plugins/copilot/scripts/hook.sh`

**Interfaces:**
- Consumes: stdin JSON payload; env creds; `$EVENT` argv[1].
- Produces: for `agentStop`/`subagentStop`, POST body augmented with `"transcriptTailB64"`; for `sessionStart` with a key set, an audit POST (returns `{}`); relays backend response verbatim for sync events.

- [ ] **Step 1: Add a transcript-augment helper** — after the `sanitize()` definition in `hook.sh`:

```sh
# Append the last ~256KB of the transcript (events.jsonl) as base64 so the
# backend can extract the final assistant message. Safe string concat: base64
# output contains no JSON-special chars. Fail-open: returns $1 unchanged on any
# problem. $1 = original JSON body; echoes the (possibly augmented) body.
augment_with_transcript() {
  _body="$1"
  _tp=$(printf '%s' "$_body" | sed -n 's/.*"transcriptPath":"\([^"]*\)".*/\1/p')
  [ -n "$_tp" ] || { printf '%s' "$_body"; return; }
  [ -r "$_tp" ] || { printf '%s' "$_body"; return; }
  _b64=$(tail -c 262144 "$_tp" 2>/dev/null | base64 2>/dev/null | tr -d '\r\n')
  [ -n "$_b64" ] || { printf '%s' "$_body"; return; }
  printf '%s,"transcriptTailB64":"%s"}' "${_body%\}}" "$_b64"
}
```

- [ ] **Step 2: Refactor the POST into a reusable function** — replace the block from `URL="…"` through `exit 0` at the end with:

```sh
[ -r "${PLUGIN_ROOT}/scripts/actor.sh" ] && . "${PLUGIN_ROOT}/scripts/actor.sh"

URL="${ROGUE_API_URL:-${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/copilot}"

# POST $1 (body) for $EVENT; echoes the relayable body ("" on any failure).
post_event() {
  _raw=$(printf '%s' "$1" | curl -sS -X POST "$URL" \
    -H "x-rogue-api-key: $ROGUE_API_KEY" \
    -H "x-rogue-event: $EVENT" \
    -H "x-rogue-actor-email: $ROGUE_ACTOR_EMAIL" \
    -H "x-rogue-actor-name: $ROGUE_ACTOR_NAME" \
    -H 'Content-Type: application/json' \
    --data-binary @- --max-time 15 -w '\n%{http_code}')
  _rc=$?
  _code=$(printf '%s' "$_raw" | tail -n1)
  _body=$(printf '%s' "$_raw" | sed '$d')
  log "http=$_code rc=$_rc raw=$(sanitize "$_body" | head -c 400)"
  if [ "$_rc" -ne 0 ] || [ "$_code" != "200" ] || [ -z "$_body" ]; then
    printf ''
    return
  fi
  printf '%s' "$_body"
}

BODY="$(cat)"

# agentStop / subagentStop: enrich with the transcript tail so the backend can
# evaluate the final assistant reply (main) / subagent message.
case "$EVENT" in
  agentStop|subagentStop) BODY="$(augment_with_transcript "$BODY")" ;;
esac

RESP="$(post_event "$BODY")"
if [ -z "$RESP" ]; then
  log "outcome=allow"
  echo '{}'
  exit 0
fi
printf '%s' "$RESP"
exit 0
```

- [ ] **Step 3: Update the `sessionStart` early-return** to POST for audit — replace the existing `if [ "$EVENT" = "sessionStart" ]; then … fi` block:

```sh
# SessionStart: emit the unconfigured hint when no key; otherwise POST for audit
# (persistence) and allow. The heartbeat is a separate hooks.json entry.
if [ "$EVENT" = "sessionStart" ]; then
  if [ -z "${ROGUE_API_KEY:-}" ]; then
    log "outcome=unconfigured"
    printf '{"additionalContext":"[Rogue Security] Not configured. Run /rogue:setup to connect your API key."}'
    exit 0
  fi
  # fall through to the normal POST path below (audit-only; backend returns {}).
fi
```

Ensure the `[ -z "$ROGUE_API_KEY" ]` generic fail-open check still runs after this (unconfigured non-sessionStart events emit `{}`). The `actor.sh` sourcing, `post_event`, and `BODY` handling from Step 2 now serve `sessionStart` too (its `case` doesn't match agentStop/subagentStop, so no augmentation).

- [ ] **Step 4: POSIX lint under dash**

Run: `dash -n /Users/yuval/work/rogue-plugins/plugins/copilot/scripts/hook.sh && echo OK`
Expected: `OK` (no syntax errors).

- [ ] **Step 5: Commit**

```bash
cd /Users/yuval/work/rogue-plugins
git add plugins/copilot/scripts/hook.sh
git commit -m "feat(copilot): hook.sh sessionStart audit POST + transcript-tail augmentation (FIRE-1678)"
```

---

### Task B4: hook.ps1 — mirror sessionStart audit POST + transcript-tail augmentation

**Files:**
- Modify: `plugins/copilot/scripts/hook.ps1`

**Interfaces:**
- Produces: identical behavior to `hook.sh` on Windows (PowerShell 5.1): sessionStart audit POST; `transcriptTailB64` augmentation for `agentStop`/`subagentStop`.

- [ ] **Step 1: Read `hook.ps1`** to match its current structure (variable names, the `Invoke-WebRequest` block, the sessionStart branch).

Run: `sed -n '1,200p' /Users/yuval/work/rogue-plugins/plugins/copilot/scripts/hook.ps1`

- [ ] **Step 2: Add a transcript-augment function** (5.1-compatible) near the top helpers:

```powershell
function Add-TranscriptTail([string]$Body) {
  try {
    $m = [regex]::Match($Body, '"transcriptPath":"([^"]*)"')
    if (-not $m.Success) { return $Body }
    $tp = $m.Groups[1].Value
    if ([string]::IsNullOrEmpty($tp) -or -not (Test-Path -LiteralPath $tp)) { return $Body }
    $fs = [System.IO.File]::Open($tp, 'Open', 'Read', 'ReadWrite')
    try {
      $len = $fs.Length
      $take = [Math]::Min(262144, $len)
      $fs.Seek($len - $take, 'Begin') | Out-Null
      $buf = New-Object byte[] $take
      [void]$fs.Read($buf, 0, $take)
    } finally { $fs.Close() }
    $b64 = [Convert]::ToBase64String($buf)
    if ([string]::IsNullOrEmpty($b64)) { return $Body }
    return ($Body.TrimEnd().TrimEnd('}')) + ',"transcriptTailB64":"' + $b64 + '"}'
  } catch { return $Body }
}
```

- [ ] **Step 3: Buffer stdin + augment for agentStop/subagentStop** — where `hook.ps1` reads stdin into the request body, capture it into `$body`, then:

```powershell
if ($EVENT -eq 'agentStop' -or $EVENT -eq 'subagentStop') {
  $body = Add-TranscriptTail $body
}
```

- [ ] **Step 4: sessionStart audit POST** — update the sessionStart branch so that, when the API key IS set, it falls through to the normal POST (audit; relay `{}`), and only emits the unconfigured `additionalContext` hint when the key is missing (mirror `hook.sh` Step 3).

- [ ] **Step 5: Confirm always-`exit 0` / fail-open** on every path (missing key, non-200, exception). PowerShell parse check:

Run: `pwsh -NoProfile -Command "[void][ScriptBlock]::Create((Get-Content -Raw -LiteralPath '/Users/yuval/work/rogue-plugins/plugins/copilot/scripts/hook.ps1')); 'OK'"`
Expected: `OK` (parses; skip this step if `pwsh` is unavailable on the dev machine — CI covers Windows).

- [ ] **Step 6: Commit**

```bash
cd /Users/yuval/work/rogue-plugins
git add plugins/copilot/scripts/hook.ps1
git commit -m "feat(copilot): hook.ps1 sessionStart audit POST + transcript-tail augmentation (FIRE-1678)"
```

---

### Task B5: Dispatcher e2e tests

**Files:**
- Modify: `tests/test_hook_sh_copilot.sh`

**Interfaces:**
- Consumes: `hook.sh` from B3; the repo mock server (`tests/mock_server.py`).
- Produces: assertions that agentStop augments the body with `transcriptTailB64`, sessionStart POSTs when configured, and every path exits 0.

- [ ] **Step 1: Read the existing test** to reuse its harness (mock server, `run_dispatcher`, env-file setup).

Run: `sed -n '40,200p' /Users/yuval/work/rogue-plugins/tests/test_hook_sh_copilot.sh`

- [ ] **Step 2: Add an agentStop transcript-tail test.** Create a temp `events.jsonl`, feed an `agentStop` payload whose `transcriptPath` points at it, and assert the request body the mock server received contains `transcriptTailB64` and that stdout is the relayed body with exit 0. Use the harness's mock-server request capture (extend `mock_server.py` to also dump the request body to a file if it does not already). Concretely:

```sh
test_agentstop_augments_transcript() {
  tdir="$(mktemp -d)"
  printf '%s\n' \
    '{"type":"user.message","timestamp":"2026-07-20T09:00:00.000Z","data":{"content":"hi","interactionId":"main-1"}}' \
    '{"type":"assistant.message","timestamp":"2026-07-20T09:00:02.000Z","data":{"content":"MAIN final","interactionId":"main-1"}}' \
    > "$tdir/events.jsonl"
  payload=$(printf '{"sessionId":"u1","timestamp":1784538002000,"stopReason":"end_turn","transcriptPath":"%s"}' "$tdir/events.jsonl")
  # run hook.sh agentStop with $payload on stdin against the mock server;
  # assert captured request body contains "transcriptTailB64" and exit code is 0.
}
```

Wire it into the test's runner list alongside the existing cases. If `mock_server.py` lacks body capture, add a minimal write of the POST body to `$BODY_FILE` (env-provided path) in its POST handler.

- [ ] **Step 3: Add a sessionStart-configured-POST test** — assert that with a key set, `sessionStart` produces a request to `/hooks/copilot` (mock receives it) and stdout is `{}` with exit 0; and with NO key, stdout contains `additionalContext` and no request is made.

- [ ] **Step 4: Run the dispatcher tests (sh and dash)**

Run: `bash /Users/yuval/work/rogue-plugins/tests/test_hook_sh_copilot.sh && TEST_SH=dash bash /Users/yuval/work/rogue-plugins/tests/test_hook_sh_copilot.sh`
Expected: both pass (POSIX-clean).

- [ ] **Step 5: Commit**

```bash
cd /Users/yuval/work/rogue-plugins
git add tests/test_hook_sh_copilot.sh tests/mock_server.py
git commit -m "test(copilot): dispatcher transcript-tail + sessionStart audit POST (FIRE-1678)"
```

---

### Task B6: Version bump + plugin docs

**Files:**
- Modify: `plugins/copilot/plugin.json` (version `1.0.0` → `1.1.0`)
- Modify: `.github/plugin/marketplace.json` (both `version` occurrences → `1.1.0`)
- Modify: `/Users/yuval/work/rogue-plugins/CLAUDE.md` (Copilot section)

- [ ] **Step 1: Bump the version** in `plugins/copilot/plugin.json` and BOTH `version` fields in `.github/plugin/marketplace.json` to `1.1.0`.

- [ ] **Step 2: Verify version-sync invariant**

Run: `python3 -c "import json;a=json.load(open('/Users/yuval/work/rogue-plugins/plugins/copilot/plugin.json'))['version'];m=json.load(open('/Users/yuval/work/rogue-plugins/.github/plugin/marketplace.json'));vs={a}|{p['version'] for p in m.get('plugins',[])}|{m.get('version')};print('sync' if len(vs)==1 else ('MISMATCH: '+str(vs)))"`
Expected: `sync`.

- [ ] **Step 3: Update `CLAUDE.md`** GitHub Copilot section: list all 14 events with the audit/enforce split; document the transcript-tail augmentation (`transcriptTailB64`) in `hook.sh`/`hook.ps1`; the `sessionStart` audit POST; the `agentStop`/`subagentStop` decision shapes; `userPromptTransformed` forward-compat note; subagent `sessionId=toolu_bdrk_…` + empty `transcriptPath`; concurrent-subagent best-effort attribution limitation; and that `Stop` is intentionally NOT registered.

- [ ] **Step 4: Run the full plugin test suite** (regression)

Run: `bash /Users/yuval/work/rogue-plugins/tests/test_hooks_json_copilot.sh && bash /Users/yuval/work/rogue-plugins/tests/test_hook_sh_copilot.sh`
Expected: both pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/yuval/work/rogue-plugins
git add plugins/copilot/plugin.json .github/plugin/marketplace.json CLAUDE.md
git commit -m "chore(copilot): bump to 1.1.0 + document full hook coverage (FIRE-1678)"
```

---

## PHASE C — End-to-end verification

### Task C1: Live capture verification against real Copilot

**Files:** none (verification only).

- [ ] **Step 1:** With the plugin installed (from the repo dir source) and `~/.rogue-env` configured against a test backend, run a real delegating session:

```bash
copilot -p "Delegate to two agents in parallel and summarize." --allow-all
```

- [ ] **Step 2:** Confirm in `~/.rogue/hook.log` that `agentStop`, `subagentStart`, `subagentStop`, `sessionEnd`, `userPromptSubmitted`, `preToolUse`, `postToolUse`, `sessionStart` all logged an `http=200` (or fail-open `outcome=allow` if backend down).

- [ ] **Step 3:** Confirm on the backend that events persisted for the session AND for subagent `toolu_bdrk_…` sessionIds, and that an `agentStop` event carries an extracted assistant reply (findings evaluated).

- [ ] **Step 4:** Negative check — a prompt that induces a blockable tool call is denied at `preToolUse` (native Copilot deny shown), and the hook log shows `outcome=block`.

- [ ] **Step 5 (cleanup):** Remove any temporary test agents from `~/.copilot/agents`; ensure the installed-plugin cache `hooks.json` matches the repo (re-run the installer or `copilot plugin update` so the new events are trusted via `/hooks`).

---

## Self-Review (completed)

- **Spec coverage:** every event in the design matrix maps to a task — registration (B1), dispatch/augmentation (B3/B4), parse/classify/format (A1–A4), config (A5), docs (A6/B6), verification (C1). sessionStart audit POST → B3/B4. subagentStop enforce → A2/A4/B1/B3. userPromptTransformed forward-compat → A2/A3/A4/B1.
- **Placeholder scan:** all code steps contain real code; commands have expected output. The only intentionally descriptive steps (A6, B6 docs; B5 harness reuse) reference exact files and the concrete assertions to add.
- **Type consistency:** `extractAssistantReply(tailB64, maxTs, wantSubagent)`, `toEpochMs(ts)`, `augment_with_transcript`/`Add-TranscriptTail`, `post_event`, and the `transcriptTailB64` field name are used consistently across backend (A2) and plugin (B3/B4/B5). Decision shapes match the formatter (A3) and Global Constraints.

## Known limitations (carried from spec)

- No pre-model prompt block on Copilot ≤ v1.0.71 (`userPromptTransformed` unfired); enforce path is dormant but wired.
- Concurrent-subagent `agentName` attribution is best-effort (content still evaluated).
- `agentStop`/`subagentStop` "block" forces continuation, not retraction.
