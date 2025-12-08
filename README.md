# Agency

Agent-assisted kanban for macOS, powered by Markdown cards under `project/phase-*` folders.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Agency App (SwiftUI)                      │
│                                                                 │
│  ┌─────────────┐    ┌─────────────┐    ┌──────────────────┐    │
│  │ CardListView│    │AgentRunPanel│    │SupervisorStatus  │    │
│  └─────────────┘    └─────────────┘    └──────────────────┘    │
└───────────────────────────┬─────────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────────┐
│                      AgentSupervisor                             │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │                 SupervisorCoordinator                       │ │
│  │  ┌─────────────┐  ┌──────────────┐  ┌───────────────────┐  │ │
│  │  │BacklogWatcher│  │FlowPipeline  │  │SupervisorState   │  │ │
│  │  │ (FSEvents)   │  │Orchestrator  │  │Store             │  │ │
│  │  └─────────────┘  └──────────────┘  └───────────────────┘  │ │
│  └────────────────────────────────────────────────────────────┘ │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │                   AgentScheduler                            │ │
│  │  • Queue management (soft/hard limits)                     │ │
│  │  • Concurrency control (per-flow limits)                   │ │
│  │  • Card locking (prevent concurrent runs on same card)     │ │
│  │  • Backoff/retry logic                                     │ │
│  └────────────────────────────────────────────────────────────┘ │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │                AgentFlowCoordinator                         │ │
│  │  • Enqueue runs with frontmatter updates                   │ │
│  │  • Complete runs with checklist/history updates            │ │
│  │  • Parse result.json for flow-specific data                │ │
│  └────────────────────────────────────────────────────────────┘ │
└───────────────────────────┬─────────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────────┐
│                     AgentRunner (UI-facing)                      │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                   ProviderRegistry                           ││
│  │  • Registers CLI providers (Claude Code, future: Aider)     ││
│  │  • Checks availability (CLI path, version)                  ││
│  │  • Selects default provider for flows                       ││
│  └─────────────────────────────────────────────────────────────┘│
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                    AgentExecutors                            ││
│  │  • SimulatedAgentExecutor (testing/previews)                ││
│  │  • XPCAgentExecutor (XPC-based workers)                     ││
│  │  • ClaudeCodeExecutor (direct Claude Code CLI)              ││
│  │  • GenericCLIExecutor (provider-based)                      ││
│  │  • CLIPhaseExecutor (phase scaffolding)                     ││
│  └─────────────────────────────────────────────────────────────┘│
└───────────────────────────┬─────────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────────┐
│                      CLI Provider Layer                          │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                 AgentCLIProvider Protocol                    ││
│  │  • identifier, displayName                                  ││
│  │  • supportedFlows, capabilities                             ││
│  │  • locator: CLILocating                                     ││
│  │  • streamParser: StreamParsing                              ││
│  │  • buildArguments(), buildEnvironment()                     ││
│  └─────────────────────────────────────────────────────────────┘│
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                   ClaudeCodeProvider                         ││
│  │  • Locates claude CLI in common paths                       ││
│  │  • Parses stream-json output                                ││
│  │  • Supports: implement, review, research, plan              ││
│  └─────────────────────────────────────────────────────────────┘│
└───────────────────────────┬─────────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────────┐
│                       Prompt System                              │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                   PromptBuilder                              ││
│  │  • Loads templates (project → app → built-in fallback)      ││
│  │  • Resolves {{VARIABLE}} and {{#VAR}}...{{/VAR}} blocks     ││
│  │  • Combines system + role + flow templates                  ││
│  └─────────────────────────────────────────────────────────────┘│
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                   PromptContext                              ││
│  │  • Card info (title, code, summary, acceptance criteria)    ││
│  │  • Flow-specific (branch, reviewTarget, researchPrompt)     ││
│  │  • Project context (AGENTS.md, CLAUDE.md)                   ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
```

## Agent/Supervisor Flow

### Automatic Background Processing

```
BacklogWatcher (FSEvents)
    │
    ▼ Card appears in backlog folder
SupervisorCoordinator.handleNewCard()
    │
    ▼ Check eligibility (agent_status=idle, parallelizable, etc.)
FlowPipelineOrchestrator.suggestPipeline()
    │
    ▼ Select pipeline (e.g., implement-review)
AgentScheduler.enqueue()
    │
    ▼ Queue management, concurrency checks
AgentFlowCoordinator.enqueueRun()
    │
    ▼ Update card frontmatter (agent_status: running)
WorkerLauncher → GenericCLIExecutor
    │
    ▼ Run Claude Code CLI with prompt
AgentFlowCoordinator.completeRun()
    │
    ▼ Parse result.json, update checklist, add history
FlowPipelineOrchestrator.onFlowCompleted()
    │
    ▼ Continue to next flow or complete pipeline
```

### Flow Pipelines

| Pipeline | Flows | Use Case |
|----------|-------|----------|
| `implement-only` | implement | Simple changes |
| `implement-review` | implement → review | Standard workflow |
| `research-implement` | research → implement | Unknown territory |
| `full` | research → plan → implement → review | Complex features |

### Agent Roles

| Role | Flow | Description |
|------|------|-------------|
| Implementer | implement | Executes acceptance criteria, writes code, runs tests |
| Reviewer | review | Analyzes changes, provides feedback, identifies issues |
| Researcher | research | Gathers info, documents findings, explores codebase |
| Architect | plan | Designs solutions, breaks down tasks, creates plans |
| Supervisor | - | Coordinates flows, monitors progress (future) |

## Key Components

| Component | Location | Purpose |
|-----------|----------|---------|
| **SupervisorCoordinator** | `Supervisor/SupervisorCoordinator.swift` | Top-level orchestration, background activity |
| **AgentScheduler** | `Models/AgentScheduler.swift` | Queue, concurrency, locks, backoff |
| **AgentFlowCoordinator** | `Models/AgentFlowCoordinator.swift` | Card updates, run lifecycle |
| **FlowPipelineOrchestrator** | `Supervisor/FlowPipelineOrchestrator.swift` | Multi-step flow sequencing |
| **BacklogWatcher** | `Supervisor/BacklogWatcher.swift` | FSEvents monitoring of backlog folders |
| **ProviderRegistry** | `CLIProviders/ProviderRegistry.swift` | CLI provider discovery & selection |
| **GenericCLIExecutor** | `CLIProviders/GenericCLIExecutor.swift` | Runs any registered CLI provider |
| **PromptBuilder** | `Prompts/PromptBuilder.swift` | Template loading & variable resolution |

## Agent-driven Phase Creation

- Start from the app: **Add Phase (with Agent...)**. The agent scaffolds `phase-N-<label>` with standard status folders and writes a plan artifact at `backlog/N.0-phase-plan.md`.
- Plan artifact contents:
  - Frontmatter (owner/agent fields + `plan_version`, `plan_checksum`).
  - Human-readable sections: summary, acceptance criteria, notes, "Plan Tasks" with rationale and acceptance criteria per task.
  - Machine-readable JSON block of tasks (for future MCP/automation).
  - History entries stamped with run IDs.
- Manual edits are safe: update the markdown sections and JSON together; rerun validation to confirm structure.
- Creating cards from the plan:
  - Auto-create during the flow by toggling "Auto-create cards from plan".
  - If tasks remain, use "Create cards from plan" in the sheet after a run; duplicates are skipped.

## Feature Flags

| Flag | Effect |
|------|--------|
| `AGENCY_DISABLE_PLAN_FLOW=1` | Hide/disable the agent phase-creation flow |
| `AGENCY_ENABLE_PLAN_FLOW=1` | Explicitly enable (default when unset) |

## CLI Plan Scaffolding

See `docs/phase-scaffolding-cli.md` for arguments, exit codes, and examples of the underlying CLI used by the app.

## Siri & Shortcuts Integration

Agency supports Siri and the Shortcuts app for hands-free kanban management.

### Available Commands

| Command | Description | Example Phrase |
|---------|-------------|----------------|
| List Cards | Query cards, optionally by status or phase | "List cards in Agency" |
| Project Status | Get card counts by status | "Project status in Agency" |
| Move Card | Move a card to a new status | "Move card in Agency" |
| Create Card | Create a new backlog card | "Create card in Agency" |
| Open Card | Open a specific card in the app | "Open card in Agency" |

### Setup

The Siri entitlement is included. On first launch, Shortcuts should recognize Agency's intents automatically. You can also add them manually in the Shortcuts app.

### Spotlight Search

Cards are indexed in Spotlight when viewed. Search by card code (e.g., "1.3") or title keywords to find cards quickly.

## Claude Code Integration

Agency can run agent tasks using the Claude Code CLI for AI-powered card implementation.

### Prerequisites

1. **Install Claude Code CLI:**
   ```bash
   npm install -g @anthropic-ai/claude-code
   ```

2. **Configure in Agency:**
   - Open Agency Settings
   - The CLI will be auto-detected, or specify a custom path
   - Add your Anthropic API key (stored securely in macOS Keychain)

### Usage

- **From Card Detail:** Select "Claude Code" from the backend picker, then click Run
- **Quick Action:** Right-click any card on the board and select "Run with Claude Code"

The agent reads the card's acceptance criteria, implements the changes, runs tests, and updates the card. Cost and duration are displayed after completion.

## Directory Structure

```
Agency/
├── Models/
│   ├── AgentRunner.swift           # UI-facing run orchestration
│   ├── AgentScheduler.swift        # Queue and concurrency management
│   ├── AgentFlowCoordinator.swift  # Card lifecycle and updates
│   ├── CLIProviders/               # CLI provider abstraction
│   │   ├── AgentCLIProvider.swift  # Provider protocol
│   │   ├── ProviderRegistry.swift  # Provider discovery
│   │   ├── GenericCLIExecutor.swift
│   │   └── Providers/
│   │       └── ClaudeCodeProvider.swift
│   └── Prompts/                    # Prompt template system
│       ├── PromptBuilder.swift
│       ├── PromptContext.swift
│       ├── AgentRole.swift
│       └── DefaultPromptTemplates.swift
├── Supervisor/
│   ├── AgentSupervisor.swift       # Singleton supervisor API
│   ├── SupervisorCoordinator.swift # Background orchestration
│   ├── FlowPipelineOrchestrator.swift
│   ├── BacklogWatcher.swift        # FSEvents monitoring
│   ├── SupervisorStateStore.swift  # State persistence
│   └── WorkerLauncher.swift        # Process spawning
└── Worker/
    ├── AgentWorkerEntrypoint.swift
    └── AgentWorkerRuntime.swift
```

## Running Tests

```bash
xcodebuild -scheme Agency -destination 'platform=macOS' test
```
