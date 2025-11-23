# Codex Parallel Worker Architecture

This document outlines how to run multiple Codex processes in parallel on macOS using XPC and modern process-isolation APIs.

## Goals
- Enable multiple Codex runners to execute concurrently.
- Full isolation for each worker (crash containment, sandbox separation).
- Clean, async/await-friendly communication across processes.
- A deterministic, world-class architecture.

## High-Level Architecture
**App → CodexSupervisor.xpc → N Worker Jobs**

The app communicates with a single supervisory XPC service. The supervisor launches small, ephemeral worker processes—one per Codex task. Each worker runs a single task and exits.

### Components

### 1. Host App
- Owns the Kanban board UI.
- Manages concurrency policy (e.g., max 4 workers).
- Creates XPC sessions with the supervisor.

### 2. CodexSupervisor.xpc
- Bundled XPC service embedded in the app.
- Provides async/await API:
  - `launchWorker(payload: Data) async throws -> XPCEndpoint`
  - `cancelWorker(id: UUID)`
- Supervisor is responsible for:
  - Launching worker processes via `SMAppService`.
  - Passing initial configuration to workers.
  - Reconnecting to workers via returned `XPCEndpoint`.
  - Relaying results and logs back to the app.

### 3. Worker Process
- Lightweight executable, not an XPC service bundle.
- Registered as an on-demand job via `SMAppService`.
- Each invocation is a new process instance.
- Runs one Codex task, communicates results via provided endpoint.
- Shuts down immediately after task completion.

---

## Lifecycle

### Launching a Task
1. App requests: `try await supervisor.launchWorker(...)`.
2. Supervisor registers or kicks off a worker job.
3. Worker starts and connects back using an `XPCEndpoint`.
4. App now communicates directly with the worker using async XPC calls.

### Streaming Output
Workers can provide:
- Live logs
- Progress updates
- Final result payloads

Supervisor forwards these to the app.

### Completion / Cleanup
- Worker exits.
- Supervisor tears down connection.
- App marks task as completed or failed.

---

## Advantages
- True parallelism: as many workers as needed.
- Crash isolation: one worker dying doesn’t affect others.
- Clean Swift Concurrency: async/await end-to-end.
- Launchd manages worker lifecycle—robust, reliable.
- No clutter of multiple `.xpc` bundles.

---

## File Access Model
Workers run in isolated sandboxes, which prevents accidents.

Supervisor handles:
- Mounted file read-only access for task input.
- Temporary directories for output.
- Secure passing of sandbox bookmarks.

App never directly touches worker internals.

---

## Concurrency Model
Use a Scheduler Actor in the app:

- Tracks number of active workers.
- Ensures tasks don’t exceed system limits.
- Handles cancellation propagation.

Supervisor ensures any cancelled task kills its worker job cleanly.

---

## Summary
This architecture lets you run many Codex tasks simultaneously without creating multiple XPC bundles. Each worker is a separate OS process with clean Swift async/await communication.

This is the scalable template for your agent-based Kanban system.

