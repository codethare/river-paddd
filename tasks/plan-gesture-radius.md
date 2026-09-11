# Plan: Gesture refactor → HiDPI → Runtime config

**Target:** G3 (extract gesture state machine), RC4 (HiDPI corners), G4a (file-based gesture config).

## G3 — Extract gesture state machine (`river/Gesture.zig`)

**Why:** Seat.zig is 1423 lines with ~300 lines of gesture logic mixed with compositor IO.
Extracting the pure state machine makes it unit-testable, reduces merge conflicts with upstream,
and makes G4a's runtime remap trivial to test.

**Design:**
- `river/Gesture.zig` owns `DeviceState` (swipe/hold/pinch/bridging) and the per-device map
  (`Gestures`, keyed by `*wlr.InputDevice`).
- The event methods (`swipeBegin/swipeUpdate/swipeEnd/holdBegin/holdEnd/pinch*`) are pure decision
  functions: they update the per-device state and return `Effects = { release: bool, action: Action }`.
- `Action = union(enum) { none, forward, key, button, drag }`. `release` is a separate flag rather
  than an action because a new hold can supersede one whose press is still down (release + press).
- The press itself (`Release`, holding the binding pointer) and `naturalScroll()` stay in `Seat.zig`:
  both need compositor state (bindings; the input device list and its libinput handle), and keeping
  them out is what makes `Gesture.zig` testable.
- `held()` / `forget()` are pure helpers for the seat's flush and for device removal.
- `Seat.zig` keeps only the adapter (~90 lines): `applyGesture()` executes actions
  (cursor.move / opUpdate / inject / release) and each event handler forwards to the client on `.forward`.

**Files:** `river/Gesture.zig` (new, with state machine tests), `river/Seat.zig`, `river/main.zig`
(test wiring).

## RC4 — HiDPI corner textures

**Why:** Corner textures are rasterized at logical size → blurred on 2x/3x outputs.
`Output.scale` is available (`Output.zig:55`), `setDestSize` binding exists, and
`OutputManager.outputAt(lx,ly)` can find the window's output.

**Design:**
- Determine scale via `OutputManager.outputAt(center_x, center_y)` → `wlr_output.scale`.
- Rasterize corner textures at `ceil(size * scale)` px (radius scaled accordingly).
- `scene_buffer.setDestSize(size, size)` to display at logical size → crisp downscale.
- Add `scale` to `border_rendered` cache key.
- `Output.scale` defaults to 1.0 (graceful fallback).

**Files:** `river/Window.zig`.

## G4a — Runtime gesture config (file-based, no protocol)

**Why:** Remapping gestures today requires recompiling. A config file lets users change
bindings without touching the compositor.

**Design:** `$XDG_CONFIG_HOME/river/gestures.conf` (or `~/.config/river/gestures.conf`),
read once at startup.

Line format: `enabled = true/false`, `3up = F1`, `4right = none`, `hold3 = button:0x113`,
`pinch4out = F11`. Values are xkbcommon keysym names (case insensitive) or
`button:<evdev code>` for holds; `none` unmaps an entry. Malformed lines are logged and
skipped, and a missing file leaves the compiled defaults in place.

- `GestureConfig.Config` holds the mapping, with the former compile-time tables as its
  defaults. `parseLine`/`parse` are pure and unit tested; `load` resolves the XDG path and
  reads the file.
- The server owns the loaded config; each seat's `Gestures` points at it, so the mapping is
  read live.
- Reloading requires a restart (no hotkey, no runtime reload).

**Files:** `river/gesture_config.zig` (config + parser + loader), `river/Server.zig` (field),
`river/main.zig` (startup load), `river/Gesture.zig` (consumes the config), `README.md`.

## Order & gates

1. G3 → 2. RC4 → 3. G4a. Each is a separate commit. All must pass `zig build test` + `zig fmt`.
