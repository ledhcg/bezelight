<div align="center">

# Bezelight

**Ambient light for your screen.** A native, tiny, open-source macOS app that drives USB LED
strips behind your display, in sync with your screen or your music.

[![CI](https://github.com/ledhcg/bezelight/actions/workflows/ci.yml/badge.svg)](https://github.com/ledhcg/bezelight/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey)

[English](README.md) · [Tiếng Việt](README.vi.md)

</div>

- **Light on resources.** Measured on an M2 while streaming the screen: about 2% CPU with the window
  hidden, 6% with it open, ~80 MB RAM; ~0% when the screen is static. Static color mode stops
  screen capture entirely.
- **Looks like macOS 26.** Liquid Glass interface with a live preview of every LED; falls back
  to system materials on macOS 14 and 15.
- **Accurate colors.** One sample per LED at the strip's real position, averaged in linear light,
  gamma-corrected for LEDs, with automatic letterbox detection and white-balance control.
- **Music modes without a microphone.** Bass / mids / treble / spectrum / a 16-band **equalizer** from
  system audio via ScreenCaptureKit and an FFT. Nothing is recorded or stored.
- **Animated effects:** Rainbow (4 palettes or your own), Breathing, Comet, Spectrum Cycling, Starry Night,
  each with its own controls. They need neither screen nor audio access.
- **Finds your hardware.** The controller is asked who it is on connect, so the model and LED layout are
  picked automatically; "Test layout" lights each segment in its own colour to check the wiring.
- **Global shortcuts** (⌃⌥⇧F8 toggle, F9 on, F10 off, ↑/↓ brightness), lights on/off from the menu bar,
  and the controller's own button on models that have one.
- **Agent alerts.** The strip lights up when Claude Code, Codex or OpenCode needs you, finishes or fails, across any number of sessions. See [Agent alerts](#agent-alerts).
- **Five languages**, switchable live: English, Tiếng Việt, 简体中文, 日本語, 한국어.
- **Menu bar controls**, launch at login, multiple displays, every known kit (4/3/2-sided and straight
  strips up to 1024 LEDs) plus custom layouts.

## Install

Download `Bezelight.app` from the [Releases](../../releases) page, or build it yourself:

```bash
git clone https://github.com/ledhcg/bezelight && cd bezelight
scripts/build-app.sh          # -> dist/Bezelight.app (universal, ad-hoc signed)
open dist/Bezelight.app
```

**Keeping the Screen Recording permission across rebuilds.** macOS ties that permission to the app's
signature. An ad-hoc build (the default) has a new code hash every time, so the prompt returns after each
rebuild. Sign with a stable identity instead (a free *Apple Development* certificate is enough on your own Mac):
`security find-identity -v -p codesigning`, then `CODESIGN_IDENTITY="<SHA-1 or name>" scripts/build-app.sh`.

Requires macOS 14 or later and Xcode 15+ (Xcode 26 for the Liquid Glass look). A locally built,
ad-hoc signed app is fine for your own Mac; for distribution sign it with a Developer ID
(`CODESIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh`) and notarize it.

## Use

1. Plug in the controller, open Bezelight, open **Settings** (⌘,) and pick the **serial port** and
   your **model**. Not listed? Choose *Custom layout* and enter the number of LEDs per side.
2. Press **Start** (Space). The first time, macOS asks for *Screen & System Audio Recording*.
   That single permission covers both screen colors and music.
3. Pick a mode and tune brightness, saturation and smoothing. Closing the window keeps the lights
   running; use the menu bar icon to control them. Quitting turns the LEDs off.

If the port is *busy*, another program is using it (for example the vendor's own app). Quit it first.

## Agent alerts

Bezelight can light the strip when an AI coding agent needs you, finishes or fails: **Claude Code**,
**Codex** and **OpenCode**, any number of sessions at once. It is off until you set it up.

**Agents is a mode of its own**, next to Screen, Music and Colors. In that mode the strip is only a
notification light (dark, or a calm colour you choose, until something happens) and it needs neither the
screen nor audio, so it asks for no Screen Recording permission. In the other modes nothing is ever drawn over
your lights, unless you turn on *Also show alerts in other modes*.

| Alert | Default look | Stays |
|---|---|---|
| **Needs you**: a permission or a question | amber, breathing | until answered |
| **Failed**: a turn ended with an error | red | until you are back |
| **Finished**: an agent finished while you were away | dim green | until you touch the keyboard or mouse |
| **Working** (off by default) | cyan, first 10% of the strip | while it works |

When several sessions want attention the strip shows the most important one (needs you, then failed,
then finished), and the menu bar lists them. With several waiting, "Needs you" switches to a double beat.

**Set up.** Pick the **Agents** mode next to Screen, Music and Colors. Its options appear on the right, like
those of the other modes: press *Set up detected agents* there.

- **Claude Code**: adds small hooks to `settings.json` in every Claude folder it finds (`~/.claude` and
  each `~/.claude-accounts/*`). Restart sessions that are already open: they read hooks when they start.
- **Codex**: adds hooks to `~/.codex/hooks.json`. In Codex type `/hooks` and trust them.
- **OpenCode** (2.x): nothing to install. Bezelight listens to OpenCode's own event stream.

**Safe by construction.** Nothing leaves your Mac and prompts or answers are never read: only the kind of
event, a session id and the folder name travel, over a private socket in `~/.bezelight`. Other tools' hooks
(Orca, for instance) are left byte for byte as they were, a backup is kept before the first change, and
*Remove* puts the file back exactly. If Bezelight is not running, the hooks do nothing and the agents never
show an error.

**Make it yours.** For each alert you can change the colour, an opening effect (blink, pulse, flash), what it
does next (steady, breathe, blink, comet), how long it stays, which part of the strip it uses, whether it
shows with the lights off, and which agents it applies to, with a live preview on the strip. Every option
is explained next to the control. Control-Option-Shift-F11 dismisses the alerts showing now.

**Accessibility.** Flashing never exceeds 3 times a second, "Reduce flashing" (and macOS *Reduce motion*)
replaces blinking with slow swells, and the menu bar icon changes shape, not only colour.

**If nothing happens**, press *Check now* in Agent alerts: it tests the helper, the socket and each agent
and tells you what to fix. The usual causes are an open session that has not been restarted (Claude Code), a
hook that has not been trusted yet (Codex, `/hooks`), or hooks installed in a different Claude folder than the
one you use (set up every folder you use). Verified with Claude Code 2.1, Codex 0.162 and OpenCode 2.0.28;
OpenCode's event stream is not a public API, so a future version may need an update.

## How light is it?

Measured on an M2 streaming a 96-LED strip, against the vendor's own app (3.0.3, UI + core + web view):

| | Bezelight | Vendor app |
|---|---|---|
| Memory | 65–80 MB | ~350 MB |
| CPU, window hidden | ~1–3% | ~12% |
| Animated effect, window open | 1–9% | – |

About 20 MB of the memory is the shader library SwiftUI loads for any window; the rest is small.

## How it stays fast

| Stage | Technique |
|---|---|
| Capture | ScreenCaptureKit downscales on the GPU to a 64×36 grid; frames arrive only when the screen changes |
| Sampling | Per-LED windows from the strip layout; ~96 × <60 cells per frame; linear-light averaging |
| Smoothing | Time-based, adaptive time constant: instant on scene cuts, calm on flicker |
| Output | One 768-entry lookup table: gamma + white balance + brightness |
| Serial | Frame written as soon as it is ready, never faster than the UART drains (294 B ≈ 25.5 ms @ 115200); unchanged frames are skipped, 10 Hz keep-alive |
| UI | Live values live in tiny observed objects; updates pause when the window is hidden |

## Acknowledgements

The device handshake and model table were cross-checked against the vendor's MIT-licensed controller
plugin. The vendor's effect plugins are GPL-2.0; Bezelight does **not** use any of their code. The effects
here were written from scratch from their behaviour.

## Hardware

Bezelight speaks the serial protocol of common USB ambient-light controllers (CH340/CP210x style,
115200 baud). See [docs/PROTOCOL.md](docs/PROTOCOL.md). Use `bezelight-probe <port>` to test a
controller without the GUI. It is an independent project and is not affiliated with any hardware vendor.

## Contributing

Bug reports, new device presets and translations are welcome. Translations are plain
`.strings` files; see [CONTRIBUTING.md](CONTRIBUTING.md).

```bash
swift build && swift test
```

## License

[MIT](LICENSE)
