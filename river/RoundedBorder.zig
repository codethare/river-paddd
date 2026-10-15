// SPDX-FileCopyrightText: © 2026 codethare
// SPDX-License-Identifier: GPL-3.0-only

//! Rounded window borders (fork-only).
//!
//! wlroots 0.20 has no rounded-rect scene primitive, so the outer corners of a
//! window's border are drawn as small anti-aliased textures while the straight
//! edges stay scene rects. The corner curve is a quarter circle of the radius
//! joined to each edge by one cubic Bézier (Apple's continuous corner), built at
//! comptime by buildCornerBoundary().
//!
//! Only a corner whose two edges are both drawn is rounded, and all four
//! rounded corners are congruent in their own frame: one tile serves every
//! corner, mirrored into place by cornerTransform().
//!
//! This is fork-only code and deliberately lives outside river/Window.zig so
//! that the file river shares with upstream keeps the fork's diff small.

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const river = @import("wayland").server.river;
const util = @import("util.zig");

pub const Border = struct {
    edges: river.WindowV1.Edges = .{},
    width: u31 = 0,
    r: u32 = 0,
    b: u32 = 0,
    g: u32 = 0,
    a: u32 = 0,
};

/// A premultiplied ARGB8888 image of a window's border corner, uploaded to the
/// GPU as a custom wlr.Buffer.
const FrameBuffer = struct {
    base: wlr.Buffer,
    pixels: []align(16) u8,
    fw: usize,
    fh: usize,
    alloc: std.mem.Allocator,

    /// wl_shm ARGB8888 (little-endian byte order B,G,R,A)
    const format_argb8888: u32 = 0x34325241;

    fn destroyImpl(buffer: *wlr.Buffer) callconv(.c) void {
        const frame: *FrameBuffer = @fieldParentPtr("base", buffer);
        frame.alloc.free(frame.pixels);
        frame.alloc.destroy(frame);
    }

    fn beginDataPtrAccess(
        buffer: *wlr.Buffer,
        flags: u32,
        data: **anyopaque,
        format: *u32,
        stride: *usize,
    ) callconv(.c) bool {
        _ = flags;
        const frame: *FrameBuffer = @fieldParentPtr("base", buffer);
        data.* = @ptrCast(frame.pixels.ptr);
        format.* = format_argb8888;
        stride.* = frame.fw * @sizeOf(u32);
        return true;
    }

    fn endDataPtrAccess(_: *wlr.Buffer) callconv(.c) void {}

    const impl: wlr.Buffer.Impl = .{
        .destroy = destroyImpl,
        .get_dmabuf = null,
        .get_shm = null,
        .begin_data_ptr_access = beginDataPtrAccess,
        .end_data_ptr_access = endDataPtrAccess,
    };

    fn create(width: usize, height: usize) !*FrameBuffer {
        const alloc = util.gpa;
        const frame = try alloc.create(FrameBuffer);
        errdefer alloc.destroy(frame);
        frame.alloc = alloc;
        frame.pixels = try alloc.alignedAlloc(u8, .@"16", width * height * @sizeOf(u32));
        errdefer alloc.free(frame.pixels);
        frame.fw = width;
        frame.fh = height;
        wlr.Buffer.init(&frame.base, &impl, @intCast(width), @intCast(height));
        return frame;
    }

    /// Fill the tile with the ring's anti-aliased coverage, clipped to `clip`
    /// (in tile coordinates). `scale` is the tile's own device pixels per
    /// logical pixel, see cornerScale().
    fn fillCorner(
        frame: *FrameBuffer,
        ctx: *const TileFillContext,
        clip: wlr.Box,
        scale: f64,
    ) void {
        @memset(frame.pixels, 0);

        const raster = frame.fw;
        const pixels: [*]u32 = @ptrCast(@alignCast(frame.pixels.ptr));
        const clipped = !clip.empty();
        const clip_x0: f64 = @floatFromInt(clip.x);
        const clip_y0: f64 = @floatFromInt(clip.y);
        const clip_x1: f64 = @floatFromInt(clip.x + clip.width);
        const clip_y1: f64 = @floatFromInt(clip.y + clip.height);

        var j: usize = 0;
        while (j < raster) : (j += 1) {
            const y = (@as(f64, @floatFromInt(j)) + 0.5) / scale;
            if (clipped and (y < clip_y0 or y >= clip_y1)) continue;
            var i: usize = 0;
            while (i < raster) : (i += 1) {
                const x = (@as(f64, @floatFromInt(i)) + 0.5) / scale;
                if (clipped and (x < clip_x0 or x >= clip_x1)) continue;
                const coverage = cornerRingCoverage(x, y, ctx.radius, ctx.bw);
                if (coverage == 0) continue;
                pixels[j * raster + i] = premultipliedPixel(ctx.color, coverage);
            }
        }
    }
};

/// A premultiplied ARGB pixel for the border color at the given coverage.
/// Scaling every component keeps the premultiplied invariant (rgb <= alpha).
fn premultipliedPixel(color: [4]u8, coverage: f64) u32 {
    const a: u32 = @intFromFloat(@round(@as(f64, color[3]) * coverage));
    const r: u32 = @intFromFloat(@round(@as(f64, color[0]) * coverage));
    const g: u32 = @intFromFloat(@round(@as(f64, color[1]) * coverage));
    const b: u32 = @intFromFloat(@round(@as(f64, color[2]) * coverage));
    return a << 24 | r << 16 | g << 8 | b;
}

/// Inputs of the corner fill: the ring's shape and color, in the corner's own
/// frame (the corner's outer point is the origin, the border running along the
/// positive axes), which is the same shape for all four corners.
const TileFillContext = struct {
    /// Border width in logical pixels.
    bw: f64,
    /// Corner radius in logical pixels.
    radius: f64,
    color: [4]u8,
};

/// Geometry of the border ring in frame coordinates: the frame is the content
/// box expanded by the border width, with its origin at the window's
/// (-bw, -bw). The ring splits into solid strips, which scene rects can draw,
/// and one square around each rounded corner, which needs an anti-aliased
/// texture. Outside those squares the ring's coverage is always 0 or 1, so the
/// split is pixel-exact.
const BorderGeometry = struct {
    /// Solid strips (left, right, top, bottom); an edge that is not drawn gets
    /// a zero-sized box.
    strips: [4]wlr.Box,
    /// Corner squares (top-left, top-right, bottom-left, bottom-right). A
    /// corner that is not rounded gets a zero-sized box, and the strips cover
    /// it exactly as upstream's border rects do.
    corners: [4]wlr.Box,
    /// Side of a rounded corner square.
    size: usize,
};

/// Side of a corner square in logical pixels: the tile has to hold the corner
/// of the given radius and never less than the width of the strips joining it.
fn cornerExtent(radius: usize, bw: usize) usize {
    return @max(cornerSize(radius), bw);
}

fn borderGeometry(
    content_width: usize,
    content_height: usize,
    bw: usize,
    radius: usize,
    edges: river.WindowV1.Edges,
) BorderGeometry {
    const frame_right = content_width + bw;
    const frame_bottom = content_height + bw;
    const frame_width = frame_right + bw;
    const frame_height = frame_bottom + bw;

    // A corner is rounded, and so needs a texture, only where both of its edges
    // are drawn: that is where two strips meet. Elsewhere the strips cover the
    // corner square exactly as upstream's border rects do.
    const size: usize = if (radius == 0) 0 else cornerExtent(radius, bw);
    const tl: usize = if (edges.top and edges.left) size else 0;
    const tr: usize = if (edges.top and edges.right) size else 0;
    const bl: usize = if (edges.bottom and edges.left) size else 0;
    const br: usize = if (edges.bottom and edges.right) size else 0;

    // A side strip spans the content and reaches into the corner squares its
    // adjacent horizontal edge leaves to it (as upstream's rects do), stopping
    // where a rounded corner square takes over.
    const y_lo: usize = if (edges.top) 0 else bw;
    const y_hi: usize = if (edges.bottom) frame_height else frame_bottom;

    const left_y0 = @max(y_lo, tl);
    const left_y1 = @max(left_y0, @min(y_hi, frame_height - bl));
    const right_y0 = @max(y_lo, tr);
    const right_y1 = @max(right_y0, @min(y_hi, frame_height - br));
    const top_x0 = @max(bw, tl);
    const top_x1 = @max(top_x0, @min(frame_right, frame_width - tr));
    const bottom_x0 = @max(bw, bl);
    const bottom_x1 = @max(bottom_x0, @min(frame_right, frame_width - br));

    return .{
        .strips = .{
            .{ .x = 0, .y = @intCast(left_y0), .width = if (edges.left) @intCast(bw) else 0, .height = @intCast(left_y1 - left_y0) },
            .{ .x = @intCast(frame_right), .y = @intCast(right_y0), .width = if (edges.right) @intCast(bw) else 0, .height = @intCast(right_y1 - right_y0) },
            .{ .x = @intCast(top_x0), .y = 0, .width = @intCast(top_x1 - top_x0), .height = if (edges.top) @intCast(bw) else 0 },
            .{ .x = @intCast(bottom_x0), .y = @intCast(frame_bottom), .width = @intCast(bottom_x1 - bottom_x0), .height = if (edges.bottom) @intCast(bw) else 0 },
        },
        .corners = .{
            .{ .x = 0, .y = 0, .width = @intCast(tl), .height = @intCast(tl) },
            .{ .x = @intCast(frame_width - tr), .y = 0, .width = @intCast(tr), .height = @intCast(tr) },
            .{ .x = 0, .y = @intCast(frame_height - bl), .width = @intCast(bl), .height = @intCast(bl) },
            .{ .x = @intCast(frame_width - br), .y = @intCast(frame_height - br), .width = @intCast(br), .height = @intCast(br) },
        },
        .size = size,
    };
}

/// Transform that mirrors the shared corner tile into each corner's own
/// orientation. The tile holds the corner with its outer point at the tile's
/// top-left, so the top-left corner needs no mirroring, the top-right corner is
/// mirrored horizontally, and so on.
fn cornerTransform(index: usize) wl.Output.Transform {
    return switch (index) {
        0 => .normal,
        1 => .flipped,
        2 => .flipped_180,
        3 => .@"180",
        else => unreachable,
    };
}

/// Continuous corner smoothing: how far the corner's shoulder reaches along
/// each edge beyond where a plain quarter circle would touch it, as a fraction
/// of the corner radius. The corner then extends (1 + corner_smoothing) * radius
/// from its outer point and the curvature fades out along the shoulder instead
/// of jumping from 0 to 1/radius where an arc meets an edge. 0 gives back the
/// plain quarter circle.
const corner_smoothing = 0.6;

/// Reach of the corner curve along each edge, in units of the corner radius.
const corner_reach_hat = 1 + corner_smoothing;

/// Samples of the corner's outer boundary, evenly spaced in x over the corner's
/// reach and in units of the corner radius: `y` is the boundary's height at that
/// x, `tx` the x component of its unit tangent there, which turns a vertical
/// offset from the boundary into a distance perpendicular to it.
///
/// The boundary is a circular arc of the corner radius, centered the radius away
/// from both edges exactly where a plain rounded corner has its center, with one
/// cubic Bézier per side joining it to the straight edge: the construction
/// behind Apple's continuous corners, see
/// https://www.figma.com/blog/desperately-seeking-squircles/. The corner is
/// symmetric about its diagonal, so each half is a graph over x and this table
/// evaluates the curve without solving the Bézier per pixel.
const corner_boundary = buildCornerBoundary();

const corner_samples = 33;

const CornerPoint = struct { x: f64, y: f64 };

const CornerSample = struct { y: f64, tx: f64 };

/// Cubic Bézier at parameter `t`.
fn cubicBezier(p0: CornerPoint, c1: CornerPoint, c2: CornerPoint, p1: CornerPoint, t: f64) CornerPoint {
    const u = 1 - t;
    return .{
        .x = u * u * u * p0.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p1.x,
        .y = u * u * u * p0.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p1.y,
    };
}

fn buildCornerBoundary() [corner_samples]CornerSample {
    @setEvalBranchQuota(100000);
    const s = corner_smoothing;
    const reach = corner_reach_hat;
    // Construction parameters for a radius of 1: the arc's chord and the Bézier
    // control point offsets a, b, c, d add up to the reach along each edge.
    const arc_half: f64 = 0.25 * math.pi * (1 - s); // half the arc's angular span
    const arc_chord: f64 = @sin(arc_half) * math.sqrt2;
    const beta: f64 = 0.25 * math.pi * s;
    const c: f64 = @tan(beta / 2.0) * @cos(beta);
    const d: f64 = c * @tan(beta);
    const b: f64 = (reach - arc_chord - c - d) / 3.0;
    const a: f64 = 2 * b;

    const arc_start: CornerPoint = .{ .x = d, .y = reach - a - b - c };
    const arc_end: CornerPoint = .{ .x = d + arc_chord, .y = arc_start.y - arc_chord };
    const to_center: CornerPoint = .{ .x = arc_start.x - 1, .y = arc_start.y - 1 };

    // Dense samples from the left edge to the top edge, for the resampling below.
    const steps = 256;
    var dense: [3 * (steps + 1)]CornerPoint = undefined;
    var n: usize = 0;
    for (0..steps + 1) |i| {
        const t = @as(f64, @floatFromInt(i)) / steps;
        dense[n] = cubicBezier(
            .{ .x = 0, .y = reach },
            .{ .x = 0, .y = reach - a },
            .{ .x = 0, .y = reach - a - b },
            arc_start,
            t,
        );
        n += 1;
    }
    for (0..steps + 1) |i| {
        const angle = 2 * arc_half * @as(f64, @floatFromInt(i)) / steps;
        const cos = @cos(angle);
        const sin = @sin(angle);
        dense[n] = .{
            .x = 1 + to_center.x * cos - to_center.y * sin,
            .y = 1 + to_center.x * sin + to_center.y * cos,
        };
        n += 1;
    }
    for (0..steps + 1) |i| {
        const t = @as(f64, @floatFromInt(i)) / steps;
        dense[n] = cubicBezier(
            arc_end,
            .{ .x = arc_end.x + c, .y = arc_end.y - d },
            .{ .x = arc_end.x + b + c, .y = arc_end.y - d },
            .{ .x = reach, .y = 0 },
            t,
        );
        n += 1;
    }

    var out: [corner_samples]CornerSample = undefined;
    var slot: usize = 0;
    for (&out, 0..) |*sample, i| {
        const x = reach * @as(f64, @floatFromInt(i)) / (corner_samples - 1);
        while (slot + 2 < n and dense[slot + 1].x < x) slot += 1;
        const lo = dense[slot];
        const hi = dense[slot + 1];
        // The tangent comes from the neighbouring samples so that it is defined
        // at both ends of the curve as well.
        const before = if (slot > 0) dense[slot - 1] else lo;
        const after = if (slot + 2 < n) dense[slot + 2] else hi;
        const dx = after.x - before.x;
        const dy = after.y - before.y;
        const span = hi.x - lo.x;
        sample.* = .{
            .y = lo.y + (hi.y - lo.y) * (if (span > 0) (x - lo.x) / span else 0),
            .tx = if (dx == 0 and dy == 0) 0 else @abs(dx) / @sqrt(dx * dx + dy * dy),
        };
    }
    return out;
}

/// Boundary sample at `x`, in units of the corner radius, interpolated between
/// the table's entries.
fn cornerBoundaryAt(x: f64) CornerSample {
    const last = corner_samples - 1;
    const u = @min(@max(x / corner_reach_hat, 0), 1) * @as(f64, @floatFromInt(last));
    const lo = @min(@as(usize, @intFromFloat(@floor(u))), last);
    const hi = @min(lo + 1, last);
    const f = u - @floor(u);
    return .{
        .y = corner_boundary[lo].y + (corner_boundary[hi].y - corner_boundary[lo].y) * f,
        .tx = corner_boundary[lo].tx + (corner_boundary[hi].tx - corner_boundary[lo].tx) * f,
    };
}

/// Signed distance from the corner's outline at a pixel center (x, y) in corner
/// coordinates (the corner's outer point is the origin): positive inside the
/// window, in pixels. The outline is symmetric about the corner's diagonal, so
/// the half where y > x is evaluated as the mirror image of the other one.
fn cornerDistance(x: f64, y: f64, r: f64) f64 {
    const along = @max(x, y);
    const across = @min(x, y);
    // The outline is vertical at the corner's outer point, where the graph
    // degenerates: that point is outside the outline for any radius.
    if (along == 0) return -r;
    const boundary = cornerBoundaryAt(along / r);
    return (across / r - boundary.y) * boundary.tx * r;
}

/// Largest corner radius (pixels) for a border of the given width that keeps the
/// content's square corners inside the outline, so no content pokes out of the
/// rounded shape. The arc reaches radius * (1 - 1/sqrt(2)) along the corner's
/// diagonal, like a plain quarter circle, so the content corner at (bw, bw)
/// stays inside as long as radius <= (bw + 0.5) * (2 + sqrt(2)); the 0.5 leaves
/// room for the feather.
fn overflowFreeRadius(bw: usize) usize {
    const max = (@as(f64, @floatFromInt(bw)) + 0.5) * (2.0 + math.sqrt2);
    return @intFromFloat(@floor(max));
}

/// Reach of a corner in pixels: the side of the square a corner texture covers.
fn cornerSize(radius: usize) usize {
    return @intFromFloat(@ceil(@as(f64, @floatFromInt(radius)) * corner_reach_hat));
}

/// Corner radius used for a window: the requested radius, capped so that the
/// corner squares of neighbouring corners stay disjoint — the curve reaches
/// (1 + smoothing) * radius from each corner — and so that the content's square
/// corners stay inside the outline (see overflowFreeRadius).
fn effectiveRadius(content_width: usize, content_height: usize, bw: usize, requested: usize) usize {
    const frame = @min(content_width + 2 * bw, content_height + 2 * bw);
    const disjoint = @floor(@as(f64, @floatFromInt(frame)) / (2 * corner_reach_hat));
    return @min(@min(requested, overflowFreeRadius(bw)), @as(usize, @intFromFloat(disjoint)));
}

/// Device pixel size of a corner texture: the corner square is `size` logical
/// pixels, rasterized at `scale` device pixels per logical pixel so the arc
/// stays crisp on HiDPI outputs.
fn cornerRaster(size: usize, scale: f64) usize {
    const scaled = @ceil(@as(f64, @floatFromInt(size)) * scale);
    if (!(scaled >= 1)) return 1;
    return @intFromFloat(scaled);
}

/// Device pixels per logical pixel of a corner texture. The texture is drawn in
/// exactly `size` logical pixels, so this ratio — not the output scale — maps
/// texel centers to logical coordinates. `cornerRaster` rounds the raster size
/// up, so the two differ on fractional-scale outputs: using the output scale
/// there would sample a grid that is too wide for the square.
fn cornerScale(raster: usize, size: usize) f64 {
    return @as(f64, @floatFromInt(raster)) / @as(f64, @floatFromInt(size));
}

/// Coverage of the point (x, y) — a pixel center in corner coordinates —
/// relative to a rounded corner of radius r: 1 = fully inside the rounded
/// outline, 0 = fully cut away. The outline is feathered over one pixel.
fn cornerCoverage(x: f64, y: f64, r: f64) f64 {
    return @max(0, @min(1, 0.5 + cornerDistance(x, y, r)));
}

/// Coverage of the border ring's corner band over the window corner: the part
/// of the outline within the border's thickness of it. The band is what makes
/// the two strips visibly join around the corner when the border is thinner
/// than the corner radius, and it is drawn above the window content. Its outer
/// edge is feathered like the outline, its inner edge a hard cut.
fn bandCoverage(x: f64, y: f64, r: f64, bw: f64) f64 {
    const distance = cornerDistance(x, y, r);
    if (distance < 0 or distance > bw) return 0; // cut away, or inside the ring's inner edge
    return @min(1, 0.5 + distance);
}

/// Ring membership and coverage at a pixel center (x, y) in corner coordinates:
/// returns 0 for points that are not part of the border ring. The corner is
/// rounded, so both of its edges are drawn; the straight parts of the ring are
/// drawn by the strips outside the corner square.
fn cornerRingCoverage(x: f64, y: f64, r: f64, bw: f64) f64 {
    const reach = r * corner_reach_hat;
    // The arms are the two strips joining at this corner.
    const arm = x < bw or y < bw;
    if (x < reach and y < reach) {
        return if (arm) cornerCoverage(x, y, r) else bandCoverage(x, y, r, bw);
    }
    return if (arm) 1 else 0;
}

/// The border nodes owned by a window.
pub const Nodes = struct {
    /// Solid edge strips (left, right, top, bottom); the anti-aliased corners
    /// cannot be drawn with scene rects, so they use small textures.
    strips: [4]*wlr.SceneRect,
    /// Corner textures (top-left, top-right, bottom-left, bottom-right).
    corners: [4]*wlr.SceneBuffer,
};

/// Inputs of the last border textures, so draw() can skip the render and upload
/// work on render sequences where nothing changed. `radius` is the per-window
/// clamped one; the frame size is compared separately, because the corner
/// tiles do not depend on it.
pub const Cache = struct {
    valid: bool = false,
    scale: f64 = 1,
    radius: usize = 0,
    width: u31 = 0,
    color: u32 = 0,
    edges: u32 = 0,
    content_width: u31 = 0,
    content_height: u31 = 0,
    clip: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    /// The tiles of the last draw, one per distinct tile; a corner whose tile
    /// matches an earlier one draws with it (see `alias`).
    tiles: [4]?*Tile = .{ null, null, null, null },
    /// For each corner, the entry of `tiles` that draws it.
    alias: [4]u8 = .{ 0, 1, 2, 3 },
};

/// One border draw for one window.
pub const Params = struct {
    /// The window's content box in window coordinates.
    content: wlr.Box,
    /// The content clip box requested by the wm.
    content_clip: wlr.Box,
    /// The clip box requested by the wm, in window coordinates.
    clip: wlr.Box,
    border: Border,
    /// The radius requested by the config, before the per-window clamp.
    radius: usize,
    /// The scale of the output the window is on.
    scale: f64,
};

/// Corner textures are decoration drawn over the window's content, so a click
/// over one belongs to the content below it rather than to the texture. This is
/// wlroots' hook for exactly that; upstream's border rects only ever sit outside
/// the content box, which is why its hit testing needs no such thing.
fn cornerRejectsInput(_: *wlr.SceneBuffer, _: *f64, _: *f64) callconv(.c) bool {
    return false;
}

/// Create one corner node. Its transform never changes: it is what mirrors the
/// shared tile into this corner's orientation.
pub fn createCorner(tree: *wlr.SceneTree, index: usize) error{OutOfMemory}!*wlr.SceneBuffer {
    const scene_buffer = try tree.createSceneBuffer(null);
    scene_buffer.point_accepts_input = cornerRejectsInput;
    scene_buffer.setTransform(cornerTransform(index));
    return scene_buffer;
}

/// The box the border ring is drawn around: the content box, clipped to the
/// content clip box when the wm set one, per the protocol. Null when the clip
/// leaves no content, in which case there is no border to draw either. Only the
/// resulting size is used, as in upstream's border drawing.
fn borderContentBox(content: wlr.Box, content_clip: wlr.Box) ?wlr.Box {
    if (content_clip.empty()) return content;
    var clipped = content;
    if (!clipped.intersection(&clipped, &content_clip)) return null;
    return clipped;
}

/// What a corner tile holds. Two corners with equal keys draw the same pixels,
/// so they share one textured buffer.
const TileKey = struct {
    raster: usize,
    radius: usize,
    width: usize,
    color: u32,
    /// The wm's clip box in the tile's own frame; empty for no clipping.
    clip: wlr.Box,
};

/// A corner tile in the shared cache. Every window whose border needs the same
/// pixels holds a reference to the one tile, so a focus or border color change
/// reuses the texture instead of rasterizing and uploading one per window.
///
/// The frame holds the cache's own reference; the scene buffers hold their own,
/// so the pixels outlive an eviction until the nodes using them are repainted.
const Tile = struct {
    key: TileKey,
    frame: *FrameBuffer,
    /// References held by windows; the cache's own reference is implicit in the
    /// entry being resident.
    refs: u32 = 1,
    last_used: u64 = 0,
    /// False for a tile the cache had no room for: the last window to release
    /// it frees it.
    cached: bool = true,
};

/// How many different tiles stay resident. A window needs at most four (one per
/// corner, and only when the wm clips it), and all windows of one border color
/// and scale share one, so this covers several colors and scales at once.
///
/// shortcut: the key is found by linear scan and more than this many live keys
/// fall back to a tile per window; upgrade to a hash map if a wm ever makes
/// borders differ between windows.
const tile_cache_capacity = 8;

var tile_cache: [tile_cache_capacity]?*Tile = .{ null, null, null, null, null, null, null, null };
var tile_cache_clock: u64 = 0;

/// Tiles rasterized since startup, which the tests use to prove that a cached
/// border is not filled again.
pub var tiles_created: u64 = 0;

fn sameTileKey(a: TileKey, b: TileKey) bool {
    return a.raster == b.raster and a.radius == b.radius and a.width == b.width and
        a.color == b.color and a.clip.x == b.clip.x and a.clip.y == b.clip.y and
        a.clip.width == b.clip.width and a.clip.height == b.clip.height;
}

/// Drop a tile's frame and the tile itself. The scene buffers may still hold
/// references to the buffer, so the pixels stay alive until those nodes are
/// repainted or destroyed.
fn freeTile(tile: *Tile) void {
    tile.frame.base.drop();
    util.gpa.destroy(tile);
}

/// The tile for `key`, rasterizing it on the first use. The caller gets a
/// reference it must hand back with releaseTile().
fn acquireTile(key: TileKey, ctx: *const TileFillContext, sample_scale: f64) error{OutOfMemory}!*Tile {
    tile_cache_clock += 1;
    for (tile_cache) |entry| {
        if (entry) |tile| {
            if (sameTileKey(tile.key, key)) {
                tile.refs += 1;
                tile.last_used = tile_cache_clock;
                return tile;
            }
        }
    }

    const frame = try FrameBuffer.create(key.raster, key.raster);
    errdefer frame.base.drop();
    frame.fillCorner(ctx, key.clip, sample_scale);
    tiles_created += 1;

    const tile = try util.gpa.create(Tile);
    tile.* = .{
        .key = key,
        .frame = frame,
        .last_used = tile_cache_clock,
    };
    insertTile(tile);
    return tile;
}

/// Put a new tile in the cache, making room by dropping the least recently used
/// tile no window is using. A cache with no room left keeps the tile out of it:
/// the last window to release it frees it.
fn insertTile(tile: *Tile) void {
    var empty: ?usize = null;
    var evict: ?usize = null;
    for (tile_cache, 0..) |entry, i| {
        const resident = entry orelse {
            empty = i;
            break;
        };
        if (resident.refs == 0) {
            if (evict == null or resident.last_used < tile_cache[evict.?].?.last_used) evict = i;
        }
    }

    if (empty) |i| {
        tile_cache[i] = tile;
    } else if (evict) |i| {
        freeTile(tile_cache[i].?);
        tile_cache[i] = tile;
    } else {
        tile.cached = false;
    }
}

fn releaseTile(tile: *Tile) void {
    assert(tile.refs > 0);
    tile.refs -= 1;
    if (tile.refs == 0 and !tile.cached) freeTile(tile);
}

/// Release every distinct tile of one window, skipping the corners that share a
/// tile with an earlier one.
fn releaseTiles(tiles: [4]?*Tile, alias: [4]u8) void {
    for (tiles, 0..) |tile, i| {
        if (i != alias[i]) continue;
        if (tile) |t| releaseTile(t);
    }
}

/// Drop every cached tile. Only for tests and shutdown; the scene buffers keep
/// their own references.
pub fn deinitTiles() void {
    for (&tile_cache) |*entry| {
        if (entry.*) |tile| freeTile(tile);
        entry.* = null;
    }
}

/// The tiles built for one draw.
const Tiles = struct {
    /// One referenced tile per distinct key.
    owned: [4]?*Tile = .{ null, null, null, null },
    /// For each corner, the entry of `owned` that draws it.
    alias: [4]u8 = .{ 0, 1, 2, 3 },
};

fn colorKey(color: [4]u8) u32 {
    return @as(u32, color[0]) |
        @as(u32, color[1]) << 8 |
        @as(u32, color[2]) << 16 |
        @as(u32, color[3]) << 24;
}

/// The wm's clip box — in frame coordinates — as seen inside one corner's tile:
/// what the clip leaves of the corner square, in the tile's own frame. Null
/// when the clip leaves nothing of the corner, which draws no tile at all.
fn cornerClip(index: usize, corner: wlr.Box, clip: wlr.Box) ?wlr.Box {
    if (clip.empty()) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    var box = corner;
    if (!box.intersection(&box, &clip)) return null;
    // Mirror into the tile's frame the same way cornerTransform() mirrors the
    // tile: the tile's x axis runs into the window from the corner's own edge.
    const size: c_int = corner.width;
    const x: c_int = if (index == 1 or index == 3) size - (box.x + box.width - corner.x) else box.x - corner.x;
    const y: c_int = if (index == 2 or index == 3) size - (box.y + box.height - corner.y) else box.y - corner.y;
    return .{ .x = x, .y = y, .width = box.width, .height = box.height };
}

fn buildTiles(
    geometry: BorderGeometry,
    radius: usize,
    width: usize,
    color: [4]u8,
    clip: wlr.Box,
    scale: f64,
) error{OutOfMemory}!Tiles {
    var tiles: Tiles = .{};
    errdefer releaseTiles(tiles.owned, tiles.alias);

    const raster = cornerRaster(geometry.size, scale);
    const sample_scale = cornerScale(raster, geometry.size);
    const ctx = TileFillContext{
        .bw = @floatFromInt(width),
        .radius = @floatFromInt(radius),
        .color = color,
    };

    var keys: [4]?TileKey = .{ null, null, null, null };
    for (0..4) |i| {
        if (geometry.corners[i].width == 0) continue;
        const local = cornerClip(i, geometry.corners[i], clip) orelse continue;
        const key = TileKey{
            .raster = raster,
            .radius = radius,
            .width = width,
            .color = colorKey(color),
            .clip = local,
        };
        var reuse: ?u8 = null;
        for (0..i) |j| {
            if (keys[j]) |j_key| {
                if (sameTileKey(j_key, key)) {
                    reuse = tiles.alias[j];
                    break;
                }
            }
        }
        if (reuse) |j| {
            tiles.alias[i] = j;
            continue;
        }
        keys[i] = key;
        tiles.owned[i] = try acquireTile(key, &ctx, sample_scale);
        tiles.alias[i] = @intCast(i);
    }
    return tiles;
}

fn sameTexture(cache: *const Cache, radius: usize, width: u31, color: u32, edges: u32, clip: wlr.Box, scale: f64) bool {
    return cache.valid and cache.scale == scale and cache.radius == radius and
        cache.width == width and cache.color == color and cache.edges == edges and
        cache.clip.x == clip.x and cache.clip.y == clip.y and
        cache.clip.width == clip.width and cache.clip.height == clip.height;
}

fn sameFrame(cache: *const Cache, content_width: u31, content_height: u31) bool {
    return cache.content_width == content_width and cache.content_height == content_height;
}

pub fn draw(cache: *Cache, nodes: Nodes, p: Params) void {
    const border = &p.border;
    const border_width = border.width;
    const edges = border.edges;

    // A window the wm has clipped keeps its border at the clip edge. This also
    // covers a fully clipped window (e.g. a closing animation), which draws no
    // border at all.
    const content_box = borderContentBox(p.content, p.content_clip) orelse {
        hide(nodes);
        return;
    };
    const content_width: usize = @intCast(content_box.width);
    const content_height: usize = @intCast(content_box.height);
    const drawable = border_width != 0 and content_width != 0 and content_height != 0 and
        (edges.top or edges.bottom or edges.left or edges.right);

    if (!drawable) {
        hide(nodes);
        return;
    }

    // The corner textures are rasterized at the scale of the output the window
    // is on, so the corners stay crisp on HiDPI outputs.
    const scale = p.scale;

    const frame_width = content_width + 2 * border_width;
    const frame_height = content_height + 2 * border_width;
    // wlroots stores buffer sizes as c_int.
    if (frame_width > math.maxInt(c_int) or frame_height > math.maxInt(c_int)) {
        hide(nodes);
        return;
    }

    // The scene graph cannot clip client content to a rounded rect, so the
    // effective radius is bounded by the border width and by the frame: see
    // effectiveRadius().
    const radius = effectiveRadius(
        content_width,
        content_height,
        border_width,
        p.radius,
    );
    const geometry = borderGeometry(content_width, content_height, border_width, radius, edges);

    // The border color is premultiplied per the protocol.
    const color: [4]u8 = .{
        @intCast(border.r >> 24),
        @intCast(border.g >> 24),
        @intCast(border.b >> 24),
        @intCast(border.a >> 24),
    };

    // Skip the work when nothing changed since the last render sequence (this
    // function runs for every window on every sequence). The textures and the
    // frame are compared separately: a corner's pattern only depends on the
    // corner parameters, not on the window size, so a resize only has to move
    // the nodes.
    const texture_unchanged = sameTexture(cache, radius, border.width, colorKey(color), @bitCast(edges), p.clip, scale);
    const frame_unchanged = sameFrame(cache, @intCast(content_width), @intCast(content_height));
    if (texture_unchanged and frame_unchanged) {
        // Re-enable in case the nodes were disabled while fullscreen.
        show(nodes);
        return;
    }

    const color_f32: [4]f32 = .{
        @as(f32, @floatFromInt(color[0])) / 255.0,
        @as(f32, @floatFromInt(color[1])) / 255.0,
        @as(f32, @floatFromInt(color[2])) / 255.0,
        @as(f32, @floatFromInt(color[3])) / 255.0,
    };

    // The geometry is in frame coordinates; the clip arrives in window ones.
    var clip = p.clip;
    if (!clip.empty()) {
        clip.x += @intCast(border_width);
        clip.y += @intCast(border_width);
    }
    const offset: c_int = -@as(c_int, @intCast(border_width));

    for (geometry.strips, nodes.strips) |strip, rect| {
        var box = strip;
        if (!clip.empty()) _ = box.intersection(&box, &clip);
        rect.node.setEnabled(true);
        rect.setColor(&color_f32);
        if (box.width > 0 and box.height > 0) {
            rect.setSize(box.width, box.height);
            rect.node.setPosition(box.x + offset, box.y + offset);
        } else {
            rect.setSize(0, 0);
        }
    }

    if (!texture_unchanged) {
        const old_tiles = cache.tiles;
        const old_alias = cache.alias;
        const tiles = buildTiles(geometry, radius, border_width, color, clip, scale) catch {
            std.log.err("out of memory drawing window borders", .{});
            return;
        };
        for (geometry.corners, nodes.corners, 0..) |corner, scene_buffer, i| {
            // The scene buffer holds a reference of its own, so the tile stays
            // alive until the next draw replaces it.
            if (tiles.owned[tiles.alias[i]]) |tile| {
                scene_buffer.setBuffer(&tile.frame.base);
                scene_buffer.node.setEnabled(true);
                // Display the device resolution texture at its logical size.
                scene_buffer.setDestSize(@intCast(geometry.size), @intCast(geometry.size));
            } else {
                scene_buffer.node.setEnabled(false);
            }
            scene_buffer.node.setPosition(corner.x + offset, corner.y + offset);
        }
        releaseTiles(old_tiles, old_alias);
        cache.tiles = tiles.owned;
        cache.alias = tiles.alias;
    } else {
        for (geometry.corners, nodes.corners, 0..) |corner, scene_buffer, i| {
            if (cache.tiles[cache.alias[i]] != null) {
                scene_buffer.node.setEnabled(true);
            } else {
                scene_buffer.node.setEnabled(false);
            }
            scene_buffer.node.setPosition(corner.x + offset, corner.y + offset);
        }
    }

    cache.valid = true;
    cache.scale = scale;
    cache.radius = radius;
    cache.width = border.width;
    cache.color = colorKey(color);
    cache.edges = @bitCast(edges);
    cache.content_width = @intCast(content_width);
    cache.content_height = @intCast(content_height);
    cache.clip = p.clip;
}

/// Drop this window's corner tiles. The scene buffers may still hold references
/// to them, so the pixels stay alive until those nodes are repainted or
/// destroyed.
pub fn release(cache: *Cache) void {
    releaseTiles(cache.tiles, cache.alias);
    cache.* = .{};
}

/// Hide every border node (no visible border, e.g. fullscreen or a fully
/// clipped window). The corner textures are kept so that the cache still
/// holds when the border comes back.
pub fn hide(nodes: Nodes) void {
    for (nodes.strips) |rect| rect.node.setEnabled(false);
    for (nodes.corners) |scene_buffer| scene_buffer.node.setEnabled(false);
}

/// Re-enable the border nodes, which are kept around between renders.
pub fn show(nodes: Nodes) void {
    for (nodes.strips) |rect| rect.node.setEnabled(true);
    for (nodes.corners) |scene_buffer| scene_buffer.node.setEnabled(true);
}

test "rounded border corner coverage" {
    const testing = std.testing;
    // The corner's outer point and the pixel center next to it are cut away.
    try testing.expectEqual(@as(f64, 0), cornerCoverage(0, 0, 10));
    try testing.expectEqual(@as(f64, 0), cornerCoverage(0.5, 0.5, 10));
    // Deep inside the outline is fully covered, in the middle and on either
    // side of the corner's diagonal.
    try testing.expectEqual(@as(f64, 1), cornerCoverage(9, 9, 10));
    try testing.expectEqual(@as(f64, 1), cornerCoverage(1, 12, 10));
    try testing.expectEqual(@as(f64, 1), cornerCoverage(17, 17, 10));
    // The arc reaches radius * (1 - 1/sqrt(2)) along the diagonal, as a plain
    // quarter circle does, so the feather puts the coverage halfway there.
    const diagonal = 10.0 * (1 - 1.0 / math.sqrt2);
    try testing.expectApproxEqAbs(@as(f64, 0.5), cornerCoverage(diagonal, diagonal, 10), 0.05);
    // The shoulder reaches past the radius and beyond a plain arc: this point
    // is outside the quarter circle of the same radius but inside the outline.
    try testing.expect(cornerCoverage(13, 0.2, 10) > 0.5);
    // The overflow-free radius bound keeps content corners inside the outline.
    try testing.expectEqual(@as(usize, 5), overflowFreeRadius(1));
    try testing.expectEqual(@as(usize, 8), overflowFreeRadius(2));
    try testing.expectEqual(@as(usize, 11), overflowFreeRadius(3));
}

test "the effective radius keeps corner squares disjoint" {
    const testing = std.testing;
    // A window with room for it gets the requested radius.
    try testing.expectEqual(@as(usize, 10), effectiveRadius(200, 100, 3, 10));
    // Without the frame cap the corner squares of a small window would overlap,
    // which is what the cap is for: 2 * cornerExtent(11, 3) does not fit in 26.
    try testing.expect(2 * cornerExtent(overflowFreeRadius(3), 3) > 20 + 2 * 3);
    inline for (.{ 200, 40, 30, 20, 10 }) |width| {
        const radius = effectiveRadius(width, width, 3, 30);
        try testing.expect(2 * cornerExtent(radius, 3) <= width + 2 * 3);
    }
    // A border wider than the corner curve is part of the square too.
    inline for (.{ 200, 60, 20 }) |width| {
        const radius = effectiveRadius(width, width, 20, 30);
        try testing.expect(2 * cornerExtent(radius, 20) <= width + 2 * 20);
    }
}

test "border ring corner band spans the content corner" {
    const testing = std.testing;
    // bw=2, r=10: the band is the ring's thickness inward from the outline.
    // The arc band crosses the content corner, joining the strips.
    try testing.expect(cornerRingCoverage(3, 3, 10, 2) > 0);
    // Deep inside the content corner (inside the ring's inner edge) is empty.
    try testing.expectEqual(@as(f64, 0), cornerRingCoverage(5, 5, 10, 2));
    // The very corner is trimmed by the arc.
    try testing.expectEqual(@as(f64, 0), cornerRingCoverage(0, 0, 10, 2));
    // The straight strip parts are solid, on either arm.
    try testing.expectEqual(@as(f64, 1), cornerRingCoverage(1, 20, 10, 2));
    try testing.expectEqual(@as(f64, 1), cornerRingCoverage(20, 1, 10, 2));
    // Inside the content box away from the corner there is no border.
    try testing.expectEqual(@as(f64, 0), cornerRingCoverage(20, 20, 10, 2));
}

fn hasPartialCoverage(frame: *const FrameBuffer, raster: usize) bool {
    const pixels: [*]const u32 = @ptrCast(@alignCast(frame.pixels.ptr));
    for (pixels[0 .. raster * raster]) |pixel| {
        const alpha = pixel >> 24;
        if (alpha > 0 and alpha < 255) return true;
    }
    return false;
}

fn expectBox(expected: wlr.Box, actual: wlr.Box) !void {
    try std.testing.expectEqual(expected.x, actual.x);
    try std.testing.expectEqual(expected.y, actual.y);
    try std.testing.expectEqual(expected.width, actual.width);
    try std.testing.expectEqual(expected.height, actual.height);
}

fn boxContains(box: wlr.Box, px: usize, py: usize) bool {
    if (box.width <= 0 or box.height <= 0) return false;
    const x: usize = @intCast(box.x);
    const y: usize = @intCast(box.y);
    const w: usize = @intCast(box.width);
    const h: usize = @intCast(box.height);
    return px >= x and px < x + w and py >= y and py < y + h;
}

/// The corner's own frame of one frame pixel: the outer point is the origin and
/// the axes run into the window, which is the mirroring cornerTransform() and
/// cornerClip() undo.
fn cornerLocal(index: usize, corner: wlr.Box, px: usize, py: usize) [2]f64 {
    const x = @as(f64, @floatFromInt(px)) + 0.5 - @as(f64, @floatFromInt(corner.x));
    const y = @as(f64, @floatFromInt(py)) + 0.5 - @as(f64, @floatFromInt(corner.y));
    const size: f64 = @floatFromInt(corner.width);
    return .{
        if (index == 1 or index == 3) size - x else x,
        if (index == 2 or index == 3) size - y else y,
    };
}

/// Upstream's border rects: what the split into strips and corner squares has to
/// cover, pixel for pixel, as upstream draws it.
fn upstreamRing(
    edges: river.WindowV1.Edges,
    content_width: usize,
    content_height: usize,
    bw: usize,
    px: usize,
    py: usize,
) bool {
    const frame_right = content_width + bw;
    const frame_bottom = content_height + bw;
    const frame_height = frame_bottom + bw;
    // The side rects reach into the corner square of an adjacent edge only when
    // that edge is drawn; see upstream's drawBorders().
    const y_lo: usize = if (edges.top) 0 else bw;
    const y_hi: usize = if (edges.bottom) frame_height else frame_bottom;
    const in_left = edges.left and px < bw and py >= y_lo and py < y_hi;
    const in_right = edges.right and px >= frame_right and py >= y_lo and py < y_hi;
    const in_top = edges.top and py < bw and px >= bw and px < frame_right;
    const in_bottom = edges.bottom and py >= frame_bottom and px >= bw and px < frame_right;
    return in_left or in_right or in_top or in_bottom;
}

test "border geometry keeps the strips clear of the corners" {
    const testing = std.testing;
    const all: river.WindowV1.Edges = .{ .top = true, .bottom = true, .left = true, .right = true };
    const g = borderGeometry(100, 50, 3, 10, all);
    // Frame 106x56: the corner square is 16px (the corner reaches
    // (1 + smoothing) * radius along the edges) and takes that much off each
    // strip end.
    try testing.expectEqual(cornerSize(10), g.size);
    try expectBox(.{ .x = 0, .y = 16, .width = 3, .height = 24 }, g.strips[0]);
    try expectBox(.{ .x = 103, .y = 16, .width = 3, .height = 24 }, g.strips[1]);
    try expectBox(.{ .x = 16, .y = 0, .width = 74, .height = 3 }, g.strips[2]);
    try expectBox(.{ .x = 16, .y = 53, .width = 74, .height = 3 }, g.strips[3]);
    try expectBox(.{ .x = 0, .y = 0, .width = 16, .height = 16 }, g.corners[0]);
    try expectBox(.{ .x = 90, .y = 0, .width = 16, .height = 16 }, g.corners[1]);
    try expectBox(.{ .x = 0, .y = 40, .width = 16, .height = 16 }, g.corners[2]);
    try expectBox(.{ .x = 90, .y = 40, .width = 16, .height = 16 }, g.corners[3]);

    // An edge that is not drawn gets an empty strip.
    const left_top = borderGeometry(100, 50, 3, 10, .{ .top = true, .left = true });
    try testing.expectEqual(@as(c_int, 3), left_top.strips[0].width);
    try testing.expectEqual(@as(c_int, 0), left_top.strips[1].width);
    try testing.expectEqual(@as(c_int, 0), left_top.strips[3].height);

    // Without both edges of a corner the corner is left to the strips, exactly
    // as upstream's rects cover it.
    try testing.expect(boxContains(left_top.corners[1], 0, 0) == false);
    try testing.expect(boxContains(left_top.corners[3], 0, 0) == false);
    try expectBox(.{ .x = 0, .y = 0, .width = 16, .height = 16 }, left_top.corners[0]);
    try expectBox(.{ .x = 0, .y = 16, .width = 3, .height = 37 }, left_top.strips[0]);
    try expectBox(.{ .x = 16, .y = 0, .width = 87, .height = 3 }, left_top.strips[2]);

    // A square-cornered border needs no texture at all.
    const square = borderGeometry(100, 50, 3, 0, all);
    try testing.expectEqual(@as(usize, 0), square.size);
    for (square.corners) |corner| try testing.expect(boxContains(corner, 0, 0) == false);
    try expectBox(.{ .x = 0, .y = 0, .width = 3, .height = 56 }, square.strips[0]);

    // A corner square is never narrower than a strip.
    const thick = borderGeometry(100, 50, 20, 10, all);
    try testing.expectEqual(@as(usize, 20), thick.size);
}

test "corner textures are rasterized at the output scale" {
    const testing = std.testing;
    // The texture is never smaller than the logical square: the arc is never
    // upscaled, only downscaled onto the output.
    try testing.expectEqual(@as(usize, 10), cornerRaster(10, 1));
    try testing.expectEqual(@as(usize, 20), cornerRaster(10, 2));
    try testing.expectEqual(@as(usize, 15), cornerRaster(10, 1.5));
    try testing.expectEqual(@as(usize, 13), cornerRaster(10, 1.25));
    try testing.expectEqual(@as(usize, 1), cornerRaster(1, 0.5));
}

test "corner texture grid spans exactly the logical square" {
    const testing = std.testing;
    const size = 10;
    // Rounding the raster up makes the texture's own ratio (13/10 = 1.3) differ
    // from the output scale (1.25). Sampling with the output scale would cover
    // 13/1.25 = 10.4 logical pixels, i.e. overshoot the square.
    const raster = cornerRaster(size, 1.25);
    try testing.expectEqual(@as(usize, 13), raster);
    try testing.expect(cornerScale(raster, size) > 1.25);

    // The texel grid spans exactly the square: the ratio times the logical size
    // is the raster again, and both outer texel centers stay inside it.
    const scale = cornerScale(raster, size);
    try testing.expectApproxEqAbs(@as(f64, @floatFromInt(raster)), scale * size, 1e-9);
    try testing.expect(0.5 / scale > 0);
    try testing.expect((@as(f64, @floatFromInt(raster)) - 0.5) / scale < size);

    // On an integer scale the two ratios are identical, which is why the
    // mismatch only shows up on fractional-scale outputs.
    try testing.expectEqual(@as(f64, 2), cornerScale(cornerRaster(11, 2), 11));
}

/// Which axes a transform mirrors, per the wayland definition of the flipped
/// values: an initial flip around a vertical axis, then the rotation.
fn transformMirrors(transform: wl.Output.Transform) struct { horizontal: bool, vertical: bool } {
    return switch (transform) {
        .normal => .{ .horizontal = false, .vertical = false },
        .flipped => .{ .horizontal = true, .vertical = false },
        .flipped_180 => .{ .horizontal = false, .vertical = true },
        .@"180" => .{ .horizontal = true, .vertical = true },
        else => unreachable,
    };
}

test "corner tiles are mirrored into the other corners" {
    const testing = std.testing;
    const bw = 3;
    const radius = 10;
    const size = cornerExtent(radius, bw);
    const raster = cornerRaster(size, 1);
    try testing.expectEqual(size, raster);
    const sample_scale = cornerScale(raster, size);
    const color = [4]u8{ 200, 100, 50, 255 };
    const ctx = TileFillContext{
        .bw = @floatFromInt(bw),
        .radius = @floatFromInt(radius),
        .color = color,
    };
    const no_clip: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 };

    const tile = try FrameBuffer.create(raster, raster);
    defer tile.base.drop();
    tile.fillCorner(&ctx, no_clip, sample_scale);
    try testing.expect(hasPartialCoverage(tile, raster));

    // The tile holds the corner with its outer point at the tile's top-left.
    // Mirroring it the way its transform does has to give the coverage the
    // corner needs in the frame, which is what the corners were rasterized to
    // one by one before they shared a tile.
    const frame_width = 106;
    const frame_height = 56;
    const corners = [4]wlr.Box{
        .{ .x = 0, .y = 0, .width = @intCast(size), .height = @intCast(size) },
        .{ .x = @intCast(frame_width - size), .y = 0, .width = @intCast(size), .height = @intCast(size) },
        .{ .x = 0, .y = @intCast(frame_height - size), .width = @intCast(size), .height = @intCast(size) },
        .{ .x = @intCast(frame_width - size), .y = @intCast(frame_height - size), .width = @intCast(size), .height = @intCast(size) },
    };
    const pixels: [*]const u32 = @ptrCast(@alignCast(tile.pixels.ptr));

    for (0..4) |index| {
        const corner = corners[index];
        const mirrors = transformMirrors(cornerTransform(index));
        var j: usize = 0;
        while (j < raster) : (j += 1) {
            var i: usize = 0;
            while (i < raster) : (i += 1) {
                // Pixel of the corner square this texel is drawn at, then the
                // frame point that pixel covers in this corner's own frame.
                const px = corner.x + @as(c_int, @intCast(if (mirrors.horizontal) raster - 1 - i else i));
                const py = corner.y + @as(c_int, @intCast(if (mirrors.vertical) raster - 1 - j else j));
                const local = cornerLocal(index, corner, @intCast(px), @intCast(py));
                const expected = cornerRingCoverage(local[0], local[1], @floatFromInt(radius), @floatFromInt(bw));
                // The transform places this texel at that pixel, unchanged.
                const alpha = pixels[j * raster + i] >> 24;
                const shown = @as(f64, @floatFromInt(alpha)) / @as(f64, color[3]);
                try testing.expectApproxEqAbs(expected, shown, 1.0 / 255.0);
            }
        }
    }
}

test "a clip box maps into each corner's own frame" {
    const testing = std.testing;
    const size = 16;
    const no_clip: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    const tl = wlr.Box{ .x = 0, .y = 0, .width = size, .height = size };
    const tr = wlr.Box{ .x = 100 - size, .y = 0, .width = size, .height = size };
    const bl = wlr.Box{ .x = 0, .y = 40, .width = size, .height = size };
    const br = wlr.Box{ .x = 100 - size, .y = 40, .width = size, .height = size };

    // No clip leaves the whole tile.
    try expectBox(no_clip, cornerClip(0, tl, no_clip).?);

    // A clip that cuts the frame's left edge away leaves the right part of the
    // top-left tile (its x runs away from the outer point) and all of the
    // top-right one.
    const left_clip = wlr.Box{ .x = 8, .y = 0, .width = 92, .height = 100 };
    try expectBox(.{ .x = 8, .y = 0, .width = 8, .height = 16 }, cornerClip(0, tl, left_clip).?);
    try expectBox(.{ .x = 0, .y = 0, .width = 16, .height = 16 }, cornerClip(1, tr, left_clip).?);

    // ... and a clip that cuts the frame's right edge away cuts the top-right
    // tile near its outer point instead, i.e. mirrored.
    const right_clip = wlr.Box{ .x = 0, .y = 0, .width = 92, .height = 100 };
    try expectBox(.{ .x = 0, .y = 0, .width = 16, .height = 16 }, cornerClip(0, tl, right_clip).?);
    try expectBox(.{ .x = 8, .y = 0, .width = 8, .height = 16 }, cornerClip(1, tr, right_clip).?);

    // The bottom corners are mirrored vertically.
    const top_clip = wlr.Box{ .x = 0, .y = 0, .width = 100, .height = 48 };
    try expectBox(.{ .x = 0, .y = 0, .width = 16, .height = 16 }, cornerClip(0, tl, top_clip).?);
    try expectBox(.{ .x = 0, .y = 8, .width = 16, .height = 8 }, cornerClip(2, bl, top_clip).?);
    try expectBox(.{ .x = 0, .y = 8, .width = 16, .height = 8 }, cornerClip(3, br, top_clip).?);

    // A clip that leaves nothing of the corner draws no tile.
    try testing.expect(cornerClip(0, tl, .{ .x = 50, .y = 50, .width = 10, .height = 10 }) == null);
    try testing.expect(cornerClip(1, tr, .{ .x = 0, .y = 0, .width = 8, .height = 16 }) == null);
}

test "corner tiles are built once per distinct key" {
    const testing = std.testing;
    defer deinitTiles();
    const all: river.WindowV1.Edges = .{ .top = true, .bottom = true, .left = true, .right = true };
    const geometry = borderGeometry(100, 50, 3, 10, all);
    const no_clip: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    const color = [4]u8{ 1, 2, 3, 255 };

    // Without a clip all four corners are the same tile.
    var tiles = try buildTiles(geometry, 10, 3, color, no_clip, 1);
    try testing.expect(tiles.owned[0] != null);
    inline for (.{ 1, 2, 3 }) |i| {
        try testing.expectEqual(@as(u8, 0), tiles.alias[i]);
        try testing.expect(tiles.owned[i] == null);
    }

    // A second window with the same border shares that tile instead of filling
    // another one: this is what makes a focus change free.
    const created = tiles_created;
    var other = try buildTiles(geometry, 10, 3, color, no_clip, 1);
    try testing.expectEqual(created, tiles_created);
    try testing.expect(other.owned[0] == tiles.owned[0]);
    releaseTiles(other.owned, other.alias);

    // A clip cuts the corners differently, so each one gets its own tile.
    const clip = wlr.Box{ .x = 0, .y = 0, .width = 96, .height = 46 };
    other = try buildTiles(geometry, 10, 3, color, clip, 1);
    inline for (.{ 0, 1, 2, 3 }) |i| {
        try testing.expect(other.owned[other.alias[i]] != null);
    }
    try testing.expect(other.owned[0] != other.owned[1]);
    releaseTiles(other.owned, other.alias);

    // A different radius is a different tile.
    releaseTiles(tiles.owned, tiles.alias);
    const clipped_tile = other.owned[0];
    tiles = try buildTiles(borderGeometry(100, 50, 3, 6, all), 6, 3, color, no_clip, 1);
    try testing.expect(tiles.owned[0] != null);
    try testing.expect(tiles.owned[0] != clipped_tile);
    releaseTiles(tiles.owned, tiles.alias);
}

test "the tile cache never evicts a tile a window is using" {
    const testing = std.testing;
    defer deinitTiles();
    const empty: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    const ctx = TileFillContext{
        .bw = 3,
        .radius = 10,
        .color = .{ 255, 255, 255, 255 },
    };
    const held_key = TileKey{ .raster = 16, .radius = 10, .width = 3, .color = 1, .clip = empty };
    const held = try acquireTile(held_key, &ctx, 1);

    // Fill the cache with tiles that no window uses any more.
    var i: usize = 0;
    while (i < tile_cache_capacity + 2) : (i += 1) {
        const key = TileKey{
            .raster = 16,
            .radius = 10,
            .width = 3,
            .color = @intCast(100 + i),
            .clip = empty,
        };
        releaseTile(try acquireTile(key, &ctx, 1));
    }

    // The held tile survived: acquiring it again neither rasterizes nor hands
    // out a tile that was freed under a window's feet.
    const created = tiles_created;
    const again = try acquireTile(held_key, &ctx, 1);
    try testing.expectEqual(created, tiles_created);
    try testing.expect(again == held);
    releaseTile(again);
    releaseTile(held);
}

test "the border cache separates the texture from the frame" {
    const testing = std.testing;
    const clip: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    const color = colorKey(.{ 200, 100, 50, 255 });
    const edges: u32 = 0b1111;
    var cache = Cache{
        .valid = true,
        .scale = 2,
        .radius = 10,
        .width = 3,
        .color = color,
        .edges = edges,
        .content_width = 100,
        .content_height = 50,
        .clip = clip,
    };

    try testing.expect(sameTexture(&cache, 10, 3, color, edges, clip, 2));
    try testing.expect(!sameTexture(&cache, 11, 3, color, edges, clip, 2));
    try testing.expect(!sameTexture(&cache, 10, 4, color, edges, clip, 2));
    try testing.expect(!sameTexture(&cache, 10, 3, colorKey(.{ 1, 2, 3, 255 }), edges, clip, 2));
    try testing.expect(!sameTexture(&cache, 10, 3, color, 0b0011, clip, 2));
    try testing.expect(!sameTexture(&cache, 10, 3, color, edges, clip, 1));
    try testing.expect(!sameTexture(&cache, 10, 3, color, edges, .{ .x = 4, .y = 0, .width = 0, .height = 0 }, 2));

    // A resize keeps the textures: only the frame changes.
    try testing.expect(sameFrame(&cache, 100, 50));
    try testing.expect(!sameFrame(&cache, 101, 50));
    try testing.expect(!sameFrame(&cache, 100, 51));
    try testing.expect(sameTexture(&cache, 10, 3, color, edges, clip, 2));
}

test "border geometry covers exactly the ring" {
    const testing = std.testing;
    const bw = 3;
    var mask: u5 = 0;
    while (mask < 16) : (mask += 1) {
        const edges: river.WindowV1.Edges = .{
            .top = mask & 1 != 0,
            .bottom = mask & 2 != 0,
            .left = mask & 4 != 0,
            .right = mask & 8 != 0,
        };
        inline for (.{ .{ 100, 50 }, .{ 30, 20 } }) |window| {
            const content_width = window[0];
            const content_height = window[1];
            const radius = effectiveRadius(content_width, content_height, bw, 10);
            const geometry = borderGeometry(content_width, content_height, bw, radius, edges);
            const frame_width = content_width + 2 * bw;
            const frame_height = content_height + 2 * bw;
            // The frame cap above is what keeps the corner squares disjoint.
            try testing.expect(2 * geometry.size <= @min(frame_width, frame_height));

            var py: usize = 0;
            while (py < frame_height) : (py += 1) {
                var px: usize = 0;
                while (px < frame_width) : (px += 1) {
                    var in_strip = false;
                    var pieces: usize = 0;
                    for (geometry.strips) |strip| {
                        if (boxContains(strip, px, py)) {
                            in_strip = true;
                            pieces += 1;
                        }
                    }
                    var corner_index: ?usize = null;
                    for (geometry.corners, 0..) |corner, i| {
                        if (boxContains(corner, px, py)) {
                            corner_index = i;
                            pieces += 1;
                        }
                    }
                    // No pixel is drawn twice.
                    try testing.expect(pieces <= 1);
                    const ring = upstreamRing(edges, content_width, content_height, bw, px, py);
                    if (in_strip) {
                        // Strips are solid, so they must never sit outside the
                        // ring upstream draws.
                        try testing.expect(ring);
                    }
                    if (ring) {
                        // Every pixel upstream's border rects cover is drawn by
                        // exactly one of our pieces.
                        try testing.expectEqual(@as(usize, 1), pieces);
                    }
                    if (corner_index) |i| {
                        // A corner square may only be transparent where the arc
                        // cuts the ring away. The only pixels it covers outside
                        // upstream's ring are the band over the content corner.
                        const local = cornerLocal(i, geometry.corners[i], px, py);
                        const coverage = cornerRingCoverage(local[0], local[1], @floatFromInt(radius), @floatFromInt(bw));
                        const over_content = local[0] >= @as(f64, @floatFromInt(bw)) and
                            local[1] >= @as(f64, @floatFromInt(bw));
                        if (!ring) try testing.expect(coverage == 0 or over_content);
                    }
                }
            }

            // A square-cornered border is upstream's geometry exactly: the four
            // rects, with no corner square left to a texture.
            if (radius == 0) {
                try testing.expectEqual(@as(usize, 0), geometry.size);
                for (geometry.corners) |corner| {
                    try testing.expectEqual(@as(c_int, 0), corner.width);
                    try testing.expectEqual(@as(c_int, 0), corner.height);
                }
            }
        }
    }
}

test "the border box follows the content clip box" {
    const testing = std.testing;
    const content: wlr.Box = .{ .x = 0, .y = 0, .width = 200, .height = 100 };
    const no_clip: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 };

    // No content clip set: the border wraps the whole content.
    try expectBox(content, borderContentBox(content, no_clip).?);

    // Content clipped by the wm: the border shrinks to the clip box, so a
    // window smaller than the content it could not shrink keeps its border at
    // the edge of what is actually visible.
    try expectBox(
        wlr.Box{ .x = 0, .y = 0, .width = 60, .height = 40 },
        borderContentBox(content, .{ .x = 0, .y = 0, .width = 60, .height = 40 }).?,
    );

    // Clipped away entirely: nothing left to draw a border around.
    try testing.expect(borderContentBox(content, .{ .x = 500, .y = 500, .width = 10, .height = 10 }) == null);
}
