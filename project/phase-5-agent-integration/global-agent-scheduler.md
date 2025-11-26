# Global Agent Scheduler

Defines the single Scheduler global actor that governs when Codex runs start, how many run in parallel, and how locks/backpressure are enforced before invoking `CodexSupervisor.xpc`. Uses Swift concurrency (no DispatchQueues) and the locking primitives described in `project/phase-5-agent-integration/agent-flow-mechanics.md`.

## Configuration Inputs
- `agents.maxConcurrent` (default 1) from `project/config.yaml`; hard cap across all flows.
- `agents.perFlow` map (`implement|review|research`; default 1 each) for per-flow limits.
- `queue.softLimit` (computed as `maxConcurrent * 4`, min 8) for backpressure warnings; `queue.hardLimit` (`softLimit * 2`) to reject/enforce deferral.
- `retry` policy shared with the flow mechanics doc: base 30s, 2x multiplier, ±10% jitter, capped at 5 minutes, max 5 retries per card before surfacing failure.
- `staleLockTimeout` default 10 minutes for crash recovery (aligned with flow mechanics).

## State & Locks (held by the global actor)
- `runningByFlow: [Flow: Int]` and `totalRunning: Int` to compare against caps.
- `readyQueues: [Flow: Deque<RunRequest>]` ordered FIFO.
- `cardLocks: [CardPath: RunLock]` loaded/updated from the card lock store; enqueue refuses when a lock exists.
- `phaseSerialLocks: Set<PhaseFlow>` to serialize non-parallelizable work within a phase+flow pair.
- `backoffTimers: [CardPath: Task<Void, Never>]` to re-enqueue after failures with the retry schedule.

## Enqueue Path
1. Caller requests `enqueue(run)` with `cardPath`, `flow`, `parallelizable`, `runID`, and bookmark payload.
2. Scheduler checks `cardLocks`; if locked, return `.alreadyRunning` to the UI.
3. Acquire `cardLock` and write frontmatter `agent_status=queued` (via card edit pipeline); optionally add a history line.
4. If `parallelizable == false`, reserve a `phaseSerialLock` for `(phase, flow)` so only one such run can be active/queued at a time.
5. Place the run in `readyQueues[flow]` and call `drainQueues()`.

## Dispatch Selection (`drainQueues`)
- While `totalRunning < maxConcurrent` and a flow queue has work below its `perFlow` cap, pop the oldest `RunRequest` that is not blocked by a `phaseSerialLock` held by another running item.
- Transition the card to `running` just-in-time: set `agent_status=running`, create the per-run log directory, and persist the `runID` in memory.
- Call `CodexSupervisor.launchWorker(payload:)`; on success, add to `runningByFlow`/`totalRunning` and keep the card/phase locks.
- If launch fails synchronously, release locks, schedule retry using backoff policy, and set `agent_status=failed` with error details.

## Finish Transition
- On `workerFinished` or `cancel` acknowledgement, update frontmatter to `succeeded|failed|canceled` based on exit.
- Release `cardLock` and, if present, the `phaseSerialLock` for `(phase, flow)`.
- Decrement `runningByFlow`/`totalRunning`, cancel any backoff timers for the card, and immediately call `drainQueues()` to start the next eligible run.
- Record queue latency and run duration metrics for telemetry and UI timelines.

## Parallelization Rules
- `parallelizable: true` (or missing cap after opt-in) → only global/per-flow limits apply; multiple cards from the same phase may run together if caps allow.
- `parallelizable: false` (default) → scheduler enforces a `phaseSerialLock` per `(phase, flow)` so only one card in that phase/flow runs at a time even if capacity remains.
- Caps are evaluated after the phase lock check, so a non-parallelizable card will wait until both capacity and its phase lock are free.

## Backpressure & Queue Growth
- If `readyQueues` length exceeds `queue.softLimit`, surface a UI warning (“Queue delayed; respecting caps”) and show per-flow queue depths.
- At `queue.hardLimit`, new enqueue requests return `.deferred`; UI keeps the card unlocked and asks the user to retry later or raise caps.
- Scheduler periodically (every 30s) logs queue depth and drops expired backoff timers to avoid starvation.
- Users may raise `maxConcurrent`/`perFlow` at runtime; scheduler recalculates limits and immediately re-drains queues.

## Retry & Backoff (failures)
- Failures increment a per-card counter; scheduler schedules a re-enqueue with exponential backoff using the policy above, holding the `cardLock` during the wait to prevent a duplicate user-initiated run from colliding.
- A manual rerun clears the counter and backoff timer, then enqueues fresh with a new `runID`.
- After exceeding max retries, scheduler sets `agent_status=failed`, releases locks, and leaves the run out of the queue so the user can inspect logs.

## Crash/Recovery Handling
- On app relaunch, scheduler reloads persisted locks and asks the supervisor for live workers; stale locks older than `staleLockTimeout` are cleared.
- Any runs left in `running` without a supervisor match are marked `failed` with a “scheduler recovery” reason and their locks released; queues then resume.
