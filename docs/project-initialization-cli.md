# Project Initialization CLI (bootstrap flow)

Initialize a repository from a roadmap, creating the `project/` tree and status folders for each phase. The command defaults to **dry-run** so you can preview changes before writing.

## Usage
```
project-init --project-root <path> [--roadmap <path>] [--goal "<text>"] [--yes|--apply|--dry-run]
```

Required:
- `--project-root <path>`: repository root where `project/` and `ROADMAP.md` should live.

Options:
- `--roadmap <path>`             Use a roadmap file from another location (copies to `<project-root>/ROADMAP.md` if missing).
- `--goal "<text>"`              Generate `ROADMAP.md` with the existing roadmap generator when no file is present.
- `--yes` / `--apply`            Apply changes (create folders/files). Without this, the command previews only.
- `--dry-run`                    Force preview mode even if `--yes` is supplied.

## Behavior
- Reads (or generates) `ROADMAP.md` and creates `project/phase-<n>-<label>/{backlog,in-progress,done}` with `.gitkeep` files.
- Works in-place on non-empty directories without overwriting existing files; conflicts surface as warnings.
- Supports bootstrapping a brand-new directory when paired with `--roadmap` and `--yes`.
- Emits human-readable logs plus a JSON result (created/ skipped paths, warnings, dry-run flag) on stdout.
- Exit codes: `0` success, `3` missing `--project-root`, `4` missing roadmap, `5` invalid roadmap, `6` empty roadmap, `7` roadmap generation failed, `1` unexpected error.

## Examples
Preview initialization for an existing repo:
```
project-init --project-root /repo
```

Create a new project folder from a template roadmap:
```
project-init --project-root /repo-new --roadmap /templates/ROADMAP.md --yes
```
