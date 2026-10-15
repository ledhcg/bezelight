---
paths:
  - "Tests/**/*.swift"
---
# Tests

- swift-testing only (`import Testing`, `@Test`, `#expect`). Names describe behaviour in plain English.
- No hardware, network or wall-clock sleeps longer than needed; use the injected clocks and transports in `Tests/*/AgentSupport.swift` and `TransportSupport.swift`.
- Fix a bug with a failing test first. Keep fuzz tests deterministic (seeded).
- Fixtures are sanitised: no prompts, commands, answers or personal paths.
