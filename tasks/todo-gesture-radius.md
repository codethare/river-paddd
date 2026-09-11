# Tasks: G3 → RC4 → G4a

## G3 — Extract gesture state machine

- [ ] Create `river/Gesture.zig` with `DeviceState`, `Release`, `Action`, `Gestures`
- [ ] Move `handleSwipe*`, `handlePinch*`, `handleHold*`, `naturalScroll` to Gesture.zig
- [ ] Update `Seat.zig` adapter to call Gesture methods and execute Actions
- [ ] Verify `zig build test` passes (existing tests)
- [ ] `zig fmt` clean

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
