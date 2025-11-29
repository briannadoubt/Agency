# Roadmap

## Phase 6 — Agent Planning (current)
- Agent-driven phase creation UI and CLI (plan flow) with plan artifacts at `phase-N-<label>/backlog/N.0-phase-plan.md`.
- Optional auto-materialization of cards from plan tasks; UI CTA to create cards later.
- Tests, previews, and guardrails in place; flow can be disabled via `AGENCY_DISABLE_PLAN_FLOW`.
- MCP integration deferred: current implementation uses local CLI backend and app-side runner; revisit once MCP is ready.

## Phase 7 — Project Bootstrap
- Roadmap-driven project initializer that can scaffold in an existing directory or create a new one.
- ROADMAP.md generator/spec as the single source of truth for phases, tasks, and subtasks.
- Task/card materialization from the roadmap with proper frontmatter and folder layout.
- ARCHITECTURE.md generation derived from the roadmap plus stack/platform inputs.
- Validation and end-to-end tests to keep the bootstrap flow safe and idempotent.

## Future (post-Phase 6)
- Wire MCP worker for plan flow and downstream implement/review tasks.
- Broaden feature flags/entitlements once MCP hardening lands.
- Expand docs with MCP-specific setup and permissions.
