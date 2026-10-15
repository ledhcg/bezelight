# Agent Light Notifications

> Status: **implemented in 0.3.0** (this document is the spec and a log of measurements; the plan and architecture decisions are in [`AGENT_NOTIFICATIONS_PLAN.md`](AGENT_NOTIFICATIONS_PLAN.md)) · Agent scope: **Claude Code, Codex, OpenCode**
> Survey date: 2026-10-14 · Versions checked: OpenCode 2.0.28 (local binary) + `@opencode-ai/sdk` (`v2` types), Claude Code hooks docs, Codex hooks docs.

---

## Table of contents

1. [Goals and scope](#1-goals-and-scope)
2. [Decisions made](#2-decisions-made)
3. [User story analysis](#3-user-story-analysis)
4. [Real-world scenario analysis (multiple sessions)](#4-real-world-scenario-analysis-multiple-sessions)
5. [Research on each agent's mechanism](#5-research-on-each-agents-mechanism)
6. [Event normalization](#6-event-normalization)
7. [Architecture](#7-architecture)
8. [User configuration (every option in detail)](#8-user-configuration-every-option-in-detail)
9. [Hook installation spec (installer)](#9-hook-installation-spec-installer)
10. [`bezelight-hook` helper spec](#10-bezelight-hook-helper-spec)
11. [UI spec](#11-ui-spec)
12. [Build plan](#12-build-plan)
13. [Test plan](#13-test-plan)
14. [Risks and items to verify (Phase 0)](#14-risks-and-items-to-verify-phase-0)
15. [Backlog outside v1 scope](#15-backlog-outside-v1-scope)
16. [Appendix](#16-appendix)

---

## 1. Goals and scope

**Goal.** The LED strip behind the display shows the status of AI coding agents running on the machine, so users do not have to keep watching the terminal:

- The agent **needs your answer** (permission request, follow-up question) → an attention-grabbing light, held until resolved.
- The agent **finishes** while you are not looking → a dim green glow, held until you come back.
- The agent **hits an error** → red light.
- The agent **is working** → optional, off by default.

**In scope for v1**
- 3 agents: Claude Code, Codex, OpenCode, running on the **same Mac** as Bezelight.
- Multiple parallel sessions, multiple parallel agents, subagents.
- Install and remove hooks from the UI, safely with respect to existing configuration (for example Orca's hooks).
- Full customization of color, effect, timing and persistence for each event type.

**Out of scope for v1.** Antigravity (dropped; no reliable "awaiting approval" signal), agents running over SSH/containers, sending notifications to other devices, sound. See [Backlog](#15-backlog-outside-v1-scope).

**Design principles**
1. **A hook must never break the agent**: always exit 0, fast, silent, even when the app is not running.
2. **Privacy**: never forward prompt contents or agent replies.
3. **Zero cost when idle**: the overlay only runs the render pipeline while a notification is active.
4. **Cooperate, do not overwrite**: merge into existing configuration, remove only our own entries.
5. **Pure, testable logic**: the state machine lives in `BezelightCore`, independent of UI and I/O.

---

## 2. Decisions made

| # | Decision | Default | Configurable |
|---|---|---|---|
| D1 | The "Done" event is an **unseen** state: keep a dim green glow until the user comes back | Hold until the user returns | Yes: until return / timed / until manually dismissed / blink once only |
| D2 | When the lights are **off**, still alert for `needsInput` and `error` | Alert (needsInput, error); `done` and `working` stay silent | Yes, per event type |
| D3 | **Working** state | **Off** | Yes: enable, color, effect, coverage, brightness |
| D4 | Everything is adjustable **per event**: color, effect, timing, persistence, coverage | See the [defaults table](#82-default-values) | Yes, with live preview on the LED strip |
| D5 | Drop Antigravity | n/a | n/a |
| D6 | Helper written in Swift | n/a | n/a |
| D7 | **Agents is a standalone mode** (alongside Screen, Music, Colors; all options live in that mode's right-hand column, with no separate window or entry), not an overlay on every mode. In other modes nothing is drawn on top, brightness is unchanged, and the lights are not forced on; Agents mode does not need the screen recording permission | Only in Agents mode | Yes: *Show notifications in other modes too* (off by default); background color when idle; always-visible preview |

---

## 3. User story analysis

Priority legend: **P0** required for v1, **P1** should have, **P2** can be deferred.

### 3.1 Setup and connection

| ID | As a… | I want to… | So that… | Acceptance criteria | Priority |
|---|---|---|---|---|---|
| US-01 | User | install the hook for each agent with one button | I do not have to edit config files by hand | **Given** an agent is detected on the machine **When** I click Install **Then** the hook is added (Claude/Codex; OpenCode needs no install, the app connects by itself), status changes to "Installed", and the required activation step is shown (Codex: `/hooks` to trust; Claude/OpenCode: restart the session) | P0 |
| US-02 | User | remove the hook cleanly | no leftovers remain in the agent config | **When** I click Remove **Then** only Bezelight's entries are deleted; the rest of the file stays byte-for-byte meaningful; a `.bak` copy exists | P0 |
| US-03 | User who uses Orca | install the hook without breaking Orca's hooks | the existing tool keeps working | Merge test with a fixture containing Orca entries: before and after install/remove, Orca entries are unchanged | P0 |
| US-04 | User | know whether the hook really works | I do not wrongly assume it is running | Each agent shows "Last real event: X minutes ago" or "No events received yet"; a "Send test" button checks the app side separately | P0 |
| US-05 | User | enable/disable each agent | I only get notifications from agents I care about | Disable an agent → its events are ignored immediately, no hook removal needed | P0 |

### 3.2 Core notifications

| ID | As a… | I want to… | So that… | Acceptance criteria | Priority |
|---|---|---|---|---|---|
| US-10 | User | the light to react as soon as an agent asks for permission or asks a question | the agent does not wait needlessly | **Given** an agent is running **When** an `ask` occurs **Then** within ≤ 300 ms (excluding the agent's own hook latency) the light switches to the needsInput style and holds until all of the session's requests are resolved | P0 |
| US-11 | User who is away | know the agent finished when I come back | I do not miss the result | **Given** the agent finishes while I am inactive **Then** the light holds a dim green until keyboard/mouse activity; **Given** I am typing when it finishes **Then** it fades automatically after the configured time | P0 |
| US-12 | User | a red light when the agent errors | I notice problems early | `error` → blink, then dim red glow, held until I come back | P0 |
| US-13 | User | (optional) to see when the agent is working | I know it has not hung | Off by default; when enabled, shown per the configured style and coverage, without covering ambient light outside that region | P1 |
| US-14 | User | to dismiss notifications quickly | the light does not bother me once I know | A global hotkey + a menu bar button clear the current "unseen"/"needs attention" notifications | P0 |
| US-15 | User | a session's notification to clear itself when I send a new prompt | I do not have to dismiss it manually | `working` from that session clears that session's unseen `done`/`error` | P0 |

### 3.3 Multiple sessions

| ID | As a… | I want to… | So that… | Acceptance criteria | Priority |
|---|---|---|---|---|---|
| US-20 | User running multiple sessions | the light to reflect the session needing the most attention | a single light strip is still enough | Global priority: needsInput > error > unseen done > working; a "done" session never masks a session "waiting for you" | P0 |
| US-21 | User | to distinguish "one session waiting" from "many sessions waiting" | I know how urgent it is | With 2 or more needsInput sessions, the rhythm pattern changes (double beat) | P1 |
| US-22 | User | to see the list of tracked sessions | I know which session is waiting | The menu bar and the Agents tab show: agent, project name (last component of cwd), state, time in that state | P1 |
| US-23 | User who uses subagents | not to get a "done" when only a subagent finishes | no false alerts | A subagent's `Stop`/`session.idle` does not create `done`; a subagent's permission requests still count for the parent session | P0 |
| US-24 | User | the notification to vanish when the session dies | the light does not get stuck | The app detects the agent PID is no longer alive within ≤ 10 s → removes the session; a stale timeout acts as a second safety net | P0 |

### 3.4 Customization

| ID | As a… | I want to… | So that… | Acceptance criteria | Priority |
|---|---|---|---|---|---|
| US-30 | User | to adjust the color of each event type | it fits my taste and works for color-blind users | A color picker + a few suggested colors for each event | P0 |
| US-31 | User | to choose the effect and parameters (speed, blink count, brightness) | I can tune how attention-grabbing it is | Each event has independently configurable flourish and hold phases | P0 |
| US-32 | User | to adjust notification persistence | it is neither too sticky nor too short | Choose: until resolved / until return / timed / until dismissed / once | P0 |
| US-33 | User | to choose which part of the strip is used for notifications | I do not lose all ambient light | Full strip / first N% / last N% | P1 |
| US-34 | User | to decide per event whether to alert when the lights are off | my quiet mode is respected | A separate "Alert when lights are off" flag for each event | P0 |
| US-35 | User | to preview an effect right on the LED strip | I see the result before saving | A "Preview" button plays flourish + hold for ~5 s, then restores the previous mode | P0 |
| US-36 | User | to restore defaults | I can fix things after over-tweaking | A "Restore defaults" button per event and globally | P0 |
| US-37 | User | to turn off "I'm back" detection | I stay fully in manual control | A "Presence detection" switch; when off, `done` falls back to the persistence the user chose | P1 |

### 3.5 Non-functional

| ID | Requirement | Criteria |
|---|---|---|
| NF-01 | Hooks do not break the agent | In every case (app closed, socket error, odd JSON) the helper exits 0 and writes nothing to stderr; median run time ≤ 20 ms |
| NF-02 | Performance | With no notifications: no extra CPU compared to today. With notifications: ≤ 3% additional CPU on an M2 |
| NF-03 | Privacy | Do not store or forward prompts, reply contents, or full paths off the machine; diagnostic logs contain only the event type |
| NF-04 | Local safety | Socket permissions 0600, located in the user's directory; payload size is limited, and parse failures are ignored |
| NF-05 | Multilingual | Every UI string is available in all 5 languages (en, vi, zh-Hans, ja, ko) |
| NF-06 | Compatibility | macOS 14+; old configurations (without the new keys) still load |

---

## 4. Real-world scenario analysis (multiple sessions)

| # | Scenario | Problem | Design decision |
|---|---|---|---|
| T1 | Multiple sessions of the same agent (3 Claude tabs, 3 repos) | The strip has only one color | Show the **globally highest-priority state**. Per-session details are in the menu bar / Agents tab |
| T2 | Mixed agents | One session finishes while another awaits approval | `done` does not mask `needsInput`. When needsInput is resolved, the light moves to the next-highest-priority state |
| T3 | Subagents | A subagent finishing ≠ the whole turn finishing; a subagent asking for permission blocks the parent session | Claude: **register** `SubagentStart/Stop`; subagent events carry the parent session's `session_id` plus `agent_id`, so they merge naturally; `done` is held until subagents are gone (rule 6). Codex: no subagent events seen in the trial run. OpenCode: child sessions are mapped to the **root session** via `parentID`; a child session ending is `substop`, not `done`; a child session's `permission.asked` still counts for the root session |
| T4 | Multiple permission requests/questions at once in one session (OpenCode runs in parallel) | Answering one does not mean the wait is over | Each session keeps a **set of pending `requestID`s**. Leave needsInput only when the set is empty |
| T5 | Claude/Codex have no "permission answered" event | needsInput gets stuck | Any subsequent event of the same session (`PostToolUse`, `PostToolUseFailure`, `Stop`, `UserPromptSubmit`) clears needsInput. Hence `PostToolUse` and `PostToolUseFailure` must be registered |
| T6 | `Notification(permission_prompt)` and `PermissionRequest` report the same thing | Duplicate alerts | Idempotent by session state (already needsInput → ignore). **Do not** register `idle_prompt` (it reminds again after completion, causing repeat alerts) |
| T7 | Async hooks run in parallel | `Stop` may arrive before a concurrently produced `PostToolUse` → "working" gets stuck | The helper stamps the **start-of-run timestamp** (`ts`, ms). The tracker drops events whose `ts` is older than the last applied event of the same session. On equal `ts`, the terminating event (`done/error/end/interrupt`) wins |
| T8 | Interrupt (Esc/Ctrl-C), terminal closed, process killed | Claude does not fire `Stop` on interrupt → stuck working/needsInput | **Process liveness check**: the helper records the agent PID (walking up the process tree); the app checks periodically, a dead PID → remove the session. Safety net: stale timeout. Codex has `Interrupt`, handled directly |
| T9 | You are away, the agent finishes | If it only blinks briefly, you never see it | `done` is an **unseen** state (D1): hold a dim green until HID activity after the finish time |
| T10 | You are typing exactly when the agent finishes | Holding "unseen" is redundant | If HID idle < `activeGraceSec` at `done` → treat you as present, fade automatically after `presentFadeSec` |
| T11 | Mac sleeps / screen locks | The pipeline stops during sleep | The tracker still receives events; on wake the overlay shows the state that exists |
| T12 | Lights off or strip not connected | Nowhere to display | Follow each event's "Alert when lights are off" flag (D2). With no strip, update the menu bar icon and the list |
| T13 | App starts after the agent | Old session state is lost | Accepted: only sessions with events since the app started are visible |
| T14 | `/clear`, resume, compact | Stale state lingers | `SessionStart(source=clear/startup/resume)` sets the session to idle; compact does not change state |
| T15 | Hook installed but not yet effective | Codex needs `/hooks` trust; Claude needs a session restart; OpenCode needs a restart | Show "last real event" and per-agent activation instructions (US-04) |
| T16 | Orca hooks already exist on the same event | Overwriting would break Orca | Merge by the `bezelight-hook` marker, Orca fixture test (US-03) |
| T17 | Two instances of the same agent in the same directory | Duplicate `cwd` | The session key is `(agent, sessionID)`, not `cwd` |
| T18 | A resumed session reuses its `session_id` | Two records for one session | Same key → same record; `SessionStart(resume)` resets to idle |
| T19 | OpenCode `session.retry.scheduled` (retry after a transient error, for example a rate limit) | May look like a hang | Treat as `working` (the agent is retrying itself); if `session.execution.failed` eventually occurs, then `error`. The `retry.scheduled` payload needs confirmation |
| T20 | Agent running over SSH/container | The hook cannot reach the socket | Out of scope for v1 (Backlog) |
| T21 | Claude: deny or Esc at the permission box | **No hook at all** (measured); the `needsInput` light is stuck until the next input | Track transcript growth (7.6), emit `answered`, then drop to unconfirmed `working` → `idle` after `confirmSec` (rule 7) |
| T22 | Claude: the main session's `Stop` fires while a background subagent is still running, and the subagent asks for permission afterwards | `done` is reported early and then must change to `needsInput` | Hold `done` until subagents are gone (rule 6); `SubagentStop` cleans up the subagent's requests (rule 5) |
| T23 | Claude has an "internal" `SubagentStop` (empty `agent_type`, no `SubagentStart`) | May be misread as the end of a subagent | Ignore `substop` for an ID that never had `substart` (rule 5) |
| T24 | Codex: deny/Esc | No `Stop` | `Interrupt` closes the request and returns to `idle` (rule 8) |
| T25 | OpenCode: permission denied | Chain `replied(reject)` → `tool.failed` → `execution.interrupted(shutdown)` | `answered` then `interrupt` → `idle`, no `error` alert |
| T26 | OpenCode: provider error (quota/429) | Must be distinguished from an interrupt | `session.execution.failed` → `error`; `interrupted` → `idle` |

---

## 5. Research on each agent's mechanism

### 5.1 Claude Code
- Configuration: `~/.claude/settings.json`, key `hooks` → `<Event>` → array of groups `{matcher?, hooks:[{type:"command", command, async?, timeout?}]}`.
- Common stdin JSON: `session_id`, `transcript_path`, `cwd`, `permission_mode`, `hook_event_name`; tool events add `tool_name`, `tool_input`; inside a subagent there are `agent_id`/`agent_type`.
- Events used: `SessionStart`, `UserPromptSubmit`, `PermissionRequest`, `Notification` (matcher `notification_type`), `PostToolUse`, `PostToolUseFailure`, `Stop`, `StopFailure`, `SessionEnd`.
- `Notification` has `message`, `title`, `notification_type` (`permission_prompt`, `idle_prompt`, `elicitation_dialog`, `agent_needs_input`, …). Only take `permission_prompt|elicitation_dialog|agent_needs_input`.
- `async: true` runs in the background without blocking the agent. `exit 2` can block an action, so the helper **never** returns exit 2.
- Hooks are loaded when a session starts: an already open session does not see new hooks.
- Hooks from all levels (user, project, local) **accumulate**; they do not replace each other.

### 5.2 Codex
- Configuration: `~/.codex/hooks.json` (or `[[hooks.*]]` in `config.toml`; **do not use TOML**, to avoid editing a file that holds many other things). Likewise at repo level, `<repo>/.codex/`.
- Events: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `PreCompact`, `PostCompact`, `SubagentStart`, `SubagentStop`, `Stop`, `Interrupt`, `SessionEnd`.
- Common stdin: `session_id`, `transcript_path`, `cwd`, `hook_event_name`, `model`; per-turn events add `turn_id`. `Stop` has `last_assistant_message`. `PermissionRequest` has `tool_name`, `tool_input`.
- **Strict requirements**: on exit 0, `Stop` must print **JSON** (plain text is invalid); `PermissionRequest` may only decide through `hookSpecificOutput`, and with no decision the normal approval flow runs. The helper always prints `{}`.
- **Trust**: a non-"managed" hook must be reviewed and trusted (`/hooks`); trust is tied to a **hash**, so editing the file loses trust. Repo-level hooks load only when the repo is trusted.
- `notify` in `config.toml` (`agent-turn-complete`) is **not used**: it has only one slot and this machine already uses it for Computer Use.
- Hooks are on by default (`[features] hooks = false` to turn them off).

### 5.3 OpenCode (2.0.x)
- **2.0 architecture (verified on this machine):** OpenCode runs a **shared background service** (`opencode serve --service`) serving every client (TUI, `opencode run`, apps). Connection info lives in `~/.local/state/opencode/service.json` (`url`, `pid`, `version`, `password`). The service listens on `127.0.0.1` and authenticates with **HTTP Basic** (user `opencode`, password from that file).
- **Native event stream: `GET /api/event`** (SSE, `text/event-stream`). It delivers events for **all sessions and all directories** at once, with nothing to install into OpenCode. (The `/event` and `/global/event` paths return an HTML web page and are unusable.)
- Event envelope: `{"id","created"(ms),"type","location":{"directory"}?,"data":{...},"durable"?}`. The first event is `server.connected`.
- **Events captured on this machine (OpenCode 2.0.28, model `opencode/longcat-2.5-preview-free`):**

| Event | `data` (observed) |
|---|---|
| `session.created` | `sessionID`, `slug`, `version`, `projectID`, `location{directory}`, `subpath`, `model` |
| `session.execution.started` | `sessionID` (a run starts) |
| `session.execution.succeeded` | `sessionID` (a run finishes) |
| `permission.asked` | `id`, `sessionID`, `action` (for example `"shell"`), `resources[]` (for example `["echo hi-probe"]`), `save[]`, `source{type:"tool", messageID, id}` |
| `permission.replied` | `sessionID`, `requestID`, `reply` (`once`/`always`/`reject`) |
| `session.tool.failed` | `sessionID`, `id`, `error{type:"permission.rejected", message}` |
| `session.renamed`, `session.usage.updated`, `session.step.*`, `session.text.*`, `session.reasoning.*`, `session.tool.*`, `shell.*` | internal progress within a run (not used) |

- **Names present in the 2.0.28 binary but with no real payload captured yet:** `session.execution.failed` (error), `session.execution.interrupted` (interrupted), `session.retry.scheduled` (retry), `permission.rejected`, `session.interrupt`. A real trigger (causing an error, interrupting mid-run, forcing a retry) is needed to confirm the payloads.
- **The agent's questions are `form.created`/`form.replied`** (verified; `question.asked` belongs to the old SDK and does not appear on the native stream). `form.created` has `form{id, sessionID, title, metadata{kind:"question", tool}}`; `form.replied` has `id`, `sessionID`, `answer`. `form.rejected`/cancel has not been captured.
- **Note on non-interactive mode:** `opencode run` (without `--auto`) automatically rejects permission requests (`permission.asked` then `permission.replied reply=reject` within a few ms). Only the interactive TUI keeps `permission.asked` open waiting for the user.
- **Two schemas coexist:** the legacy events (`session.idle`, `session.status`, `session.error`, `permission.updated`) belong to the v1 stream/SDK; the native 2.0 stream uses `session.execution.*`. Bezelight uses the **native** stream as the primary source; the mapping table can accept both names for compatibility.
- **The JS/TS plugin (docs: `.opencode/plugins/`) did not load on 2.0.28** in testing (not even a `plugin.init` line), so it is **not used** as the primary path. The SSE stream does not depend on it.
- **Child sessions (subagents): verified.** A child session's `session.created` has `parentID`, `title`, `agent:"general"`; the child session has its own `session.execution.*`, and `permission.asked` carries the child session's `sessionID`; the child session ends before the parent.

### 5.4 Capability comparison

| Capability | Claude Code | Codex | OpenCode |
|---|---|---|---|
| Precise "needs your answer" signal | Yes (`PermissionRequest`, including `AskUserQuestion`) | Yes | Yes (`permission.asked`, `form.created`) |
| "Answered" signal | Allow: `PostToolUse`. **Deny/Esc: no hook** (use the transcript) | Allow: `PostToolUse`; deny/Esc: `Interrupt` | Yes (`permission.replied`, `form.replied`) |
| "Done" signal | `Stop` | `Stop` | `session.idle` |
| "Error" signal | `StopFailure` (not captured yet) | None | `session.execution.failed` (`error.type`, `status`) |
| "Interrupt" signal | None (use transcript/PID) | `Interrupt` | `session.execution.interrupted` (`reason`) |
| Subagent distinction | `agent_id` + `SubagentStart/Stop` | Not seen yet | `parentID` (verified) |
| Activation requirement | Restart the session (hook) | `/hooks` trust (hook) | None: the app connects to SSE by itself |

---

## 6. Event normalization

### 6.1 Wire format v1

One Unix datagram, UTF-8, a single JSON object, **≤ 1024 bytes**:

```json
{"v":1,"agent":"claude","kind":"ask","session":"0a1b2c","req":null,
 "cwd":"/Users/me/work/app","pid":48213,"ts":1760000000123,"src":"PermissionRequest"}
```

| Field | Type | Required | Meaning |
|---|---|---|---|
| `v` | int | yes | Format version, currently 1 |
| `agent` | `claude` \| `codex` \| `opencode` | yes | Source |
| `kind` | enum below | yes | Normalized event type |
| `session` | string | yes | ID of the **root** session (OpenCode: already mapped to the root session) |
| `req` | string \| null | no | `requestID` (OpenCode `ask/answered` only) |
| `cwd` | string | no | Working directory; the app uses only the last path component for display |
| `pid` | int | no | PID of the agent process, for liveness checks |
| `ts` | int (ms epoch) | yes | The moment the helper **started running** (used for ordering) |
| `sub` | string \| null | no | ID of the subagent that emitted the event (Claude: `agent_id`; OpenCode: child session ID). Used for `substart`/`substop` and to attribute the source of an `ask` |
| `tp` | string \| null | no | Transcript path, **only** for Claude's `ask`, so the app can watch for growth (7.6). The app only `stat`s/reads the appended portion in memory, without storing or logging it |
| `src` | string | no | Original event name, for diagnostics only |

`kind`: `start`, `working`, `ask`, `answered`, `done`, `error`, `interrupt`, `end`, `substart`, `substop`, `seen`.

The helper does **not** forward: prompt contents, `last_assistant_message`, `tool_input`, `tool_response`. `transcript_path` accompanies only Claude's `ask` (field `tp`).

### 6.2 Mapping table: native event → normalized

| `kind` | Claude Code | Codex | OpenCode (2.0, native SSE stream) |
|---|---|---|---|
| `start` | `SessionStart` | `SessionStart` | `session.created` (root session, no `parentID`) |
| `working` | `UserPromptSubmit`, `PostToolUse`, `PostToolUseFailure` | `UserPromptSubmit`, `PostToolUse` | `session.execution.started` (root session), `session.retry.scheduled` (not captured yet) |
| `ask` | `PermissionRequest` (including `AskUserQuestion`; has `agent_id` if from a subagent); `Notification` of type `elicitation_dialog`/`agent_needs_input` | `PermissionRequest` | `permission.asked`, `form.created` (`metadata.kind="question"`); `sub` = the session ID if it is a child session |
| `answered` | — (inferred from the next event or the transcript, 6.4 and 7.6) | — (inferred from the next event, or `Interrupt`) | `permission.replied`, `form.replied` (`form.rejected` not captured yet) |
| `done` | `Stop` | `Stop` | `session.execution.succeeded` of the root session |
| `error` | `StopFailure` (not captured yet) | — | `session.execution.failed` (`error{type,message,status}`) |
| `interrupt` | — (see 7.6) | `Interrupt` | `session.execution.interrupted` (`reason`: `user` \| `shutdown`) |
| `end` | `SessionEnd`, `SessionStart` (clear) | `SessionEnd`, `SessionStart` | `session.deleted` (not captured yet) |
| `substart` | `SubagentStart` (`agent_id`) | — | `session.created` of a child session (`parentID`) |
| `substop` | `SubagentStop` (`agent_id`) | — | `session.execution.succeeded/failed/interrupted` of a child session |
| `seen` | — | — | `session.viewed` (the user viewed the session in the TUI) |

Notes:
- `SessionStart(source=clear)` and `startup/resume` set the session to `idle` (see 6.4). `compact` does not change state.
- For Claude/Codex there is no "answered" event. Codex: `Interrupt` (deny/Esc) or `PostToolUse` (allow) closes the request. Claude: `PostToolUse` on allow, but on deny/Esc there is **no hook at all**, so transcript tracking is used (7.6).
- `Notification(permission_prompt)` is **not registered**: it arrives about 6 s after `PermissionRequest` and is redundant.
- For OpenCode, a child session is treated as a **subagent of the root session** (same mechanism as Claude's `SubagentStart/Stop`): the app keeps a `sessionID → parentID` table from `session.created` (verified to carry `parentID`). A child session's events are mapped to the root session's ID; a child's `session.execution.started` is `substart`, and a child's end is `substop` (not `done`). A child session's `permission.asked` still counts as `ask` for the root session.

### 6.3 Session state model

Session key: `(agent, session)`.

```
Session {
  agent, session, project(last path component), pid?
  state:  idle | working | needsInput | done | error
  pending: Set<requestID | "implicit">     // outstanding requests (needsInput)
  seen:   Bool                              // only meaningful for done/error
  lastTs: Int64                             // ts of the most recently applied event
  since:  Date                              // when the current state was entered
  doneAt: Date?                             // used to compute "came back"
  presentAtDone: Bool                       // you were present when it finished (HID idle < activeGraceSec)
  activeSubs: Set<String>                   // running subagents (SubagentStart / OpenCode child sessions)
  mainStopped: Bool                         // main session reported done but subagents are still running
  askOrigin: [requestKey: String?]          // which request came from which subagent
  transcript: String?                       // transcript path (Claude), for tracking (7.6)
  unconfirmedSince: Date?                   // entered "unconfirmed" working state after the transcript grew
}
```

### 6.4 State transition table

| From \ Event | `start` | `working` | `ask` | `answered` | `done` | `error` | `interrupt` | `end` |
|---|---|---|---|---|---|---|---|---|
| (none) | idle | working | needsInput | — | done | error | — | — |
| idle | idle | working | needsInput | — | done | error | idle | remove |
| working | idle | working | needsInput | working | done | error | idle | remove |
| needsInput | idle | working¹ | needsInput (add req) | if `pending` is empty → working, otherwise keep | done | error | idle | remove |
| done | idle | working² | needsInput | — | done | error | idle | remove |
| error | idle | working² | needsInput | — | done | error | idle | remove |

¹ For Claude/Codex, `working` from a needsInput session means it was answered (rule T5): clear `pending`.
² `working` clears the session's own unseen flag for `done`/`error` (US-15).

Cross-cutting rules:
1. **Ordering (T7)**: drop an event if `event.ts < session.lastTs`. On equal `ts`, a terminating event (`done/error/end/interrupt`) wins over `working`.
2. **"Unseen" state**: `done` and `error` carry `seen=false` until (a) there is HID activity after `doneAt`, or (b) the user dismisses it, or (c) it expires per the configured persistence, or (d) the session gets a new `working`.
3. **Safety expiry**: `working` with no event for longer than `staleWorkingSec` → idle; `needsInput` longer than `staleNeedsInputSec` → idle; dead PID → remove the session.
4. **All computation is a pure function** `reduce(state, event, now, presence) -> state`.
5. **Subagents (real data)**: `substart(sub)` adds to `activeSubs`. `substop(sub)` removes from `activeSubs` and removes every `ask` request whose source is `sub`; a `substop` for an ID not in `activeSubs` (Claude's "internal" subagent, empty `agent_type`, no `SubagentStart`) is ignored.
6. **`done` is held while subagents remain**: Claude fires the main session's `Stop` **while background subagents are still running**, and a subagent may still ask for permission afterwards. If `Stop` arrives while `activeSubs` is non-empty → set `mainStopped = true` and keep the `working` state (or `needsInput` if there are requests). Only when `activeSubs` is empty and no requests remain → enter `done`. Bounded by `subagentHoldSec` (default 300 s): once exceeded, enter `done` even if the subagent has not reported stopping, to avoid getting stuck when `SubagentStop` is lost.
7. **Claude deny/Esc has no hook (real data)**: `TranscriptWatcher` (7.6) emits `answered` when the transcript grows after an `ask`. The session moves to "unconfirmed" `working` (`unconfirmedSince`); if no hook event arrives within `confirmSec` (default 45 s) it returns to `idle` (the case where it was denied and Claude stopped). Any hook event during that time confirms the normal state.
8. **Codex `interrupt`** clears every `ask` request and returns the session to `idle` (matches real data: both deny and Esc produce only `Interrupt`, with no `Stop`).
9. **OpenCode `seen`** (`session.viewed`) arriving after the root session's `doneAt`/`errorAt` is treated as "came back": set `seen = true`, independent of HID detection. It can be toggled in configuration (`presence.useAgentSeen`).

### 6.5 Global display state

Priority (high → low): `needsInput` > `error` (unseen) > `done` (unseen) > `working` > none.

- Pick the state of the highest-priority event existing on **any session of an enabled agent**.
- `needsInput` on 2 or more sessions (or 2 `pending` entries from different sessions) → apply `multiPattern` (see section 8).
- When the displayed state changes, crossfade for `crossfadeMs`.

---

## 7. Architecture

```
Claude/Codex hook ──► bezelight-hook ──► unix datagram (0600)
                                         ~/.bezelight/agent.sock
                                                 │
                                   AgentHookServer (app, DispatchSource) ─┐
OpenCode SSE (/api/event) ──► OpenCodeStreamClient (app) ────────────────┤
Claude transcript (growth) ──► TranscriptWatcher (app) ──────────────────┤
                                                                          ▼  AgentEvent
                                                         AgentTracker (BezelightCore, pure)
                                                                          │  display state + configuration
                                                   AppModel ──► LightPipeline.setAgentOverlay(...)
                                                                          │
                                                   AgentOverlay (renderer) ──► DeviceManager.submit
```

### 7.1 Components and locations

| Component | Purpose | Location |
|---|---|---|
| `AgentEvent`, `AgentKind`, `AgentState` | Data types + wire decoding | `Sources/BezelightCore/AgentEvent.swift` |
| `AgentTracker` | Pure state machine (6.3–6.5) | `Sources/BezelightCore/AgentTracker.swift` |
| `AgentAlertSettings` | Codable configuration (section 8) | `Sources/BezelightCore/AgentAlertSettings.swift` |
| `AgentOverlay` | Produces color frames from state + configuration + time | `Sources/BezelightCore/AgentOverlay.swift` |
| `PresenceProvider` (protocol) | Supplies HID idle; the real implementation uses `CGEventSource`, a fake one is used in tests | Core (protocol) + App (implementation) |
| `AgentHookServer` | Socket server receiving datagrams | `Sources/BezelightCore/AgentHookServer.swift` |
| `OpenCodeStreamClient` | SSE client for the OpenCode background service, maps to `AgentEvent` (9.4) | `Sources/BezelightCore/OpenCodeStreamClient.swift` |
| `TranscriptWatcher` | Emits `answered` when the Claude transcript grows after an `ask` (7.6) | `Sources/BezelightCore/TranscriptWatcher.swift` |
| `AgentInstaller` (pure merge logic) | Install/remove/status of hooks for the 3 agents | `Sources/BezelightCore/AgentInstaller.swift` (file I/O lives in App) |
| `bezelight-hook` | CLI helper | New target `Sources/BezelightHook/main.swift` |
| UI | Agents tab, menu bar | `Sources/Bezelight/AgentSettingsView.swift`, `AppModel+Agents.swift`, edit `MenuBarView.swift`, `SettingsView.swift` |
| Pipeline integration | Overlay drawn over the base frame | Edit `LightPipeline.swift` |

### 7.2 `LightPipeline` integration

- Add `setAgentOverlay(_ plan: OverlayPlan?)`, similar to `showTestPattern`.
- In `tick`: compute the base frame as today (or reuse the most recent frame if the base is already stable), then **blend the overlay** by region and intensity. The optimization `if engine.isSettled && !dirty { return }` must **not** block a running overlay.
- If `powered == false` and the current overlay has the "alert when lights are off" flag: the base is black, and frames are still sent. Capture stays off, so no extra measurement resources are spent.
- When the overlay ends: set `dirty = true` to return to the previous mode.
- The overlay runs at ~30 Hz **only while active**; a static effect (`solid`) emits one frame and then rests.

### 7.3 Transport: why a Unix datagram

| Option | Verdict |
|---|---|
| **Unix datagram socket (chosen)** | No network port, per-user permissions, does not block when the app is closed (sending fails silently), low latency |
| HTTP localhost (Claude's `http` hook) | Needs a port + token, any local process can call it, does not cover Codex/OpenCode |
| File writes + FSEvents | Slow, easy to miss events, hard to order |
| Codex `notify` | Only one slot (already taken), only a "done" event |

The default macOS datagram limit is ~2 KB (`net.local.dgram.maxdgram`), so a normalized payload of ≤ 1 KB is enough.

### 7.4 Process liveness check (T8)

- The helper walks up the process tree from itself (`sysctl KERN_PROC_PID`) to find the **nearest ancestor that is not a shell** (`sh`, `bash`, `zsh`, `env`, …). **Do not match by name**: Phase 0 showed Claude's process name is a version number (`2.1.296`), and Claude often runs through a wrapper (`cca`). For Claude, the hook's `PPID` is the agent process itself. If none is found, leave `pid` empty. OpenCode has **no per-session PID** (all sessions run in one background service): see 9.4.
- The app checks `kill(pid, 0)` every `livenessIntervalSec`. Not alive → treat as `end`.
- Applies only to sessions with a `pid` (Claude, Codex). OpenCode sessions rely on the SSE connection state and the stale timeout.

### 7.5 "Came back" detection (presence)

- `PresenceProvider.idleSeconds()` relies on `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: …)` (to be confirmed in Phase 0 that it does not require the Accessibility permission).
- At `done`: if `idle < activeGraceSec` → `presentAtDone = true` (fades automatically after `presentFadeSec`). Otherwise → "unseen" until there is activity (HID idle drops below the time elapsed since `doneAt`).
- Checked at 1 Hz and **only when** an unseen notification exists (costs nothing when idle).

---

### 7.6 Tracking the Claude transcript (when deny/Esc has no hook)

Measured: after `PermissionRequest`, if the user denies or presses Esc, Claude **fires no hook** but immediately writes to the transcript file (an error `tool_result` line, an "interrupted" text line, a system line) within ~4 s of the prompt.

- `TranscriptWatcher` runs only for Claude sessions that are `needsInput` and have `tp`. It uses `DispatchSource.makeFileSystemObjectSource(.extend/.write)` (or periodic `stat` every 1 s if opening fails).
- When the file is larger than its size at `ask`: read **only the appended portion** in memory, look for the `"tool_result"` marker; if found, emit `answered`. Nothing is stored, logged, or sent anywhere.
- After a transcript-driven `answered`: the session enters unconfirmed `working` (rule 7).
- Risk: the transcript may also grow because of other work while waiting (parallel subagents, parallel tools). Mitigation: require a `tool_result`; if wrong, it only turns the light off early, and the next `PermissionRequest` turns it back on.
- Stop tracking when the session leaves `needsInput`, on `SessionEnd`, and when the file disappears.

## 8. User configuration (every option in detail)

Stored separately from `StreamSettings` (key `agents.v1` in `UserDefaults` via `Store`), because changing notification settings must not trigger `pipeline.apply`. Every key is optional when decoding so that older versions still load.

### 8.1 General settings

| Key | Type | Default | Detailed description |
|---|---|---|---|
| `enabled` | Bool | `true` | Master switch. Off: nothing is displayed and no events are processed (hooks remain in the agent config but the app ignores them). |
| `agents.claude.enabled` | Bool | `true` | Whether to receive notifications from Claude Code. Off only ignores this agent's events; it does not remove the hook. |
| `agents.codex.enabled` | Bool | `true` | Same as above, for Codex. |
| `agents.opencode.enabled` | Bool | `true` | Same as above, for OpenCode. |
| `presence.enabled` | Bool | `true` | **Presence detection.** On: keyboard/mouse activity is used to know you have come back (clearing "unseen" notifications) and to know you were present when the agent finished. Off: HID is not measured; unseen notifications go away only per the persistence you chose (timed or manual dismissal). |
| `presence.activeGraceSec` | Double (seconds) | `5` | If you were active within this window when the agent finished, you are treated as **present**: no need to hold "unseen", it just fades. Increase this if you often read the screen without typing. Range 1–60. |
| `presence.presentFadeSec` | Double (seconds) | `8` | For the "present" case above, how long the dim green glow is held before turning off. Range 1–60. |
| `multiPattern` | enum | `doubleBeat` | How to distinguish **multiple sessions needing attention at once** (see 8.4). |
| `crossfadeMs` | Int | `250` | Duration of the smooth transition between two display states. 0 = instant switch. Range 0–1000. |
| `minBrightness` | Double 0–1 | `0.4` | Minimum strip brightness **while a notification is displayed**, even if your global brightness is set lower. The purpose is that an alert is not lost when you keep the strip very dim. Set 0 to always follow global brightness. |
| `reduceFlashing` | Bool | `false` | Replaces every blink/pulse effect with slow smooth breathing. Always on when macOS *Reduce Motion* is on. For people sensitive to flashing light. |
| `diagnostics.log` | Bool | `false` | Enables an in-memory event log (event types only, no content) for diagnostics; nothing is written to disk unless you export it. |
| `overlayBrightness` | Double 0–1 | `1.0` | Maximum brightness factor for all notifications, multiplied by the strip's overall brightness. Reduce it if it is glaring at night. |
| `dismissHotkey.enabled` | Bool | `true` | Enables the global "dismiss notifications" hotkey. The specific key is chosen at implementation time so it does not collide with `HotKeys.swift`. |
| `stale.workingSec` | Int | `600` | A `working` session with no events in this window is considered hung/dead and returned to idle. Range 60–7200. |
| `stale.needsInputSec` | Int | `1800` | Same for `needsInput`. Range 120–14400. |
| `liveness.intervalSec` | Int | `5` | Interval for checking that the agent PID is alive. Range 2–60. |
| `subagentHoldSec` | Int | `300` | When the main agent reports done but subagents are still running, the light does not yet report "Done" and waits for the subagents. If this time is exceeded and the subagent still has not stopped, "Done" is reported anyway. Increase it if you use background subagents that run very long. Range 10–3600. |
| `confirmSec` | Int | `45` | After the system guesses that you denied (Claude does not report it; only the transcript change is seen), the session stays in an "uncertain" state for this window; if no signal arrives, the session is considered stopped. Range 10–300. |
| `presence.useAgentSeen` | Bool | `true` | For OpenCode, use OpenCode's own "session viewed" signal to clear "unseen" notifications instead of relying only on keyboard/mouse. Turn off if you want to use activity detection only. |

### 8.2 Default values

| Event | Enabled | Color | Flourish | Hold | Persistence | Coverage | Alert when lights are off |
|---|---|---|---|---|---|---|---|
| **needsInput** | yes | Amber `#FFAA00` | blink 2 times, 0.5 s period | breathe, 1.6 s period, 100% intensity | until resolved | full strip | **yes** |
| **error** | yes | Red `#FF2828` | blink 3 times, 0.4 s period | solid, 30% intensity | until return | full strip | **yes** |
| **done** | yes | Green `#28DC64` | blink 2 times, 0.4 s period | solid, 25% intensity | until return | full strip | no |
| **working** | **no** | Cyan `#00C8FF` | none | breathe, 2.4 s period, 40% intensity | while working | first 10% of the strip | no |

### 8.3 Per-event configuration (`needsInput`, `error`, `done`, `working`)

Each event has the same set of options:

| Key | Type / values | Detailed description |
|---|---|---|
| `enabled` | Bool | Whether this event type is displayed. Turning off `done` means only needsInput/error are on. Turning off `needsInput` is not recommended because it removes the main function. |
| `color` | RGB | The event's color. Used for both flourish and hold. Suggestions: amber for attention, red for errors, green for done, cyan for working. For people who have trouble distinguishing red/green, change `done` to cyan or white. |
| `flourish.effect` | enum | The **flourish phase**, run once when the event begins to grab attention. Values: `none` (skip), `blink` (on/off blink), `pulse` (one smooth pulse), `flash` (one harsh bright flash, then off). |
| `flourish.count` | Int 1–10 | Number of `blink`/`pulse` repetitions. Does not apply to `none`/`flash`. |
| `flourish.periodSec` | Double 0.1–3 | Duration of **one cycle** of the flourish (on + off). Smaller = faster, harsher. |
| `hold.effect` | enum | The **hold phase**, which lasts after the flourish. Values: `none` (fully off after the flourish), `solid` (steady light), `breathe` (bright–dim breathing), `blink` (steady blink), `comet` (a light spot running along the strip). |
| `hold.intensity` | 0–1 | Brightness of the hold phase, relative to strip brightness. For `breathe`/`blink` this is the peak brightness. Keep it low (0.2–0.3) for `done` so it is not bothersome when it is merely "unseen". |
| `hold.periodSec` | Double 0.3–10 | Period of `breathe`/`blink`, or the time of one lap of `comet`. Does not apply to `solid`. |
| `persistence` | enum | **Persistence**: when the notification disappears. `untilResolved` (until the request is answered; only suitable for needsInput), `untilReturn` (until keyboard/mouse activity afterwards), `timed` (after `timeoutSec`), `untilDismissed` (until you dismiss it manually), `once` (run only the flourish and then turn off, no hold). |
| `timeoutSec` | Int 1–3600 | Used only when `persistence = timed`. Number of seconds to keep the notification. Also serves as an upper bound if you want to prevent it from lingering too long. |
| `coverage` | enum | The **part of the strip** used for the notification. `full` (whole strip), `start` (first N% of LEDs), `end` (last N% of LEDs). The rest still shows the current mode (ambient/effect), so `working` should use a small region. |
| `coveragePercent` | Int 5–100 | N% for `start`/`end`. Does not apply to `full`. |
| `alertWhenLightsOff` | Bool | When you have turned the **lights off** (button/hotkey/menu), whether this event type is still displayed. On: the light temporarily turns on for the notification over a black background. Off: completely silent while the lights are off. Default on for needsInput/error, off for done/working. |
| `perAgent.<agent>` | Bool | (Advanced option) Allow this event type from each agent individually. By default it follows the agent switch. |

**Flicker safety (mandatory):** `flourish.periodSec` and `hold.periodSec` (when `blink`) are clamped to **≥ 0.34 s** (≤ 3 flashes per second, per WCAG 2.3.1), and `flourish.count` ≤ 10. When the system has *Reduce Motion* on (or the `reduceFlashing` option is on), every `blink/flash/pulse` is replaced by smooth breathing with a period ≥ 2 s.

Validation constraints on save: `persistence = untilResolved` is valid only for `needsInput`; `flourish.effect = none` together with `hold.effect = none` would make the event invisible, so the UI warns.

### 8.4 Rhythm pattern when multiple sessions need attention (`multiPattern`)

| Value | Description |
|---|---|
| `none` | No distinction: one or many sessions keep the chosen `hold` style. |
| `doubleBeat` (default) | With 2 or more `needsInput` sessions, the hold phase changes to a double beat "thump-thump … rest", making it easy to tell that multiple things are waiting. |
| `faster` | Halves the `hold.periodSec` period when 2 or more sessions are waiting. |

### 8.5 Data model (Codable, suggested)

```swift
public struct AgentAlertSettings: Codable, Sendable, Equatable {
    public var enabled = true
    public var agents: [AgentKind: Bool] = [.claude: true, .codex: true, .opencode: true]
    public var presence = PresenceSettings()
    public var multiPattern: MultiPattern = .doubleBeat
    public var crossfadeMs = 250
    public var overlayBrightness = 1.0
    public var dismissHotkeyEnabled = true
    public var stale = StaleSettings()
    public var needsInput = EventStyle.defaultNeedsInput
    public var error      = EventStyle.defaultError
    public var done       = EventStyle.defaultDone
    public var working    = EventStyle.defaultWorking
}

public struct EventStyle: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var color: LEDColor
    public var flourish: Flourish      // effect, count, periodSec
    public var hold: Hold              // effect, intensity, periodSec
    public var persistence: Persistence
    public var timeoutSec: Int
    public var coverage: Coverage      // full | start | end
    public var coveragePercent: Int
    public var alertWhenLightsOff: Bool
}
```

---

## 9. Hook installation spec (installer)

### 9.1 General principles
1. **Detection**: an agent is "present on the machine" if its binary or config directory is found (`claude`, `codex`, `opencode`).
2. **Status**: `Not installed` / `Installed` / `Partially installed` (missing events) / `Needs activation` (installed but no real event received yet).
3. **Back up** to `*.bak-bezelight` before the first write for each file.
4. **Atomic writes** (write a temp file, then rename), preserving file permissions.
5. **Idempotent**: running install twice creates no duplicates.
6. **Marker**: Bezelight entries are identified by the string `bezelight-hook` in `command`. Removal deletes only entries with the marker; groups/keys that become empty are deleted as a result.
7. The helper is **copied** to `~/.bezelight/bin/bezelight-hook` (a stable path **without spaces**, so moving the app does not break hooks). Update the helper when the app is upgraded.
8. JSON must **preserve** unrelated parts (including key order where possible).

### 9.2 Claude Code: `settings.json` of each config directory

**Multiple config directories (found in Phase 0).** Claude reads configuration from `$CLAUDE_CONFIG_DIR` if set, otherwise `~/.claude`. On this machine `CLAUDE_CONFIG_DIR=~/.claude-accounts/work`, and `~/.claude-accounts/work/settings.json` has **no hooks**, so a hook installed into `~/.claude/settings.json` would not run for the session in use. Therefore the installer must:
- List candidate directories: `~/.claude`, `$CLAUDE_CONFIG_DIR`, and every `~/.claude-accounts/*/` that has `settings.json` or other signs of being a Claude config directory.
- Let the user **choose which ones to install into** (by default, select the directory in use per `$CLAUDE_CONFIG_DIR` and `~/.claude`), with status shown per directory.
- The "last event" memory is also per directory (inferred from `transcript_path` in the payload).

Events to add (one group per event, `async: true`, short `timeout`):

| Event | Matcher |
|---|---|
| `SessionStart` | (none) |
| `UserPromptSubmit` | (none) |
| `PermissionRequest` | `*` |
| `Notification` | `elicitation_dialog\|agent_needs_input` (`permission_prompt` is not registered: redundant and ~6 s late) |
| `PostToolUse` | `*` |
| `PostToolUseFailure` | `*` |
| `Stop` | (none) |
| `StopFailure` | (none) |
| `SubagentStart` | (none) |
| `SubagentStop` | (none) |
| `SessionEnd` | (none) |

Example entry:

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command",
            "command": "[ -x \"$HOME/.bezelight/bin/bezelight-hook\" ] && \"$HOME/.bezelight/bin/bezelight-hook\" claude || echo '{}'",
            "async": true, "timeout": 5 }
        ]
      }
    ]
  }
}
```

Note: `PostToolUse` runs after **every** tool call, so the helper must be very fast. Users who already have Orca hooks on the same event: hooks accumulate, no conflict. Already open sessions must be restarted to pick up the hooks.

### 9.3 Codex: `~/.codex/hooks.json`

| Event | Matcher |
|---|---|
| `SessionStart` | (none) |
| `UserPromptSubmit` | (none) |
| `PermissionRequest` | `*` |
| `PostToolUse` | `*` |
| `Stop` | (none) |
| `Interrupt` | (none) |
| `SessionEnd` | (none) |

```json
{ "hooks": { "Stop": [ { "hooks": [
  { "type": "command",
    "command": "[ -x \"$HOME/.bezelight/bin/bezelight-hook\" ] && \"$HOME/.bezelight/bin/bezelight-hook\" codex || echo '{}'",
    "timeout": 5 } ] } ] } }
```

- The helper always prints `{}` to stdout (a requirement of `Stop`, and safe for `PermissionRequest`: it is not a decision).
- **Do not** use `async` for `Stop`/`PermissionRequest` until Phase 0 confirms it is valid with Codex.
- After installing, show the instruction "run `/hooks` in Codex and trust the Bezelight hook". Whenever the helper path or the entry content changes, the hash changes and trust must be granted again, so the entry must be **stable** across versions.
- Do not touch `notify` and do not edit `config.toml`.

### 9.4 OpenCode: nothing to install (SSE client in the app)

- Bezelight **writes no files** into OpenCode's configuration. Instead `OpenCodeStreamClient` (in the app) connects to `GET {url}/api/event` with HTTP Basic (`opencode` : `password`), with `url`/`password` read from `~/.local/state/opencode/service.json`.
- Connection lifecycle:
  1. Read `service.json`. If the file is missing or `pid` is no longer alive → status "OpenCode is not running", retry after a few seconds (lightweight, no busy loop).
  2. Open SSE; on receiving `server.connected`, consider it connected.
  3. On connection loss (service restart, port/password change) → re-read `service.json` and reconnect with backoff (1 s, 2 s, 5 s, up to 30 s).
  4. Each event is converted directly to `AgentEvent` (table 6.2), **not** through `bezelight-hook`/the socket.
- `cwd` comes from the event's `location.directory`. There is **no PID** per session (all sessions run in one service), so the "agent still alive" check (7.4) is replaced by: when the SSE connection is lost, mark every OpenCode session as unknown and remove it after `stale`.
- **Privacy and security:** only use `type`, `data.sessionID`, `data.id`/`requestID`, `location.directory`; ignore every content field (`text.delta`, `reasoning.delta`, `resources`, `tool` …). The password is kept in memory only and never logged. Connect only to `127.0.0.1`.
- **Risk:** the format of `service.json` and the `/api/event` path are not a stable public API. Mitigation: detect failures and show "OpenCode: cannot connect (version X is not supported)" instead of failing silently; show the verified OpenCode version (2.0.28) in the UI.
- Fallback for OpenCode 1.x: a JS plugin (docs `.opencode/plugins/`) may be considered later; it is currently **not** in scope.

### 9.5 Status table shown in the UI

| Status | Condition | Suggested action to show |
|---|---|---|
| Agent not found | No binary/config directory | Hide the install button, note "this agent is not installed" |
| Hook not installed | No marker entry | **Install** button |
| Partially installed | Some events missing | **Repair** button |
| Installed, awaiting activation | Entries exist, no real event received | Per-agent activation instructions (Codex `/hooks`; Claude/OpenCode restart the session) |
| Active | Real events received recently | Show "last event: X minutes ago" |

---

## 10. `bezelight-hook` helper spec

**Syntax**

```
bezelight-hook claude                 # read the hook JSON from stdin (hook_event_name determines kind)
bezelight-hook codex                  # read the hook JSON from stdin
# OpenCode does not use the helper: the app reads the SSE stream directly (9.4)
```

**Behavior**
1. Record `ts = now (ms)` **immediately on start**.
2. Claude/Codex: read stdin (size-limited, for example 1 MB, dropping the excess), take `hook_event_name`, `session_id`, `cwd`, `agent_id` (→ `sub`), and `transcript_path` (→ `tp`, only for Claude's `ask`); apply the mapping table in section 6.2; for `Notification`, check `notification_type`.
3. Silently ignore events not in the mapping table.
4. Find the agent `pid` (7.4) if not already provided.
5. Build the section 6.1 payload and `sendto` the socket (non-blocking). Send failures (app closed, socket missing) are ignored.
6. Stdout: always `{}\n` for `claude`/`codex` (safe for Codex's JSON requirement). Never write to stderr.
7. **Exit code is always 0**, even on parse errors.

**Performance target**: ≤ 20 ms median; no dependencies beyond Foundation/Darwin.

**Socket path localization**: `~/.bezelight/agent.sock`; directory 0700, socket 0600. If it does not exist, the helper exits immediately (the app is closed).

---

## 11. UI spec

### 11.1 The "Agent notifications" tab in Settings

1. **General**: master switch, presence detection (with `activeGraceSec`, `presentFadeSec`), multi-session rhythm pattern, maximum brightness, crossfade time, dismiss hotkey.
2. **Agents** (3 rows): name + icon, enable switch, hook status (9.5), Install/Remove/Repair buttons, "last event", a **Send test** button, activation note.
3. **Events** (4 cards: Needs attention, Error, Done, Working): every option from 8.3, each with a short description line below, a **Preview** button (plays on the LED strip for ~5 s) and **Restore defaults**.
4. **Advanced**: stale timeouts, PID check interval, "View diagnostic log" button (event types only, no content).

Principle: dependent controls are hidden/dimmed (for example `timeoutSec` is enabled only when `persistence = timed`), and there is a warning when the configuration is invisible.

### 11.2 Menu bar
- The icon changes color/dot according to the highest-priority state.
- List of tracked sessions: agent, project, state, time.
- A **Dismiss all** button.

### 11.3 Main window
- A small status line "n sessions waiting for you" when applicable.

### 11.4 UI strings
Add keys to all 5 `Localizable.strings` files (en, vi, zh-Hans, ja, ko), with the prefix `agents.`, for example `agents.event.needsInput.title`, `agents.option.persistence.untilReturn.help`.

---

## 12. Build plan

> **The detailed, production-ready implementation plan is in [`AGENT_NOTIFICATIONS_PLAN.md`](AGENT_NOTIFICATIONS_PLAN.md)** (final architecture, code interfaces, pipeline integration, safe installer, testing, release, schedule of ~17.5 person-days). This section keeps only the original summary.

Rough estimate (person-days for a developer familiar with the codebase): total **~9–10 days**.

### Phase 0: Verification (0.5–1 day), **partially done** on 2026-10-14
Does not modify your configuration; uses temporary scripts/plugins in the working directory.

**Confirmed**
- [x] Claude: captured real payloads of `SessionStart`, `UserPromptSubmit`, `PostToolUse`, `Stop`, `SessionEnd`; fields match the docs (`session_id`, `cwd`, `hook_event_name`, `Stop.last_assistant_message`, `PostToolUse.tool_input/tool_response`). `--settings <file>` adds hooks on top without editing `settings.json`.
- [x] The `PPID` of Claude's hook is the agent process itself (no intermediate shell).
- [x] `CGEventSource.secondsSinceLastEventType(.combinedSessionState, …)` works **without any permission** (returns idle seconds).
- [x] Datagram limit: `net.local.dgram.maxdgram = 2048` (a payload ≤ 1 KB is safe).
- [x] Claude's process name is a version number (`2.1.296`) and it runs through the `cca` wrapper: matching by name is **unusable** (section 7.4 corrected).
- [x] Claude has multiple config directories (`~/.claude-accounts/*`), `CLAUDE_CONFIG_DIR` points to `work` with `hooks=0` (section 9.2 corrected).
- [x] Your machine runs Claude with `--dangerously-skip-permissions`: `PermissionRequest` almost never fires in that configuration; the remaining "needs you" signals are mostly `AskUserQuestion`/`Notification`. Users who do not skip permissions get the full set.

**Results of real interactive runs (2026-10-14, 3 agents, without `--dangerously-skip-permissions`)**

The real data is in `Tests/Fixtures/agents/` (35 sanitized payloads: prompts, reply contents, commands, personal paths removed).

*Claude Code (interactive session, hooks for 15 events)*
- [x] Sequence on allow: `UserPromptSubmit → PermissionRequest (+0) → Notification permission_prompt (+6 s if unanswered) → PostToolUse (answered) → Stop`. **`PermissionRequest` fires immediately; `Notification` arrives ~6 s late and is redundant**; it is usable only for `elicitation_dialog`/`agent_needs_input`.
- [x] **On deny/interrupt (Esc, "No"): NO hook fires** (no `PostToolUse`, `PostToolUseFailure`, `PermissionDenied` or `Stop`) until the next `UserPromptSubmit`. But the transcript **is appended to right then** (an error `tool_result` + an "interrupted" line + a system line), so tracking transcript growth is a reliable "answered" signal (see 7.6).
- [x] `AskUserQuestion`: `PreToolUse` then `PermissionRequest` with `tool_name="AskUserQuestion"` immediately, `PostToolUse` as soon as it is answered. It goes through `PermissionRequest`, so no special handling is needed.
- [x] **Subagent**: `SubagentStart` (has `agent_id`, `agent_type`) → the subagent's events carry `agent_id`/`agent_type` (including `PermissionRequest`) → `SubagentStop`. **The main session's `Stop` fires while a background subagent is still running** (at +85.6 s, the subagent ended at +101.5 s), and after `Stop` the subagent still asks for permission. There is an "internal" `SubagentStop` (empty `agent_type`, no matching `SubagentStart`, 3 times in the trial) that must be ignored. `PostToolUse` of tools inside a subagent is **not observable**, so `SubagentStop` is the signal for cleaning up the subagent's requests.
- [x] `PostToolUse.tool_name="Agent"` fires when work is delegated to a subagent.
- [x] `permission_mode:"default"` in every payload.
- [ ] Still not captured: `StopFailure`, `PostToolUseFailure`, `PermissionDenied` (did not occur in the test scenarios), `Notification` of type `elicitation_dialog`/`agent_needs_input`.

*Codex (`codex-cli 0.162.1`, interactive TUI, `-s read-only -a on-request`)*
- [x] Allow: `UserPromptSubmit → PermissionRequest (+0) → PostToolUse (answered) → Stop`. `PermissionRequest` has `tool_name`, `tool_input{command,description}`, `turn_id`.
- [x] **Deny or Esc: `Interrupt` (has `turn_id`), no `Stop` and no `PostToolUse`.** `Interrupt` is a sufficient "answered/stopped" signal, no heuristic needed.
- [x] `SessionEnd` fires on exit. `permission_mode:"default"`.
- [x] No `SubagentStart/Stop` in the trial (no subagents were used).
- [ ] Not yet verified: stdout `{}` for `PermissionRequest` specifically in the TUI (the hook still runs normally and the approval flow is unaffected, so it appears fine), `async`, and hooks when using the Codex desktop app.

*OpenCode 2.0.28 (TUI + SSE stream `/api/event`, 136 events)*
- [x] Permission request: `permission.asked` (`id`, `sessionID`, `action`, `resources[]`, `save[]`, `source`) → `permission.replied` (`requestID`, `reply: once|reject`). Real observed wait times: 14 s, 2 s, 3 s.
- [x] **The agent's questions are `form.created` (`form{id, sessionID, title, metadata.kind:"question"}`) → `form.replied` (`id`, `sessionID`, `answer`)**, not `question.asked`. `form.rejected/cancelled` has not been seen (need to try canceling a question).
- [x] Permission denied: `permission.replied reply=reject` → `session.tool.failed` (`error.type="aborted"`, "The user declined this tool call") → `session.step.failed` → `session.execution.interrupted reason="shutdown"`.
- [x] Interrupt with Esc mid-run: `session.tool.failed` ("Tool execution interrupted") → `session.step.failed` → `session.execution.interrupted reason="user"`.
- [x] **Provider error**: `session.step.failed` then `session.execution.failed` with `error{type:"provider.quota", message, status:429, …}`.
- [x] **Subagent**: a child session's `session.created` has `parentID`; the child session has its own `session.execution.started/succeeded` (ending ~3 s before the parent) and `permission.asked` carries the child session's `sessionID`.
- [x] **`session.viewed {sessionID, idle}`** fires whenever the user views the session in the TUI after a run (5 times in the trial, right after `execution.succeeded/interrupted/failed`). Used as the "seen" signal for OpenCode (see 6.4).
- [ ] Not captured: `session.retry.scheduled`, `session.deleted`, `form.rejected`.

- **Output**: `Tests/Fixtures/agents/{claude,codex,opencode}/*.json` (35 real, sanitized payloads). The payload capture scripts live in the session's temp directory and are not committed to the repo.

### Phase 1: Core logic (2 days)
- [ ] `AgentEvent`, `AgentKind`, `AgentState`, wire v1 decoding (including `substart`/`substop`/`seen`, `sub`, `tp`).
- [ ] `AgentTracker.reduce` + display-state selection + stale expiry + presence + subagent/transcript/`seen` rules (6.4, rules 5–9).
- [ ] `TranscriptWatcher` (7.6) with a fake interface for testing.
- [ ] Tests using the **real fixtures** in `Tests/Fixtures/agents/` and the measured timeline sequences (Claude allow/deny/AskUserQuestion/subagent; Codex allow/Interrupt; OpenCode allow/deny/Esc/error/subagent/form).
- [ ] `AgentAlertSettings`, `EventStyle` (Codable, loading older versions).
- [ ] `AgentOverlay` renderer (flourish → hold, persistence, coverage, crossfade, multiPattern); time-deterministic for testing.
- [ ] `LightPipeline` integration (`setAgentOverlay`, frame blending, bypassing the "settled" optimization, lights-off support).
- [ ] Tests: the transition table, T1–T19, overlay rendering over time.
- **Done when**: `swift test` is green; a demo runs using the test pattern instead of real hooks.

### Phase 2: Transport (1.5 days)
- [ ] `BezelightHook` target + helper per section 10.
- [ ] `AgentHookServer` (datagram socket, permissions, cleanup of stale sockets).
- [ ] `build-app.sh`: universal build, signing, place the helper in the bundle; mechanism to copy it to App Support.
- [ ] Wire `AppModel` ↔ server ↔ tracker ↔ pipeline; real presence provider; PID check loop.
- **Done when**: a manual test send with `bezelight-hook` changes the light state correctly.

### Phase 3: Installer (2 days)
- [ ] Pure merge logic for Claude/Codex JSON (marker, idempotent, clean removal) + fixture test with Orca entries.
- [ ] `OpenCodeStreamClient` (read `service.json`, SSE `/api/event` with Basic auth, auto-reconnect, map to `AgentEvent`); writes nothing into OpenCode's configuration.
- [ ] Safe file I/O (backup, atomic write, preserved permissions).
- [ ] Agent detection, status computation (9.5), tracking of the "last event".
- **Done when**: install/remove on a real machine does not change Orca's hooks; each agent can deliver real events to the app.

### Phase 4: UI (2.5 days)
- [ ] Agents tab: general, agents, 4 event cards (all section 8 options, with descriptions), preview, restore defaults, constraint validation.
- [ ] Menu bar: status icon, session list, dismiss all; dismiss hotkey.
- [ ] 5-language strings.
- **Done when**: every option changes light behavior exactly as described; no strings are missing in any language.

### Phase 5: Polish (0.5 day)
- [ ] README (en/vi): features, installation, troubleshooting, privacy.
- [ ] CHANGELOG, `docs/PROTOCOL.md` linking to this document.
- [ ] Manual E2E testing (13.3), CPU measurement.

### List of changed files
- **New**: `Sources/BezelightCore/{AgentEvent,AgentTracker,AgentAlertSettings,AgentOverlay,AgentHookServer,AgentInstaller,OpenCodeStreamClient,TranscriptWatcher}.swift`, `Sources/BezelightHook/main.swift`, `Sources/Bezelight/{AgentSettingsView,AppModel+Agents}.swift`, `Tests/Fixtures/agents/*`.
- **Modified**: `Package.swift`, `Sources/BezelightCore/LightPipeline.swift`, `Sources/Bezelight/{AppModel,MenuBarView,SettingsView,HotKeys,MainView}.swift`, 5 `Localizable.strings` files, `scripts/build-app.sh`, `README*.md`, `CHANGELOG.md`, `Tests/BezelightCoreTests/CoreTests.swift`.

---

## 13. Test plan

### 13.1 Unit tests (BezelightCore)
- **Tracker**: every cell in table 6.4; every scenario T1–T19 is a table-driven test; clock and presence are faked.
- **Ordering**: events arriving in reverse order, equal `ts`, very old events.
- **Overlay**: frames at fixed points in time (flourish counts the right number of blinks, hold, correct expiry for each `persistence`, coverage, multiPattern, crossfade).
- **Settings**: loading old/missing-key JSON; constraints; restore defaults.
- **Installer**: merge/remove/idempotent/preserving foreign entries; a fixture containing Orca; empty file / file without a `hooks` key; broken JSON is refused for writing.
- **Wire**: decoding valid/broken/oversized input.

### 13.2 Integration tests
- Send a real datagram into the server and check the tracker.
- The helper with sample stdin (Phase 0 fixtures) yields the expected `kind`; always exits 0 and stdout `{}`.
- Pipeline: overlay on a fake frame; lights off; static/ambient/screen modes; when the overlay ends the exact previous frame is restored.

### 13.3 Manual E2E tests (on a real machine)
| # | Scenario | Expected |
|---|---|---|
| E1 | Claude asks permission to run a command | Amber within ≤ 1 s, held until I choose; after choosing the light returns |
| E2 | Claude finishes while I am away from the desk | Dim green held until I touch the mouse |
| E3 | Claude finishes while I am typing | Fades after `presentFadeSec` |
| E4 | 2 Claude sessions ask permission at the same time | Double beat; answer one → still waiting; answer both → gone |
| E5 | Codex `PermissionRequest` / `Stop` | Same as E1/E2 (after `/hooks` trust) |
| E6 | OpenCode asks permission and a `question` | Same as E1; `replied` returns to working |
| E7 | OpenCode subagent finishes before the parent session | No premature `done` |
| E8 | Close the terminal while waiting for permission | Light returns to normal within ≤ 10 s |
| E9 | Quit the Bezelight app, then use an agent | The agent is not slowed and shows no errors |
| E10 | Turn the lights off with the hotkey, then the agent asks permission | Light turns on amber; turns off again when finished |
| E11 | Install/remove when Orca hooks already exist | Orca unchanged |
| E12 | Mac sleeps while the agent is waiting, then wakes | Shows the correct state |
| E13 | Measure CPU when idle and when alerting | Idle: as before; alerting: ≤ +3% |

---

## 14. Risks and items to verify (Phase 0)

| Risk | Level | Mitigation |
|---|---|---|
| OpenCode event names/payloads change by version | Medium | Listen to both `permission.asked` and `permission.updated`; the mapping table is separate and easy to fix; version-specific fixture tests |
| Codex changes the hook hash when the helper/entry changes → loses trust | Medium | Keep entries stable; clear trust instructions; update only the helper binary (do not change the command line) |
| `async` hooks run out of order | High if ignored | Start-of-run timestamp + tie-break winner rule (T7) |
| Claude does not fire `Stop` on interrupt | High | PID check + stale timeout |
| Spawning the helper on every `PostToolUse` adds load | Low–Medium | Minimal helper, measure in Phase 0; backlog: filter early when there is no needsInput |
| Agent PID cannot be found | Low | Fall back to the stale timeout |
| HID idle requires a permission | Low | Confirm in Phase 0; if it requires a permission, turn it off by default and use timed persistence |
| User configures an invisible event (both effects `none`) | Low | Warning in the UI |
| Agent config corrupted during a write | High if it occurs | Backup, atomic write, refuse on broken JSON, fixture tests |
| Claude deny/Esc has no hook (measured) | High | Transcript tracking (7.6) + `confirmSec`; accept the margin of error: the light may turn off early |
| Claude `Stop` arrives while a background subagent is still running (measured) | Medium | Hold `done` until subagents finish, with `subagentHoldSec` (rule 6) |
| OpenCode's SSE stream `/api/event` and `service.json` are not a public API | Medium | Show a clear connection error + verified version; encapsulate in `OpenCodeStreamClient` so changes are made in one place |
| OpenCode `session.viewed` has unclear semantics (what is `idle`) | Low | Use only as a secondary signal (`presence.useAgentSeen`), can be turned off |
| Hooks affect privacy | Low | Do not forward content; logs record only the event type |

---

## 15. Backlog outside v1 scope

- Antigravity (if an official approval signal appears later).
- Agents on other machines (SSH/container): TCP localhost + token + tunnel.
- Accompanying sound/system notifications.
- A distinct identifying color per agent, or each waiting session occupying its own segment of the strip.
- Early filtering in the helper to reduce spawns when nothing is waiting.
- Triggering actions (for example bringing the terminal window to the front) when clicking the menu bar.
- Configuration profiles (day/night, meeting mode).

---

## 16. Appendix

### A. Example flow of a Claude session

```
UserPromptSubmit  → working
PermissionRequest → needsInput (pending={implicit})        [amber light]
PostToolUse       → working    (clear pending, answered)   [light returns]
Stop              → done (unseen)                          [dim green until the user returns]
UserPromptSubmit  → working    (clear unseen flag)
```

### B. Example flow of OpenCode with a subagent

```
session.created(A)                       → start A
session.status(A, busy)                  → working A
session.created(B, parentID=A)           → remember B→A
permission.asked(B, id=r1)               → ask A req=r1     [amber light]
permission.replied(B, requestID=r1)      → answered A r1    [pending empty → working]
session.idle(B)                          → ignored (child session)
session.idle(A)                          → done A
```

### C. References
- Claude Code hooks: https://code.claude.com/docs/en/hooks
- Codex hooks: https://learn.chatgpt.com/docs/hooks
- Advanced Codex config (`notify`, TUI notifications): https://learn.chatgpt.com/docs/config-file/config-advanced
- OpenCode plugins: https://opencode.ai/docs/plugins/
- OpenCode permissions: https://opencode.ai/docs/permissions/
- OpenCode SDK: https://opencode.ai/docs/sdk/
- OpenCode v2 event types: npm package `@opencode-ai/sdk`, file `dist/v2/gen/types.gen.d.ts`
- Local cross-check: the binary `~/.opencode/bin/opencode` v2.0.28 contains `permission.asked`/`permission.replied` and does not contain `permission.updated`.
