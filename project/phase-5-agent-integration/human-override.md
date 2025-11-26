# Human Override Behavior

Defines how users can manually override agent state while keeping automation predictable and audit-friendly. Complements `agent-flow-mechanics.md`, `global-agent-scheduler.md`, and `failure-handling.md`.

## Allowed Manual Actions
- Edit frontmatter directly (external editor or in-app) to change `agent_flow`, `agent_status`, or `branch`.
- Use UI “Reset Agent State” control to set `agent_flow: null`, `agent_status: idle`, and optionally clear `branch` after confirmation.
- Rerun any flow after overrides; scheduler re-validates frontmatter before enqueue.

## Rules the App Enforces
- Card lock required for UI-driven overrides to avoid racing a running/queued job. If `agent_status` is `running/queued`, UI first offers Cancel; overrides apply after lock is released.
- No folder moves: manual overrides never relocate the card; status folder remains user-controlled.
- Frontmatter order is preserved; only requested keys are changed.
- Manual edits are authoritative: the inspector reloads frontmatter on focus/refresh; if values changed externally, UI reflects them and adjusts controls (e.g., disables “Retry” if `agent_status` is already `idle`).

## Rerun After Override
- Scheduler checks frontmatter on enqueue. If `agent_status` is `idle`, it proceeds; if it is in an incompatible state (`running` without a live run), scheduler offers a “Recover” path (reset to idle) instead of silently fixing.
- New runs overwrite `agent_flow` with the chosen flow and set `agent_status=queued` as usual; previous manual values are kept in History for audit.

## Audit / History Entries (UI adds when overrides occur)
- Reset: `YYYY-MM-DD: Agent state reset to idle by user (previous flow/status: <flow>/<status>).`
- Manual frontmatter edit detected (optional): `YYYY-MM-DD: Frontmatter changed externally; UI reloaded to match file.`
- Rerun after manual override: standard run-queue line (`Run <runID> queued (<flow>)`) to tie the override to the next execution.

## Messaging
- When a user resets while a run is queued/running, show: “Cancel current run to reset agent state.” Button chain: Cancel → wait for status update → Reset.
- When external edits conflict with an active lock, surface “State changed on disk; retry after current run finishes or reset.”

## Data Integrity
- Overrides never touch workspace files or logs.
- Locks are cleared on reset; stale locks follow `global-agent-scheduler.md` timeout rules.
- Branch pointer is left as-is unless the user chooses “clear branch” during reset (optional checkbox).
