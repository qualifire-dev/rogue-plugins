# Design: Full GitHub Copilot CLI hook-event coverage

**Date:** 2026-07-20
**Repos:** `rogue-plugins` (plugin) + `qualifire-fire-1678-copilot` (backend)
**Ticket lineage:** FIRE-1678 (Copilot CLI plugin)

## Problem

The Rogue GitHub Copilot CLI plugin currently registers **only 4 of Copilot's 14 hook
events** (`sessionStart`, `userPromptSubmitted`, `preToolUse`, `postToolUse`). Every other
lifecycle event — including subagent lifecycle, turn-end (`agentStop`), session end, errors,
compaction, and notifications — is never sent to the backend, so those surfaces are
invisible to AIDR. **Requirement: send ALL hook events to the backend** for audit,
persistence, and (where the platform allows) enforcement.

## Empirical grounding

All decisions below were validated against **GitHub Copilot CLI v1.0.71** on macOS by
registering capture hooks and running real (`copilot -p … --allow-all`) sessions, including
multi-subagent runs. Key findings:

1. **`transcriptPath` = `~/.copilot/session-state/<sessionId>/events.jsonl`** — one
   **session-aggregated** JSONL file per session. Subagents write into the *same* file
   (not per-subagent files). Confirmed empirically.

2. **Transcript schema** — each line is `{type, data, id, timestamp, parentId}`.
   `timestamp` is an **ISO-8601 string** (e.g. `"2026-07-20T09:00:36.070Z"`). Relevant
   `type`s: `session.start`, `user.message`, `assistant.turn_start`, **`assistant.message`**
   (`data.content` = reply text, `data.interactionId`), `assistant.turn_end`,
   `tool.execution_start`/`_complete`, `subagent.started`/`subagent.completed`
   (`data.agentName` + `data.toolCallId`), `hook.start`/`hook.end`, `session.shutdown`.

3. **Turn-end payload timestamps are epoch-ms numbers** (e.g. `1784538036075`), whereas
   transcript line timestamps are ISO strings — the backend must normalize both to epoch ms
   before comparing.

4. **Main agent vs subagent is cleanly distinguishable:**
   - **Main agent** hooks (`agentStop`, etc.): `sessionId` = the session **UUID**;
     `agentStop.transcriptPath` = the real path.
   - **Subagent** hooks (`userPromptSubmitted`, `preToolUse`, `postToolUse`, `agentStop`):
     `sessionId` = the subagent's **task-call id** (`toolu_bdrk_…`), NOT a UUID; the
     subagent's own `agentStop.transcriptPath` is **empty (`""`)**.
   - The dedicated `subagentStart`/`subagentStop` hooks carry the **main** `sessionId` +
     **`agentName`**.

5. **A subagent's entire loop is already instrumented.** Its prompt fires
   `userPromptSubmitted`, its tool calls fire `preToolUse`/`postToolUse`, its turn-end fires
   `agentStop` — all tagged with the subagent's `toolu_bdrk_…` sessionId. So subagent
   **actions** are already enforceable once these events are registered. The only gap is the
   subagent's **message text**, covered by `subagentStop`.

6. **`subagentStart` does NOT include the subagent's prompt** — only
   `{agentName, agentDisplayName, agentDescription}`. The prompt is caught at the `task`
   call's `preToolUse` (`toolArgs.prompt`) and the subagent's own `userPromptSubmitted`.
   Per docs, `subagentStart` cannot block creation (only `additionalContext`).

7. **`userPromptTransformed` is NOT emitted in v1.0.71** (transformation happens —
   `user.message.transformedContent` exists — but no hook fires). Combined with
   `userPromptSubmitted` output being ignored by Copilot, **there is currently no way to
   block a prompt before the model sees it.** Decision: build the enforce path anyway
   (forward-compatible) so it activates automatically if a future Copilot version emits it.

8. **`postToolUse` live stdin is NOT elided.** The `[copilot:elided textResultForLlm …]`
   placeholder appears only in the transcript recording; the real hook stdin carries the
   full `toolResult.textResultForLlm`. Current postToolUse eval/redaction is correct.

9. **Both `agentStop` (camelCase) and `Stop` (PascalCase/snake_case) fire** for the same
   turn-end. Register **only `agentStop`** to avoid double-POST.

## Decisions (authoritative)

### Event treatment matrix (all 14 events)

| Event | Fires in v1.0.71 | Plugin dispatch | Backend treatment |
|---|---|---|---|
| `sessionStart` | yes | sync + detached heartbeat | **POST audit-only** (persist), + unconfigured hint when no API key |
| `userPromptSubmitted` | yes (main + subagent) | detached | evaluate as prompt → **audit-only** (Copilot ignores output; cannot block) |
| `userPromptTransformed` | **no** (build enforce-ready) | sync | **ENFORCE (forward-compat)**: eval `transformedPrompt`; on block emit `modifiedTransformedPrompt` |
| `preToolUse` | yes (main + subagent) | sync | **ENFORCE**: `permissionDecision:"deny"` |
| `postToolUse` | yes (main + subagent) | sync | **ENFORCE**: `modifiedResult.textResultForLlm` = standard block reason |
| `permissionRequest` | when a permission decision is needed | detached | **audit-only** |
| `agentStop` | yes (main + subagent) | sync + transcript-tail | **ENFORCE (main)**: full-eval final reply, `decision:"block"` on findings |
| `subagentStart` | yes | detached | **audit-only** (no prompt in payload; can't block creation) |
| `subagentStop` | yes | sync + transcript-tail | **ENFORCE**: full-eval subagent's last message (best-effort attribution) |
| `sessionEnd` | yes | detached | audit-only |
| `postToolUseFailure` | on tool failure | detached | audit-only |
| `errorOccurred` | on error | detached | audit-only |
| `preCompact` | on compaction | detached | audit-only |
| `notification` | on notification | detached | audit-only |

**Dispatch rule:** events that return a *meaningful decision* (`preToolUse`, `postToolUse`,
`agentStop`, `subagentStop`, `userPromptTransformed`) run **synchronously**; audit-only
events that Copilot ignores the output of run **detached** (fire-and-forget, like the
heartbeat) to add zero session latency. `sessionStart` stays sync (it emits the unconfigured
hint) and also fires the detached heartbeat + a synchronous audit POST.

### Enforcement decision shapes (backend, already/newly emitted)

- `preToolUse` → `{"permissionDecision":"deny","permissionDecisionReason":<reason>}`
- `postToolUse` → `{"modifiedResult":{"resultType":"success","textResultForLlm":<reason>}}`
  where `<reason>` is the **standard `result.reason`** built in `hook-evaluator.ts`
  (findings explanation + `"If you believe this is a false positive, prepend rgx! to your
  prompt and resubmit."`). **Not** the old `[Tool result withheld: …]` wrapper.
- `agentStop` / `subagentStop` → `{"decision":"block","reason":<reason>}`
- `userPromptTransformed` → `{"modifiedTransformedPrompt":<standard block reason>}` on block
- allow (all events) → `{}`

### `rgx!` / standard reason

The canonical user-facing block text is produced by `hook-evaluator.ts` as `result.reason`
(includes the `rgx!` override guidance). `postToolUse` and `userPromptTransformed` both reuse
this exact text so the block message is consistent across events.

## Architecture

### Plugin (`rogue-plugins`, `plugins/copilot/`)

**`hooks.json`** — add the 10 missing events. Each entry keeps a `bash` and a `powershell`
command key, **byte-stable forever** (Copilot hook-trust), ending `; exit 0` (fail-open;
`preToolUse` is fail-CLOSED so a non-zero exit would deny). Detached (audit-only) events use
the existing heartbeat pattern: `( nohup bash … & ) ; exit 0` (bash) and
`Start-Process -WindowStyle Hidden … ; exit 0` (powershell). Sync events call
`hook.sh`/`hook.ps1` as today. Matchers (`.*`) on `preToolUse`, `postToolUse`,
`postToolUseFailure`, `permissionRequest`, `subagentStart`, `subagentStop`, `preCompact`,
`notification`. Register **`agentStop`** only (not `Stop`).

**`hook.sh` / `hook.ps1`** — stay **pure relay** for all events EXCEPT:

- `sessionStart`: when `ROGUE_API_KEY` is set, additionally POST the payload to
  `/hooks/copilot` for audit (return `{}`); keep the unconfigured hint when the key is
  missing. (Heartbeat remains a separate detached `hooks.json` entry.)
- `agentStop` and `subagentStop`: **transcript-tail augmentation.**
  1. Buffer stdin (`BODY="$(cat)"`).
  2. Extract `transcriptPath` from the body (single known key; `grep`/regex, fail-open).
  3. If non-empty and readable, read the **last ~256 KB** of the file
     (`tail -c 262144` / `Get-Content -Tail`), base64-encode it (base64 output contains no
     JSON-special characters), and append `,"transcriptTailB64":"<b64>"` to the JSON body by
     stripping the trailing `}` and re-adding it. This is safe string concatenation because
     base64 has no `"` or `\`.
  4. POST the augmented body. On ANY failure (missing/empty path, unreadable file, read
     error), POST the original body unchanged and continue. Always `exit 0`.
  - Subagent `agentStop` (empty `transcriptPath`) → no tail appended → backend treats it as
    metadata-only (audit).

  Keep the sh implementation POSIX-clean; keep the ps1 5.1-compatible. The augmentation is
  the only new logic; keep the two dispatchers in lockstep.

**Version bump** in `plugins/copilot/plugin.json` and the Copilot marketplace file
`.github/plugin/marketplace.json` (kept in sync — enforced by `validate.yml`).

**Docs:** update `plugins/copilot/skills/status/SKILL.md` / `commands/setup.md` only if the
event list is surfaced there; update the repo `CLAUDE.md` Copilot section (event list +
transcript-tail note + the `toolu_bdrk_…` subagent-sessionId note).

### Backend (`qualifire-fire-1678-copilot`)

**`hook-parsers/copilot-hook-parser.ts`**
- Extend `EVENT_ALIASES` with PascalCase variants: `PermissionRequest→permissionRequest`,
  `SubagentStart→subagentStart`, `SubagentStop→subagentStop`, `PreCompact→preCompact`,
  `Notification→notification`, `UserPromptTransformed→userPromptTransformed`
  (`Stop→agentStop`, `SessionEnd`, `ErrorOccurred`, `PostToolUseFailure` already present).
- Extend `classifyCopilotEvent` for the new events:
  `userPromptTransformed→"prompt"`; `permissionRequest` → same tool/mcp/shell/file
  classification as `preToolUse`; `subagentStart`/`subagentStop`/`preCompact`/`notification`
  → `"other"` (or `"session"` for start/stop as appropriate).
- Build canonical messages:
  - `userPromptTransformed`: content = `transformedPrompt` (fallback `prompt`), role `user`.
  - `agentStop`: if `transcriptTailB64` present, base64-decode → parse JSONL → select the
    last `type==="assistant.message"` with `toEpochMs(line.timestamp) ≤ toEpochMs(payload.timestamp)`,
    preferring lines whose `data.interactionId` equals the **main** interactionId (derived
    as the `interactionId` of the latest top-level `user.message`); role `assistant`,
    content = `data.content`.
  - `subagentStop`: same extraction, but select the subagent's last `assistant.message`
    (`interactionId ≠ main` and `ts ≤ event.timestamp`); **best-effort** under concurrent
    subagents — document that `agentName` attribution may be approximate (content is still
    evaluated). Carry `agentName` onto the canonical event for audit.
- Add a small `toEpochMs()` helper accepting both ISO strings and epoch-ms numbers.
- `parseCopilot` must not assume `sessionId` is a UUID (subagent events use `toolu_bdrk_…`).

**`hook-formatters/copilot-hook-formatter.ts`**
- Add `case "userPromptTransformed":` → `{ modifiedTransformedPrompt: reason }` on block.
- `postToolUse`: change `textResultForLlm` from the `[Tool result withheld: …]` wrapper to
  the standard `reason`.
- `preToolUse`/`permissionRequest`/`agentStop`/`subagentStop` shapes already present.

**`hook-event-classification.ts`**
- `BLOCKING_EVENTS` (i.e. "evaluated"): add `agentStop`, `subagentStop`,
  `userPromptTransformed`. (`userPromptSubmitted`, `preToolUse`, `postToolUse` already
  present.) Audit-only-but-still-evaluated events (`permissionRequest`) — see below.
- `FULL_EVAL_EVENTS`: add `agentStop`, `subagentStop` (final reply / subagent message get
  the full ruleset, like Claude's `Stop`).
- `ASSISTANT_RESPONSE_EVENTS`: add `agentStop` (ThetaLake forwarding of the final reply).
- `ASSISTANT_DIRECTION_EVENTS`: add `agentStop`, `subagentStop` (assistant-authored
  content). (`preToolUse`/`postToolUse` already present.) `userPromptTransformed` is
  user-derived → treat as a prompt (do NOT add to assistant-direction).
- Audit-only events that should be **persisted but not evaluated** (`sessionStart`,
  `sessionEnd`, `subagentStart`, `permissionRequest`, `postToolUseFailure`, `errorOccurred`,
  `preCompact`, `notification`): they reach `handleCopilot` and are persisted via
  `evaluateCanonicalEvent` even when not in `BLOCKING_EVENTS`. Confirm the persistence path
  records non-blocking events; if "evaluated but never blocks" is desired for
  `permissionRequest`, add it to `BLOCKING_EVENTS` **and** `AUDIT_ONLY_EVAL_EVENTS`.
  (`isAuditOnlyEvalEvent` already exempts Copilot `postToolUse` from audit-only.)

**`routers/hooks.ts`**
- `getConfig().tools.github_copilot`: `monitoredEvents` = all 14 event names;
  `blockingEvents` = `["userPromptTransformed","preToolUse","postToolUse","agentStop","subagentStop"]`.
- `handleCopilot`: no structural change (already parses via header `x-rogue-event`, formats
  via `formatCopilotResponse(result, canonical.eventType)`, fail-open `{}`). Verify it
  tolerates the `transcriptTailB64` envelope field (it's inside the parsed body → handled in
  the parser).

**Docs:** update `docs-content/docs/integrations/coding-agents/github-copilot.mdx` (event
list + enforcement matrix) and the backend `CLAUDE.md`.

## Testing

**Plugin:**
- `hooks.json` lint (analogous to `tests/test_hooks_json.sh`): every event has `bash` +
  `powershell` keys, ends `; exit 0`, matchers where expected, `agentStop` registered
  (not `Stop`).
- `hook.sh` POSIX/`dash` test for the transcript-tail augmentation (base64 append produces
  valid JSON; missing/empty/unreadable path → original body, exit 0).

**Backend (unit):**
- `copilot-hook-parser.test.ts`: aliases + classification for all new events; `agentStop`
  extraction from a fixture `transcriptTailB64` (ISO vs epoch-ms timestamps; picks last
  `assistant.message ≤ ts`; ignores future-appended lines); `subagentStop` picks a
  non-main-interactionId message; `userPromptTransformed` content = `transformedPrompt`;
  subagent events with `toolu_bdrk_…` sessionId parse fine.
- `copilot-hook-formatter.test.ts`: `userPromptTransformed` → `modifiedTransformedPrompt`;
  `postToolUse` → standard reason (no "withheld" wrapper); allow → `{}` for audit-only.
- `hook-event-classification.test.ts` / `hook-parsers.test.ts`: new set memberships.

Use fixtures captured from the real v1.0.71 payloads recorded during investigation
(`agentStop`, `subagentStart`, `subagentStop`, `sessionEnd`, subagent `preToolUse`/
`postToolUse` with `toolu_bdrk_…` sessionId, and an `events.jsonl` slice).

## Non-goals / documented limitations

- **No pre-model prompt block on current Copilot** (`userPromptTransformed` unfired,
  `userPromptSubmitted` output ignored). Malicious prompts are caught downstream at
  `preToolUse`; the `userPromptTransformed` enforce path is dormant until Copilot emits it.
- **Concurrent-subagent `agentName` attribution is best-effort** (transcript has no
  `interactionId ↔ agentName` link). Content is still evaluated; only the audit label may be
  approximate.
- **`agentStop`/`subagentStop` "block" forces continuation, not retraction** — the reply was
  already produced; detection (findings/alerts/ThetaLake) is the primary value.
- Copilot cloud-agent surface, `permissionRequest` under cloud agent, and model-provider
  attribution are out of scope (unchanged from current behavior).

## Invariants to preserve

- Fail-open everywhere; every `hooks.json` command ends `; exit 0`; `preToolUse` never
  denies on error.
- `bash`/`powershell` command strings byte-stable (hook trust); mutate only `scripts/*`.
- `hook.sh`/`hook.ps1` kept in lockstep; sh POSIX-clean, ps1 5.1-compatible.
- `x-rogue-event` header matches the `hooks.json` key; no `x-rogue-source`, no
  `x-rogue-agent` for Copilot.
- HTTP client timeout (15s) inside the hook `timeoutSec` (30s for sync, short for detached).
- Plugin `plugin.json` version = marketplace version (validate.yml).
