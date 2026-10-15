# Audit: Agents mode (performance, UX, UI, robustness)

Date: 2026-10-14 · Audited build: 0.3.0 (commit `09487f3`), build installed in `/Applications`.

## Method

Not just a code read. Every conclusion below is backed by at least one of these kinds of evidence:

- **Measured on the real running app:** `top`, `sample`, `footprint` while idle and while receiving 150 events/second through the real socket.
- **Real UI screenshots** (rendering the main window and the menu bar popover) with simulated session data, in English and Vietnamese.
- **Tests/scratch code with counters** (publish counts, list order) and a release-build benchmark (SSE reading).

Severity: **P1** should be fixed before wide release, **P2** should be fixed soon, **P3** minor.

## Summary

| # | Issue | Type | Severity |
|---|---|---|---|
| H1 | CPU 1% → **~80%** when receiving 150 events/s | Performance | **P1** |
| U1 | "Needs you" sessions sit at the **bottom** of the list (app and menu bar) | UX | **P1** |
| U2 | Choosing Agents mode without pressing Start means **nothing happens** and there is no hint | UX | **P1** |
| U3 | No "no agent connected yet" state (the light strip stays dark forever, unexplained) | UX | **P1** |
| U4 | "Set up" installs into **all 5** Claude directories, with no way to choose and no confirmation | UX | **P1** |
| U5 | No **Launch at login** reminder: if the app is off, the hooks stay silent forever | UX | **P2** |
| H2 | The 1 s timer keeps running for up to **1 hour** after the last event even though there is nothing left to track | Performance | P2 |
| U6 | Hint text (`.tertiary`) has **low contrast** on the pastel glass background | UI | **P2** |
| U7 | Relative times show in the **wrong language** ("3 secs" in the Vietnamese UI) | UI | P2 |
| U8 | The panel is ~3000 px long, pushing the main settings below Setup | UX | P2 |
| U9 | The master switch "Show agent notifications…" duplicates choosing the mode; turning it off also hides Setup/Check | UX | P2 |
| U10 | Inconsistent controls (checkbox vs switch); the on/off state of the "Applies to" chips is hard to see | UI | P2 |
| U11 | No success feedback after installing; Check does not run automatically | UX | P2 |
| U12 | The left column is empty and does not show what the agents are doing | UI | P3 |
| U13 | Repetitive help text, ambiguous "Then"/"Stays" labels | UI | P3 |
| H3 | Footprint 110 MB vs the 65–80 MB stated in the README (cause unclear) | Performance | P3, needs verification |
| H4 | `Localizer.resolved`, `refreshSetup`, `OverlayStore.spec()` repeat work | Performance | P3 |

## Performance

### H1. An event storm pushes CPU to ~80% (P1)

**Measured:** installed app, idle ≈ **1.2%** CPU. Sending 145 `working` events/second from 40 sessions into the real socket for 10 s: **80–85%** CPU
(≈ 5.5 ms CPU per event). Real agents emit far fewer, but a heavy tool-use turn with several parallel sessions
and subagents can reach dozens of events/second, i.e. roughly 10–30% CPU just to report "still working".

**Causes (from `sample`, 5 seconds):**

1. **Every event re-sorts the whole session table.** `AgentCenter.ingest → publish → makeSnapshot → sessions` calls `sort` on
   all of `table.values`, copying every `AgentSession` (a large struct with dictionaries/sets). This accounts for **207/230** samples of `ingest`.
2. **Every event makes the snapshot "different".** `AgentSession` uses the synthesized `==`, which includes `lastEventAt` and `lastTs`.
   Measured: **200 events with no visible change → 200 publishes**. The `AsyncStream` dedup is useless.
3. **Every publish makes SwiftUI redraw the whole panel.** `AgentsPanel` observes the entire `AgentsModel`; the sample shows
   `AgentsPanel.body`, `AgentEventEditor.body`, `ValueSlider.body`, `tr()` and ~**1900** `AttributeGraph` samples. The four
   event editors (hundreds of views) are re-evaluated just because one session reported "working".
4. **A `UserDefaults` write on every event.** `AgentsModel.apply` compares `lastEventTimes()` (which changes on every event) and then calls `saveLastEvents`.

**Fixes (in order of payoff):**
- Publish only on a **visible change**: add a custom `==` for `AgentSession` (excluding `lastEventAt`, `lastTs`, `holdSince`…) or a `visibleVersion` counter that the tracker bumps when `state/pendingCount/activeSubs/since/project/unconfirmed` change.
- Coalesce publishes to at most ~10 per second, and sort only when actually publishing.
- Split the model: `AgentsModel` (settings) and `AgentsLive` (snapshot, runtime) so dragging a slider does not redraw the session list and vice versa; extract `AgentSessionsList` into its own view.
- Write `lastEvents` at most once per 10 s (or on quit).
- **Target:** 150 events/s ≤ 5% CPU. Regression test: 200 events with no change → 0–1 publishes.

### H2. The 1-second timer runs too long (P2)
`done`/`idle` sessions are kept for `historySeconds = 3600` s to show history, and the 1 Hz timer runs the whole time
(waking the CPU every second → battery cost). It should tick at 1 s only when there is a `working`/`needsInput`/`unconfirmed` session, a `done` held
waiting for a subagent, or a `done` not yet acknowledged by the user; otherwise tick every 30 s.

### H3. Memory (P3, needs verification)
`footprint` of the running app: **110 MB**; the README states 65–80 MB for 0.2.0. We could not separate the part due to the new features
(main window open, SwiftUI) from the part that was already there. Measure 0.2.0 and 0.3.0 under the same conditions (hidden window, same mode).

### H4. Small repeated work (P3)
`Localizer.resolved` walks the language list on every `tr()` call (31 samples during the storm); `refreshSetup()` re-reads and re-parses
every config file each time the panel appears; `OverlayStore.spec()` rebuilds `OverlaySpec` (including copying `EventStyle`) 30 times/second
while a notification is showing. All small, but easy to cache.

### Checked, fine
- Reading the SSE stream byte by byte: **44 MB/s** (release build); a real model streams ~20 KB/s ⇒ < 0.1% CPU.
- `bezelight-hook` helper: median 5.1 ms, p99 9–15 ms. 90 s soak: no FD leak, stable memory.
- Overlay rendering, `FlashLimiter`, tick pipeline: negligible (the release build is 20–50× faster than debug).
- Idle ≈ 1.2% CPU.

## UX

### U1. Session list order (P1)
`AgentTracker.sessions` sorts by `since`, newest first. Measured: `["finished:done", "failed:error", "waiting:needsInput", "a:working"]`.
The menu bar says "1 waiting for you" while that row is at the **bottom**. It must sort by **priority** (needsInput > error > done >
working > idle), then by time. Apply this to the main window, the menu bar and the badge.

### U2. You must press Start to get lights (P1)
Agents mode does not need screen capture, but the pipeline only runs after **Start** (which connects the serial port). Choosing Agents without Start:
no lights, no notifications, no hint (only a small orange line by the Preview button). Suggestion: a clear status line in the left column
while stopped ("Press Start so the light strip can report agents"), or offer to start automatically when you choose this mode.

### U3. Empty state (P1)
Choosing Agents when no hook is installed: the light strip stays dark forever, with no explanation. It needs a banner "No agent connected yet → Set
up" at the top of the panel and in the left column, disappearing once at least one agent is connected.

### U4. "Set up detected agents" installs into every Claude directory (P1)
On this machine it would edit **5** `settings.json` files (`~/.claude`, `work`, `9router`, `gemini`, `psa`), without asking and without a summary.
A GUI app does not see `CLAUDE_CONFIG_DIR`, so it cannot know which directory is in use. Proposal: a list with checkboxes, defaulting to
the directory with the most recent activity (mtime of `projects/`), a confirmation dialog stating exactly which files will be edited + "backed up, can be removed",
and an Undo button after installing.

### U5. No reminder to launch at login (P2)
The hook does nothing if Bezelight is not running. If "Launch at login" is off after installing, we need a reminder (one line + a button).

### U8. Panel too long, layout not ordered by importance (P2)
~3000 px, of which Setup (≈ 650 px) is always open and takes space even when it is done. Suggestion: once every agent is connected, collapse Setup into
a single status line ("Claude Code ✓ 3 directories · Codex ✓ · OpenCode ✓", click to expand); "Check" and "Advanced" collapsed
by default; order: status → 4 notifications → general → check → advanced.

### U9. Master switch (P2)
Inside a *mode*, "Show agent notifications on the light strip" duplicates choosing the mode, and when turned off it also hides
Setup/Check, so the problem cannot be fixed. It should become "Listen to agents" inside Advanced, and must not hide Setup.

### U11. Feedback after installing (P2)
After installing, the only change is the row label becoming "Installed". It needs a result message ("Installed in 2 directories, backup at …"), should run
Check automatically, and should remind the user of the next step (restart the session / `/hooks`) right next to that row.

### U12. Empty left column (P3)
In Agents mode the preview is just a gray bell icon. It could show a live summary: the number of sessions per state and the
color currently playing.

## UI

### U6. Hint text contrast (P2)
About 45 help lines use `.tertiary` on the pastel glass background (screenshot: nearly unreadable, estimated < 3:1). Use
`.secondary` for every informative caption, and `.tertiary` only for decoration. Check in light mode, dark mode, and *Reduce Transparency*.

### U7. Wrong language in relative times (P2)
The UI is Vietnamese but the session list says "3 secs", "4 secs": `Text(date, style: .relative)` follows the system locale, not
`Localizer`. Add `.environment(\.locale, Locale(identifier: Localizer.resolved.rawValue))` at the root, or use a
`RelativeDateTimeFormatter` with its locale set, as the "Latest event" row does. Similarly, `String(format: "%.2f")` uses a decimal point
whereas Vietnamese uses a comma.

### U10. Control consistency (P2)
The master switch is a *checkbox*, while the notifications are *switches*. The "Applies to" chips (`toggleStyle(.button)`) look almost the same
when on and off, so users cannot tell the state. Use a switch/chip with a clear checkmark, and give the VoiceOver label "on/off".

### U13. Help text (P3)
The "Opening" section shows **two** consecutive help lines; the labels "Then" and "Stays" are ambiguous. Merge the help and rename the labels to
"Opening effect / Follow-up effect / Duration".

### Pre-existing note
The selected tab of the mode picker (Agents included) looks **paler** than the unselected tabs: a `Brand.accent.opacity(0.75)` tint on a
pastel background plus white text. This styling was already there but is more noticeable now with 4 tabs.

## Robustness / functionality (reviewed, no immediate fix needed)
- **Known limitation:** an OpenCode child session created before the app connected is treated as a root session (its `parentID` cannot be known).
- "Latest event" still shows for an agent with no hook installed if there was ever an event before; acceptable but potentially misleading.
- Every write path for agent config, the socket, SSE (loopback only) and the log (no content) was verified in earlier phases.

## Suggested fix order

1. **Performance H1** (one cluster of work: publish on visible change, coalescing, model split, fewer `UserDefaults` writes) and **U1** (priority order): all small, low risk, testable.
2. **U2, U3, U5** (first-run guidance: Start, empty banner, launch at login) and **U4** (directory choice + confirmation + undo).
3. **U6, U7, U10, U13** (contrast, language, controls, text).
4. **U8, U9, U11, U12** (layout: collapse Setup/Advanced, remove the master switch, post-install feedback, left column).
5. **H2, H3, H4** and re-measure memory.

## Resolution status

Fixed: performance + priority order (c474750), first-run guidance + safe setup (dbdcd88), contrast/locale/collapsible Check and Advanced (7a7ab6c), Setup collapses once connected + master switch moved into Advanced + unified switches.
H3 could not be compared with 0.2.0 (no baseline build); the 0.3.0 build measured ~144 MB RSS, ~3.6% CPU while idle.
