# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Agency is a macOS SwiftUI app for agent-assisted kanban project management. It uses Markdown files as cards stored in `project/phase-*/{backlog,in-progress,done}/` folders. The filesystem is the source of truth—moving a card between status folders changes its state.

## Build & Test Commands

```bash
# Build
xcodebuild -scheme Agency -destination 'platform=macOS' build

# Run all tests
xcodebuild -scheme Agency -destination 'platform=macOS' test

# Open in Xcode
open Agency.xcodeproj
```

## Architecture

### Directory Structure
- `Agency/` - Main app source (SwiftUI views, models)
- `Agency/Models/` - Core domain: Card parsing, ProjectLoader, AgentRunner, validators, generators
- `Agency/Supervisor/` - XPC supervisor/worker orchestration for agent runs
- `Agency/Worker/` - Sandboxed worker runtime for Codex agents
- `Agency/Conventions/` - Project validation (RoadmapValidator, ArchitectureValidator, ConventionsValidator)
- `AgencyTests/` - Unit tests (Swift Testing with `#expect`)
- `AgencyUITests/` - UI tests
- `project/` - Kanban phases with Markdown task cards

### Key Components
- **Card**: Markdown file with YAML frontmatter and sections (Summary, Acceptance Criteria, Notes, History)
- **CardStatus**: `backlog`, `in-progress`, `done` (determined by parent folder)
- **Phase**: Directory `project/phase-N-label/` grouping related cards
- **ProjectLoader**: Scans project folder, watches for changes, provides `ProjectSnapshot`
- **AgentRunner**: Orchestrates agent runs with pluggable backends (simulated, codex, cli)
- **PhaseCreator**: CLI-driven phase scaffolding with plan artifacts

### Card Filename Convention
`<phase>.<task>-slug.md` (e.g., `1.3-input-routing.md`)

### Card Frontmatter Fields
`owner`, `agent_flow`, `agent_status`, `branch`, `risk`, `review`, `parallelizable`

## Task Workflow

See `PROJECT_WORKFLOW.md` for the full workflow. Key points:
1. Work on the lowest-numbered card in backlog first
2. Create branch `implement/<kebab-slug>`
3. Move card to `in-progress/`, implement, run tests
4. Move to `done/` after review approval

## Code Conventions

- Swift 6.2, macOS 26, Xcode 26
- Use `@Observable` macro and Swift Concurrency (async/await, actors)
- **Do not use DispatchQueues** - prefer Swift Concurrency
- Avoid Combine unless absolutely necessary
- Test methods: `test<Behavior>` using `#expect`
- Views end with `View`; tests mirror subject (`ContentViewTests`)

## Feature Flags

- `AGENCY_DISABLE_PLAN_FLOW=1` - Disable agent-driven phase creation
- `AGENCY_ENABLE_PLAN_FLOW=1` - Explicitly enable (default when unset)

## Related Documentation

- `AGENTS.md` - Full repository guidelines for agents
- `PROJECT_WORKFLOW.md` - Markdown-driven kanban workflow details
- `docs/phase-scaffolding-cli.md` - CLI for phase creation
- `docs/project-initialization-cli.md` - CLI for project bootstrap
