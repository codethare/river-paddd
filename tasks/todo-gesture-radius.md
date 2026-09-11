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

- [ ] Determine output scale in `drawBorders` via `OutputManager.outputAt`
- [ ] Scale corner raster size: `ceil(size * scale)`, `radius * scale`, `setDestSize`
- [ ] Add `scale` to `border_rendered` cache key
- [ ] Verify `zig build test` passes
- [ ] `zig fmt` clean

## G4a — File-based gesture config

- [ ] Add `$XDG_CONFIG_HOME/river/gestures.conf` parser in `gesture_config.zig`
- [ ] Integrate config loading in `Server.init` / `InputManager.init`
- [ ] Add `river/gesture_config.zig` to test module
- [ ] Verify `zig build test` passes
- [ ] `zig fmt` clean
