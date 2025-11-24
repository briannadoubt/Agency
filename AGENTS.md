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
- Backlog sequencing: work the lowest-numbered card in `project/**/backlog/`; if already in `in-progress/`, finish it first.
- When a backlog path is provided, resolve from repo root and ensure it still lives under `project/**/backlog/` or abort.
- Standard lane: `git checkout main && git pull --ff-only origin main` → `git checkout -b implement/<slug>` → `git mv` card to `in-progress/` and set status → build/implement/tests → `git commit -m "Implement <slug>"` → run tests → pause for review → move card to `done/`, update status/history, `git commit -m "Complete <slug>"`; run `git status` before finishing.

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
