# Tasks: G3 → RC4 → G4a

## G3 — Extract gesture state machine

- [x] Create `river/Gesture.zig` with `DeviceState`, `Effects`, `Action`, `Gestures`
- [x] Move the swipe/hold/pinch decision logic to Gesture.zig; keep the binding release and
      `naturalScroll()` in Seat.zig (they need compositor state)
- [x] Update the `Seat.zig` adapter to call the state machine and execute its actions
- [x] Wire `river/Gesture.zig` into the test module; cover bridging, cancelled, sub-threshold,
      per-device isolation and unmapped finger counts
- [x] Verify `zig build test` passes (15/15) and `zig fmt` clean

## RC4 — HiDPI corner textures

- [x] Determine the output scale in `drawBorders` via `OutputManager.outputAt` (window center)
- [x] Rasterize the corner textures at `ceil(size * scale)` device pixels and display them at the
      logical size with `scene_buffer.setDestSize`
- [x] Move the coverage math to f64 pixel centers so fractional scales work (1x output is
      pixel-identical to before)
- [x] Add `scale` to the `border_rendered` cache key (re-rasterize when the window changes output)
- [x] Verify `zig build test` passes (16/16) and `zig fmt` clean

## G4a — File-based gesture config

- [x] Add the `Config` struct (defaults = the former compile-time tables) and a line parser in
      `gesture_config.zig`, with tests for remapping, whole-file parsing and malformed lines
- [x] Resolve `$XDG_CONFIG_HOME/river/gestures.conf` / `~/.config/river/gestures.conf` and read it
      at startup (`main.zig`, after `Server.init` and before the event loop)
- [x] Let the server own the config and point each seat's gesture state machine at it
- [x] Document the file, its keys and values in the README
- [x] Verify `zig build test` passes (19/19) and `zig fmt` clean
