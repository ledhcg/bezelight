# Style guide

One place for how Bezelight code, UI and text should look, so contributions feel like one project.

## Language

All code, comments, docs, commit messages and PR text are English. Other languages live only in
`Sources/BezelightCore/Resources/<lang>.lproj/Localizable.strings`, `README.vi.md` and the native language
names in `Localizer.swift`. Write plain, direct sentences; say what a thing does and why, not how clever it is.

## Swift

- Follow the surrounding file first. Four-space indent, no trailing whitespace, lines up to about 140 columns.
- Types `UpperCamelCase`, everything else `lowerCamelCase`; booleans read as assertions (`isRunning`, `hasPending`).
- Prefer `struct`/`enum` and value semantics. Use `final class` only for identity, shared mutable state or `ObservableObject`.
- Mark cross-thread types `Sendable` honestly. Do not silence the compiler with `@unchecked Sendable` without a comment
  explaining the lock or queue that makes it safe.
- No `try!`, `!` or `fatalError` on external input (files, sockets, serial, JSON, hook payloads). Decode defensively and fall back.
- Access control: `internal` by default inside the app target; `public` only for what other targets use.
- Comments explain intent, constraints and measured numbers. Do not restate the code. Doc comments (`///`) on public API.
- No dead code, no commented-out code, no TODO without an issue number.
- Foundation-only targets (`BezelightAgents`, `BezelightHook`) must not import AppKit, SwiftUI or ScreenCaptureKit.

## Errors and logging

- Recoverable problems degrade quietly and show a status line in the UI; they never crash and never block the main thread.
- The hook helper is silent: no stderr, always exit 0, always print `{}`.
- Diagnostics go through `FrameLog` / the Diagnostics panel, not `print`.

## Performance

- Capture, sampling and output run off the main thread; UI state updates are coalesced.
- Keep live values (preview colors, levels, session lists) in small observed objects so one update does not redraw a window.
- Measure before optimising, and record the number in the comment or the docs.

## UI

- Build from the shared pieces in `Sources/Bezelight/Surfaces.swift`: `surface`, `capsuleSurface`, `Card`, `SoftSlider`,
  `ValueSlider`, `PrimaryActionStyle`, `StageBackdrop`. Do not use system sliders or raw `.background(.black)` plates.
- Typography: system fonts only, by role (`.headline` titles, `.callout` body, `.caption` hints). No fixed point sizes
  unless drawing a custom control.
- Spacing scale: 4, 8, 12, 14, 22 (card corner radius 14 to 22). Use 8 between related controls, 12 to 14 between groups.
- Color comes from the system palette or the user's tint. Never hard-code black or white for text; use `.primary`,
  `.secondary`. Hint text must stay readable over glass (not `.tertiary` on pastel).
- Follow the system appearance. Check light and dark, and macOS 14/15 fallbacks, before opening a pull request.
- Every icon-only control has an accessibility label; state is never conveyed by color alone.
- Do not wrap scrolled surfaces in a clipping container: their highlight and shadow extend past the frame.

## Localisation

- Keys are dotted, lowercase-first: `area.name` (`action.start`, `hint.mode.screen`, `status.stopped`).
- Never concatenate translated fragments; use one key with `%d` / `%@` placeholders, identical in every language.
- Add a key to all five files in the same commit. `swift test` verifies coverage and placeholders.
- UI text: sentence case, no trailing period on labels, imperative verbs on buttons.

## Tests

- swift-testing: `@Test func theBehaviourInPlainWords()`. Names describe behaviour, not the function under test.
- Pipelines run end to end without hardware. Use fixtures from `Tests/Fixtures`; sanitise anything captured from a real agent.
- Fix a bug with a failing test first.

## Git and pull requests

- Conventional commits: `feat(scope):`, `fix(scope):`, `perf(scope):`, `docs:`, `test:`, `refactor:`, `chore:`.
  Scopes seen here: `agents`, `ui`, `core`, `hook`, `i18n`, `build`.
- One focused change per commit; the subject is imperative and under 72 characters.
- A PR says what changed and why, how it was verified (`swift test`, screenshots for UI in light and dark), and
  mentions the hardware used for device changes.
