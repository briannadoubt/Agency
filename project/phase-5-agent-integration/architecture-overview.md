# Phase 5 Agent Architecture Overview

Authoritative plan for the SwiftUI app + Codex XPC stack. Builds on `project/XPC_ARCHITECTURE.md` and pins process boundaries, capabilities, and telemetry required for Phase 5.

## Separation of Concerns
- **Host App (SwiftUI, sandboxed)**
  - Renders kanban UI, card inspector, and agent controls.
  - Owns the Scheduler actor (max concurrency + per-flow caps from `project/config.yaml`).
  - Resolves user-selected project directories into security-scoped bookmarks and persists them.
  - Talks only to `CodexSupervisor.xpc`; never spawns Codex directly.
- **CodexSupervisor.xpc (XPC service)**
  - Entry point for all agent runs: `launchWorker(payload: Data) async throws -> XPCEndpoint` and `cancelWorker(id: UUID)`.
  - Validates payload (card path exists, bookmark decodes) and enforces capability checklist before launching workers.
  - Creates/refreshes per-run log directories; returns `XPCEndpoint` so the app can attach to the worker.
  - Tracks launched worker job IDs for cancellation/backoff and reconnects if the app restarts.
- **Worker Process (on-demand helper via SMAppService)**
  - Single responsibility: execute one Codex CLI task, stream output, then exit.
  - Opens the project bookmark with `.withSecurityScope`, mounts a scoped temp directory for outputs, and trims environment to the minimum needed for Codex.
  - Establishes the returned `XPCEndpoint` back to the app; no direct file moves or status changes.
  - Emits structured logs/metrics and terminates immediately after completion or cancellation.

## Control & Data Flow (Happy Path)
1. App requests `launchWorker` with card-relative path, agent flow (`implement|review|research`), and serialized bookmark for the project root.
2. Supervisor validates inputs, records a run token, and launches the worker job via `SMAppService` with the token + bookmark.
3. Worker starts, calls `startAccessingSecurityScopedResource`, opens the XPCEndpoint supplied by the supervisor, and sends a `workerReady(runID, metadata)` event.
4. App streams logs/progress over XPC while the worker runs `codex exec --allow-files <scoped-project> --flow <flow> <card>`.
5. On completion, worker sends `workerFinished(status, exitCode, summary, metrics)` and exits. Supervisor tears down the endpoint and releases the bookmark.
6. Scheduler marks the card unlocked and advances the queue.

## XPCEndpoint Contract (simplified)
- `func streamLogs() -> AsyncThrowingStream<LogEvent, Error>`
- `func progress() -> AsyncStream<ProgressEvent>`
- `func result() async throws -> RunResult` (exit code, stdout tail, duration, bytes written)
- `func cancel()` (idempotent; maps to `SMAppService` stop)

## Capability Sandbox Checklist
**Host App**
- Required: App Sandbox; XPC client entitlement; `com.apple.security.files.user-selected.read-write` for bookmark creation; read/write inside app container; optional `com.apple.security.network.client` only if telemetry uploads are enabled.
- Deny: `automation.apple-events`, device access (camera/mic), removable volumes, full disk access.

**CodexSupervisor.xpc**
- Required: App Sandbox; XPC server entitlement; `com.apple.security.files.bookmarks.app-scope` to resolve bookmarks; read/write limited to app container + scoped project; temporary directory access for per-run logs.
- Deny: outgoing network, hardware access, `allow-unsigned-executable-memory`.

**Worker Process**
- Required: App Sandbox; launched via `SMAppService` in the app’s team; `com.apple.security.files.bookmarks.app-scope`; scoped temporary directory for outputs; optional read-only network for model downloads (disabled by default).
- Deny: camera/mic, location, USB, user home traversal beyond bookmark, writing outside bookmark or temp.

Enforcement steps: supervisor validates entitlements at launch, drops any env overrides, and aborts if the bookmark cannot be resolved or the run attempts outside-path writes.

## Security-Scoped Bookmark Handling
- App captures a project root using `NSOpenPanel`, stores a persistent bookmark in the app container, and refreshes stale bookmarks on open.
- Supervisor unwraps the bookmark on each launch and passes the scoped URL to workers; bookmarks are never stored or copied by workers.
- Worker encloses all file access in `startAccessingSecurityScopedResource`/`stopAccessing...` and treats the scoped directory as read/write; all other paths are treated as read-only or denied.

## Logging & Metrics (Per Run)
- Log directory: `~/Library/Containers/<bundle>/Data/Logs/Agents/<YYYYMMDD>/<run-id>/` created by supervisor.
- Contents: stdout/stderr stream from Codex, lifecycle events (ready/progress/finish), exit code, duration, bytes read/written, and bookmark scope path.
- Metrics payload returned in `RunResult` for UI display and trend charts; UI surfaces last N runs with quick export.
- Crash/timeout: supervisor records termination reason and last heartbeat timestamp; scheduler marks the run failed and surfaces logs in the card inspector.

## Failure & Isolation Notes
- Worker crashes do not crash supervisor/app; XPCEndpoint closure signals failure.
- Cancellation propagates app → supervisor → `SMAppService` stop → worker termination.
- Backoff policy lives in the scheduler actor: exponential backoff capped at 5 minutes per card, counting consecutive failures.
- UI never calls Codex directly; all mutations flow through the XPC channel, preserving sandbox guarantees.

## Open Follow-Ups (for later cards)
- Define structured log schema (JSONLines) shared between supervisor and UI.
- Add optional network client entitlement toggle when Codex needs remote model pulls.
- Wire health pings into the XPCEndpoint to detect hung workers faster.
