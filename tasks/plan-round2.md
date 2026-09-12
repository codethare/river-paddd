# Plan round 2: gesture and border polish

**Target:** batch A (RC-fix-1, G-fix-1, G-ux-2a), then B (G-ux-1, G-threshold-1, RC5-lite),
then C (RC-perf-1, G-perf-1, RC-simplify-1) as needed.

**Not doing:**

- **Protocol changes** (river-window-management v6 for a per-window radius, a new
  `river-gesture-config-v1` for gesture bindings): the cost is a public interface plus
  cross-repo coordination with flume, while the `gestures.conf` file added in G4a already
  covers the real need. A protocol is only justified when a *window manager* must decide
  (per-window radius) or several clients must register gesture bindings.
- **Sharing corner textures across windows / decoupling them from the clip with
  `setSourceBox`:** a corner texture is ~17x17 px, so the memory win is negligible. flume does
  no animation at all (`flume/src/app.rs:250`) and only ever calls `set_clip_box` with an
  all-zero box (`flume/src/seat.rs:336`), so the clip in the cache key never changes in
  practice. Revisit only if a WM with clipped animations shows up.

## Batch A

### RC-fix-1 — Sample corner textures with their own ratio

**Why:** `cornerRaster(size, scale) = ceil(size * scale)`, but `fillCorner` maps texel centers
back to logical coordinates with the *output* scale (`Window.zig:1380`). The texture is
displayed in exactly `size` logical pixels, so its own ratio is `raster / size`, which equals
the output scale only when `size * scale` happens to be an integer. On a fractional-scale
output (1.25, 1.5) the arc is drawn ~3-4% off and the outer edge is sampled incorrectly.
Example: `size=10, scale=1.25` → `raster=13`, ratio 1.3, so the sampling grid spans
`13/1.25 = 10.4` logical pixels instead of 10.

**Design:** add `cornerScale(raster, size) = raster / size` and pass it to `fillCorner`
instead of the output scale. `border_rendered.scale` keeps holding the output scale, since
that is what picks `raster`.

**Files:** `river/Window.zig` (fix + tests).

**Check:** a test asserting the texel grid spans exactly `[0, size]`, and that the output
scale does not (documenting the bug).

### G-fix-1 — Let swipes and pinches inject mouse buttons

**Why:** Only holds can press a mouse button binding today, so a swipe or pinch can only drive
key bindings. A `button:` target lets them fire a pointer binding too (as a click-like tap)
through the existing injection path.

**Design:** unify `HoldTarget` into `Target = union(enum) { key: xkb.Keysym, button: u32 }`
used by `swipe`, `hold` and `pinch`; the parser already has the value syntax
(`parseTargetOrNone`, formerly `parseHoldTarget`). `Gesture.zig` maps a target to an `Action`
with one shared helper instead of three copies. `Seat.applyGesture` already handles both
`.key` and `.button`, and a swipe's press is released by the existing deferred release.

**Files:** `river/gesture_config.zig`, `river/Gesture.zig`, `README.md`.

**Check:** config tests for `3up = button:0x113`, and a state machine test that a swipe with a
button target fires `.button`.

### G-ux-2a — Log swallowed gestures

**Why:** A gesture that is taken over but has no binding is swallowed silently, which makes
"my gesture does nothing" undiagnosable.

**Design:** `log.debug` in `injectGestureKey` / `injectGestureButton` when no binding matches,
reusing the keysym name buffer pattern from `XkbBinding.zig:67`.

**Files:** `river/Seat.zig`.

**Check:** `zig build test` + a manual `RIVER_LOG_LEVEL=debug` run.

## Batch B

### G-ux-1 — Reload the config on SIGHUP

**Why:** G4a requires a restart for any config change, which makes the file barely usable for
tuning. The wayland binding already exposes `EventLoop.addSignal`
(`wayland-0.6.0/src/wayland_server_core.zig:522`) and river already has the loop
(`Server.zig:125`), so no thread, signalfd or self-pipe is needed: the handler runs in the
event loop thread, which is also where gestures are handled.

**Design:** store the resolved config path (or the `Environ`) on the server, register a SIGHUP
source in `Server.init`, and call `GestureConfig.load` from the handler. A gesture already in
flight keeps the keysym it was started with, which is fine.

**Files:** `river/Server.zig`, `river/main.zig`, `river/gesture_config.zig`, `README.md`.

### G-threshold-1 — Configurable thresholds

**Why:** `min_swipe_delta` (10) and `min_scale_delta` (0.05) are compiled in, and the right
values depend on the touchpad.

**Design:** `swipe_threshold` / `pinch_threshold` keys in `gestures.conf`, stored in `Config`
and used by `resolveDirection` / `isPinchIn` / `isPinchOut` (which take the threshold as an
argument). Rounding to one decimal is enough.

**Files:** `river/gesture_config.zig`, `river/Gesture.zig`, `README.md`.

### RC5-lite — Configurable border radius

**Why:** `border_radius` is a constant (`Window.zig:69`); the config file already exists.

**Design:** a `border_radius` key in the same file, read by `drawBorders`. The key is also
added to the border cache key so a reload re-renders the corners without any other change.
The setting lives in `gestures.conf` / `gesture_config.zig` because that is the compositor's
only config file; renaming both to `river.conf` / `config.zig` is a possible follow-up, but it
touches the module alias in every importer.

**Note:** the radius stays clamped by `overflowFreeRadius(bw)` (`Window.zig:1324`) so the
content's square corners cannot poke out of the rounded outline: `bw=3` caps the radius at 11,
`bw=4` at 15, `bw=6` at 22. This must be documented, otherwise "I set 20 and nothing changed"
will be reported as a bug.

**Files:** `river/Window.zig`, `river/gesture_config.zig` (or a shared config module),
`river/Server.zig`, `README.md`.

## Batch C (measure first)

### RC-perf-1 — Decouple corner textures from the window size

**Why:** `border_rendered` includes `content_width`/`content_height`, so an interactive resize
re-rasterizes and re-uploads all four corner textures every frame. The texture content only
depends on `(radius, bw, which edges are drawn, color, scale)`: mirroring maps the right and
bottom corners onto the same `[0, size]` square, so the window size never enters the pattern
(except through the per-window radius clamp, which must still invalidate).

**Design:** split the cache: a corner cache keyed on the corner parameters, and per-frame strip
geometry as today.

**Check:** count `FrameBuffer.create` calls per frame before and after.

### G-perf-1 — Drag ratio knob

**Why:** The bridged drag feeds libinput's gesture deltas straight to
`Cursor.move` (`Seat.zig:457`) as if they were layout pixels. They are not: libinput
normalizes them to a 1000 dpi device (`/usr/include/libinput.h`), i.e. 1 unit is 1/1000 inch
of finger travel, and libinput has already applied pointer acceleration. So one inch of finger
travel moves the cursor 1000 layout pixels, which is 6 inches on a 163 dpi output at scale 1
and 12 inches at scale 2: the drag is much too fast, and faster the higher the scale.

**Design:** a `drag_sensitivity` key (default 1.0, i.e. today's mapping) multiplied into the
drag delta, divided by the scale of the output under the cursor so 1x and 2x feel the same.
The scale is passed into the pure state machine (`swipeUpdate(device, dx, dy, scale)`) so the
math is unit tested. The default is deliberately uncalibrated: the state machine logs the
accumulated units per gesture at debug level, so a measured finger travel (5 cm is about 1970
units) can be turned into a value.

**Files:** `river/Seat.zig`, `river/Gesture.zig`, `river/gesture_config.zig`, `README.md`.

### RC-simplify-1 — One corner texture rotated four ways

**Why:** `setTransform` exists (`wlroots-0.20.1/src/types/scene.zig:321`), so one rasterized
corner could serve all four corners by rotation, cutting the texture count 4x.

**Design:** exact when all four edges are drawn (the common case); asymmetric edge sets need a
texture per edge pair. Medium complexity: adds a transform-dependent path.

**Files:** `river/Window.zig`.

## Progress

- Batch A: RC-fix-1 done, G-fix-1 done, G-ux-2a done.
- Batch B: G-ux-1 done, G-threshold-1 done, RC5-lite done.
- Batch C: not started, measure first.

## Order & gates

A → B → C. Each item is a separate commit and must pass `zig build test` (currently 19/19) and
`zig fmt --check river/ build.zig`.
