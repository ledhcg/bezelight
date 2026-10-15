# Implementation Plan: Agent notifications on the light strip (production-ready)

> Companion document: [`AGENT_NOTIFICATIONS.md`](AGENT_NOTIFICATIONS.md) (analysis, event normalization, configuration, Phase 0 results).
> This document is the **execution plan**: locked architecture, work breakdown, code interfaces, acceptance criteria, testing, release.
> Scope: Claude Code, Codex, OpenCode · Platform: macOS 14+ · Target version: **0.3.0**

---

## Progress

| Milestone | Status | Notes |
|---|---|---|
| M0 Foundation | **Done** | `BezelightAgents`, `BezelightHook` (safe stub), `BezelightAgentsTests`; replay harness; 12 real timelines |
| M1 Model, normalizer, tracker | **Done** | `AgentEvent`/`Wire`, 3 normalizers, `AgentAlertSettings`/`Sanitize`, `AgentTracker`, `AgentCenter` |
| M2 Overlay and pipeline | **Done** | `AgentOverlay`, `FrameCrossfade`, `FlashLimiter`, `OverlayStore`; `LightPipeline` integration (lights off, brightness floor, restoring the original mode) |
| M3 Transport and event sources | **Done** | Real helper, `AgentHookServer`, `OpenCodeStreamClient`, `TranscriptWatcher`, `SystemPresence`, `AgentRuntime`; M3.6 verified with real Claude and Codex |
| M4 Installer | **Done** | `JSONText` (byte-position edits), `HookConfigEditor`, `HookInstaller` (lock, atomic write, rotating backups, symlinks, concurrent edits), `HelperDeployer`, `AgentDoctor` |
| M5 App and UI | **Done** | `AgentsModel`, Agent alerts options live in the right column of Agents mode (every option has a description), preview on the LED strip, menu bar changes shape, hotkey ⌃⌥⇧F11, 199 strings × 5 languages |
| M6 Quality | **Done** (except manual QA, 24 h soak) | Fuzz, soak test (`scripts/soak.sh`), speed measurements, hook command run through a real shell |
| M7 Release | **Done** (not yet verifiable: the GitHub release workflow) | `build-app.sh` bundles and signs the helper, CI, `release.yml` (conditional signing + notarization), README en/vi, CHANGELOG 0.3.0 |

**M0–M1 results (2026-10-14):** 120 tests green (20 in `BezelightAgentsTests`, 100 in `BezelightCoreTests`); release build green; the 155 KB helper links only Foundation. Mutation check done: breaking the rule that holds `done` while a subagent is still running made timeline 04 fail on exactly the expected line.

**Measurements (2026-10-14, Apple Silicon dev machine, release build):**
- S2: `bezelight-hook` median **5.1 ms**, p99 9–15 ms (targets 15 / 40 ms), size 443 KB, links only Foundation.
- S10 (scaled down): 90 s soak, 60 sessions × 3 agents, **30,504 events**, all invariants hold, FD 14 → 13, memory stable at 36 MB. The 24-hour soak has not been run: `scripts/soak.sh 86400`.
- Tests: **202 + 96** runnable (previously 39 declared), stable across 5 consecutive runs.
- Verified on copies of the machine's 4 real config files (including the Orca hook): install → uninstall restores every byte exactly.

**Not possible in this environment (needs a user on a real machine):**
- Manual QA Q1–Q15 (especially Q13/Q14: Reduce Motion and VoiceOver), because the GUI cannot be driven here.
- Measuring the app's CPU/RAM while alerting (S5–S7) with Instruments.
- The `release.yml` workflow (signing + notarization) has not been exercised because it needs an Apple Developer account and GitHub.
- 24-hour soak.

**M3.6 (verification with real agents, 2026-10-14):** `claude -p` and `codex exec` ran with a hook calling the real `bezelight-hook`; a listener on a separate socket received the full `start / working / ask / done / end` sequence from both. The hook **can send into the Unix socket from inside the agent** (Q-1 is answered; the file-write fallback is not needed). The helper finds the correct agent PID even when the hook runs through `sh -c`; `tp` appears only on Claude's `ask`; the outgoing keys are strictly within the allowed set. The OpenCode stream heartbeat is `: heartbeat` every 15 s, so the client treats 45 s of silence as a dead connection.

**M4 (2026-10-14):** 278 tests green. Verified on copies of this machine's 4 real config files (`~/.claude`, two accounts in `~/.claude-accounts`, `~/.codex/hooks.json`, the largest file of 45 KB containing an Orca hook): install → reinstall → uninstall yields the original file **byte for byte**, and a second install changes nothing.

**Differences from the plan in M4:**
- `OrderedJSON` (parse then re-serialize) was replaced by **text editing at byte positions** (`JSONText`): anything not touched stays absolutely identical, including indentation, CRLF/tabs, key order and escapes. Install followed by uninstall is the identity.
- Our own stale entries (timeout, matcher, different command) are **fixed in place**, keeping their position among other hooks.
- Known limitation, documented: if the original file already has `"Stop": []` (an empty event array) or an empty `"hooks": {}`, that empty key disappears after uninstall. The two forms are equivalent to the agent, so the safety check (`isSafeEdit`) compares semantically and ignores empty arrays.
- `AgentDoctor` returns **keys + parameters** (not strings) so M5 can translate them into 5 languages; there is a real send-receive round trip through the installed helper (`--selftest`).
- `AgentCenter.lastEventTimes()` records the time of the latest real event per agent (selftest events do not count).

**Bugs found during M3 (fixed, with regression tests):**
- The server's event coalescer once dropped a `working` that arrived less than 50 ms after an unanswered `ask`, but that is exactly the "answer" (Claude has no `answered` event) → the light got stuck. The correct rule: coalesce `working` only when the immediately preceding event from the same source was also `working`.
- `deinit` called `queue.sync` on the very queue that might hold the last reference → trap (`TranscriptWatcher`, `AgentHookServer`). `deinit` now cleans up directly.
- One `Task` per event reordered events, and the tracker then dropped events older than ones already seen → `AgentRuntime` uses a single ordered queue for all sources.
- `URLComponents` needs bracketed `[::1]` for IPv6.

**Differences from the plan (worth knowing for later milestones):**
- `DisplayState` dropped `presentAtStart` and gained `sessionCount`; `AgentCenter` additionally has `display(at:)` and `snapshot()` so the pipeline can read cheaply.
- `TrackerEffect.watchTranscript` does not carry `baseSize`: `TranscriptWatcher` (M3.4) calls `stat` itself when it starts watching.
- The rule "activity from the same source is the answer": `working` clears only the `ask` request of the same `origin` (main or subagent), not that of another source. There is a dedicated test.
- `OpenCodeNormalizer` uses the SSE stream's `created` as `ts` (not the app clock) for exact ordering.
- OpenCode's `form.rejected` / `form.cancelled` are mapped to `answered` by inference (real payloads not yet captured).
- Decoding nested config (`flourish`, `hold`) keeps **each alert's own defaults** when keys are missing (fixed while writing tests).
- The test privacy scan uses an **allow-list of wire keys** instead of searching for sensitive keywords (avoids false positives such as `"answered"`).

---

## Table of contents
1. [Goals, success metrics, budgets](#1-goals-success-metrics-budgets)
2. [Locked architecture decisions (ADR)](#2-locked-architecture-decisions-adr)
3. [Module structure and dependencies](#3-module-structure-and-dependencies)
4. [Key code interfaces](#4-key-code-interfaces)
5. [`LightPipeline` integration (concrete changes)](#5-lightpipeline-integration-concrete-changes)
6. [Threading model, performance, resource limits](#6-threading-model-performance-resource-limits)
7. [Security, privacy, threat model](#7-security-privacy-threat-model)
8. [Visual safety (photosensitivity) and accessibility](#8-visual-safety-photosensitivity-and-accessibility)
9. [Safe installer: technical requirements](#9-safe-installer-technical-requirements)
10. [Failure modes and recovery](#10-failure-modes-and-recovery)
11. [Observability and diagnostics (Doctor)](#11-observability-and-diagnostics-doctor)
12. [Work breakdown by milestone](#12-work-breakdown-by-milestone)
13. [Test strategy](#13-test-strategy)
14. [CI/CD, packaging, signing and notarization](#14-cicd-packaging-signing-and-notarization)
15. [Rollout, upgrade, uninstall](#15-rollout-upgrade-uninstall)
16. [Definition of done and release checklist](#16-definition-of-done-and-release-checklist)
17. [Schedule, critical path, parallelization](#17-schedule-critical-path-parallelization)
18. [Open questions and assumptions](#18-open-questions-and-assumptions)

---

## 1. Goals, success metrics, budgets

**Goal.** The user installs the hooks with one button, after which the LED strip correctly reports the "needs you / done, not yet seen / error (/ working)" state of every Claude Code, Codex and OpenCode session on the machine, while **never** breaking an agent, leaking content, or consuming resources when idle.

### 1.1 Success metrics (SLOs) and how to measure them

| Code | Metric | Target | Measured by |
|---|---|---|---|
| S1 | Event → LED latency (excluding agent latency) | p95 ≤ 150 ms | Integration test with a fake clock + real measurement on a machine |
| S2 | `bezelight-hook` helper run time | p50 ≤ 15 ms, p99 ≤ 40 ms | Benchmark of 1000 runs on an M2 |
| S3 | Hook breaks/slows an agent | 0 cases (always exit 0, stdout `{}`) | Fuzz test + app-off scenario |
| S4 | State accuracy on the 12 real timelines | 100% match | Replay test (13.2) |
| S5 | CPU when idle (no sessions) | No increase over today | Measure with `ps`/Instruments for 10 minutes |
| S6 | CPU while alerting (animated overlay, M2) | ≤ +3% | Measure for 10 minutes |
| S7 | Additional RAM | ≤ 3 MB | Measure before/after |
| S8 | Agent configs corrupted on install/uninstall | 0 | Merge tests + fuzz + backup/rollback |
| S9 | Content leakage (prompts, answers, commands) to socket/log | 0 | Automated check on every fixture |
| S10 | 24-hour soak, 3 simulated agents | No memory/FD leak, no stuck light | Soak test (13.5) |

### 1.2 Resource budget (hard)
- At most **256 sessions** tracked at once; beyond that, evict the oldest (LRU by `lastTs`).
- Datagram ≤ **1024 B**; the server ignores datagrams larger than 2048 B.
- The server coalesces events with the same `(agent, session, kind)` within a 50 ms window (`PostToolUse` storms).
- At most **200 events/second** into the tracker; beyond that, drop `working` events (keep `ask/answered/done/error/interrupt/end` intact).
- `AgentCenter`'s 1 Hz timer **runs only when there is ≥ 1 session**.

---

## 2. Locked architecture decisions (ADR)

| ADR | Decision | Rationale / consequence |
|---|---|---|
| ADR-1 | Claude/Codex: `command` hook → `bezelight-hook` helper → **Unix datagram socket** | No network port, per-user permissions, silent when the app is off |
| ADR-2 | OpenCode: **SSE client inside the app** to `GET {url}/api/event` (Basic auth, `url`/`password` from `~/.local/state/opencode/service.json`) | JS plugins do not load in 2.0.28; SSE covers every session of every client and installs nothing into OpenCode. Risk: the API is not public, so it is wrapped in `OpenCodeStreamClient` |
| ADR-3 | Claude rejection/Esc has no hook → **TranscriptWatcher** (size growth + a `"tool_result"` marker) | Measured; backed up by `confirmSec` |
| ADR-4 | **Dotdir `~/.bezelight/`** for the helper and socket (`bin/bezelight-hook`, `agent.sock`, `app.lock`, `backups/`) | Path has no spaces (safe in hook commands), fits the `~/.claude`, `~/.codex` convention. Directory is 0700 |
| ADR-5 | The hook command is **stable and unchanged across versions**: `[ -x "$HOME/.bezelight/bin/bezelight-hook" ] && "$HOME/.bezelight/bin/bezelight-hook" <agent> \|\| echo '{}'` | (a) Codex pins trust by entry hash: only the binary changes, never the entry. (b) If the helper is deleted the hook still exits 0 and shows no error in the agent |
| ADR-6 | Create a lightweight library target **`BezelightAgents`** (Foundation/Darwin only): event types, normalizers, wire codec, `OrderedJSON`, installer logic. The helper links only this library | The helper starts fast (does not pull in `BezelightCore`'s ScreenCaptureKit/AVFoundation). Tracker, overlay and settings live in `BezelightCore` |
| ADR-7 | `AgentTracker` is a **pure function**; all I/O, clocks and presence are injected | Testable by timeline replay |
| ADR-8 | Config is stored under its own key `agents.v1`, **not** inside `StreamSettings` | Changing notification settings does not trigger `pipeline.apply` |
| ADR-9 | **(Revised after trial use)** Agents is a **standalone mode** `LightMode.agents`, not a default overlay on every mode: the overlay runs only when the mode is Agents, or when the user enables `alertsInOtherModes`, or for a preview (`OverlaySpec.isPreview`). Reason: a default overlay cuts into the part of the strip in use, changes hardware brightness behind the user's slider, and forces the lights on even when switched off, which conflicts with the existing modes; moreover a dedicated mode does not need screen-recording permission. First version: the overlay **blends onto the base frame** in `LightPipeline.tick`, even when the lights are off if the event allows it; minimum brightness while alerting (`minBrightness`) | Alerts are not lost at low brightness |
| ADR-10 | **The feature is opt-in via the act of installing hooks**: if not installed, nothing happens | Safe on upgrade, no change to existing users' behavior |
| ADR-11 | No telemetry, no network calls (except loopback to OpenCode) | Privacy |

---

## 3. Module structure and dependencies

```
Package.swift
 ├─ BezelightAgents  (lib, Foundation+Darwin)      ← new
 │    AgentEvent.swift, Wire.swift, Normalizers/{Claude,Codex,OpenCode}.swift,
 │    OrderedJSON.swift, Installer/{ClaudeInstaller,CodexInstaller,HelperDeployer,InstallerStatus}.swift
 ├─ BezelightHook    (executable "bezelight-hook")  ← new, depends on BezelightAgents
 ├─ BezelightCore    (lib)                          ← depends on BezelightAgents
 │    AgentTracker.swift, AgentAlertSettings.swift, AgentOverlay.swift, AgentCenter.swift (actor),
 │    AgentHookServer.swift, OpenCodeStreamClient.swift, TranscriptWatcher.swift, PresenceProvider.swift,
 │    LightPipeline.swift (modified), Resources/*.lproj/Localizable.strings (new keys)
 ├─ Bezelight        (app)                          ← depends on BezelightCore
 │    AgentSettingsView.swift, AppModel+Agents.swift, MenuBarView (modified), HotKeys (modified)
 └─ Tests/BezelightCoreTests, Tests/BezelightAgentsTests  (+ Tests/Fixtures/{agents,timelines})
```

Note: `Tests/Fixtures/agents/` (35 real payloads) already exists; fixtures are loaded via `#filePath` (no resource bundling needed).

---

## 4. Key code interfaces

> The signatures below are the **contract** so parallel tasks do not drift apart. Names may change in detail; semantics may not.

### 4.1 `BezelightAgents`

```swift
public enum AgentKind: String, Codable, CaseIterable, Sendable { case claude, codex, opencode }

public enum EventKind: String, Codable, Sendable {
    case start, working, ask, answered, done, error, interrupt, end, substart, substop, seen
}

public struct AgentEvent: Codable, Sendable, Equatable {
    public var v = 1
    public var agent: AgentKind
    public var kind: EventKind
    public var session: String        // ID of the ROOT session
    public var req: String?           // requestID (OpenCode ask/answered)
    public var sub: String?           // subagent / child session
    public var cwd: String?
    public var pid: Int32?
    public var tp: String?            // transcript path, Claude's ask only
    public var ts: Int64              // ms epoch, when the helper started
    public var src: String?           // original event, for diagnostics
}

public enum Wire {
    public static let maxBytes = 1024
    public static func encode(_ e: AgentEvent) -> Data?          // nil if > maxBytes after trimming cwd/tp
    public static func decode(_ d: Data) -> AgentEvent?          // nil if corrupt / unsupported v
}

/// Pure: the hook's stdin JSON → 0..n normalized events. No I/O.
public enum ClaudeNormalizer { public static func events(from stdin: Data, now: Int64, pid: Int32?) -> [AgentEvent] }
public enum CodexNormalizer  { public static func events(from stdin: Data, now: Int64, pid: Int32?) -> [AgentEvent] }
/// Pure: one OpenCode SSE frame → 0..n events. Takes the session relationship table.
public struct OpenCodeNormalizer {
    public init()
    public mutating func events(from frame: Data, now: Int64) -> [AgentEvent]   // keeps a parent map (LRU 512)
}

/// JSON that preserves key order, number literals, escapes, indentation; round-trips byte for byte if unmodified.
public indirect enum OrderedJSON { case object([(String, OrderedJSON)]), array([OrderedJSON]), string(String), number(String), bool(Bool), null
    public init(parsing data: Data) throws
    public func serialized(indent: Indent) -> Data }
```

### 4.2 `BezelightCore`

```swift
public enum SessionState: Sendable, Equatable { case idle, working(confirmed: Bool), needsInput, done, error }

public struct AgentSession: Sendable, Equatable, Identifiable {
    public var id: SessionKey              // (agent, session)
    public var project: String             // last path component of cwd
    public var state: SessionState
    public var since: Date
    // internal: pending, activeSubs, mainStopped, doneAt, seen, presentAtDone, lastTs, pid, transcript, unconfirmedSince
}

public protocol PresenceProvider: Sendable { func idleSeconds() -> Double }   // real: CGEventSource; fake: tests

public struct PresenceSample: Sendable { public var idleSeconds: Double; public var lastInputAt: Date }

public enum TrackerEffect: Sendable, Equatable {
    case watchTranscript(SessionKey, path: String, baseSize: UInt64)
    case unwatchTranscript(SessionKey)
    case sessionRemoved(SessionKey)
}

public struct AgentTracker: Sendable {
    public init(settings: AgentAlertSettings)
    public mutating func apply(_ e: AgentEvent, now: Date, presence: PresenceSample) -> [TrackerEffect]
    public mutating func tick(now: Date, presence: PresenceSample, alive: (Int32) -> Bool) -> [TrackerEffect]
    public mutating func dismissAll(now: Date)
    public mutating func updateSettings(_ s: AgentAlertSettings)
    public var sessions: [AgentSession] { get }
    public func display(now: Date) -> DisplayState?            // highest-priority state (6.5 of the design document)
}

public struct DisplayState: Sendable, Equatable {
    public enum Kind: Sendable { case needsInput, error, done, working }
    public var kind: Kind; public var since: Date
    public var waitingCount: Int           // number of needsInput sessions (for multiPattern)
    public var presentAtStart: Bool        // done while the user is present → fades on its own
}

public struct OverlayFrameRequest: Sendable {
    public var display: DisplayState; public var style: EventStyle; public var now: Date
    public var ledCount: Int; public var reduceMotion: Bool; public var multiPattern: MultiPattern
}
public enum AgentOverlay {
    /// Pure, deterministic in time. Returns nil when expired. `alpha` 0...1 for crossfade.
    public static func render(_ r: OverlayFrameRequest, base: [LEDColor]) -> OverlayResult?
}
public struct OverlayResult: Sendable { public var frame: [LEDColor]; public var minBrightness: Double?; public var continues: Bool }

public actor AgentCenter {          // owns the tracker, the sources, the 1 Hz timer
    public init(presence: PresenceProvider, settings: AgentAlertSettings, now: @escaping @Sendable () -> Date = Date.init)
    public func ingest(_ e: AgentEvent) async
    public func updateSettings(_ s: AgentAlertSettings) async
    public func dismissAll() async
    public func sessions() async -> [AgentSession]
    public var updates: AsyncStream<AgentSnapshot> { get }       // snapshot when the displayed state/list changes
}
```

### 4.3 Small contracts

- `AgentAlertSettings`/`EventStyle` exactly as in section 8.5 of the design document, with lenient decoding (missing key = default) and **value clamping** on load (`Sanitize.clamp`).
- `SessionKey: Hashable { agent: AgentKind; session: String }`.
- Every public API is `Sendable`; no `@unchecked Sendable` except the POSIX socket wrapper class.

---

## 5. `LightPipeline` integration (concrete changes)

Existing file: `Sources/BezelightCore/LightPipeline.swift` (actor, 33 ms `run()` loop, `tick` has several early `return`s for static mode / a screen that has no new frame yet).

**Add state**
```swift
private var overlayRequest: (@Sendable (Date) -> OverlayFrameRequest?)?   // nil = no overlay
private var overlayWasActive = false
private var lastBase: [LEDColor] = []
private var overlayBrightnessApplied = false
```
**New API:** `public func setAgentOverlay(_ provider: (@Sendable (Date) -> OverlayFrameRequest?)?)`.

**Modify `tick`** (principle: no behavior change when there is no overlay):
1. After the `testFrame` block (layout check wins over the overlay), before `guard powered`:
   - `let ov = overlayRequest?(Date())`; `overlayAllowedWhenOff = ov?.style.alertWhenLightsOff == true`.
2. If `!powered`: only when there is a valid `ov` and `alertWhenLightsOff`, set `base = black × n`, call `render`, `submit`; otherwise keep the old `blackSent` logic. When the overlay has just ended in the off state: send one black frame and set `blackSent = true`.
3. When `powered`: complete the base `frame` as before but **replace the early `return`s** of `.staticColor`/`.screen` with: if `ov != nil`, use `lastBase` (the most recent base frame) instead of exiting; if `ov == nil` keep the `return`.
4. If there is an `ov`: `let r = AgentOverlay.render(ov, base: frame ?? lastBase)`; `frame = r.frame`; update the minimum brightness (`device.setOutput` with `max(settings.brightness, r.minBrightness)`, **called only when the value changes**, set a flag so it can be restored).
5. When the overlay goes from active to inactive: `dirty = true`, restore brightness (`device.setOutput(settings.brightness, …)`), clear the flag.
6. `lastBase = frame` before blending the overlay (so subsequent overlay frames have a background).
7. `apply(_:)`/`start`/`stop` are unchanged; `stop()` clears the overlay.

**Invariants to test**
- No overlay ⇒ the output frame is **identical** to today's (test comparing against static/effect modes).
- With overlay ⇒ output = a function of (base, time, config), deterministic.
- The overlay does not raise the sent `fps` above the current ceiling (`DeviceManager`'s frame pacing is unchanged).
- `testFrame` always wins over the overlay.

**Cost:** the `run()` loop already runs at 30 Hz; it adds one closure call + an O(LED) render ≤ 1024 per tick, only while an overlay is active.

---

## 6. Threading model, performance, resource limits

| Component | Thread | Notes |
|---|---|---|
| `AgentHookServer` | Dedicated queue (`DispatchSource` read), decode, 50 ms coalesce, `await center.ingest` | Never touches the main thread |
| `OpenCodeStreamClient` | Dedicated `Task`, `URLSession.bytes(for:)` + SSE parser | Cancellable; backoff with jitter |
| `TranscriptWatcher` | File `DispatchSource` per watched session | At most one watcher per session; cancelled when leaving `needsInput` |
| `AgentCenter` (actor) | Serializes every tracker mutation; 1 Hz timer only while sessions exist | Emits `AgentSnapshot` via `AsyncStream` |
| `AppModel+Agents` (`@MainActor`) | Receives snapshots, pushes the `OverlayFrameRequest` provider into the pipeline, updates UI | `@Published` only when the value changes (like `pollOnce`) |
| `LightPipeline` | Existing actor | The provider closure is `@Sendable` and reads immutable state |

**Avoid keeping the UI busy:** like `AppModel.pollOnce`, publish the session list only while the window/menu is visible; the top-priority state for the menu bar icon is always updated, but only when it changes.

**Clock:** all time logic takes an injected `now: Date`, including `ContinuousClock` converted at the boundary. Presence: a `PresenceSample` is taken by `AgentCenter` once per tick.

---

## 7. Security, privacy, threat model

| Asset | Threat | Mitigation |
|---|---|---|
| Prompt/answer/command content | Leak through socket, logs, files | Normalizers **hard-filter fields with an allow-list**; an automated test scans every fixture to ensure sensitive strings never appear in a datagram (S9) |
| `tp` (transcript path) | Path disclosure | Only accompanies Claude's `ask`, only on the machine; logs never record the full `tp`/`cwd` |
| Transcript content | Reading private data | Only `stat` + reading the **appended part** in memory to look for the `"tool_result"` marker, discarded immediately; never stored, never logged |
| OpenCode service password | Leak if `service.json` is edited to point at a foreign host | **Send credentials only to loopback** (`127.0.0.1`/`::1`/`localhost` after resolution); any other host ⇒ refuse and report an error. Never log the Authorization header. Keep it in memory only |
| Socket | Another user's process writes fake events | `~/.bezelight` directory 0700, socket 0600 (same user = same trust boundary). A `getpeereid` check does not apply to dgram; the same-user risk is accepted and documented |
| Malicious datagram | Memory exhaustion/DoS | Maximum size, rate limit, 256-session cap, lenient parsing that never crashes (fuzz) |
| Writing agent config | Corrupted file, losing other config, symlinks | Section 9 |
| Helper | Binary replaced | Installed with 0755 permissions owned by the user; `HelperDeployer` compares the hash at startup and repairs; signed (ad-hoc/Developer ID) together with the app |
| Session key | Session ID contains odd characters | Truncate the length (128), printable characters only; never used as a path |

There is **no**: telemetry, network beyond loopback, or storage of agent content anywhere.

---

## 8. Visual safety (photosensitivity) and accessibility

A flashing LED within the field of view is a real risk (photosensitive epilepsy). Mandatory requirements:

1. **Flash rate ≤ 3 per second** (per WCAG 2.3.1). `flourish.periodSec` and `hold.periodSec` (when `blink`) are **clamped to ≥ 0.34 s** both in the UI and when loading config; `flourish.count` ≤ 10, total continuous flashing time ≤ 5 s.
2. Updated defaults: **error** flashes 3 times with a **0.4 s** period (instead of 0.25 s); needsInput flashes 2 times with a 0.5 s period. (Already fixed in the design document.)
3. **System Reduce Motion** (`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`): replace every `blink/flash/pulse` with a slow smooth breathing (period ≥ 2 s). The user option `Reduce flashing` can always be turned on even when the system setting is off.
4. Never switch between two high-contrast colors across the full strip at a rate > 3 Hz (checked by a test on frames rendered over time).
5. **Users who have trouble distinguishing colors:** add a built-in "Color-blind friendly" palette (needs attention = orange, error = flashing white, done = cyan, working = purple), plus an extra distinction by **effect style** (breathing vs blinking vs solid), not by color alone.
6. UI: VoiceOver labels for every control, state values, and the session list; keyboard operation; never convey information by color alone.

---

## 9. Safe installer: technical requirements

Applies to `ClaudeInstaller`, `CodexInstaller`, `HelperDeployer`.

1. **`OrderedJSON`**, self-written (small), to preserve key order, unicode escapes, number literals and indentation style (detecting 2 spaces/4 spaces/tab). Do not use `JSONSerialization` (it loses order). Test: round-tripping real sample files (including a file with a long Orca hook) is **byte-for-byte identical** when unmodified.
2. **Symlinks:** if `settings.json` is a symlink (dotfiles), write to the **resolved target**, keeping the symlink intact.
3. **Locking & conflict detection:** `flock` recommended on `~/.bezelight/install.lock`; before `rename`, re-check (mtime + hash) the source file; if an agent/Orca has just modified it, re-read and merge again (at most 3 times).
4. **Atomic write:** write a temp file in the same directory, `fsync`, preserve permissions/ACL/owner, `rename`.
5. **Backups:** `~/.bezelight/backups/<name>.<yyyyMMdd-HHmmss>.bak`, keep the 5 most recent; a "Restore latest backup" button in the UI.
6. **Idempotent & self-repairing:** recognize our entry by the string `bezelight-hook` in `command`; installing twice does not duplicate; a missing/stale entry is **fixed in place** (no reordering of others); `Partially installed` is shown clearly.
7. **Clean uninstall:** remove only entries that carry the marker; remove empty matcher groups and empty event keys that we created; do not remove the `hooks` key if other content remains.
8. **Safe refusal:** corrupt/unreadable JSON ⇒ **do not write**, report a specific error and the path; read-only file ⇒ report an error.
9. **Multiple Claude directories:** list `~/.claude`, `$CLAUDE_CONFIG_DIR`, `~/.claude-accounts/*` (with `settings.json` or other signs of configuration); install/uninstall per directory; default-select the directory in use.
10. **Managed settings:** if a managed policy that allows only managed hooks (`allowManagedHooksOnly`) is detected, show a warning instead of pretending success.
11. **Standardized hook command (ADR-5)**; timing: Claude `async: true`, `timeout: 5`; Codex `timeout: 5`, no `async` for `Stop`/`PermissionRequest` until verified.
12. **Codex trust:** after installing, show "Run `/hooks` and trust the Bezelight hook"; since the hash is per entry, **never change the command line** between updates.
13. **HelperDeployer:** copy `Contents/Helpers/bezelight-hook` from the bundle to `~/.bezelight/bin/bezelight-hook` (0755), compare hash/version (`bezelight-hook --version` prints `<app-version> <protocol>`); repair automatically at app launch if missing/stale; independent of the `.app` location.

---

## 10. Failure modes and recovery

| Failure | Behavior |
|---|---|
| App not running when the hook fires | The helper's `sendto` fails ⇒ exit 0, stdout `{}` |
| Helper deleted | The hook command falls through to `echo '{}'` (ADR-5); relaunching the app restores the helper |
| Socket full | The helper uses non-blocking mode, drops the datagram, exits 0 |
| Two app instances running | `~/.bezelight/app.lock` (flock): the second instance does not take the socket and shows a warning |
| Stale socket left after a crash | At startup: `unlink` then `bind` (safe because the lock is held) |
| OpenCode SSE connection lost | Backoff 1/2/5/10/30 s + jitter; OpenCode sessions become "unknown" and expire per `stale` |
| `service.json` changed / port changed | Re-read on every reconnect |
| Stuck session (agent died, events lost) | Dead PID (Claude/Codex), `stale` timeout, `confirmSec`, `subagentHoldSec` |
| Events arrive out of order | Dropped by `ts`; termination wins on equal `ts` |
| System clock jumps | `ts` is used only for per-session ordering; deadlines use `AgentCenter`'s monotonic clock |
| LED device disconnected | The pipeline keeps running, the overlay shows only while connected; the menu bar icon still alerts |
| Corrupt config on load | Fall back to defaults, keep the corrupt copy at `agents.v1.corrupt` for diagnosis |
| Mac sleep/wake | The tracker keeps its state; after waking the overlay reappears; PIDs are checked on the first tick |

---

## 11. Observability and diagnostics (Doctor)

- **Event log** (ring buffer of 500 lines, in memory, off by default, enabled in *Advanced*): only `time · agent · kind · src · shortened session (6 chars) · project`. No content, no `tp`, nothing written to disk unless the user clicks "Export".
- `os_log` (subsystem `io.github.ledhcg.bezelight`, category `agents`): info level for state changes, debug for events; no sensitive data.
- **Doctor** ("Check" button in the Agents tab): runs these checks
  1. helper exists/runs/version matches; 2. socket is bound/has correct permissions; 3. **trial send-receive round trip** (run the helper with a fake payload, wait up to 1 s); 4. each Claude directory: has our `hooks`, valid JSON; 5. Codex: `hooks.json` has the entry, remind about `/hooks` trust, time of the latest real event; 6. OpenCode: read `service.json`, connect SSE, receive `server.connected`, version; 7. managed settings flag; 8. write permission on the config files.
  - Results are shown as a ✓/✗ table + fix instructions, with a "Copy report" button (private information redacted).
- `bezelight-hook --selftest`: sends a test event to the socket and prints the result (for support).

---

## 12. Work breakdown by milestone

Estimates are in person-days (d) for a developer who knows the codebase. Each task has a **code**, **dependencies**, and **acceptance**.

### M0. Foundation (1 d)
| Code | Task | Dependencies | Acceptance |
|---|---|---|---|
| M0.1 | Create the `BezelightAgents` and `BezelightHook` targets; update `Package.swift`; `BezelightAgentsTests` test scaffold | — | `swift build`, `swift test` green with an empty library |
| M0.2 | `FixtureLoader` (`#filePath` → `Tests/Fixtures`) and the **timeline format** `Tests/Fixtures/timelines/*.jsonl` (`{"t":ms,"src":"fixture:claude/PermissionRequest.bash"|inline,...}` + `expect` at checkpoints) | M0.1 | 1 sample timeline runs |
| M0.3 | Build the **12 real timelines** from the measured data (see 13.2) | M0.2 | Each timeline has expectations for the displayed state over time |

### M1. Model, normalizer, tracker (2.5 d)
| Code | Task | Dependencies | Acceptance |
|---|---|---|---|
| M1.1 | `AgentEvent`, `Wire` encode/decode (trim cwd/tp to fit 1 KB) | M0.1 | Round-trip; rejects unknown `v`, corrupt JSON, oversize |
| M1.2 | `ClaudeNormalizer`, `CodexNormalizer` per table 6.2 + field allow-list; assign `sub` from `agent_id`, `tp` only for Claude `ask` | M1.1 | Each fixture yields the correct `kind`; scan test: no sensitive strings |
| M1.3 | `OpenCodeNormalizer` (SSE `data:` frames, `parent map` LRU 512, collapse into the root session, `substart/substop`, drop deltas) | M1.1 | OpenCode fixtures; child sessions; unknown events dropped |
| M1.4 | `AgentAlertSettings`, `EventStyle`, enums, **`Sanitize.clamp`** (clamping per 8.x), defaults, lenient decoding | M0.1 | Loading missing/corrupt/out-of-range JSON ⇒ valid values |
| M1.5 | `AgentTracker.apply/tick/display` with all rules of 6.4 (1–9), priority 6.5, stale expiry, `confirmSec`, `subagentHoldSec`, presence, LRU 256 | M1.1, M1.4 | 100% of the state transition table; 12 timelines green |
| M1.6 | `AgentCenter` (actor, conditional 1 Hz timer, `AsyncStream<AgentSnapshot>`, dismiss) | M1.5 | Fake clock: expiry/ack/stale correct; timer stops when no sessions remain |

### M2. Overlay and pipeline (2 d)
| Code | Task | Dependencies | Acceptance |
|---|---|---|---|
| M2.1 | `AgentOverlay.render`: flourish (blink/pulse/flash/none) → hold (solid/breathe/blink/comet/none), coverage (full/start/end %), crossfade, `multiPattern` (none/doubleBeat/faster), `minBrightness`, time-based persistence | M1.4 | Golden frames at 0/0.25/0.5/1/2 s for each effect |
| M2.2 | Visual safety constraints (8): clamp periods, reduce-motion substitution, check the transition-edge frequency ≤ 3 Hz by scanning frames | M2.1 | Property test: for every valid config, bright/dark edges per second ≤ 3 |
| M2.3 | `LightPipeline` integration (section 5) + `setAgentOverlay` | M2.1 | Section 5 invariants green; tests for `staticColor`/`screen`/lights off/`testFrame` |
| M2.4 | Hook into `DeviceManager.setOutput` for minimum brightness and restoring | M2.3 | Test: brightness is correctly restored after the overlay ends |

### M3. Transport and event sources (3 d)
| Code | Task | Dependencies | Acceptance |
|---|---|---|---|
| M3.1 | `bezelight-hook`: read stdin capped at 1 MB, pick a normalizer, find the agent PID (nearest non-shell ancestor), non-blocking `sendto`, stdout `{}`, exit 0, `--version`, `--selftest` | M1.2 | Fuzz does not crash; benchmark S2 |
| M3.2 | `AgentHookServer`: bind `AF_UNIX/SOCK_DGRAM`, directory 0700/socket 0600, `app.lock`, clean up stale socket, 50 ms coalesce, rate limit, `ingest` | M1.6 | Integration test: send 10k datagrams, no FD leak; oversize datagrams rejected |
| M3.3 | `OpenCodeStreamClient`: read `service.json`, **loopback check**, SSE via `URLSession.bytes`, parser, backoff+jitter, re-read `service.json` on reconnect, public connection state | M1.3, M1.6 | Tests with a fake SSE server (including mid-stream cuts, fragmented frames, non-loopback host rejected) |
| M3.4 | `TranscriptWatcher` (+ a fake file interface for tests): `stat`/`DispatchSource`, read the appended part, look for `"tool_result"`, cancel at the right moment | M1.5 | Tests: size growth with/without `tool_result`; deleted/rotated file |
| M3.5 | Real `PresenceProvider` (`CGEventSource.secondsSinceLastEventType`) + a fake | M1.6 | Confirm it requests no permission (measured) |
| M3.6 | **Real** verification: hook fires into the socket from inside Claude/Codex (does the agent's sandbox block `sendto`?) | M3.1, M3.2 | Record the result in the document; if blocked, activate the fallback (13.6) |

### M4. Installer (2.5 d)
| Code | Task | Dependencies | Acceptance |
|---|---|---|---|
| M4.1 | `OrderedJSON` (parser/serializer, indent detection) | M0.1 | Byte-for-byte round trip on sample `~/.claude/settings.json`, `~/.codex/hooks.json` (redacted copies) |
| M4.2 | `ClaudeInstaller`: list directories, status, idempotent install/repair/uninstall, event list per 9.2 of the design document | M4.1 | Orca fixture: Orca part unchanged before/after; install×2 = install×1; uninstall restores the original file |
| M4.3 | `CodexInstaller` (`~/.codex/hooks.json`; does not touch `config.toml`/`notify`) | M4.1 | As above; stable command line (string comparison) |
| M4.4 | `HelperDeployer` (hash, version, permissions, repair at launch) | M3.1 | Delete the helper ⇒ app launch restores it; entry unchanged |
| M4.5 | Locking, conflict detection, symlinks, rotating backups, restore | M4.1 | Tests simulating concurrent edits, symlinks, read-only files, corrupt JSON (no write) |
| M4.6 | `InstallerStatus` + Doctor (section 11) | M4.2–M4.4, M3.3 | Correct report on a real environment |

### M5. App and UI (3 d)
| Code | Task | Dependencies | Acceptance |
|---|---|---|---|
| M5.1 | `AppModel+Agents`: create `AgentCenter`, server, SSE client; push the provider into the pipeline; persist `agents.v1` (debounced like `scheduleSave`); start/stop by `enabled` | M2.3, M3.2, M3.3 | The master switch takes effect immediately; no task leaks when off |
| M5.2 | **"Agent notifications"** tab/card in `SettingsView`: General, Agents (3 rows + Doctor), 4 event cards with fully described options, **Preview** (plays on the strip for ~5 s via a temporary `setAgentOverlay`), Restore defaults, warning for invisible configs, built-in palettes | M1.4, M2.1, M4.6 | Every option changes the light behavior as described (QA checklist) |
| M5.3 | Menu bar: icon changes with the priority state (with different shapes, not only color), session list, "Dismiss all" | M5.1 | Updates within ≤ 1 s; VoiceOver reads correctly |
| M5.4 | Global hotkey "Dismiss notifications": add `Action.dismissAlerts` to `HotKeys` (pick a key not colliding with ⌃⌥⇧F8/9/10/↑/↓, proposed ⌃⌥⇧F11), honoring `hotkeysEnabled` | M5.1 | Verified no conflicts; disabled when hotkeys are off |
| M5.5 | First-run onboarding: when the tab is first opened, a short explanation + a "Set up detected agents" button, a reminder of `/hooks` (Codex) and restarting the session (Claude) | M4.6 | Can be completed without reading the docs |
| M5.6 | **Localization in 5 languages**: ~150 `agents.*` keys into en, vi, zh-Hans, ja, ko; the existing test ensures all keys are present | M5.2 | `swift test` (the all-keys test) green |
| M5.7 | Accessibility: labels, focus order, no color-only signalling, Reduce Motion | M5.2, M2.2 | Manual review with VoiceOver |

### M6. Quality (2 d)
| Code | Task | Dependencies | Acceptance |
|---|---|---|---|
| M6.1 | Replay tests of the 12 timelines + property tests for the tracker | M1.5 | Green; runs in < 5 s |
| M6.2 | Integration test: real helper ↔ real server ↔ tracker ↔ overlay (fake clock) | M3.* | Green on CI |
| M6.3 | Fuzz: helper (random stdin), `Wire.decode`, `OpenCodeNormalizer`, `OrderedJSON` | M3.1, M4.1 | No crash in 1 million samples |
| M6.4 | 24 h soak with a simulator of 3 agents × 20 sessions | M5.1 | S10 met; no leaks |
| M6.5 | Measure S1/S2/S5/S6/S7 | M5.1 | Table of measurements attached to the PR |
| M6.6 | Manual QA on a real machine per matrix 13.4 | M5.* | Every row passes |

### M7. Release (1.5 d)
| Code | Task | Dependencies | Acceptance |
|---|---|---|---|
| M7.1 | `build-app.sh`: build `bezelight-hook` with the same `ARCHS`, place it in `Contents/Helpers/`, sign with hardened runtime before signing the app, check `codesign --verify --strict --deep` | M3.1 | Universal app signs; the helper runs from the bundle |
| M7.2 | `ci.yml`: build all 3 products, `swift test`, run the helper benchmark (soft threshold), upload artifact | M6.* | CI green |
| M7.3 | Docs: README en/vi (features, installation, security, troubleshooting), CHANGELOG 0.3.0, update the `docs/PROTOCOL.md` link, a "Troubleshooting" page | M5.* | Reviewed by someone else |
| M7.4 | Version 0.3.0, notarization (`notarytool`) if a Developer ID is available, tag, release notes | M7.1–M7.3 | Download, open, install hooks, see the lights alert |

**Total estimate: ~17.5 person-days** (M0 1 + M1 2.5 + M2 2 + M3 3 + M4 2.5 + M5 3 + M6 2 + M7 1.5). Critical path and parallelization are in section 17.

---

## 13. Test strategy

### 13.1 Pyramid
- **Unit (the most):** normalizers, `Wire`, `Sanitize`, tracker, overlay, `OrderedJSON`, installer logic. Swift Testing (`@Test`) like the existing `CoreTests.swift`.
- **Timeline replay:** the source of truth for behavior (13.2).
- **Integration:** real helper + real socket; fake SSE; pipeline with a fake/frame-recording `DeviceManager`.
- **Manual/E2E:** matrix 13.4 on a real machine with the 3 real agents.

### 13.2 Twelve standard timelines (from measured data)
| # | Timeline | Main expectation |
|---|---|---|
| 1 | claude-allow | working → needsInput (PermissionRequest) → working (PostToolUse) → done (Stop) |
| 2 | claude-deny | needsInput stuck → transcript grows (+4 s) → unconfirmed working → idle after `confirmSec` |
| 3 | claude-askuser | needsInput immediately (PermissionRequest AskUserQuestion) → cleared on PostToolUse |
| 4 | claude-subagent-bg | Main Stop is held while a subagent remains → subagent asks for permission → needsInput → SubagentStop → done |
| 5 | claude-internal-substop | Internal `SubagentStop` is ignored |
| 6 | codex-allow | needsInput → working → done |
| 7 | codex-deny-interrupt | needsInput → Interrupt → idle (not done) |
| 8 | opencode-allow | permission.asked → replied(once) → succeeded → done |
| 9 | opencode-reject | asked → replied(reject) → interrupted(shutdown) → idle (not error) |
| 10 | opencode-esc | interrupted(user) → idle |
| 11 | opencode-fail-quota | execution.failed → unseen error |
| 12 | opencode-subagent-form | child session (parentID) asks for permission → root needsInput; form.created/replied |

Each timeline is also run with: user present/absent; valid random reordering (same `ts`); duplicated events (idempotent).

### 13.3 Property tests (tracker/overlay)
- For random valid event sequences: no panic, `display` always belongs to the set of existing sessions, `needsInput` always has a non-empty `pending`, no session stays `working` beyond `stale`.
- Ordering: permuting events with different `ts` gives the same result as sorting by `ts`.
- Overlay: for every `clamp`ed `EventStyle`, transition-edge frequency ≤ 3 Hz; channel values ∈ [0,255]; `render` is deterministic (same input, same output).

### 13.4 Manual QA matrix (real machine)
| # | Scenario | Passes when |
|---|---|---|
| Q1 | Each agent: allow / deny / Esc a permission request | Light on within ≤ 1 s, off right after the answer |
| Q2 | Claude `AskUserQuestion`, OpenCode `question`/form | Alerts and clears correctly |
| Q3 | 3 parallel Claude sessions, 1 waiting | Light alerts; the menu bar lists the waiting session |
| Q4 | Subagent waiting for permission (Claude, OpenCode) | Alerts for the root session |
| Q5 | Agent finishes while the user is away / while typing | Green holds dimly / fades after `presentFadeSec` |
| Q6 | OpenCode provider error | Red |
| Q7 | Turn the lights off with the hotkey, then an agent asks for permission | Lights per the `alertWhenLightsOff` setting |
| Q8 | Bezelight app off, using an agent | Agent not slowed, no error shown |
| Q9 | Delete `~/.bezelight/bin/bezelight-hook` | Agent shows no hook error; opening the app restores it |
| Q10 | Install/uninstall with an Orca hook present; install twice | Orca intact; no duplicates |
| Q11 | Mac sleep/wake with a waiting session | Displays again correctly |
| Q12 | Restart the OpenCode service | App reconnects on its own within ≤ 35 s |
| Q13 | Turn on system Reduce Motion | No more flashing, only breathing |
| Q14 | VoiceOver walks the Agents tab and menu bar | Reads correctly, keyboard operable |
| Q15 | Switch language live (5 languages) | No raw keys visible |

### 13.5 Soak and performance
- Soak: a simulator (script) fires 3 agents × 20 sessions with random behavior (including mid-run cancellations) for 24 hours; monitor FDs, memory, task count, clock drift, and no stuck light.
- Performance: measure S1, S2, S5, S6, S7; attach the table to the PR; thresholds act as merge conditions.

### 13.6 Fallback if the hook cannot send to the socket (M3.6)
If the agent's sandbox blocks Unix socket `sendto`: (a) the helper switches to **writing a small file into the queue** `~/.bezelight/queue/` (atomic rename) and `AgentHookServer` watches it with `DispatchSource`/FSEvents; (b) same `Wire` format. Decided after M3.6; does not affect the tracker.

---

## 14. CI/CD, packaging, signing and notarization

**`Package.swift`:** add 2 targets + 2 test targets; `BezelightHook` is `.executable(name: "bezelight-hook", targets: ["BezelightHook"])`.

**`scripts/build-app.sh` (modified):**
1. `swift build -c release` already builds all products; take `bezelight-hook` from `BIN_DIR`.
2. `mkdir -p "$APP/Contents/Helpers"`; `cp "$BIN_DIR/bezelight-hook" "$APP/Contents/Helpers/"`.
3. Sign the **helper first**: `codesign --force --options runtime $TS -s "$IDENTITY" --identifier io.github.ledhcg.bezelight.hook "$APP/Contents/Helpers/bezelight-hook"`, then the bundle, then the app (keeping the existing order).
4. `codesign --verify --strict --deep`; check that the helper's `lipo -archs` = `ARCHS`.
5. Print the helper version: `"$APP/Contents/Helpers/bezelight-hook" --version`.

**`ci.yml` (modified):** keep the existing job; add a step running `swift build -c release --product bezelight-hook`, run the helper benchmark (print numbers, soft threshold warns), upload `dist/Bezelight.app`. If a Developer ID is in secrets: a separate release job signs + `notarytool submit --wait` + `stapler staple`.

**Version:** 0.3.0; does `Info.plist` need `NSAppleEventsUsageDescription`? **No** (Apple Events are not used). No new permissions are needed (Accessibility is unused; Screen Recording only for screen mode as before). State this clearly in the README.

**Accompanying docs:** CHANGELOG 0.3.0; README en/vi ("Agent alerts" section); `docs/AGENT_NOTIFICATIONS.md` (specification) and this document (plan) are kept in the repo.

---

## 15. Rollout, upgrade, uninstall

- **Safe by default (ADR-10):** upgrading to 0.3.0 changes no current behavior; the feature works only after the user presses **Install** for each agent.
- **Beta:** release 0.3.0-beta with a "Beta" flag in the UI for one cycle; gather feedback through Issues (a bug report template with a privacy-redacted Doctor report).
- **Kill switch:** `enabled` (master) and a per-agent switch; turning off takes effect immediately without removing hooks.
- **App upgrade:** `HelperDeployer` replaces the binary and **does not change** the hook entry (preserving Codex trust). If the helper's `protocol` > what the app supports: the app records a diagnostic, ignores events, and prompts for an update.
- **Config backward compatibility:** `agents.v1` is lenient; new keys always have defaults; unknown keys are preserved when writing back (not lost on downgrade).
- **Clean uninstall:** a "Remove all hooks" button (all agents, all directories) + "Delete `~/.bezelight`"; the README documents manual removal if the app has already been deleted (delete entries containing `bezelight-hook`; the hooks remain harmless thanks to ADR-5).
- **Post-release monitoring:** a periodic checklist whenever Claude/Codex/OpenCode ship a new version (see 16.3); fixtures + replay tests give early warning when payloads change.

---

## 16. Definition of done and release checklist

### 16.1 Definition of done (every PR)
- Builds clean (no new warnings), `swift test` green, test coverage for new logic.
- No new `@unchecked Sendable`/`nonisolated(unsafe)` other than POSIX wrappers with a documented reason.
- No printing/logging of sensitive content (checked by the S9 test).
- New UI strings are provided in all 5 languages.
- Related docs updated.

### 16.2 0.3.0 release checklist
- [ ] S1–S10 met, with measurements attached.
- [ ] 12 replay timelines green; fuzz of 1 million samples without a crash; 24 h soak passed.
- [ ] Manual QA Q1–Q15 passed on at least one Apple Silicon machine (and Intel if available).
- [ ] Installer: byte-for-byte round trip, Orca hook intact, install/uninstall/restore verified.
- [ ] Visual safety: property tests pass; Reduce Motion works.
- [ ] Hardened runtime signing, `codesign --verify --strict --deep` passes; (if available) notarization + staple.
- [ ] README (en/vi), CHANGELOG, troubleshooting page; Issue template with Doctor.
- [ ] Verified on agent versions: Claude Code (≥ the measured 2.1.296), Codex (0.162.1), OpenCode (2.0.28); recorded in the README "Verified" section.

### 16.3 Compatibility watch list (every time an agent upgrades)
Re-run the capture suite (`kit/`), compare payloads against `Tests/Fixtures/agents/`; run replay; update the mapping table if event names change.

---

## 17. Schedule, critical path, parallelization

**Critical path:** M0 → M1 (M1.5 tracker) → M2 (overlay + pipeline) → M5 (UI) → M6 → M7.
**Can run in parallel** (after M0):
- Stream A (core): M1 → M2.
- Stream B (transport): M3.1–M3.5 (needs M1.1–M1.3 finished first).
- Stream C (installer): M4 (independent, only needs `OrderedJSON`).
- M5 waits for A + B; M6.1–M6.3 run in parallel with M5; M6.4–M6.6 come last.

| Week | Content |
|---|---|
| 1 | M0, M1, start M4.1 (`OrderedJSON`) |
| 2 | M2, M3 (M3.6 early to learn the fallback), M4 |
| 3 | M5, M6.1–M6.3 |
| 4 | M6.4–M6.6 (soak, QA), M7, beta |

(One person working sequentially: ~4 calendar weeks including buffer; two people in parallel: ~2.5 weeks.)

**Review gates:**
- G1 after M1: 12 timelines green ⇒ lock the behavior.
- G2 after M3.6: confirm the hook can send to the socket ⇒ lock the transport channel.
- G3 after M4: installer passes the safety test suite ⇒ allowed to try on users' real configs.
- G4 after M6: measurements & soak met ⇒ release the beta.

---

## 18. Open questions and assumptions

| # | Question | Working assumption | When to settle |
|---|---|---|---|
| Q-1 | Can a hook running in the agent's sandbox send to a Unix socket? | Yes (hooks run outside the tool sandbox) | M3.6 |
| Q-2 | Does Codex support `async` for hooks, and is `{}` valid for `PermissionRequest` in every version? | Use synchronous, the helper is fast | M3.6 |
| Q-3 | Do Codex hooks run when using the Codex desktop app? | Yes (same mechanism) | QA Q1 |
| Q-4 | OpenCode's `session.viewed` (what is `idle`)? | Use as a secondary signal, can be turned off | M3.3 (see more real events) |
| Q-5 | OpenCode's `form.rejected`, `session.deleted`, `session.retry.scheduled` | Handle leniently: ignore unknown events; `stale` cleans up | When encountered |
| Q-6 | Claude `StopFailure`, `Notification` of type `elicitation_dialog` | Follow the official documentation | When encountered |
| Q-7 | Is a Developer ID available for notarization? | Can sign ad-hoc for trial builds | M7.4 |
| Q-8 | Default "dismiss" hotkey | ⌃⌥⇧F11 | M5.4 |
| Q-9 | Is OpenCode 1.x (plugin) support needed? | No (out of scope for 0.3.0) | After release |

---

*End of plan. Section 4 ("Key code interfaces") and section 5 ("`LightPipeline` integration") are the contract for dividing the work; major changes must update this document first.*
