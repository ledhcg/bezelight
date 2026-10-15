---
paths:
  - "Sources/BezelightAgents/**"
  - "Sources/BezelightHook/**"
  - "Sources/BezelightCore/Agent*"
  - "Sources/BezelightCore/OpenCodeStreamClient.swift"
  - "Sources/BezelightCore/TranscriptWatcher.swift"
  - "Tests/Fixtures/**"
---
# Agent alerts: invariants

- `bezelight-hook` never writes to stderr, never exits non-zero, always prints `{}`, and stays fast
  (median target 15 ms). No new imports beyond Foundation and Darwin.
- The installer never rewrites a settings file it did not fully understand; it backs up first and keeps only the newest few backups.
- Treat every payload, file and socket message as hostile: bounded reads, defensive decoding, no force unwraps.
- A behaviour change starts with a recorded timeline in `Tests/Fixtures/timelines/*.jsonl`. Fixtures contain no prompts,
  commands, answers or personal paths.
- When an agent ships a new version, re-capture payloads and update the mapping tables in `docs/AGENT_NOTIFICATIONS.md`.
