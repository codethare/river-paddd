# Plan: Rounded Window Borders (SPEC-rounded-window-borders.md)

Approved decisions: 1) compositor-side constant radius; 2) all four corners; 3) bw ≥ r → no visible rounding, accepted; 4) maximized = rounded like tiled.

## Approach

Replace the 4 border `wlr.SceneRect`s in `Window.drawBorders()` (`river/Window.zig`) with one CPU-rendered ARGB8888 frame texture displayed via `wlr.SceneBuffer`, because wlroots 0.20 scene/render API has no rounded primitives (only rects, buffers, box clips).

Payload geometry (frame-local coords, content box W×H at [bw, bw+W)×[bw, bw+H)):
- Strips per drawn edge, replicating the documented corner contract (corners only between adjacent drawn edges; side strips extend vertically only when the neighboring top/bottom edge is drawn).
- Corner cut: for each corner where both adjacent edges are drawn, pixels with px<r ∧ py<r get 1px analytical AA coverage `cov = clamp(r - dist(center,(r,r)) + 0.5, 0, 1)`.
- Pixels premultiplied (protocol specifies premultiplied RGBA) × coverage.
- `requested.clip` (tree coords) ported by clamping the filled pixel range (clip shifted by (+bw,+bw)).

Upload: custom `wlr.Buffer` via `wlr.Buffer.init` + own `Buffer.Impl` (`beginDataPtrAccess`/`getShm`), fresh buffer per redraw, handed to `wlr_scene_buffer_set_buffer` (scene locks it; we drop our ref). Destroyed automatically when the window tree node dies.

## Files
- `river/Window.zig` — only file changed.
- `tasks/todo.md` — task list.

## Risks / mitigations
- Data-buffer texture import on gles/vk/pixman renderers: standard `wlr_texture_write_pixels` path; verify on a real session (visual task).
- Buffer/refcount mistakes: rely on scene-buffer locking + `wlr_buffer_drop`; no manual freeing in Window.deinit.
- Premultiplication mismatch: protocol says premultiplied; if corners look off, revisit blend.
- Re-render cost on resize: border area only (perimeter × bw + corner arcs), trivial.

## Verification
- `zig build test` (new corner-coverage assert test).
- Manual: compositor session, check 4 corners, translucent borders, tiled partial edges, drag/resize/maximize.