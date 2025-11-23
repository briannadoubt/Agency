# Markdown-Driven Kanban macOS App

This is the roadmap for a macOS app driven entirely by a **filesystem + markdown** workflow. Cards are markdown files. Status = which folder they’re in. Agents operate by editing those files.

---

## Core Model (Simple + Durable)

* **Card = one markdown file** named `<phase>.<task>-slug.md`.
* **Status = folder**: `backlog/`, `in-progress/`, `done/`.
* **Phase = directory**: `phase-0-*`, `phase-1-*`, etc.
* No JSON, no DB — filesystem is the API.
* App = viewer + editor + file‑mover.

---

## Card Markdown Format

```markdown
---
owner: bri
agent_flow: null        # implement | review | research
agent_status: idle      # idle | requested | running | completed | failed
branch: null
risk: normal
review: not-requested
---

# 1.3 Input Routing

Summary:
Short description.

Acceptance Criteria:
- [ ] measurable thing
- [ ] another thing

Notes:
Optional free-form content.

History:
- 2025-11-22: Created.
```

Frontmatter optional. App parses it if present.

---

## Phase 0 — Foundation

**0.1 — Conventions**

* Establish the core folder hierarchy (`project/phase-N/...`).
* Define naming conventions for cards (`<phase>.<task>-slug.md`).
* Add examples demonstrating good vs. bad filenames.
* Document rules for status = folder mapping.
  Define filesystem layout + card format.
* Acceptance: parsing must tolerate missing/extra sections and report validation errors without crashing.

**0.2 — Models**

* Implement `Card` model derived entirely from filename + folder.
* Implement `Phase` model by parsing phase directory naming.
* Add helpers to extract code, slug, and task numbers.
* Support optional frontmatter fields.
  Swift structs for `Card` and `Phase` (derived, not stored).

**0.3 — Scanner**

* Walk the `project/` tree and detect phases automatically.
* Locate `backlog`, `in-progress`, and `done` under each phase.
* Parse all markdown files into `Card` instances.
* Report naming collisions or orphaned card files.
  Walk phase folders → load cards.
* Acceptance: handles 1k cards in <500ms scan on M-series Mac; debounced filesystem watcher for live updates.

**0.4 — Markdown Parser**

* Parse YAML frontmatter (if present) into key-value pairs.
* Extract title from the first `#` heading.
* Detect `Summary`, `Acceptance Criteria`, `Notes`, `History` blocks.
* Normalize checklist items (`- [ ]` / `- [x]`).
  Extract title, summary, criteria, notes, frontmatter.

---

## Phase 1 — App Shell + Kanban

**1.1 — Project Loader**

* Present open dialog to select a project directory.
* Validate the existence of the `project/` root.
* Immediately scan and load all phases and cards.
* Handle reloads when filesystem changes occur.
  Pick directory → scan project.

**1.2 — Phase Sidebar**

* Display phases sorted numerically.
* Show phase name (derived from dir name) as subtitle.
* Highlight selected phase.
* Trigger kanban refresh when selection changes.
  List phases numerically.

**1.3 — Kanban Columns**

* Render three vertical lists: Backlog → In‑Progress → Done.
* Enable drag-and-drop between columns.
* Animate rearrangements smoothly.
* Reflect changes by moving the file on disk.
  Backlog / In‑Progress / Done → move files on drag.
* Acceptance: empty/error states displayed; filesystem changes reflected within 300ms via watcher.

**1.4 — Card Inspector**

* Display parsed title, summary, criteria, notes.
* Provide a read-only view initially.
* Include "Open in Editor" button.
* Prepare hooks for future inline editing (Phase 3).
  Show parsed markdown; open in external editor.

---

## Phase 2 — UI Foundations & Design System (Design-Led)

**2.1 — Design Source Import**

* Collect screenshots/design doc into `project/phase-2-ui-foundations/design/`.
* Capture typography scale, spacing, motion cues, and color tokens from the doc.
* Summarize primary/secondary backgrounds, border opacities, and accent usage.

**2.2 — Design Tokens**

* Define colors (dark background, blue accent, risk colors), typography, spacing, radii, shadows in a single Swift file (e.g., `DesignSystem/Tokens.swift`).
* Provide SwiftUI `ShapeStyle`/`Font`/`CGFloat` helpers.
* Acceptance: include spacing grid and a11y tokens; snapshot/preview references captured for regression checks.

**2.3 — Layout, Surfaces, and Header**

* Implement header bar styling (vibrancy/blur), title/subtitle, and toolbar baseline spacing.
* Specify board gutters, column widths, and card chrome (rounded, bordered, dark surfaces).

**2.4 — Card Component**

* Build dark card with phase.task badge, risk badge colors, summary truncation, progress bar, owner/branch/parallelizable/agent_status pills, and hover state.
* Support progress derived from acceptance criteria counts.
* Acceptance: contrast verified against design tokens; hover state respects reduced-motion fallback.

**2.5 — Detail Modal (View + Edit)**

* Large modal with view mode (metadata grid, summary, criteria list with checkboxes, notes box, history timeline) and structured form mode (inputs for metadata, criteria editor, notes, history with “Add Entry” prefilled date).
* Raw markdown mode with warning banner; share Save/Cancel controls.
* Acceptance: autosave guard rejects write if file changed on disk; preserves frontmatter order; history entry optional on save.

**2.6 — Interaction & Motion**

* Define animation curves/durations for hover, drag, and modal transitions.
* Ensure keyboard/focus/hover affordances; support reduced motion.
* Acceptance: document motion tokens (durations/curves) and reduced-motion behavior across cards, modal, and drag/drop.

**2.7 — Accessibility & Theming**

* Enforce contrast targets, Dynamic Type/Content Size, and fallback colors.
* Document safe color combos for risk badges and borders on dark background.

**2.8 — Handoff to Existing Screens**

* Wire tokens/components into Phase 1 shell (loader, sidebar, columns) and prep hooks for Phase 3 editors.

---

## Phase 3 — Editing & File Ops

**3.1 — Inline Editing**

* Provide text fields for summary and notes.
* Render acceptance criteria as checkboxes.
* Rewrite modified markdown back to the original file.
* Preserve all unedited formatting whenever possible.
  Edit summary, criteria, notes → write back to file.
* Acceptance: detects on-disk changes before save (optimistic locking or merge); preserves frontmatter order and untouched sections.

**3.2 — Create Card**

* Prompt for title.
* Auto-generate next task number in current phase.
* Generate slug automatically (kebab-case).
* Write a new markdown file using the standard template.
  Generate file: next task number + template.
* Acceptance: new card template includes optional history entry; validates filename uniqueness per phase.

**3.3 — Move Card**

* Drag card between columns moves file on disk.
* App validates that moves are legal (no skipping).
* Update live model instantly after move.
* Log movement in History if desired.
  Moving between folders = updating status.

**3.4 — Frontmatter Editor**

* Detect frontmatter block and show editable fields.
* Add/remove frontmatter cleanly if missing.
* Provide drop-downs for risk and review states.
* Validate YAML syntax before writing.
  Optional fields (owner, branch, review, risk).
* Acceptance: round-trip keeps ordering of unknown keys; rejects invalid YAML with inline error.

---

## Phase 4 — Developer Utilities

**4.1 — Claim Card**

* Automatically find the lowest-numbered card in Backlog.
* Move it to In‑Progress.
* Optionally set `owner` to current user.
* Record action in the card’s History section.
  Find lowest backlog code → move to in-progress.
* Acceptance: completes in <200ms on 1k cards; logs history entry; refuses if card already locked/agent running.

**4.2 — Branch Helper**

* Generate recommended git branch name.
* Copy to clipboard with one click.
* Add branch name to card frontmatter.
* Provide command snippet for quick terminal usage.
  Suggest: `implement/<code>-<slug>`.
* Acceptance: uses slug normalization; updates frontmatter without reordering other keys.

**4.3 — Validator**

* Scan entire project for structural issues.
* Check for missing headings or malformed sections.
* Warn about duplicate codes or invalid filenames.
* Provide quick “fix suggestions” where possible.
  Check naming + required sections.
* Acceptance: can run on 1k cards under 1s; autofix suggestions marked as proposed (no silent writes).

**4.4 — Search**

* Filter cards by code or partial code.
* Search by owner from frontmatter.
* Match words in title, summary, or notes.
* Provide instant results while typing.
  Filter by code, title, owner.
* Acceptance: in-memory filtering over 1k cards <200ms; highlights query matches.

---

## Phase 5 — Agent Integration (XPC-Backed)

Agents operate only on markdown; the app controls all file movement. Agent execution happens safely in a separate XPC process. Architecture details live in `project/XPC_ARCHITECTURE.md` and should be referenced by every card in this phase.

### Architecture Overview

* **SwiftUI App (frontend)**: sandboxed UI, owns scheduler, state machine, renders cards.
* **XPC Worker (backend)**: isolated process that runs Codex with filesystem access.
* **Codex CLI**: modifies markdown + project files when allowed.
* App uses XPC for every agent invocation: stable, world‑class, crash‑isolated.
* Acceptance: capability sandbox checklist enforced; zero writes outside scoped dirs; per-run logs and metrics recorded.

### Agent Flow Mechanics

The app:

1. Updates frontmatter:

   ```yaml
   agent_flow: implement
   agent_status: requested
   ```
2. Validates card status & locks the card.
3. Enqueues job in a global scheduler (parallelization rules below).
4. When job is dispatched, calls the XPC worker:

   ```swift
   worker.runAgent(flow: "implement", projectBookmark: bookmarkData, cardRelativePath: "project/.../1.3-input-routing.md")
   ```
5. Reflects results by updating `agent_status`, reloading file, unlocking card.

The XPC worker:

* Resolves the project bookmark with `.withSecurityScope`.
* Calls Codex using a controlled `Process`:

  ```bash
  codex exec --allow-files "implement: project/.../1.3-input-routing.md"
  ```
* Returns exit code + optional logs.
* Has no permission to move files or modify structure.

### Global Agent Scheduler

The app controls concurrency using:

* **Per-card lock**: a card with `agent_status: running` cannot start new flows.
* **Global max concurrency** (configurable): limits total active Codex sessions.
* **Per-flow concurrency caps**: e.g., only 1 `implement` job at a time.

Example config:

```yaml
agents:
  maxConcurrent: 3
  perFlow:
    implement: 1
    review: 2
    research: 2
```

Scheduler behavior:

* Jobs enter a queue when requested.
* If concurrency limits allow, the job is dispatched to XPC.
* When a job finishes, scheduler starts the next eligible one.
* Acceptance: backpressure strategy defined when queue grows; retry/backoff policy documented.

### Supported Agent Flows

#### implement — Builder

* Reads summary + criteria; writes code/tests.
* Updates checkboxes.
* Writes branch name into frontmatter.
* Adds entries to `History:`.
* Returns `completed` or `failed`.

#### review — Reviewer

* Diffs branch (if available) and checks acceptance criteria.
* Writes feedback in Notes/History.
* Sets `review: approved | changes-requested`.
* Updates `agent_status`.

#### research — Spec Enhancer

* Expands Summary, Acceptance Criteria, and Notes.
* Suggests dependencies or clarifications.
* Appends a `History:` entry.

### Failure Handling

* Non-zero exit code:

  * `agent_status: failed`.
  * Card remains in current folder.
  * App surfaces error details.
* Partial updates remain visible in the card; user may retry.
* Acceptance: crash/timeout paths tested; worker failure must not crash supervisor/app.

### Human Override

* User may edit frontmatter manually.
* Reset `agent_status` to `idle`.
* Rerun flows or override agent output.
* App never blocks manual edits.

---

### New Execution Tasks (aligned with XPC Architecture)

* **5.7 — Supervisor & Worker Jobs**: implement `CodexSupervisor.xpc` using `SMAppService`, launch ephemeral worker executables per task, and return `XPCEndpoint` for app↔worker messaging. Acceptance: retry/backoff defined; capability sandbox checklist enforced.
* **5.8 — Sandbox & File Access**: enforce security-scoped bookmarks for project roots, prefer read-only mounts, and provide scoped temp dirs to workers for outputs. Acceptance: no write outside scoped dirs; error surfaced on bookmark failure.
* **5.9 — Streaming & Cleanup**: stream logs/progress from workers, handle cancellation, and tear down endpoints to prove crash containment. Acceptance: cancellation propagates; no leaked processes/descriptors.

## Appendix — Invariants

* Markdown file = single source of truth.
* Folder = status.
* Filename prefix = `<phase>.<task>`.
* Frontmatter optional + YAML only.
* App only moves files + edits markdown.
* Agents operate through Codex by editing markdown only.

---

This trimmed roadmap keeps the full architecture intact but removes the heavy explanations. Ready to build on directly.
