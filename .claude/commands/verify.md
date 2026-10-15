---
description: Build, run all tests and report; use before saying a change is done
---
Run `swift build` then `swift test` in the repository root. Report pass/fail counts and show the first
failure verbatim if any. If UI files changed (`git diff --name-only -- Sources/Bezelight`), also run the
`ui-review` skill on the diff. Do not claim success without the command output.
