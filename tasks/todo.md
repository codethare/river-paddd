# Tasks: Rounded Window Borders

- [x] Task: FrameBuffer type + rounded-frame pixel renderer in river/Window.zig
  - Acceptance: `FrameBuffer` with custom wlr.Buffer impl; fill function reproduces edge-mask corner contract with 1px AA; premultiplied ARGB; clip-aware.
  - Verify: corner-coverage unit test (`zig build test`)
  - Files: river/Window.zig
- [x] Task: Swap 4 border SceneRects for one SceneBuffer
  - Acceptance: Window.border holds one *wlr.SceneBuffer; create()/renderFinish()/drawBorders() use it; no other references to border.left/right/top/bottom remain.
  - Verify: `zig build` compiles; `zig build test` passes.
  - Files: river/Window.zig
- [x] Bugfix: corner arcs had a gap + clicks dead over content (visual verification round 1)
  - Root causes: (1) the ring only drew axis-aligned strips, missing the arc band that crosses the content corner when bw < r; (2) the border buffer's box covered the whole window above the surfaces, so `Scene.at` returned no surface over content.
  - Fixes: ring model with corner band (`bandCoverage`, inner erosion at r-bw); border node above surfaces + `Scene.at` falls through to the window's surfaces subtree when the hit is a surface-less window node.
  - Verify: `zig build test` (band/ring assertions added); geometry cross-checked in-sandbox (continuous arc, subset/partial-edge contract).
  - Files: river/Window.zig, river/Scene.zig
- [ ] Task: Visual verification on a live compositor session
  - Acceptance: rounded corners, translucent border blend correct, partial-edge tiling, resize/maximize no flicker, click/drag unchanged.
  - Verify: manual session (user)
  - Files: none