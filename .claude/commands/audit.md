---
description: Audit the code against docs/STYLE.md and the invariants in CLAUDE.md
argument-hint: [path or module, default whole repo]
---
Audit $ARGUMENTS (default: whole repo) read-only. Check: language policy (non-English prose outside
Localizable.strings and README.vi.md), force unwraps on external input, per-frame allocations on hot paths,
Sendable honesty, hook helper invariants, hard-coded user-facing strings, hard-coded colors, missing
accessibility labels, dead code, stale comments. Verify each finding in code, then list P1/P2/P3 with
`file:line`, the defect and the fix. Do not edit files unless asked.
