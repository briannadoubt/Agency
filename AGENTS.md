# Repository Guidelines

## Project Structure & Module Organization
- SwiftUI app: `Agency/` with `AgencyApp.swift` and root `ContentView.swift`.
- Assets: `Agency/Assets.xcassets`.
- Tests: unit in `AgencyTests/`; UI in `AgencyUITests/`.
- Project file: `Agency.xcodeproj`.
- Planning: Markdown cards in `project/phase-*/{backlog,in-progress,done}/`; follow `PROJECT_WORKFLOW.md`.
- Source code inside of the `Agency/` folder is referenced by said `Agency/` directory so the filesystem is synced with Xcode and Xcode doesn't need to understand membership of each and every file.

## Agent System Architecture

### Supervisor Layer (`Agency/Supervisor/`)
- **AgentSupervisor**: Singleton exposing supervisor API to SwiftUI app, wraps SupervisorCoordinator
- **SupervisorCoordinator**: Top-level orchestration with NSBackgroundActivityScheduler for persistent background operation
- **AgentScheduler**: Queue management (soft/hard limits), concurrency control (per-flow limits), card locking, backoff/retry
- **AgentFlowCoordinator**: Card lifecycle updates, frontmatter/history management, result parsing
- **FlowPipelineOrchestrator**: Multi-step flow sequencing with pipeline definitions
- **BacklogWatcher**: FSEvents monitoring of backlog folders for automatic card processing
- **SupervisorStateStore**: State persistence for crash recovery
- **WorkerLauncher**: Process spawning for CLI executors

### CLI Provider Layer (`Agency/Models/CLIProviders/`)
- **AgentCLIProvider**: Protocol defining CLI tool integration (locator, streamParser, buildArguments, buildEnvironment)
- **ProviderRegistry**: Singleton for provider discovery, registration, and selection
- **GenericCLIExecutor**: Runs any registered provider with streaming output parsing
- **CLILocating**: Protocol for CLI binary discovery with common path scanning
- **StreamParsing**: Protocol for parsing CLI output streams into unified message types
- **ClaudeCodeProvider**: Claude Code CLI implementation with ClaudeStreamParserAdapter

### Prompt System (`Agency/Models/Prompts/`)
- **PromptBuilder**: Template loading with project → app → built-in fallback chain, variable resolution
- **PromptContext**: All variables for prompt generation (card, flow, project context)
- **AgentRole**: Enum defining roles (implementer, reviewer, researcher, architect, supervisor)
- **DefaultPromptTemplates**: Built-in templates for system, roles, and flows
- **PromptTemplateLoader**: Loads templates from project `.agency/prompts/`, app bundle, or defaults

### Agent Flows & Pipelines

| Flow | Role | Description |
|------|------|-------------|
| `implement` | Implementer | Execute acceptance criteria, write code, run tests |
| `review` | Reviewer | Analyze changes, provide feedback, identify issues |
| `research` | Researcher | Gather info, document findings, explore codebase |
| `plan` | Architect | Design solutions, break down tasks, create plans |

| Pipeline | Flows | Use Case |
|----------|-------|----------|
| `implement-only` | implement | Simple changes |
| `implement-review` | implement → review | Standard workflow |
| `research-implement` | research → implement | Unknown territory |
| `full` | research → plan → implement → review | Complex features |

### Automatic Processing Flow
```
BacklogWatcher (FSEvents) → SupervisorCoordinator.handleNewCard()
    → FlowPipelineOrchestrator.suggestPipeline()
    → AgentScheduler.enqueue()
    → AgentFlowCoordinator.enqueueRun() [update frontmatter]
    → GenericCLIExecutor → Claude Code CLI
    → AgentFlowCoordinator.completeRun() [update checklist/history]
    → FlowPipelineOrchestrator.onFlowCompleted() [next flow or complete]
```

## Review Instructions
Always check the name of the branch and find the corresponding task file and make sure that all the acceptance criteria is completed.

## Task Execution Workflow (agent default)
- Open `PROJECT_WORKFLOW.md` before acting; required step list.
- Backlog sequencing is numeric: always work on the card whose filename in `project/**/backlog/` has the lowest leading numeral. If that card is already in `in-progress/`, finish it (move to `done/`) before selecting the next numeral.
- When given a backlog file path as the first message of a conversation, resolve it relative to the repo root, ensure it still lives under `project/**/backlog/`, and abort if it moved elsewhere.
    - Create a branch named `implement/<kebab-slug>` (kebab slug = filename without extension, lowercased, non-alphanumeric collapsed to `-`).
    - Run the standard lane progression for that card:
      1. `git checkout main && git pull --ff-only origin main`.
      2. `git checkout -b implement/<slug>`.
      3. `git mv` the card to the sibling `in-progress/` directory and change its Status to "In Progress." Capture checklist notes locally so acceptance criteria stay visible.
      4. Implement the requirements in the appropriate module(s), respecting the downhill dependency flow called out above. Check off the working notes as the work is completed.
      5. Add/adjust Swift Testing test suites.
      6. Build frequently via `xcodebuild -scheme Agency -destination 'platform=macOS' build`.
      7. Stage all related files (code, docs, backlog card) and commit `Implement <slug>`.
      8. Run `xcodebuild -scheme Agency -destination 'platform=macOS' test` and fix failures, amending the prior commit if necessary.
      9. Stop here and ask the user to review the work before moving anything to done.
      10. Move the backlog file to `done/`, update its Status to "Done/Complete," check off the working notes, and commit `Complete <slug>`.
    - Always `git status` before finishing to confirm no extra files are touched. Pushing/PRs happen outside the automation.

## Toolchain & Platforms
- Swift 6.2; Xcode 26; macOS 26 host.
- Target OS: macOS 26.
- Swift Concurrency DO NOT USE DISPATCHQUEUES

## Build, Test, and Development Commands
- Open: `open Agency.xcodeproj` (scheme `Agency`).
- Build: `xcodebuild -scheme Agency -destination 'platform=macOS' build`.
- Tests: `xcodebuild -scheme Agency -destination 'platform=macOS' test`.

## Coding Style & Naming Conventions
- Prefer small composable SwiftUI views.
- Format with Xcode (Cmd+I); 4-space indent; no trailing whitespace.
- Naming: types PascalCase; vars/functions lowerCamelCase; views end with `View`; tests mirror subject (`ContentViewTests`).
- Assets: lowerCamelCase catalog names; avoid spaces.
- Concurrency: prefer Swift Concurrency (async/await, actors); avoid XPC unless required—XPC + async is fragile.
- Use `@Observable` macro and async streams from Observation and Swift Concurrency; don't use Combine unless there isn't any way around it.

## Testing Guidelines
- Unit tests live in `AgencyTests/`; name methods `test<Behavior>` and use `#expect`.
- UI tests extend `AgencyUITests` with scenario-focused methods; keep `continueAfterFailure = false`.
- Add regression tests with fixes; aim for one test file per feature.
- Run `xcodebuild … test` before PR or card completion.

## Commit & Pull Request Guidelines
- Commits: imperative, present tense; Conventional prefixes (`feat:`, `fix:`, `chore:`) welcome.
- Keep commits scoped (code + tests + card edits together); avoid mixing refactors with features.
- PRs: describe scope, link card code, list test commands, add UI screenshots, call out risks or follow-ups.

## Security & Configuration Notes
- Never commit secrets, personal simulator data, or `DerivedData`; share schemes in `Agency.xcodeproj/xcshareddata`.
- Update card `History` (YYYY-MM-DD) for task file edits; keep status aligned with folder location.

## AppIntents Integration
- All intents live in `Agency/AppIntents/`.
- `AgencyShortcuts` provides App Shortcuts for Siri and the Shortcuts app.
- Use `@MainActor` for all intent `perform()` methods that access ProjectLoader.
- `AppIntentsProjectAccess.shared` bridges intents to the running app's state.
- `CardEntity` is the AppEntity for cards; `CardStatusAppEnum` for status filtering.
- Entitlements: `com.apple.developer.siri` enabled in `Agency.entitlements`.
- Available intents: ListCardsIntent, ProjectStatusIntent, MoveCardIntent, CreateCardIntent, OpenCardIntent.

## Claude Code CLI Integration
Agency integrates with the Claude Code CLI (`claude`) to run AI-powered agent tasks directly from the card detail view.

### Components
- **ClaudeCodeLocator**: Discovers the `claude` CLI binary via user override, PATH, or common install locations (`/usr/local/bin/claude`, `/opt/homebrew/bin/claude`, `~/.local/bin/claude`).
- **ClaudeKeyManager**: Stores the Anthropic API key in macOS Keychain under service `com.briannadoubt.Agency.anthropic-api-key`.
- **ClaudeCodeSettings**: Observable settings for CLI path override and availability status.
- **ClaudeCodeExecutor**: Implements `AgentExecutor` protocol, spawns the CLI with `--output-format stream-json`.
- **ClaudeStreamParser**: Parses newline-delimited JSON stream into `ClaudeStreamMessage` types and maps to `WorkerLogEvent`.
- **ClaudeCodeProvider**: Implements `AgentCLIProvider` for use with `GenericCLIExecutor` and `ProviderRegistry`.

### Configuration
1. Install Claude Code CLI: `npm install -g @anthropic-ai/claude-code`
2. In Agency Settings, the CLI will be auto-detected or you can specify a custom path.
3. Add your Anthropic API key in Settings. The key is stored securely in Keychain.

### Usage
- Select "Claude Code" from the backend picker in the card detail view.
- Right-click any card on the Kanban board and select "Run with Claude Code" for quick execution.
- Real-time streaming output appears in the agent panel.
- Cost is displayed in the result summary after completion.

### CLI Arguments
The executor runs: `claude -p <prompt> --output-format stream-json --allowedTools Bash,Read,Write,Edit,Glob,Grep --max-turns 50`
