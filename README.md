# Agency

Agent-assisted kanban for macOS, powered by Markdown cards under `project/phase-*` folders.

## Agent-driven phase creation (Phase 6)
- Start from the app: **Add Phase (with Agent…)**. The agent scaffolds `phase-N-<label>` with standard status folders and writes a plan artifact at `backlog/N.0-phase-plan.md`.
- Plan artifact contents:
  - Frontmatter (owner/agent fields + `plan_version`, `plan_checksum`).
  - Human-readable sections: summary, acceptance criteria, notes, “Plan Tasks” with rationale and acceptance criteria per task.
  - Machine-readable JSON block of tasks (for future MCP/automation).
  - History entries stamped with run IDs.
- Manual edits are safe: update the markdown sections and JSON together; rerun validation to confirm structure.
- Creating cards from the plan:
  - Auto-create during the flow by toggling “Auto-create cards from plan”.
  - If tasks remain, use “Create cards from plan” in the sheet after a run; duplicates are skipped.

## Feature flag / guardrail
- Set `AGENCY_DISABLE_PLAN_FLOW=1` to hide/disable the agent phase-creation flow (UI and controller).
- Optional opt-in guard: `AGENCY_ENABLE_PLAN_FLOW=1` (defaults to enabled when unset).

## CLI plan scaffolding
- See `docs/phase-scaffolding-cli.md` for arguments, exit codes, and examples of the underlying CLI used by the app.

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

## Running tests
```
xcodebuild -scheme Agency -destination 'platform=macOS' test
```
