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
- `Agency/Models/CLIProviders/` - CLI provider abstraction (AgentCLIProvider, ProviderRegistry, GenericCLIExecutor)
- `Agency/Models/Prompts/` - Prompt template system (PromptBuilder, PromptContext, AgentRole, DefaultPromptTemplates)
- `Agency/Supervisor/` - Background orchestration (SupervisorCoordinator, AgentScheduler, FlowPipelineOrchestrator, BacklogWatcher)
- `Agency/Worker/` - Sandboxed worker runtime for agent execution
- `Agency/Conventions/` - Project validation (RoadmapValidator, ArchitectureValidator, ConventionsValidator)
- `AgencyTests/` - Unit tests (Swift Testing with `#expect`)
- `AgencyUITests/` - UI tests
- `project/` - Kanban phases with Markdown task cards

### Key Components

**Core Domain:**
- **Card**: Markdown file with YAML frontmatter and sections (Summary, Acceptance Criteria, Notes, History)
- **CardStatus**: `backlog`, `in-progress`, `done` (determined by parent folder)
- **Phase**: Directory `project/phase-N-label/` grouping related cards
- **ProjectLoader**: Scans project folder, watches for changes, provides `ProjectSnapshot`

**Agent System:**
- **AgentSupervisor**: Singleton exposing supervisor API, wraps SupervisorCoordinator
- **SupervisorCoordinator**: Top-level orchestration with NSBackgroundActivityScheduler
- **AgentScheduler**: Queue management, concurrency control, card locking, backoff/retry
- **AgentFlowCoordinator**: Card lifecycle updates, frontmatter/history management
- **FlowPipelineOrchestrator**: Multi-step flow sequencing (research → plan → implement → review)
- **BacklogWatcher**: FSEvents monitoring of backlog folders for automatic processing

**CLI Provider Layer:**
- **AgentCLIProvider**: Protocol for CLI tools (locator, streamParser, buildArguments)
- **ProviderRegistry**: Discovery, registration, and selection of CLI providers
- **GenericCLIExecutor**: Runs any registered provider with streaming output
- **ClaudeCodeProvider**: Claude Code CLI implementation

**Prompt System:**
- **PromptBuilder**: Template loading with project → app → built-in fallback chain
- **PromptContext**: Variables for card, flow, project context
- **AgentRole**: Implementer, Reviewer, Researcher, Architect, Supervisor
- **DefaultPromptTemplates**: Built-in templates for all roles and flows

**Execution:**
- **AgentRunner**: UI-facing run orchestration with pluggable backends
- **PhaseCreator**: CLI-driven phase scaffolding with plan artifacts

### Agent Flows & Pipelines

| Flow | Role | Description |
|------|------|-------------|
| `implement` | Implementer | Execute acceptance criteria, write code, run tests |
| `review` | Reviewer | Analyze changes, provide feedback, identify issues |
| `research` | Researcher | Gather info, document findings, explore codebase |
| `plan` | Architect | Design solutions, break down tasks, create plans |

| Pipeline | Flows |
|----------|-------|
| `implement-only` | implement |
| `implement-review` | implement → review |
| `research-implement` | research → implement |
| `full` | research → plan → implement → review |

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
