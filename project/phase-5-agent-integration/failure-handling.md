# Failure Handling for Agent Runs

Defines deterministic behavior when agent runs fail or hang, aligning with `project/XPC_ARCHITECTURE.md`, `agent-flow-mechanics.md`, and `global-agent-scheduler.md`. Goal: failures never corrupt cards, crash the app, or strand locks; users can inspect errors and retry without data loss.

## Failure Modes (app must handle all)
- **Non-zero exit**: worker completes with exitCode != 0 and `status=failed`.
- **Launch/validation failure**: supervisor rejects payload/bookmark or cannot start worker.
- **Worker crash**: process terminates unexpectedly; XPCEndpoint closes.
- **Timeout/hung worker**: no heartbeat within watchdog window; supervisor stops job.
- **Cancellation**: user/scheduler cancels; not treated as failure, but same cleanup path.

## State & Frontmatter Updates
- On failure modes above (except cancellation), scheduler writes `agent_status=failed` and keeps existing `agent_flow` for audit; `branch` remains untouched; card stays in its current folder (`in-progress` or wherever the user placed it).
- Locks: release `cardLock` and any `phaseSerialLock` after marking failure; backoff counter increments per `global-agent-scheduler.md`.
- History templates (append dated line with runID):
  - Non-zero/crash/timeout: `YYYY-MM-DD: Run <runID> failed (<flow>); reason=<exit|crash|timeout>; see logs at <relative-log-path>.`
  - Launch/validation error: `YYYY-MM-DD: Run <runID> failed (<flow>); supervisor rejected payload: <short reason>.`

## UI Behavior
- On failure, inspector shows status chip “Failed”, latest history line, and a “View logs” button that opens `<logDirectory>/worker.log` and `result.json`.
- Present the concise error summary (exit code / validation reason / crash signal) and bytes read/written from `result.json`.
- Offer **Retry** (enqueues new runID, clears backoff counter) and **Reset Agent State** (sets `agent_flow: null`, `agent_status: idle`, releases locks; does NOT move the card or edit content). Reset requires user confirmation to avoid losing audit info.
- If frontmatter is manually edited into an impossible combination, scheduler refuses to enqueue and surfaces the reason; user can tap Reset to fix.

## Data Preservation
- The worker never reverts workspace changes; partial markdown or code edits remain on disk for user inspection.
- Log directories are retained under `~/Library/Containers/<bundle>/Data/Logs/Agents/YYYYMMDD/<runID>/`; retries create new runIDs.
- No automatic git operations on failure; branch pointer is untouched.

## Crash / Timeout Isolation
- Supervisor monitors worker heartbeat; on timeout it stops the `SMAppService` job and records reason `timeout`.
- Supervisor/app catch XPCEndpoint closure and treat it as `failed`; neither process crashes. Scheduler immediately releases locks and applies backoff.
- Tests: add integration tests that simulate (a) worker exit code 1, (b) supervisor launch rejection, (c) worker crash (simulated kill), (d) heartbeat timeout. Assertions: app stays responsive, agent_status becomes `failed`, locks are released, and retry button appears.

## Retry Path
- Retry reuses the same card but new `runID`; scheduler resets failure counter on manual retry.
- If backoff is active, Retry cancels the timer and enqueues immediately.
- Cancellation during retry follows standard cancellation path and sets `agent_status=canceled`.

## Unlocking / Reset Guidance
- If a failure leaves the card visually locked, the Reset control clears `agent_status` to `idle` and `agent_flow` to `null`, deletes the lock record, and leaves History untouched for audit.
- Automatic recovery on app relaunch mirrors `global-agent-scheduler.md`: stale locks older than the timeout are cleared after checking for live workers; failed runs remain marked `failed`.
