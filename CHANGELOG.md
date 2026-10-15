# Changelog

## Unreleased

- New app icon: the blue "b" mark on a white tile (`Resources/Icon/bezelight-mark.png`, rendered by `scripts/make-icon.swift`).
- Project docs are English only; added `docs/STYLE.md` and a Claude Code setup (`CLAUDE.md`, `.claude/`).
- Open-source project files: `SECURITY.md`, `CODE_OF_CONDUCT.md`, PR and issue templates, Dependabot, `.editorconfig`, `CODEOWNERS`.

## 0.3.0

**Agent alerts.** The strip lights up when Claude Code, Codex or OpenCode needs you, finishes or fails.

- **Agents is a mode of its own** (next to Screen, Music and Colors): the strip is a pure notification light, with
  an optional calm background colour, and needs no screen or audio access. Other modes are never interrupted unless
  you turn on *Also show alerts in other modes*; previews always play.
- Four alerts (needs you, failed, finished, working), each with its own colour, opening effect, hold effect,
  duration, coverage, behaviour with the lights off and per-agent switch, plus a live preview. "Finished"
  stays until you are back at the keyboard or mouse; with several sessions waiting, "Needs you" changes rhythm.
- Handles many sessions and subagents: a subagent's question counts for its session, and a "finished" waits
  for subagents that still run. Behaviour was measured on real Claude Code, Codex and OpenCode sessions, which
  showed that Claude Code sends no signal when you refuse a permission (Bezelight notices the transcript
  change instead) and that Codex ends a refused question with an interrupt.
- Hooks for Claude Code (every folder, including `~/.claude-accounts/*`) and Codex are installed and removed
  from the Agents mode's options, safely: other tools' hooks are untouched byte for byte, a backup is kept,
  and removing gives back the exact original file. OpenCode needs nothing: Bezelight reads its event stream.
- `bezelight-hook` (5 ms median) forwards events over a private socket in `~/.bezelight`; it always exits 0 and
  stays silent, so a missing app never disturbs an agent. Prompts and answers are never read.
- Photosensitivity: flashing is capped at 3 per second at every layer, "Reduce flashing" and macOS *Reduce
  motion* swap blinking for slow swells, and the menu bar icon changes shape rather than colour only.
- A check-up with a copyable report, an optional in-memory event log, a dismiss shortcut (⌃⌥⇧F11).
- 199 new strings in five languages. More than 250 new tests, including fuzzing, a soak test (`scripts/soak.sh`)
  and fixtures captured from real agents.

Also: the app bundle now contains the hook helper, and a release workflow can sign and notarise.

## 0.2.0

Features researched in the vendor's current app (3.0.3) and added, written from scratch:

- Automatic device identification (`Moni-A` handshake, DTR/RTS reset, retries) that selects the model.
- Complete model table (4/3/2-sided kits and straight strips up to 1024 LEDs) with the correct layout kinds.
  Two-sided kits are now left + right (they were mapped as left + top).
- Layout test, mirror option, strip edge option.
- New effects: Rainbow with palettes, Breathing, Comet, Spectrum Cycling, Starry Night; 16-band Equalizer.
- Lights on/off, global shortcuts, quit-on-close option, SK0204 hardware button, SK0121 stream priming.
- Frame pacing derived from frame size and baud rate.

Performance: the backdrop no longer animates while colours move (visible CPU with a comet effect 33% -> 1%),
nothing is published to the UI while the window is hidden, and listing displays no longer queries
ScreenCaptureKit, so launching the app can never raise a permission prompt.

## 0.1.0

First public version: ScreenCaptureKit capture, per-LED sampling, music modes from system audio,
Liquid Glass interface, menu bar controls, five languages.
