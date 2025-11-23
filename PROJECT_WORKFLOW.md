# Markdown-Driven Kanban Workflow

## Core Model
- Card: single Markdown file representing a task
- Status: folder `backlog/`, `in-progress/`, or `done/`
- Phase: directory `project/phase-N-label/` grouping related cards
- Filename convention: `<phase>.<task>-slug.md` (e.g., `1.3-input-routing.md`)

## Card Format
- YAML frontmatter (optional fields): `owner`, `agent_flow`, `agent_status`, `branch`, `risk`, `review`, `parallelizable`
- Sections (Markdown):
  - `Summary` — short description of responsibility
  - `Acceptance Criteria` — `- [ ]` or `- [x]` checklist items
  - `Notes` — implementation ideas or context
  - `History` — dated log entries

### Parallelizable Flag
- `parallelizable: true` indicates a card may run concurrently with others in scheduling flows.
- Default: treat as `false` if absent.

## Invariants
- Folder determines status; moving a card between status folders changes its state
- Filename prefix `<phase>.<task>` is the canonical card code
- The Markdown file is the single source of truth for a card
- Agents (via Codex) edit Markdown content and frontmatter only; they do not move files automatically

## Directory Layout
```
project/
  phase-N-label/
    backlog/
    in-progress/
    done/
```

## Authoring Tips
- Keep slugs lowercase kebab-case
- Use consistent section ordering
- Prefer small, atomic cards to simplify flows
- Record every edit in `History` with `YYYY-MM-DD` date
