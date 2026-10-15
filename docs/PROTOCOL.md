# Serial protocol

Supported controllers enumerate as a USB serial device (`/dev/cu.usbserial-*`, CH340 or CP210x
bridge) and use **115200 baud, 8N1, no flow control**.

This description comes from observing the traffic of hardware its author owns, for the purpose of
interoperability. No vendor code or assets are used.

## Opening the port and identifying the controller

1. Open the port at 115200 8N1 with exclusive access (`TIOCEXCL`) so no other program interleaves bytes.
2. Pulse the control lines: DTR and RTS low for ~60 ms, then high, then wait ~350 ms. On boards whose
   reset pin hangs off the USB bridge this restarts the firmware into a known state. Flush both buffers.
3. Send the 6 ASCII bytes `Moni-A`.
4. The controller answers `SKxxxx[,<serial bytes>]` ended by CR/LF, for example
   `53 4B 30 4C 32 37 2C 3C 12 22 15 0D 38 3B 0D 0A` = `SK0L27,` + serial. The first six characters
   are the product code (`SK0L27`); the bytes after the comma are the serial number.
5. No valid reply within ~500 ms: flush, wait ~120 ms and ask again, up to 3 attempts. A board that never
   answers can still be driven, but its layout has to be chosen by hand.

Model-specific behaviour:

- `SK0121` needs two all-black frames, 20 ms apart, right after (re)connecting before it streams cleanly.
- `SK0204` has a hardware button. Pressing it sends a single `0x00` byte towards the host.

## LED frame

```
offset  size  meaning
0       3     "Ada"            41 64 61
3       1     0x00
4       2     LED count        big-endian
6       3*N   RGB triplets     R G B per LED, in strip order
```

There is no checksum and no footer. Example, 96 LEDs: `41 64 61 00 00 60` followed by 288 bytes
(294 in total).

## Timing

A 96-LED frame is 294 bytes = 2940 bit times ≈ 25.5 ms at 115200 baud, so the link carries at most
~39 frames per second. Bezelight streams at 30 fps. Longer strips lower that ceiling; 300 LEDs fit
only ~12 fps at 115200 and need a faster baud rate.

The controller blanks the LEDs when the stream stops, so an unchanged picture is re-sent at 10 Hz.

## Wiring order

Seen from the **front** of the display (verified on an SK0L27, 96 LEDs):

| Kit | Segment order |
|---|---|
| 4 sides (`SK0L..`, `SKB1..`) | left edge up, top edge →, right edge down, bottom edge ← |
| 3 sides (`SK01..`, `SKA1..`) | left edge up (from the bottom corner), top edge →, right edge down (to the bottom corner) |
| 2 sides (`SK020x`, `SK0F0x`) | left edge up, then right edge down |
| strip (`SK04xx`, `SK0K..`, …) | one straight run; the user picks the edge it is mounted on |

Corners hold no LED: a segment of *n* LEDs occupies the *n* cells between two corners. If a strip is
mounted the other way round, mirror and/or reverse it in Settings; "Test layout" shows each segment in
its own colour, brightening along the wiring, to check it.

> Some vendor tooling describes the same wiring on a matrix whose left and right are swapped
> relative to the front view; the order above is the physically verified one.

## Reading acknowledgements

## Frame pacing

A frame must not be written before the previous one has left the UART: the minimum gap is
`bytes × 10 / baud` (294 B at 115200 baud ≈ 25.5 ms). A 1024-LED kit needs 3078 B ≈ 267 ms per frame at
115200 baud (about 3.7 fps), so use a faster baud rate for the very long strips.

## Acknowledgements

The identification handshake, the model table and the reset sequence were cross-checked against the
vendor's MIT-licensed controller plugin (`Skydimo-Team/Controller.SkydimoDevice`).

The controller may answer with a few bytes after frames. Bezelight reads and discards them without
blocking; they are only shown in Settings → Diagnostics.

## Agent hooks (not the LED controller)

The LED protocol above is unrelated to the agent integration. For how Claude Code, Codex and OpenCode are
connected (events, the `~/.bezelight/agent.sock` datagram format, the OpenCode event stream) see
[AGENT_NOTIFICATIONS.md](AGENT_NOTIFICATIONS.md), section 6 and the appendix.
