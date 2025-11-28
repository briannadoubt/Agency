# Phase Scaffolding CLI (plan flow)

The app’s “Add Phase (with Agent…)” sheet shells out to this CLI to create a phase, write a plan artifact, and optionally seed cards.

## Usage
```
phase-scaffold --project-root <path> --label "<phase label>" [options]
```

Required:
- `--project-root <path>`: repository root containing `project/`
- `--label "<name>"`: phase label; used for slug + heading

Options:
- `--seed-plan`                     Write `backlog/N.0-phase-plan.md`
- `--seed-card "<title>"`           Seed a backlog card (repeatable)
- `--task-hints "<text>"`           Freeform hints to include in plan notes
- `--proposed-task "<title>"`       Task to embed in plan tasks (repeatable)
- `--auto-create-cards`             Materialize plan tasks into cards

## Outputs
- Human logs on stdout (`log: ...`)
- Final JSON result on stdout with:
  - `phaseNumber`, `phaseSlug`, `phasePath`
  - `planArtifact` (path) when seeded
  - `seededCards`, `materializedCards`, `skippedTasks`
  - `logs`, `exitCode`

## Exit codes
- `0` success
- `1` generic failure (filesystem or unexpected error)
- `2` phase already exists
- `3` missing `project/` root
- `4` empty/missing label
- `5` plan artifact write failed

## Examples
Create a plan with hints and proposed tasks:
```
phase-scaffold --project-root /repo --label "Agent Planning" \
  --seed-plan --task-hints "Outline setup + guardrails" \
  --proposed-task "Create plan artifact" \
  --proposed-task "Seed starter cards"
```

Seed a plan and auto-create cards from tasks:
```
phase-scaffold --project-root /repo --label "Demo Phase" \
  --seed-plan --auto-create-cards \
  --proposed-task "Draft roadmap" \
  --proposed-task "Write README for plan flow"
```
