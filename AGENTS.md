# Repository Guidelines

## Project Structure & Module Organization
- SwiftUI app: `Agency/` with `AgencyApp.swift` and root `ContentView.swift`.
- Assets: `Agency/Assets.xcassets`.
- Tests: unit in `AgencyTests/AgencyTests.swift`; UI in `AgencyUITests/`.
- Project file: `Agency.xcodeproj`.
- Planning: Markdown cards in `project/phase-*/{backlog,in-progress,done}/`; follow `PROJECT_WORKFLOW.md`. XPC design: `project/XPC_ARCHITECTURE.md` (Phase 5).
- Source code inside of the `Agency/` folder is referenced by said `Agency/` directory so the filesystem is synced with Xcode and Xcode doesn't need to understand membership of each and every file.

## Task Execution Workflow (agent default)
- Open `PROJECT_WORKFLOW.md` before acting; required step list.
- Backlog sequencing is numeric: always work on the card whose filename in `project/**/backlog/` has the lowest leading numeral. If that card is already in `in-progress/`, finish it (move to `done/`) before selecting the next numeral. See `project/phase-1-core-shared-layer/README.md` for per-phase reminders.
- When given a backlog file path as the first message of a conversation, resolve it relative to the repo root, ensure it still lives under `project/**/backlog/`, and abort if it moved elsewhere.
    - Create a branch named `implement/<kebab-slug>` (kebab slug = filename without extension, lowercased, non-alphanumeric collapsed to `-`).
    - Run the standard lane progression for that card:
      1. `git checkout main && git pull --ff-only origin main`.
      2. `git checkout -b implement/<slug>`.
      3. `git mv` the card to the sibling `in-progress/` directory and change its Status to “In Progress.” Capture checklist notes locally so acceptance criteria stay visible.
      4. Implement the requirements in the appropriate module(s), respecting the downhill dependency flow called out above. Check off the working notes as the work is completed.
      5. Add/adjust Swift Testing test suites (unit + `Tests/NumenIntegrationTests` when behavior crosses module boundaries).
      6. Build frequently via `make ACTION=build TARGET=Numen`.
      7. Stage all related files (code, docs, backlog card) and commit `Implement <slug>`.
      8. Run `make ACTION=test` (or backlog-specified tests) and fix failures, amending the prior commit if necessary.
      9. Stop here and ask the user to review the work before moving anything to done.
      10. Move the backlog file to `done/`, update its Status to “Done/Complete,” check off the working notes, and commit `Complete <slug>`.
    - Always `git status` before finishing to confirm no extra files are touched. Pushing/PRs happen outside the automation.

## Toolchain & Platforms
- Swift 6.2; Xcode 26; macOS 26 host.
- Target OS: macOS 26.
- Swift Concurrency DO NOT USE DISPATCHQUEUES

## Build, Test, and Development Commands
- Open: `open Agency.xcodeproj` (scheme `Agency`).
- Build: `xcodebuild -scheme Agency -destination 'platform=macOS' build`.
- Tests: `xcodebuild -scheme Agency -destination 'platform=macOS' test` (OS 26 simulator).

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
