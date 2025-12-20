---
architecture_version: 2
roadmap_fingerprint: d71088f56ff0d0190c8e1bc886d4eb1e94c9304ba6008c649fd890541abc270b
generated_at: 2025-12-07
project_goal: Agent-assisted kanban for macOS with automatic background processing.
---

# ARCHITECTURE.md

Summary:
Agent-assisted kanban for macOS with automatic background processing, multi-step agent pipelines, and pluggable CLI provider support.

Goals & Constraints:
- Target platforms: macOS 26
- Languages: Swift 6.2
- Tech stack: SwiftUI, Swift Concurrency, FSEvents, NSBackgroundActivityScheduler
- Roadmap alignment: 3 phase(s) complete; fingerprint d71088f56ff0

System Overview:
Agency is a macOS SwiftUI app for agent-assisted kanban project management. It uses Markdown files as cards stored in `project/phase-*/{backlog,in-progress,done}/` folders. The filesystem is the source of truth.

The agent system provides:
- Automatic backlog processing via FSEvents monitoring
- Multi-step flow pipelines (research → plan → implement → review)
- Pluggable CLI provider architecture (Claude Code, future: Aider, Codex)
- Prompt template system with project → app → built-in fallback chain
- Background operation via NSBackgroundActivityScheduler

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        Agency App (SwiftUI)                      │
└───────────────────────────┬─────────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────────┐
│                      AgentSupervisor                             │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  SupervisorCoordinator                                      │ │
│  │  ├── BacklogWatcher (FSEvents)                             │ │
│  │  ├── FlowPipelineOrchestrator                              │ │
│  │  └── SupervisorStateStore                                  │ │
│  └────────────────────────────────────────────────────────────┘ │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  AgentScheduler (queue, concurrency, locks, backoff)        │ │
│  └────────────────────────────────────────────────────────────┘ │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  AgentFlowCoordinator (card lifecycle, frontmatter)         │ │
│  └────────────────────────────────────────────────────────────┘ │
└───────────────────────────┬─────────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────────┐
│  AgentRunner + ProviderRegistry + Executors                      │
└───────────────────────────┬─────────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────────┐
│  CLI Provider Layer (AgentCLIProvider, GenericCLIExecutor)       │
└───────────────────────────┬─────────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────────┐
│  Prompt System (PromptBuilder, PromptContext, Templates)         │
└─────────────────────────────────────────────────────────────────┘
```

## Components

### Core Domain
- **Card**: Markdown file with YAML frontmatter and sections
- **ProjectLoader**: Scans project folder, watches for changes
- **CardFileParser**: Parses card markdown into Card model

### Supervisor Layer (`Agency/Supervisor/`)
- **AgentSupervisor**: Singleton API for SwiftUI app
- **SupervisorCoordinator**: Top-level orchestration, background activity
- **AgentScheduler**: Queue management, concurrency control, card locking
- **AgentFlowCoordinator**: Card lifecycle updates, result parsing
- **FlowPipelineOrchestrator**: Multi-step flow sequencing
- **BacklogWatcher**: FSEvents monitoring of backlog folders
- **SupervisorStateStore**: State persistence for crash recovery
- **WorkerLauncher**: Process spawning for CLI executors

### CLI Provider Layer (`Agency/Models/CLIProviders/`)
- **AgentCLIProvider**: Protocol for CLI tool integration
- **ProviderRegistry**: Provider discovery and selection
- **GenericCLIExecutor**: Runs any registered provider
- **CLILocating**: Protocol for CLI binary discovery
- **StreamParsing**: Protocol for output stream parsing
- **ClaudeCodeProvider**: Claude Code CLI implementation

### Prompt System (`Agency/Models/Prompts/`)
- **PromptBuilder**: Template loading and variable resolution
- **PromptContext**: Variables for prompt generation
- **AgentRole**: implementer, reviewer, researcher, architect, supervisor
- **DefaultPromptTemplates**: Built-in templates for all roles/flows

### Execution Layer
- **AgentRunner**: UI-facing run orchestration
- **SimulatedAgentExecutor**: Testing/previews
- **XPCAgentExecutor**: XPC-based workers
- **ClaudeCodeExecutor**: Direct Claude Code CLI
- **GenericCLIExecutor**: Provider-based execution
- **CLIPhaseExecutor**: Phase scaffolding

## Agent Flows & Pipelines

| Flow | Role | Description |
|------|------|-------------|
| `implement` | Implementer | Execute acceptance criteria, write code |
| `review` | Reviewer | Analyze changes, provide feedback |
| `research` | Researcher | Gather info, document findings |
| `plan` | Architect | Design solutions, create plans |

| Pipeline | Flows |
|----------|-------|
| `implement-only` | implement |
| `implement-review` | implement → review |
| `research-implement` | research → implement |
| `full` | research → plan → implement → review |

## Completed Phases

- Phase 6 — agent-planning (done)
  - Tasks:
    - [x] 6.1 Phase Scaffolding CLI
    - [x] 6.2 Agent Plan Flow & Runner Wiring
    - [x] 6.3 UI Phase Creation Flow
    - [x] 6.4 Plan Artifact & Card Materialization
    - [x] 6.5 Validation & Cleanup
    - [x] 6.6 Tests & Previews
    - [x] 6.7 Docs & Guardrails

- Phase 7 — project-bootstrap (done)
  - Tasks:
    - [x] 7.0 Phase Plan — Project Bootstrap
    - [x] 7.1 ROADMAP Spec & Generator
    - [x] 7.2 Project Initialization CLI
    - [x] 7.3 Task Materialization from ROADMAP
    - [x] 7.4 ARCHITECTURE.md Generation
    - [x] 7.5 Validation & E2E Tests

- Phase 9 — claude-code (done)
  - Tasks:
    - [x] 9.0 Claude Code Planning
    - [x] 9.1 CLI Discovery
    - [x] 9.2 API Key Management
    - [x] 9.3 Process Spawning
    - [x] 9.4 Output Streaming
    - [x] 9.5 Agent Session UI
    - [x] 9.6 Session Persistence
    - [x] 9.7 Testing & Polish

## Data & Storage
- Cards: Markdown files in `project/phase-*/` folders
- State: SupervisorStateStore persists to Application Support
- Secrets: API keys in macOS Keychain

## Integrations
- Claude Code CLI via ClaudeCodeProvider
- Siri/Shortcuts via AppIntents
- Spotlight search via CoreSpotlight

## Testing & Observability
- Unit tests: `AgencyTests/` using Swift Testing
- UI tests: `AgencyUITests/`
- 76+ tests covering supervisor, provider, prompt, and flow components

## Risks & Mitigations
- Stale architecture vs roadmap: compare fingerprints and regenerate
- CLI availability: ProviderRegistry checks availability before runs
- Background processing: NSBackgroundActivityScheduler ensures persistence

Architecture (machine readable):
```json
{
  "version": 2,
  "generatedAt": "2025-12-07",
  "projectGoal": "Agent-assisted kanban for macOS with automatic background processing.",
  "targetPlatforms": ["macOS 26"],
  "languages": ["Swift 6.2"],
  "techStack": ["SwiftUI", "Swift Concurrency", "FSEvents", "NSBackgroundActivityScheduler"],
  "roadmapFingerprint": "d71088f56ff0d0190c8e1bc886d4eb1e94c9304ba6008c649fd890541abc270b",
  "phases": [
    {"number": 6, "label": "agent-planning", "status": "done"},
    {"number": 7, "label": "project-bootstrap", "status": "done"},
    {"number": 9, "label": "claude-code", "status": "done"},
    {"number": 12, "label": "openllm-api", "status": "done"}
  ],
  "manualNotes": null
}
```

History:
- 2025-11-29: Architecture generated from roadmap.
- 2025-12-07: Updated with Phase 9 Claude Code integration, supervisor coordinator, CLI provider abstraction, and prompt system.
