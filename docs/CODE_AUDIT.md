# Code audit (2026-10-15)

Full read of `Sources/` against `docs/STYLE.md`. Every item was verified in code. The language policy holds:
no non-English prose outside `Localizable.strings`, `README.vi.md` and native language names. All five
`Localizable.strings` files have the same 372 keys.

## Fixed in this pass

| Item | Fix |
|---|---|
| `AgentRuntime.start()` could run twice (awaits between check and store) | `starting` claim taken under the lock |
| `bezelight-hook` could die of SIGPIPE on a closed stdout | `SIGPIPE` ignored, raw `write(2)` |
| `AgentHookServer` closed the socket fd before its dispatch source was cancelled | `close` moved into the cancel handler |
| `DeviceManager` wrote frames while the reconnect handshake was running | `handshaking` guard, identity cleared on connect |
| `OpenCodeStreamClient` line buffer grew without bound on a stream with no newline | line capped at `SSEParser.maxLine`; a whole event capped at `maxEvent` (oversized events are dropped up to their blank line) |
| Flaky `boundedInputReadsEverythingThenStops` test | writer captures plain fd values |

## Open: correctness (P2)

- `AgentRuntime.stop()` during an in-flight `start()` can leave the engine running; serialise toggles in `AgentsModel`.
- `ts` from a payload is not clamped: a far-future value freezes its session (`AgentEvent.swift`, `AgentTracker.swift`).
- `AgentTracker.trim()` never evicts `needsInput` sessions, and each opens a transcript watch (fd); cap both.
- `TranscriptWatcher` opens the path before checking it is a regular file (a FIFO blocks); use `O_NONBLOCK | O_NOFOLLOW`.
- `AgentTracker.updateSettings` drops sessions of a disabled agent without unwatching their transcripts.
- Hook stdin is cut at 1 MB; a huge `PermissionRequest` loses its alert. Extract the key fields from the prefix.
- `AgentDoctor.roundTrip()` busy-waits on a cooperative thread; use a termination handler.
- `SerialPort` uses its fd after releasing the lock; hold the lock for the syscall.

## Open: performance and UI (P2)

- `AppModel.pollOnce` publishes the preview 8 times a second even when unchanged; compare before assigning.
- `LedLayout` is rebuilt on every body pass and is not `Equatable`; store it on `AppModel`.
- `AgentsPanel` / `AgentEventEditor` observe the whole `AppModel`; pass `running` and a binding instead.
- `AgentsModel.eventLog` redraws every agent view; move it to its own observed object.
- `SoftSlider` reports a percentage to VoiceOver for non-percent values; pass `ValueSlider.format(value)`.
- `Picker("")` and `ColorPicker("")` have no accessibility label (`MenuBarView.swift`, `EffectCards.swift`).

## Open: cleanup (P3)

- Per-frame allocations: black frame while off, `flatMap` in `EffectEngine`, `bandEnv` copy, `SerialPort.read` buffer.
- Selected swatch ring is invisible in light mode (`MainView.swift`); make it `.primary`, add `.isSelected`.
- Joined strings instead of format keys (`MainView.swift`, `SettingsView.swift`, `AgentsView.swift`).
- English error text reaches the UI (`CaptureError`, `SerialError`); map to `tr` keys, store `errno`.
- Session-state symbol/tint mapping exists four times; add one `SessionState` extension.
- Duplicated helpers: layout test pattern (app and probe), nearest-index resampling, duration conversion, `isUnreadable`, `swiftUIColor`.
- Menu bar status drops the "reconnecting" state; share one status dot with `StatusPill`.
- Dead code: `MockAudioSampler`, `EffectEngine.lastFrame`, `DeviceManager.availablePorts`/`setBrightness`, `LightPipeline.isPowered`.
- Collapsible agent sections do not match `Card` styling and are mis-indented; `AgentSetupRow` mutates a shared formatter in `body`.
- Stale names/comments: `skydimo.capture.*` queue labels, `LedLayout`, `EffectCards`, `AudioSampler` docs.
- `bezelight-probe`: `identify` skips the DTR reset; negative segment sizes crash.
- Backups: names sort as strings (`-10` before `-2`), `backupPrefix` can collide or exceed 255 bytes; fsync the deployed helper.
- `@unchecked Sendable` types without a comment naming their lock or queue (`HookInstaller` needs none).
