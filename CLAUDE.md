# Bezelight

Native macOS app (Swift 5.9, SwiftPM, macOS 14+) that drives USB LED strips behind a display from the
screen, system audio or effects, and lights them when AI coding agents (Claude Code, Codex, OpenCode)
need attention. Open source (MIT), no third-party dependencies.

## Language policy

**Everything is English**: code, identifiers, comments, commit messages, docs, issues, PR text, test names.
Vietnamese, Chinese, Japanese and Korean appear only in `Localizable.strings`, `README.vi.md` and the
language names in `Localizer.swift`. Reply to maintainers in the language they write in, but never put
non-English prose in the repository outside those places.

## Commands

```bash
swift build                    # debug build
swift test                     # 100+ tests, no hardware needed (includes fuzz and a short soak)
scripts/build-app.sh           # dist/Bezelight.app (ARCHS="arm64" for a fast single-arch build)
swift run bezelight-probe      # list serial ports / stream a test pattern
```

Run `swift build` and `swift test` before declaring a change done. UI changes: also check light and dark.

## Layout

- `Sources/BezelightAgents`: Foundation-only agent layer (events, normalisers, wire format, safe settings editing).
- `Sources/BezelightHook`: `bezelight-hook` helper that agents run. Tiny and fast.
- `Sources/BezelightCore`: everything except UI (capture, sampling, pipeline, serial, localisation, agent alerts).
- `Sources/Bezelight`: SwiftUI app. `Surfaces.swift` holds the shared look.
- `Tests/`: swift-testing (`@Test`, `#expect`). `Tests/Fixtures` holds sanitised real payloads and recordings.
- `docs/`: design docs. `docs/STYLE.md` is the style guide; read it before UI or API work.
- `Resources/Icon/bezelight-mark.png`: master artwork for the app icon (`scripts/make-icon.swift`).

## Rules that must not break

- No third-party dependencies. The app stays a few hundred KB.
- The hook helper never writes to stderr and never exits non-zero. The installer never rewrites a file it
  did not understand. Both are enforced by tests.
- Hot paths (capture callback, sampling, output) do not allocate per frame without a reason.
- Every user-facing string goes through `tr("key")` and exists in all five `Localizable.strings` files
  (`LocalizationCoverageTests` fails otherwise).
- Persisted raw values (`LightMode`, settings keys) never change; new fields decode with a default.
- Behaviour changes to agent rules need a recorded timeline fixture first. Fixtures hold no prompts,
  commands or personal paths.

## More detail (loaded on demand)

Path-scoped rules live in `.claude/rules/`; repeatable workflows in `.claude/skills/`
(`add-effect`, `add-language`, `add-device`, `ui-review`, `release-check`) and `.claude/commands/`
(`/verify`, `/audit`). Style guide: @docs/STYLE.md
