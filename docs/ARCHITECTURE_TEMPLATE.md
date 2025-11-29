# ARCHITECTURE.md Template (Version 1)

Use this structure when authoring or regenerating architecture docs from the Phase 7 bootstrap tooling. The generator fills each section, and validators expect these headings to stay intact.

```
---
architecture_version: 1
roadmap_fingerprint: <sha256-of-roadmap-json>
generated_at: <YYYY-MM-DD>
project_goal: <one-line goal>
---

# ARCHITECTURE.md

Summary:
<project goal or short vision>

Goals & Constraints:
- Target platforms: <macOS, iOS, web, ...>
- Languages: <Swift, Rust, ...>
- Tech stack: <SwiftUI, XPC, ...>
- Roadmap alignment: <N> phase(s); fingerprint <first-12-chars>

System Overview:
- One to three bullets that describe the system shape and delivery approach.

Components:
- Phase <n> — <label> (<status>)
  - Tasks:
    - [ ] <code> <title> — <summary>

Data & Storage:
- Notes on persistence, sandbox constraints, backups, and retention.

Integrations:
- External services, frameworks, or SDKs the roadmap depends on.

Testing & Observability:
- Test strategy (unit/UI), logging/metrics, and health signals to keep the architecture trustworthy.

Risks & Mitigations:
- Known risks plus how they are mitigated.

Architecture (machine readable):
```json
{ ... architecture document payload ... }
```

Manual Notes:
Preserved across regenerations; use for hand-authored details.

History:
- <YYYY-MM-DD>: Architecture generated from roadmap.
```

Regeneration Guardrails
- Keep `architecture_version` and `roadmap_fingerprint` in the frontmatter for validation.
- Preserve the `Architecture (machine readable)` JSON block; validators compare its fingerprint to ROADMAP.md.
- Manual Notes and History are retained on regeneration so manual annotations survive.
