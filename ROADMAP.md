---
roadmap_version: 1
project_goal: Deliver agent-driven planning and bootstrap flows.
generated_at: 2025-11-29
---

# Roadmap

Summary:
Deliver agent-driven planning and bootstrap flows.

Phase Overview:
- Phase 6 — agent-planning (done)
- Phase 7 — project-bootstrap (planned)

## Phase 6 — agent-planning (done)

Summary:
Phase 6 shipped agent-driven phase creation UI + CLI with plan artifacts.

Tasks:
- [x] 6.1 Phase Scaffolding CLI — CLI to scaffold phases and optional plan artifacts.
  - Owner: bri
  - Risk: normal
  - Acceptance Criteria:
    - [ ] Create phase directories and plan artifact
  - Status: done
- [x] 6.2 Agent Plan Flow & Runner Wiring — Add AgentFlow.plan backend wiring and runner streaming.
  - Owner: bri
  - Risk: normal
  - Acceptance Criteria:
    - [ ] Plan flow triggers CLI backend
  - Status: done
- [x] 6.3 UI Phase Creation Flow — UI entrypoints to launch agent-driven phase creation with feedback.
  - Owner: bri
  - Risk: normal
  - Acceptance Criteria:
    - [ ] Sidebar CTA and dialog submit
  - Status: done
- [x] 6.4 Plan Artifact & Card Materialization — Persist plan artifact and optional auto-card creation.
  - Owner: bri
  - Risk: normal
  - Acceptance Criteria:
    - [ ] Plan stored at phase backlog
    - [ ] Optional card auto-create
  - Status: done
- [x] 6.5 Validation & Cleanup — Keep phase creation safe while MCP deferred.
  - Owner: bri
  - Risk: normal
  - Acceptance Criteria:
    - [ ] Validator recognizes new structure
  - Status: done
- [x] 6.6 Tests & Previews — Regression tests for plan flow and UI previews.
  - Owner: bri
  - Risk: normal
  - Acceptance Criteria:
    - [ ] Add tests covering CLI + UI
  - Status: done
- [x] 6.7 Docs & Guardrails — Docs and feature flags for agent-driven creation.
  - Owner: bri
  - Risk: normal
  - Acceptance Criteria:
    - [ ] ROADMAP updated with Phase 6 scope
  - Status: done

## Phase 7 — project-bootstrap (planned)

Summary:
Phase 7 will bootstrap projects from a roadmap: generator, initializer, architecture, validation.

Tasks:
- [x] 7.0 Phase Plan — Project Bootstrap — Phase plan covering scope, risks, validation.
  - Owner: bri
  - Risk: normal
  - Acceptance Criteria:
    - [ ] Plan accepted
  - Status: done
- [ ] 7.1 ROADMAP Spec & Generator — Define roadmap schema and generator with validation.
  - Owner: bri
  - Risk: normal
  - Acceptance Criteria:
    - [ ] Schema + template
    - [ ] Generator + tests
  - Status: in-progress
- [ ] 7.2 Project Initialization CLI — Initializer for existing or new directories using roadmap.
  - Owner: bri
  - Risk: normal
  - Acceptance Criteria:
    - [ ] In-place init
    - [ ] New dir init
    - [ ] Dry-run
  - Status: backlog
- [ ] 7.3 Task Materialization from ROADMAP — Generate backlog cards from roadmap entries.
  - Owner: bri
  - Risk: normal
  - Acceptance Criteria:
    - [ ] Materialize tasks
    - [ ] Handle regeneration
  - Status: backlog
- [ ] 7.4 ARCHITECTURE.md Generation — Generate architecture doc from roadmap + inputs.
  - Owner: bri
  - Risk: normal
  - Acceptance Criteria:
    - [ ] Architecture template
    - [ ] Regeneration
  - Status: backlog
- [ ] 7.5 Validation & E2E Tests — Extend validators and add end-to-end coverage for bootstrap.
  - Owner: bri
  - Risk: normal
  - Acceptance Criteria:
    - [ ] ConventionsValidator extensions
    - [ ] E2E for existing/new dirs
  - Status: backlog

Roadmap (machine readable):
```json
{
  "generatedAt": "2025-11-29",
  "manualNotes": "",
  "phases": [
    {
      "label": "agent-planning",
      "number": 6,
      "status": "done",
      "summary": "Phase 6 shipped agent-driven phase creation UI + CLI with plan artifacts.",
      "tasks": [
        {
          "acceptanceCriteria": [
            "Create phase directories and plan artifact"
          ],
          "code": "6.1",
          "owner": "bri",
          "parallelizable": false,
          "risk": "normal",
          "status": "done",
          "summary": "CLI to scaffold phases and optional plan artifacts.",
          "title": "Phase Scaffolding CLI"
        },
        {
          "acceptanceCriteria": [
            "Plan flow triggers CLI backend"
          ],
          "code": "6.2",
          "owner": "bri",
          "parallelizable": false,
          "risk": "normal",
          "status": "done",
          "summary": "Add AgentFlow.plan backend wiring and runner streaming.",
          "title": "Agent Plan Flow & Runner Wiring"
        },
        {
          "acceptanceCriteria": [
            "Sidebar CTA and dialog submit"
          ],
          "code": "6.3",
          "owner": "bri",
          "parallelizable": false,
          "risk": "normal",
          "status": "done",
          "summary": "UI entrypoints to launch agent-driven phase creation with feedback.",
          "title": "UI Phase Creation Flow"
        },
        {
          "acceptanceCriteria": [
            "Plan stored at phase backlog",
            "Optional card auto-create"
          ],
          "code": "6.4",
          "owner": "bri",
          "parallelizable": false,
          "risk": "normal",
          "status": "done",
          "summary": "Persist plan artifact and optional auto-card creation.",
          "title": "Plan Artifact & Card Materialization"
        },
        {
          "acceptanceCriteria": [
            "Validator recognizes new structure"
          ],
          "code": "6.5",
          "owner": "bri",
          "parallelizable": false,
          "risk": "normal",
          "status": "done",
          "summary": "Keep phase creation safe while MCP deferred.",
          "title": "Validation & Cleanup"
        },
        {
          "acceptanceCriteria": [
            "Add tests covering CLI + UI"
          ],
          "code": "6.6",
          "owner": "bri",
          "parallelizable": false,
          "risk": "normal",
          "status": "done",
          "summary": "Regression tests for plan flow and UI previews.",
          "title": "Tests & Previews"
        },
        {
          "acceptanceCriteria": [
            "ROADMAP updated with Phase 6 scope"
          ],
          "code": "6.7",
          "owner": "bri",
          "parallelizable": false,
          "risk": "normal",
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
      "summary": "Phase 7 will bootstrap projects from a roadmap: generator, initializer, architecture, validation.",
      "tasks": [
        {
          "acceptanceCriteria": [
            "Plan accepted"
          ],
          "code": "7.0",
          "owner": "bri",
          "parallelizable": false,
          "risk": "normal",
          "status": "done",
          "summary": "Phase plan covering scope, risks, validation.",
          "title": "Phase Plan \u2014 Project Bootstrap"
        },
        {
          "acceptanceCriteria": [
            "Schema + template",
            "Generator + tests"
          ],
          "code": "7.1",
          "owner": "bri",
          "parallelizable": false,
          "risk": "normal",
          "status": "in-progress",
          "summary": "Define roadmap schema and generator with validation.",
          "title": "ROADMAP Spec & Generator"
        },
        {
          "acceptanceCriteria": [
            "In-place init",
            "New dir init",
            "Dry-run"
          ],
          "code": "7.2",
          "owner": "bri",
          "parallelizable": false,
          "risk": "normal",
          "status": "backlog",
          "summary": "Initializer for existing or new directories using roadmap.",
          "title": "Project Initialization CLI"
        },
        {
          "acceptanceCriteria": [
            "Materialize tasks",
            "Handle regeneration"
          ],
          "code": "7.3",
          "owner": "bri",
          "parallelizable": false,
          "risk": "normal",
          "status": "backlog",
          "summary": "Generate backlog cards from roadmap entries.",
          "title": "Task Materialization from ROADMAP"
        },
        {
          "acceptanceCriteria": [
            "Architecture template",
            "Regeneration"
          ],
          "code": "7.4",
          "owner": "bri",
          "parallelizable": false,
          "risk": "normal",
          "status": "backlog",
          "summary": "Generate architecture doc from roadmap + inputs.",
          "title": "ARCHITECTURE.md Generation"
        },
        {
          "acceptanceCriteria": [
            "ConventionsValidator extensions",
            "E2E for existing/new dirs"
          ],
          "code": "7.5",
          "owner": "bri",
          "parallelizable": false,
          "risk": "normal",
          "status": "backlog",
          "summary": "Extend validators and add end-to-end coverage for bootstrap.",
          "title": "Validation & E2E Tests"
        }
      ]
    }
  ],
  "projectGoal": "Deliver agent-driven planning and bootstrap flows.",
  "version": 1
}
```

History:
- 2025-11-29: Regenerated roadmap from goal: Deliver agent-driven planning and bootstrap flows.

