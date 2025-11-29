---
architecture_version: 1
roadmap_fingerprint: d71088f56ff0d0190c8e1bc886d4eb1e94c9304ba6008c649fd890541abc270b
generated_at: 2025-11-29
project_goal: Deliver agent-driven planning and bootstrap flows.
---

# ARCHITECTURE.md

Summary:
Deliver agent-driven planning and bootstrap flows.

Goals & Constraints:
- Target platforms: unspecified
- Languages: unspecified
- Tech stack: unspecified
- Roadmap alignment: 2 phase(s); fingerprint d71088f56ff0

System Overview:
- Generated from ROADMAP.md; keep architecture in sync after roadmap changes.
- Update and regenerate when phases or tasks change.

Components:
- Phase 6 — agent-planning (done)
  - Tasks:
    - [x] 6.1 Phase Scaffolding CLI — CLI to scaffold phases and optional plan artifacts.
    - [x] 6.2 Agent Plan Flow & Runner Wiring — Add AgentFlow.plan backend wiring and runner streaming.
    - [x] 6.3 UI Phase Creation Flow — UI entrypoints to launch agent-driven phase creation with feedback.
    - [x] 6.4 Plan Artifact & Card Materialization — Persist plan artifact and optional auto-card creation.
    - [x] 6.5 Validation & Cleanup — Keep phase creation safe while MCP deferred.
    - [x] 6.6 Tests & Previews — Regression tests for plan flow and UI previews.
    - [x] 6.7 Docs & Guardrails — Docs and feature flags for agent-driven creation.
- Phase 7 — project-bootstrap (planned)
  - Tasks:
    - [x] 7.0 Phase Plan — Project Bootstrap — Phase plan covering scope, risks, validation.
    - [x] 7.1 ROADMAP Spec & Generator — Define roadmap schema and generator with validation.
    - [x] 7.2 Project Initialization CLI — Initializer for existing or new directories using roadmap.
    - [x] 7.3 Task Materialization from ROADMAP — Generate backlog cards from roadmap entries.
    - [x] 7.4 ARCHITECTURE.md Generation — Generate architecture doc from roadmap + inputs.
    - [x] 7.5 Validation & E2E Tests — Extend validators and add end-to-end coverage for bootstrap.

Data & Storage:
- Keep artifacts under project/; prefer git-tracked text formats.

Integrations:
- None specified yet.

Testing & Observability:
- Mirror roadmap acceptance criteria with unit/UI tests per component.

Risks & Mitigations:
- Stale architecture vs roadmap: compare fingerprints and regenerate after roadmap changes.

Architecture (machine readable):
```json
{
  "generatedAt": "2025-11-29",
  "languages": [],
  "manualNotes": "",
  "phases": [
    {
      "label": "agent-planning",
      "number": 6,
      "status": "done",
      "tasks": [
        {
          "code": "6.1",
          "status": "done",
          "summary": "CLI to scaffold phases and optional plan artifacts.",
          "title": "Phase Scaffolding CLI"
        },
        {
          "code": "6.2",
          "status": "done",
          "summary": "Add AgentFlow.plan backend wiring and runner streaming.",
          "title": "Agent Plan Flow & Runner Wiring"
        },
        {
          "code": "6.3",
          "status": "done",
          "summary": "UI entrypoints to launch agent-driven phase creation with feedback.",
          "title": "UI Phase Creation Flow"
        },
        {
          "code": "6.4",
          "status": "done",
          "summary": "Persist plan artifact and optional auto-card creation.",
          "title": "Plan Artifact & Card Materialization"
        },
        {
          "code": "6.5",
          "status": "done",
          "summary": "Keep phase creation safe while MCP deferred.",
          "title": "Validation & Cleanup"
        },
        {
          "code": "6.6",
          "status": "done",
          "summary": "Regression tests for plan flow and UI previews.",
          "title": "Tests & Previews"
        },
        {
          "code": "6.7",
          "status": "done",
          "summary": "Docs and feature flags for agent-driven creation.",
          "title": "Docs & Guardrails"
        }
      ]
    },
    {
      "label": "project-bootstrap",
      "number": 7,
      "status": "planned",
      "tasks": [
        {
          "code": "7.0",
          "status": "done",
          "summary": "Phase plan covering scope, risks, validation.",
          "title": "Phase Plan \u2014 Project Bootstrap"
        },
        {
          "code": "7.1",
          "status": "done",
          "summary": "Define roadmap schema and generator with validation.",
          "title": "ROADMAP Spec & Generator"
        },
        {
          "code": "7.2",
          "status": "done",
          "summary": "Initializer for existing or new directories using roadmap.",
          "title": "Project Initialization CLI"
        },
        {
          "code": "7.3",
          "status": "done",
          "summary": "Generate backlog cards from roadmap entries.",
          "title": "Task Materialization from ROADMAP"
        },
        {
          "code": "7.4",
          "status": "done",
          "summary": "Generate architecture doc from roadmap + inputs.",
          "title": "ARCHITECTURE.md Generation"
        },
        {
          "code": "7.5",
          "status": "done",
          "summary": "Extend validators and add end-to-end coverage for bootstrap.",
          "title": "Validation & E2E Tests"
        }
      ]
    }
  ],
  "projectGoal": "Deliver agent-driven planning and bootstrap flows.",
  "roadmapFingerprint": "d71088f56ff0d0190c8e1bc886d4eb1e94c9304ba6008c649fd890541abc270b",
  "targetPlatforms": [],
  "techStack": [],
  "version": 1
}
```

Manual Notes:
None yet.

History:
- 2025-11-29: Architecture generated from roadmap.
