# Agency

Agent-assisted kanban for macOS, powered by Markdown cards under `project/phase-*` folders.

## Agent-driven phase creation (Phase 6)
- Start from the app: **Add Phase (with Agent…)**. The agent scaffolds `phase-N-<label>` with standard status folders and writes a plan artifact at `backlog/N.0-phase-plan.md`.
- Plan artifact contents:
  - Frontmatter (owner/agent fields + `plan_version`, `plan_checksum`).
  - Human-readable sections: summary, acceptance criteria, notes, “Plan Tasks” with rationale and acceptance criteria per task.
  - Machine-readable JSON block of tasks (for future MCP/automation).
  - History entries stamped with run IDs.
- Manual edits are safe: update the markdown sections and JSON together; rerun validation to confirm structure.
- Creating cards from the plan:
  - Auto-create during the flow by toggling “Auto-create cards from plan”.
  - If tasks remain, use “Create cards from plan” in the sheet after a run; duplicates are skipped.

## Feature flag / guardrail
- Set `AGENCY_DISABLE_PLAN_FLOW=1` to hide/disable the agent phase-creation flow (UI and controller).
- Optional opt-in guard: `AGENCY_ENABLE_PLAN_FLOW=1` (defaults to enabled when unset).

## CLI plan scaffolding
- See `docs/phase-scaffolding-cli.md` for arguments, exit codes, and examples of the underlying CLI used by the app.

## Running tests
```
xcodebuild -scheme Agency -destination 'platform=macOS' test
```
