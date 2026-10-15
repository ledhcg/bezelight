# Contributing

Thanks for helping. The project is small on purpose: please keep changes focused.

## Build and test

```bash
swift build
swift test                      # unit + pipeline tests, no hardware needed
scripts/build-app.sh            # produces dist/Bezelight.app
swift run bezelight-probe       # lists serial ports; add <port> to stream a test pattern
```

## Layout

| Path | Purpose |
|---|---|
| `Sources/BezelightAgents` | Foundation-only: agent events, hook normalisers, wire format, safe settings-file editing |
| `Sources/BezelightHook` | `bezelight-hook`, the helper Claude Code and Codex run (keep it tiny and fast) |
| `Sources/BezelightCore` | Everything except UI: capture, sampling, color pipeline, serial, localisation, agent alerts |
| `Sources/Bezelight` | SwiftUI app (Liquid Glass views, menu bar, settings) |
| `Sources/BezelightProbe` | Command-line controller test tool |
| `Tests/BezelightCoreTests` | Tests; the pipeline tests run end to end without a serial port |
| `Tests/BezelightAgentsTests` | Tests for the agent layer, including fuzzing |
| `Resources/Icon` | Master artwork for the app icon (`scripts/make-icon.swift` renders the `.icns`) |
| `Tests/Fixtures` | Real payloads captured from agents (`agents/`), recorded sessions (`timelines/`), config files (`configs/`) |

## Translations

Strings are `Sources/BezelightCore/Resources/<lang>.lproj/Localizable.strings`. To fix a wording,
edit that file. To add a language:

1. Copy `en.lproj` to `<code>.lproj` and translate the right-hand sides. Keep `%d` / `%@` placeholders.
2. Add the language to `AppLanguage` in `Localizer.swift` and `CFBundleLocalizations` in `Resources/Info.plist`.
3. `swift test` fails if a key is missing or a placeholder differs.

## Adding an effect

1. Add a case to `LightMode` (raw value is persisted: choose it carefully) and, if it has settings, fields to `EffectParams`
   (decode them with a default so old settings files still load).
2. Generate frames in `EffectEngine.animate`. Keep per-frame work allocation-light and independent of the frame rate (use `dt`).
3. Add its card to `AnimationCard`, its strings to every `Localizable.strings` file and a test next to the others.
4. Do not copy code from other projects whose licence is not MIT-compatible; implement the behaviour yourself.

## Adding a device

Add a `DevicePreset` to `DeviceCatalog.presets` with the LED count of each side in wiring order
(see `docs/PROTOCOL.md`). Verify with `bezelight-probe` and mention the product in your pull request.

## Guidelines

- No third-party dependencies. The app should stay a few hundred KB.
- Anything on the hot path (capture callback, sampling, output) must not allocate per frame without a reason.
- UI code must keep live values in small observed objects so a preview update does not redraw the whole window.
- Run `swift test` before opening a pull request.

## UI notes

- Translucent surfaces only look translucent over a lit, coloured backdrop. Never put them on near-black:
  they turn into flat grey plates with a black outline. `StageBackdrop` lifts every tint into a safe
  brightness band for the current appearance; keep going through it.
- Follow the system appearance. Check both light and dark before opening a pull request.
- Do not wrap scrolled surfaces in a clipping container: their edge highlight and shadow extend past
  their frame (see `rightColumn` in `MainView.swift`).
- Prefer the shared pieces in `Surfaces.swift` (`surface`, `Card`, `SoftSlider`, `PrimaryActionStyle`)
  over system sliders/buttons, whose dark tracks and saturated fills look harsh on a surface.

## Agent alerts

See [docs/AGENT_NOTIFICATIONS.md](docs/AGENT_NOTIFICATIONS.md) (design, event normalisation, measured behaviour)
and [docs/AGENT_NOTIFICATIONS_PLAN.md](docs/AGENT_NOTIFICATIONS_PLAN.md) (architecture decisions).

- **Behaviour changes need a recording.** `Tests/Fixtures/timelines/*.jsonl` replays real sessions through
  the tracker; add a timeline (and the sanitised payloads it uses under `Tests/Fixtures/agents`) before changing
  a rule. Fixtures must contain no prompts, commands, answers or personal paths.
- **When an agent releases a new version**, re-capture its payloads, run the replay tests and update the
  mapping tables in the design document if event names changed.
- `scripts/soak.sh [seconds]` runs the soak test for as long as you like.
- Never make the hook helper write to stderr or exit non-zero; never let the installer rewrite a file it did
  not understand. Both are covered by tests that must keep passing.

## Language and style

Code, comments, docs, commits and pull requests are written in English. Only `Localizable.strings`, `README.vi.md`
and native language names contain other languages. The full guide (Swift, UI, localisation, tests, commits) is
[docs/STYLE.md](docs/STYLE.md).

## Working with Claude Code

The repository ships a ready-made setup: `CLAUDE.md` (project rules), `.claude/rules/` (path-scoped rules),
`.claude/skills/` (`add-effect`, `add-language`, `add-device`, `ui-review`, `release-check`) and
`.claude/commands/` (`/verify`, `/audit`). Personal overrides go in `.claude/settings.local.json` or
`CLAUDE.local.md`, both git-ignored. AI-assisted changes are held to the same standard as any other: they must
build, pass `swift test` and follow `docs/STYLE.md`.
