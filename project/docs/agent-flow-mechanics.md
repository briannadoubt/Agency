# Agent Flow Mechanics (Phase 5)

Defines how the app coordinates card state, locking, scheduling, and XPC invocation for Codex agent runs. Complements `project/XPC_ARCHITECTURE.md` and the architecture overview.

## Frontmatter Lifecycle (agent_flow / agent_status)
- States: `idle` (default) → `queued` → `running` → `succeeded` | `failed` | `canceled`.
- When the user starts a run, the app updates the card frontmatter atomically: set `agent_flow` to the chosen flow (`implement|review|research`), set `agent_status` to `queued`, and write `branch` if supplied.
- Scheduler promotes `queued` → `running` immediately before dispatching to XPC, recording the `runID` in memory and in the per-run log directory.
- On completion: set `agent_status` to `succeeded` on exit code 0; otherwise `failed`; cancellation sets `canceled`. `agent_flow` remains for audit until the next run overwrites it.
- Frontmatter writes are performed through the card edit pipeline (preserves ordering/format) and are guarded by the card lock to avoid concurrent edits.

## Locking Rules
- A `Scheduler` global actor owns a map of `cardPath -> RunLock(runID, flow, startedAt)`. Only one lock per card.
- The app acquires the lock before setting `agent_status=queued`; if acquisition fails, the UI surfaces “Already running” and refuses to enqueue.
- Locks are released only after the worker reports `workerFinished` or a cancellation is acknowledged by the supervisor.
- Crash recovery: on app relaunch, stale locks older than the configured timeout (default 10 minutes) are cleared after checking the supervisor for any live workers with the same `runID`.
- Lock metadata is mirrored to `~/Library/Containers/<bundle>/Data/Locks/<card-hash>.json` so resumed sessions can reconcile state.

## Enqueue & Dispatch Flow
1. User clicks Run → app validates card path is under the bookmarked project root and loads frontmatter.
2. Acquire lock; write `agent_flow` + `agent_status=queued`; append a history line `Run <runID> queued (<flow>)` to the card (optional for later card).
3. Scheduler enqueues `(runID, cardRelativePath, flow, bookmarkData)`; applies per-flow concurrency limits.
4. Before dispatch, scheduler flips status to `running`, creates a per-run log directory, and calls `CodexSupervisor.launchWorker(payload:)`.
5. Payload (sent as `CodexRunRequest`): `{ runID: UUID, flow: String, cardRelativePath: String, projectBookmark: Data, logDirectory: URL, allowNetwork: Bool, cliArgs: ["--flow", flow, "--card", cardRelativePath, "--allow-files", projectScopePath] }`.
6. Supervisor validates payload, resolves the bookmark, and starts the worker via `SMAppService` with the run token and log directory path. Supervisor returns the `XPCEndpoint` to the app for streaming.
7. App listens on the endpoint: `streamLogs()`, `progress()`, `result()`; UI binds progress to the card inspector.
8. On result, scheduler updates frontmatter status, releases the lock, and posts a run summary to telemetry.

## Worker Contract (example Codex invocation)
- Worker opens the project bookmark and executes: `codex exec --flow <flow> --card <cardRelativePath> --allow-files <scopedPath> --run-id <runID>`.
- Required environment: minimal PATH, `CODEX_NONINTERACTIVE=1`, `CODEX_ENDPOINT=<endpoint-port>`, `TMPDIR=<run-log>/tmp`.
- Worker emits structured `LogEvent`/`ProgressEvent` over the returned XPC endpoint; supervisor mirrors stdout/stderr to `run-log/worker.log`.

## Retry & Backoff
- Scheduler keeps a per-card failure counter; resets after any `succeeded` run.
- On failure, re-enqueue with exponential backoff: base 30s, multiplier 2x, jitter ±10%, cap 5 minutes, max 5 retries. After cap reached, mark `agent_status=failed` and surface the error in the UI; lock is released.
- Immediate retry is allowed for user-initiated reruns; they reset the counter and lock a fresh runID.

## Observability (per run)
- Log layout: `~/Library/Containers/<bundle>/Data/Logs/Agents/YYYYMMDD/<runID>/` with `worker.log`, `events.jsonl` (XPC events), `result.json` (exit, duration, bytes read/written, flow, cardRelativePath, bookmark scope), and optional `stdout-tail.txt`.
- Metrics captured: queue latency (enqueue→start), run duration, bytes read/written within scope, exit code, retry count, cancellation source.
- UI surfaces last N runs per card with status chips and links to open the log directory; sharing/export reuses the same path.

## Cancellation Path
- User cancel → scheduler sets `agent_status=canceled` (optimistic), calls `cancelWorker(runID)` on supervisor.
- Supervisor stops the `SMAppService` job; worker observes termination and sends a final `workerFinished(status: .canceled)` if still alive; lock released regardless.
- If cancellation races with completion, completion wins and status becomes `succeeded`/`failed` accordingly.
