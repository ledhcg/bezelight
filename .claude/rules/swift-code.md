---
paths:
  - "Sources/**/*.swift"
  - "Tests/**/*.swift"
  - "scripts/*.swift"
---
# Swift code

Follow `docs/STYLE.md`. In short:

- English only in identifiers, comments and test names.
- No third-party dependencies. No `try!` / `!` / `fatalError` on external input.
- `BezelightAgents` and `BezelightHook` import Foundation and Darwin only.
- Cross-thread types are honestly `Sendable`; any `@unchecked Sendable` carries a comment naming the lock or queue.
- Comments state intent, constraints, measured numbers. No dead or commented-out code.
- Keep persisted raw values stable; decode new fields with defaults.
- Match the surrounding file's density and idiom before introducing a new pattern.
