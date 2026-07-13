# Cursor Capture Spike

Standalone proof-of-concept for RDC-style interaction with the DeskPad virtual display:
click inside the mirror window to "capture" — the real cursor warps onto the virtual
display and your mouse drives it natively — then push against a display edge to escape
back to the mirror window (edge-bounce).

Built as a separate app (no ReSwift dependency) so it can be compiled with `swiftc`
alone, without Xcode.

## Findings

- **No Accessibility permission needed.** `CGWarpMouseCursorPosition`,
  `CGDisplayMoveCursorToPoint`, `CGAssociateMouseAndMouseCursorPosition` and
  `CGGetLastMouseDelta` all work unprivileged. Only synthetic event posting
  (`CGEventPost`) requires Accessibility — this design avoids it entirely by making
  the real cursor live on the virtual display during capture.
- **Only one `CGVirtualDisplay` client activates at a time.** The spike's display is
  created (`applied=true`) but never becomes active while DeskPad.app is running.
  Quit DeskPad before running the spike.
- **macOS may bring the new display up mirrored** with the built-in screen. The spike
  detects this and forces extended mode (session-only) via
  `CGConfigureDisplayMirrorOfDisplay` + `CGConfigureDisplayOrigin`.
- **`CGDisplayStream` is compile-time removed in the macOS 15+ SDK.** The spike uses
  `ScreenCaptureKit` (`SCStream`) for the mirror; DeskPad itself will need the same
  migration once built with a current SDK.
- **Escape tuning matters.** Edge push-through uses an accumulator over
  `CGGetLastMouseDelta` (60 Hz poll). Hard-resetting it on any non-outward frame makes
  slow pushes feel dead (hand jitter wipes progress); halving it instead (decay) with a
  ~35 px threshold and 5 px edge zone feels reliable.
- Global `NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved)` did not deliver
  events in testing; the 60 Hz polling loop replaced it and needs no permissions.

## Build & run

```sh
swiftc Spike/CaptureSpike.swift \
  -import-objc-header DeskPad/DeskPad-Bridging-Header.h \
  -framework AppKit -framework ScreenCaptureKit \
  -o /tmp/CaptureSpike
/tmp/CaptureSpike
```

Needs Screen Recording permission (attributed to the terminal when run unbundled).
Quit DeskPad.app first.

## Test loop

1. Click inside the window → titlebar turns blue, cursor warps onto the virtual display.
2. Move/click/drag/scroll — all real events on the virtual display.
3. Escape: cross the edge adjacent to a real display (instant), or push ~35 px against
   a non-adjacent edge. Cursor pops out at the matching point on the window border.
