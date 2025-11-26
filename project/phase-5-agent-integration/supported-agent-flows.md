# Supported Agent Flows (Implement, Review, Research)

Defines the deterministic contract for the three supported flows executed through the Scheduler → CodexSupervisor.xpc → Worker stack. Aligns with `project/XPC_ARCHITECTURE.md` streaming/log model and the frontmatter/locking rules in `project/phase-5-agent-integration/agent-flow-mechanics.md`.

## Common Run Contract
- Inputs (all flows): `runID` (UUID), `cardRelativePath` (under project root), `flow` (`implement|review|research`), project bookmark, optional `branch`, `allowNetwork` flag, and `logDirectory` created by the supervisor.
- Frontmatter lifecycle (shared): set `agent_flow=<flow>` and `agent_status=queued` when the lock is acquired; flip to `running` immediately before dispatch; end-state `succeeded|failed|canceled` based on worker exit code or cancellation; `agent_flow` persists until the next run overwrites it.
- Streaming/logs: worker streams `LogEvent`/`ProgressEvent` to the app via the returned `XPCEndpoint`; supervisor mirrors stdout/stderr to `<logDirectory>/worker.log`, events to `events.jsonl`, and writes `result.json` with the structured payloads below.
- History: append a dated line on enqueue and completion using the templates below; include `runID` and `flow` so users can correlate with `~/Library/Containers/<bundle>/Data/Logs/Agents/<YYYYMMDD>/<runID>/`.

## Implement Flow
- Purpose: produce code/doc changes for a card with optional checklist updates.
- Required inputs: `branch` (target working branch), optional `testsToRun` array, `checklistHints` (indices of acceptance items the worker intends to satisfy).
- Worker result shape (`result.json`): `{ status: "succeeded"|"failed"|"canceled", summary: String, changedFiles: [String], tests: { ran: [String], passed: Bool }, checkedCriteria: [Int] }`.
- Frontmatter on success: keep `agent_flow=implement`, set `agent_status=succeeded`, persist `branch`. On failure: `agent_status=failed`; on cancel: `agent_status=canceled`. No additional keys are added.
- Checklist guidance: only flip acceptance criteria checkboxes whose 0-based index appears in `checkedCriteria`; all other items stay untouched to keep automation deterministic.
- History entries:
  - Queue: `YYYY-MM-DD: Run <runID> queued (implement) on branch <branch>.`
  - Start (optional if already captured in queue): `YYYY-MM-DD: Run <runID> started (implement).`
  - Success: `YYYY-MM-DD: Run <runID> succeeded (implement); checked <n> items; tests: <pass/fail>.`
  - Failure: `YYYY-MM-DD: Run <runID> failed (implement); see logs at <relative-log-path>.`
  - Cancel: `YYYY-MM-DD: Run <runID> canceled (implement).`

## Review Flow
- Purpose: perform automated review of a branch/diff and surface findings; does not mutate checklists.
- Required inputs: `branch` or `commitRange` under review, optional `focusPaths` filter, `severityThreshold` for blocking issues.
- Worker result shape: `{ status: "...", findings: [{ severity: "error"|"warn"|"info", file: String?, line: Int?, message: String }], overall: "approve"|"revise", summary: String }`.
- Frontmatter on success: `agent_status=succeeded`; branch stays unchanged. Failure/cancel mirror implement flow statuses.
- History entries:
  - Queue: `YYYY-MM-DD: Run <runID> queued (review) for <branch|range>.`
  - Success: `YYYY-MM-DD: Run <runID> succeeded (review); findings blocking/warn/info: <e>/<w>/<i>; overall=<approve|revise>.`
  - Failure: `YYYY-MM-DD: Run <runID> failed (review); see logs at <relative-log-path>.`
  - Cancel: `YYYY-MM-DD: Run <runID> canceled (review).`

## Research Flow
- Purpose: gather information, links, and structured notes; read-only with no checklist or branch changes.
- Required inputs: `prompt` or `topics` array, optional `timeboxMinutes`, optional `allowNetwork` override (defaults to app policy).
- Worker result shape: `{ status: "...", summary: String, bulletPoints: [String], sources: [{ title: String, url: String }] }`.
- Frontmatter on completion: `agent_status=succeeded|failed|canceled` (branch unchanged; no checklist mutation).
- History entries:
  - Queue: `YYYY-MM-DD: Run <runID> queued (research) topic "<prompt>".`
  - Success: `YYYY-MM-DD: Run <runID> succeeded (research); <n> sources captured.`
  - Failure: `YYYY-MM-DD: Run <runID> failed (research); see logs at <relative-log-path>.`
  - Cancel: `YYYY-MM-DD: Run <runID> canceled (research).`

## Failure and Cancellation Consistency
- For all flows, `failed` is written when the worker exits non-zero or the supervisor surfaces launch/validation errors; `canceled` is written when the user or scheduler cancels the run before exit.
- History lines should reference the same `runID` used in `events.jsonl`/`result.json` to keep telemetry and card edits aligned.
