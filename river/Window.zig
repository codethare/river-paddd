// SPDX-FileCopyrightText: © 2020 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const Window = @This();

const build_options = @import("build_options");
const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const meta = std.meta;
const posix = std.posix;
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const river = @import("wayland").server.river;
const SlotMap = @import("slotmap").SlotMap;

const server = &@import("main.zig").server;
const util = @import("util.zig");

const Decoration = @import("Decoration.zig");
const Output = @import("Output.zig");
const Scene = @import("Scene.zig");
const SceneNodeData = @import("SceneNodeData.zig");
const Seat = @import("Seat.zig");
const WmNode = @import("WmNode.zig");
const XdgToplevel = @import("XdgToplevel.zig");
const XwaylandWindow = @import("XwaylandWindow.zig");

const log = std.log.scoped(.wm);

pub const Dimensions = struct {
    width: u31,
    height: u31,
};

pub const DimensionsHint = struct {
    min_width: u31 = 0,
    max_width: u31 = 0,
    min_height: u31 = 0,
    max_height: u31 = 0,
};

const Impl = union(enum) {
    toplevel: XdgToplevel,
    xwayland: if (build_options.xwayland) XwaylandWindow else noreturn,
    /// This state is assigned during destruction after the xdg toplevel
    /// has been destroyed but while the transaction system is still rendering
    /// saved surfaces of the window.
    destroying,
};

pub const FullscreenRequest = union(enum) {
    no_request,
    fullscreen: ?*Output,
    exit,
};

pub const Border = struct {
    edges: river.WindowV1.Edges = .{},
    width: u31 = 0,
    r: u32 = 0,
    b: u32 = 0,
    g: u32 = 0,
    a: u32 = 0,
};

/// Radius in pixels of the rounded corners drawn on window borders.
/// Fixed compositor-side value, see SPEC-rounded-window-borders.md.
const border_radius: u31 = 10;

/// A premultiplied ARGB8888 image of a window's border frame, uploaded to the
/// GPU as a custom wlr.Buffer. wlroots 0.20 has no rounded-rect scene primitive,
/// so the rounded corners are rendered into this texture.
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
        frame.fw = width;
        frame.fh = height;
        frame.pixels = try alloc.alignedAlloc(u8, .@"16", width * height * @sizeOf(u32));
        errdefer alloc.free(frame.pixels);
        wlr.Buffer.init(&frame.base, &impl, @intCast(width), @intCast(height));
        return frame;
    }

    /// Render the border frame into the buffer, replicating the corner
    /// contract of the old per-edge rects: corners are drawn only between
    /// borders on adjacent edges, and a side strip does not extend past a
    /// missing horizontal edge.
    fn fillFrame(
        frame: *FrameBuffer,
        border: *const Border,
        content_width: usize,
        content_height: usize,
        clip: *const wlr.Box,
    ) void {
        const fw = frame.fw;
        const fh = frame.fh;
        const bw = border.width;
        const frame_right = content_width + bw; // first column right of the content
        const frame_bottom = content_height + bw; // first row below the content
        // The scene graph cannot clip client content to a rounded rect, so
        // the effective radius is bounded by the border width: the content's
        // square corner stays inside the arc as long as
        // r <= (bw + 0.5) * (2 + sqrt(2)).
        const radius: usize = @min(
            @as(usize, border_radius),
            @min(@min(fw, fh), overflowFreeRadius(bw)),
        );

        // Clip rectangle in tree coordinates. The frame is the content box
        // expanded by the border width on each side, so shift the clip by the
        // border width and clamp it to the frame.
        var x0: usize = 0;
        var x1: usize = fw;
        var y0: usize = 0;
        var y1: usize = fh;
        if (!clip.empty()) {
            const iw: i64 = @intCast(fw);
            const ih: i64 = @intCast(fh);
            const bwi: i64 = @intCast(bw);
            x0 = @intCast(@min(@max(@as(i64, clip.x) + bwi, 0), iw));
            x1 = @intCast(@min(@max(@as(i64, clip.x) + @as(i64, clip.width) + bwi, 0), iw));
            y0 = @intCast(@min(@max(@as(i64, clip.y) + bwi, 0), ih));
            y1 = @intCast(@min(@max(@as(i64, clip.y) + @as(i64, clip.height) + bwi, 0), ih));
        }
        if (x0 >= x1 or y0 >= y1) return;

        @memset(frame.pixels, 0);

        const color: [4]u8 = .{
            @intCast(border.r >> 24),
            @intCast(border.g >> 24),
            @intCast(border.b >> 24),
            @intCast(border.a >> 24),
        };
        const ctx = BorderFillContext{
            .pixels = @ptrCast(@alignCast(frame.pixels.ptr)),
            .fw = fw,
            .fh = fh,
            .bw = bw,
            .radius = radius,
            .frame_right = frame_right,
            .frame_bottom = frame_bottom,
            .edges = border.edges,
            .color = color,
        };

        // Cover the ring in two parts: the r x r corner zones (which may
        // overlap the strips and each other for tiny windows; the writes are
        // idempotent) and the four strips. The strips also run into the corner
        // zones, so a rounded corner is covered regardless of where the arc
        // falls.
        const r = ctx.radius;
        fillRect(&ctx, x0, @min(x1, r), y0, @min(y1, r)); // top-left
        fillRect(&ctx, @max(x0, fw - r), x1, y0, @min(y1, r)); // top-right
        fillRect(&ctx, x0, @min(x1, r), @max(y0, fh - r), y1); // bottom-left
        fillRect(&ctx, @max(x0, fw - r), x1, @max(y0, fh - r), y1); // bottom-right
        fillRect(&ctx, x0, x1, y0, @min(y1, bw)); // top strip
        fillRect(&ctx, x0, x1, @max(y0, fh - bw), y1); // bottom strip
        fillRect(&ctx, x0, @min(x1, bw), y0, y1); // left strip
        fillRect(&ctx, @max(x0, fw - bw), x1, y0, y1); // right strip
    }
};

const BorderFillContext = struct {
    pixels: [*]u32,
    fw: usize,
    fh: usize,
    bw: usize,
    radius: usize,
    frame_right: usize,
    frame_bottom: usize,
    edges: river.WindowV1.Edges,
    color: [4]u8,
};

/// Largest corner radius (pixels) for a border of the given width that keeps
/// the content's square corners inside the arc, so no content pokes out of
/// the rounded outline: (bw + 0.5) * (2 + sqrt(2)).
fn overflowFreeRadius(bw: usize) usize {
    const max = (@as(f64, @floatFromInt(bw)) + 0.5) * (2.0 + @sqrt(2.0));
    return @intFromFloat(@floor(max));
}

/// Coverage of the pixel at (px, py) relative to a rounded corner of radius r
/// centered r pixels from both edges: 1 = fully inside the rounded rect,
/// 0 = fully cut away. The arc boundary is feathered over one pixel.
fn cornerCoverage(px: usize, py: usize, r: usize) f64 {
    const rr: f64 = @floatFromInt(r);
    const dx = @as(f64, @floatFromInt(px)) + 0.5 - rr;
    const dy = @as(f64, @floatFromInt(py)) + 0.5 - rr;
    return @max(0, @min(1, rr - @sqrt(dx * dx + dy * dy) + 0.5));
}

/// Coverage of the border ring's corner band over the window corner: pixels
/// at a distance to the arc center between r - bw and r. The band is what
/// makes the two strips visibly join around the corner when the border is
/// thinner than the corner radius, and it is drawn above the window content.
fn bandCoverage(px: usize, py: usize, r: usize, bw: usize) f64 {
    const rr: f64 = @floatFromInt(r);
    const dx = @as(f64, @floatFromInt(px)) + 0.5 - rr;
    const dy = @as(f64, @floatFromInt(py)) + 0.5 - rr;
    const dist = @sqrt(dx * dx + dy * dy);
    if (dist > rr) return 0; // trimmed away by the corner
    if (dist < rr - @as(f64, @floatFromInt(bw))) return 0; // inside the ring's inner edge
    return @max(0, @min(1, rr - dist + 0.5));
}

/// Ring membership and coverage of a frame pixel: returns 0 for pixels that
/// are not part of the border ring.
fn ringCoverage(ctx: *const BorderFillContext, px: usize, py: usize) f64 {
    const bw = ctx.bw;
    const r = ctx.radius;
    const fr = ctx.frame_right;
    const fb = ctx.frame_bottom;
    const in_hole = px >= bw and px < fr and py >= bw and py < fb;
    if (!in_hole) {
        // Strips outside the content box, per the documented corner contract:
        // a side strip only extends vertically past an edge that is drawn.
        const y_lo: usize = if (ctx.edges.top) 0 else bw;
        const y_hi = fb + (if (ctx.edges.bottom) bw else 0);
        const in_left = px < bw and ctx.edges.left and py >= y_lo and py < y_hi;
        const in_right = px >= fr and ctx.edges.right and py >= y_lo and py < y_hi;
        const in_top = py < bw and ctx.edges.top and px >= bw and px < fr;
        const in_bottom = py >= fb and ctx.edges.bottom and px >= bw and px < fr;
        if (!in_left and !in_right and !in_top and !in_bottom) return 0;
        // Round the corner where the two adjacent edges are both drawn.
        if (ctx.edges.top and ctx.edges.left and px < r and py < r) return cornerCoverage(px, py, r);
        if (ctx.edges.top and ctx.edges.right and px >= ctx.fw - r and py < r) return cornerCoverage(ctx.fw - 1 - px, py, r);
        if (ctx.edges.bottom and ctx.edges.left and px < r and py >= ctx.fh - r) return cornerCoverage(px, ctx.fh - 1 - py, r);
        if (ctx.edges.bottom and ctx.edges.right and px >= ctx.fw - r and py >= ctx.fh - r) return cornerCoverage(ctx.fw - 1 - px, ctx.fh - 1 - py, r);
        return 1;
    }
    // Inside the content box, only the corner band of the ring, where both
    // adjacent edges are drawn.
    if (ctx.edges.top and ctx.edges.left and px < r and py < r) return bandCoverage(px, py, r, bw);
    if (ctx.edges.top and ctx.edges.right and px >= ctx.fw - r and py < r) return bandCoverage(ctx.fw - 1 - px, py, r, bw);
    if (ctx.edges.bottom and ctx.edges.left and px < r and py >= ctx.fh - r) return bandCoverage(px, ctx.fh - 1 - py, r, bw);
    if (ctx.edges.bottom and ctx.edges.right and px >= ctx.fw - r and py >= ctx.fh - r) return bandCoverage(ctx.fw - 1 - px, ctx.fh - 1 - py, r, bw);
    return 0;
}

fn fillRect(ctx: *const BorderFillContext, x0: usize, x1: usize, y0: usize, y1: usize) void {
    const c = ctx.color;
    var py = y0;
    while (py < y1) : (py += 1) {
        var px = x0;
        while (px < x1) : (px += 1) {
            const cov = ringCoverage(ctx, px, py);
            if (cov == 0) continue;
            // The border color is premultiplied per the protocol; scale by the
            // coverage to keep the premultiplied invariant (rgb <= alpha).
            ctx.pixels[py * ctx.fw + px] =
                @as(u32, @intFromFloat(@round(@as(f64, c[3]) * cov))) << 24 |
                @as(u32, @intFromFloat(@round(@as(f64, c[0]) * cov))) << 16 |
                @as(u32, @intFromFloat(@round(@as(f64, c[1]) * cov))) << 8 |
                @as(u32, @intFromFloat(@round(@as(f64, c[2]) * cov)));
        }
    }
}

/// Windowing state requested by the wm.
const WmRequested = struct {
    dimensions: ?Dimensions,
    bounds: Dimensions,
    ssd: bool,
    tiled: river.WindowV1.Edges,
    capabilities: river.WindowV1.Capabilities,
    resizing: bool,
    maximized: bool,
    fullscreen: ?*Output,
    inform_fullscreen: bool,
    close: bool,

    pub const init: WmRequested = .{
        .dimensions = null,
        .bounds = .{ .width = 0, .height = 0 },
        .ssd = false,
        .tiled = .{},
        .capabilities = .{
            .window_menu = true,
            .maximize = true,
            .fullscreen = true,
            .minimize = true,
        },
        .resizing = false,
        .maximized = false,
        .fullscreen = null,
        .inform_fullscreen = false,
        .close = false,
    };
};

pub const Configure = struct {
    width: ?u31,
    height: ?u31,
    bounds: Dimensions,
    /// True if the window has keyboard focus from at least one seat.
    activated: bool,
    ssd: bool,
    tiled: river.WindowV1.Edges,
    capabilities: river.WindowV1.Capabilities,
    maximized: bool,
    inform_fullscreen: bool,
    resizing: bool,

    pub const init: Configure = .{
        .width = null,
        .height = null,
        .bounds = .{ .width = 0, .height = 0 },
        .activated = false,
        .ssd = false,
        .tiled = .{},
        .capabilities = .{},
        .maximized = false,
        .inform_fullscreen = false,
        .resizing = false,
    };
};

/// Rendering state requested by the wm.
const RenderingRequested = struct {
    x: i32,
    y: i32,
    hidden: bool,
    border: Border,
    clip: wlr.Box,
    content_clip: wlr.Box,

    pub const init: RenderingRequested = .{
        .x = 0,
        .y = 0,
        .hidden = false,
        .border = .{},
        .clip = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .content_clip = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    };
};

pub const Ref = packed struct {
    key: SlotMap(*Window).Key,

    pub fn get(ref: Ref) ?*Window {
        return server.wm.windows.get(ref.key);
    }
};

ref: Ref,

/// The window management protocol object for this window
/// Created in manageStart() when state is .ready
/// Set to null in manageStart() when state is .closing
object: ?*river.WindowV1 = null,
node: WmNode,

state: enum {
    /// Initial state, also returned to after closed event is sent.
    init,
    /// The window is ready to be configured.
    /// The river_window_v1 will be created in the next manage sequence.
    ready,
    /// The first configure has been sent but the window is not yet mapped.
    initialized,
    /// The window is mapped.
    mapped,
    /// The closed event will be sent in the next manage sequence.
    closing,
} = .init,

/// The implementation of this window
impl: Impl,

/// This is the root scene tree for the window.
/// The trees in the following fields are in rendering order.
tree: *wlr.SceneTree,

/// Opaque black rectangle used as the background while this window is rendered fullscreen.
/// TODO consider using one of these per output rather than one per window to save memory
/// if the complexity tradeoff is worth it.
fullscreen_background: *wlr.SceneRect,

decorations_below: wl.list.Head(Decoration, .link),
decorations_below_tree: *wlr.SceneTree,

surfaces: Scene.SaveableSurfaces,

border: struct {
    /// Renders the border frame as a single texture so the outer corners
    /// can be rounded; wlroots has no rounded-rect scene primitive.
    scene_buffer: *wlr.SceneBuffer,
},

/// Inputs of the last border frame texture, so drawBorders() can skip the
/// render and upload work on render sequences where nothing changed.
border_rendered: struct {
    valid: bool = false,
    width: u31 = 0,
    r: u32 = 0,
    g: u32 = 0,
    b: u32 = 0,
    a: u32 = 0,
    edges: u32 = 0,
    content_width: u31 = 0,
    content_height: u31 = 0,
    clip: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
} = .{},

decorations_above: wl.list.Head(Decoration, .link),
decorations_above_tree: *wlr.SceneTree,

popup_tree: *wlr.SceneTree,

capture_scene: *wlr.Scene,
capture_source: ?*wlr.ExtImageCaptureSourceV1 = null,

/// State to be sent to the wm in the next manage sequence.
wm_scheduled: struct {
    dimensions_hint: DimensionsHint = .{},
    decoration_hint: river.WindowV1.DecorationHint = .only_supports_csd,
    show_window_menu_requested: ?struct { x: i32, y: i32 } = null,
    /// Set back to no_request at the end of each update sequence
    fullscreen_requested: FullscreenRequest = .no_request,
    maximize_requested: enum {
        no_request,
        maximize,
        unmaximize,
    } = .no_request,
    minimize_requested: bool = false,
    dirty_app_id: bool = false,
    dirty_title: bool = false,
    pointer_move_requested: ?*Seat = null,
    pointer_resize_requested: ?struct {
        seat: *Seat,
        edges: river.WindowV1.Edges,
    } = null,
    capture_session_count: u32 = 0,
} = .{},

/// State sent to the wm in the latest manage sequence.
/// This state is only kept around in order to avoid sending redundant events
/// to the wm.
wm_sent: struct {
    dimensions_hint: DimensionsHint = .{},
    decoration_hint: river.WindowV1.DecorationHint = .only_supports_csd,
    parent: ?Window.Ref = null,
    capture_session_count: u32 = 0,
} = .{},

/// Windowing state requested by the wm.
wm_requested: WmRequested = .init,

/// State to be sent to the window in the next configure.
configure_scheduled: Configure = .init,
/// State sent to the window in the latest configure.
configure_sent: Configure = .init,

/// State to be sent to the wm in the next render sequence.
rendering_scheduled: struct {
    /// Dimensions committed by the window.
    width: u31 = 0,
    height: u31 = 0,
    /// Send dimensions even if they are unchanged.
    resend_dimensions: bool = false,
} = .{},

/// State sent to the wm in the latest render sequence.
rendering_sent: struct {
    width: u31 = 0,
    height: u31 = 0,
    presentation_hint: river.OutputV1.PresentationMode = .vsync,
} = .{},

/// Rendering state requested by the wm.
rendering_requested: RenderingRequested = .init,

/// The currently rendered position/dimensions of the window in the scene graph
box: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

foreign_toplevel_handle: ?*wlr.ExtForeignToplevelHandleV1 = null,
wlr_toplevel_handle: ?*wlr.ForeignToplevelHandleV1 = null,

pub fn create(impl: Impl) error{OutOfMemory}!*Window {
    assert(impl != .destroying);

    const window = try util.gpa.create(Window);
    errdefer util.gpa.destroy(window);

    const key = try server.wm.windows.put(util.gpa, window);
    errdefer server.wm.windows.remove(key);

    const tree = try server.scene.hidden_tree.createSceneTree();
    errdefer tree.node.destroy();

    const popup_tree = try server.scene.hidden_tree.createSceneTree();
    errdefer popup_tree.node.destroy();

    window.* = .{
        .ref = .{ .key = key },
        .node = undefined,
        .impl = impl,
        .tree = tree,
        .fullscreen_background = try tree.createSceneRect(0, 0, &.{ 0, 0, 0, 1 }),
        .decorations_below = undefined,
        .decorations_below_tree = try tree.createSceneTree(),
        .surfaces = try Scene.SaveableSurfaces.init(tree),
        .border = .{
            .scene_buffer = try tree.createSceneBuffer(null),
        },
        .decorations_above = undefined,
        .decorations_above_tree = try tree.createSceneTree(),
        .popup_tree = popup_tree,
        .capture_scene = try wlr.Scene.create(),
    };

    window.node.init(.window);

    window.decorations_below.init();
    window.decorations_above.init();

    window.tree.node.setEnabled(false);
    window.popup_tree.node.setEnabled(false);
    window.fullscreen_background.node.setEnabled(false);

    window.capture_scene.restack_xwayland_surfaces = false;

    try SceneNodeData.attach(&window.tree.node, .{ .window = window });
    try SceneNodeData.attach(&window.popup_tree.node, .{ .window = window });

    return window;
}

/// It's safe to destroy the window after we no longer need the saved buffers
/// for frame perfection. We no longer need the saved buffers after the manage
/// sequence in which the closed event was sent is completed and the following
/// render sequence is completed as well.
pub fn destroy(window: *Window) void {
    assert(window.impl == .destroying);

    switch (window.state) {
        .init => {},
        .closing => {
            server.wm.dirtyWindowing();
            return;
        },
        .ready, .initialized, .mapped => unreachable,
    }
    assert(window.object == null);

    {
        var it = server.input_manager.seats.iterator(.forward);
        while (it.next()) |seat| {
            assert(seat.focused != .window or seat.focused.window != window);
        }
    }

    inline for (.{ &window.decorations_above, &window.decorations_below }) |decorations| {
        var it = decorations.safeIterator(.forward);
        while (it.next()) |decoration| decoration.destroy();
    }

    window.tree.node.destroy();
    window.popup_tree.node.destroy();
    window.capture_scene.tree.node.destroy();

    window.node.deinit();

    server.wm.windows.remove(window.ref.key);

    util.gpa.destroy(window);
}

pub fn setDimensionsHint(window: *Window, hint: DimensionsHint) void {
    window.wm_scheduled.dimensions_hint = hint;
    if (!meta.eql(window.wm_sent.dimensions_hint, hint)) {
        server.wm.dirtyWindowing();
    }
}

pub fn setDimensions(window: *Window, width: u31, height: u31) void {
    window.rendering_scheduled.width = width;
    window.rendering_scheduled.height = height;

    if (window.rendering_scheduled.resend_dimensions or
        window.rendering_scheduled.width != window.rendering_sent.width or
        window.rendering_scheduled.height != window.rendering_sent.height)
    {
        server.wm.dirtyRendering();
    }
}

pub fn setDecorationHint(window: *Window, hint: river.WindowV1.DecorationHint) void {
    window.wm_scheduled.decoration_hint = hint;
    if (hint != window.wm_sent.decoration_hint) {
        server.wm.dirtyWindowing();
    }
}

/// Send dirty state as part of a manage sequence.
pub fn manageStart(window: *Window) void {
    switch (window.state) {
        .init => {},
        .closing => {
            window.state = .init;
            window.wm_sent = .{};
            window.wm_requested = .init;
            window.rendering_sent = .{};
            window.rendering_requested = .init;

            window.node.link.remove();
            window.node.link.init();

            window.makeInert();
        },
        .ready, .initialized, .mapped => {
            const wm_v1 = server.wm.object orelse return;
            const new = window.object == null;
            const window_v1 = window.object orelse blk: {
                const window_v1 = river.WindowV1.create(wm_v1.getClient(), wm_v1.getVersion(), 0) catch {
                    log.err("out of memory", .{});
                    return; // try again next update
                };
                window.object = window_v1;
                window_v1.setHandler(*Window, handleRequest, handleDestroy, window);
                wm_v1.sendWindow(window_v1);

                window.node.link.remove();
                server.wm.rendering_requested.list.append(&window.node);

                // A handle may have already been created if the window manager is restarted.
                if (window.foreign_toplevel_handle == null) {
                    if (wlr.ExtForeignToplevelHandleV1.create(server.foreign_toplevel_list, &.{
                        .title = window.getTitle(),
                        .app_id = window.getAppId(),
                    })) |handle| {
                        window.foreign_toplevel_handle = handle;
                        handle.data = window;
                    } else |_| {
                        log.err("failed to create ext foreign toplevel handle", .{});
                    }
                }

                if (window.wlr_toplevel_handle == null) {
                    if (wlr.ForeignToplevelHandleV1.create(server.wlr_foreign_toplevel_manager)) |handle| {
                        window.wlr_toplevel_handle = handle;
                        if (window.getTitle()) |title| handle.setTitle(title);
                        if (window.getAppId()) |app_id| handle.setAppId(app_id);
                    } else |_| {
                        log.err("failed to create wlr foreign toplevel handle", .{});
                    }
                }

                break :blk window_v1;
            };

            errdefer comptime unreachable;

            if (new) {
                if (window_v1.getVersion() >= 2) {
                    window_v1.sendUnreliablePid(window.unreliablePid());
                }
                if (window_v1.getVersion() >= 4) {
                    if (window.foreign_toplevel_handle) |handle| {
                        window_v1.sendIdentifier(handle.identifier);
                    }
                }
            }

            const scheduled = &window.wm_scheduled;
            const sent = &window.wm_sent;

            if (new or !meta.eql(scheduled.dimensions_hint, sent.dimensions_hint)) {
                window_v1.sendDimensionsHint(
                    scheduled.dimensions_hint.min_width,
                    scheduled.dimensions_hint.min_height,
                    scheduled.dimensions_hint.max_width,
                    scheduled.dimensions_hint.max_height,
                );
                sent.dimensions_hint = scheduled.dimensions_hint;
            }
            if (new or scheduled.decoration_hint != sent.decoration_hint) {
                window_v1.sendDecorationHint(window.wm_scheduled.decoration_hint);
                sent.decoration_hint = scheduled.decoration_hint;
            }

            if (scheduled.show_window_menu_requested) |offset| {
                window_v1.sendShowWindowMenuRequested(offset.x, offset.y);
                scheduled.show_window_menu_requested = null;
            }
            switch (scheduled.fullscreen_requested) {
                .no_request => {},
                .fullscreen => |output_hint| {
                    if (output_hint) |output| {
                        window_v1.sendFullscreenRequested(output.object);
                    } else {
                        window_v1.sendFullscreenRequested(null);
                    }
                },
                .exit => window_v1.sendExitFullscreenRequested(),
            }
            scheduled.fullscreen_requested = .no_request;
            switch (scheduled.maximize_requested) {
                .no_request => {},
                .maximize => window_v1.sendMaximizeRequested(),
                .unmaximize => window_v1.sendUnmaximizeRequested(),
            }
            scheduled.maximize_requested = .no_request;
            if (scheduled.minimize_requested) {
                window_v1.sendMinimizeRequested();
            }
            scheduled.minimize_requested = false;

            if (window.getParent()) |parent| {
                if (sent.parent == null or sent.parent.?.get() != parent) {
                    window_v1.sendParent(parent.object);
                    sent.parent = parent.ref;
                }
            } else if (sent.parent != null) {
                window_v1.sendParent(null);
                sent.parent = null;
            }

            if (new or scheduled.dirty_app_id) {
                window_v1.sendAppId(window.getAppId());
                scheduled.dirty_app_id = false;
            }
            if (new or scheduled.dirty_title) {
                window_v1.sendTitle(window.getTitle());
                scheduled.dirty_title = false;
            }

            if (scheduled.pointer_move_requested) |seat| {
                if (seat.object) |seat_v1| {
                    log.debug("send pointer move requested", .{});
                    window_v1.sendPointerMoveRequested(seat_v1);
                }
            }
            scheduled.pointer_move_requested = null;
            if (scheduled.pointer_resize_requested) |data| {
                if (data.seat.object) |seat_v1| {
                    log.debug("send pointer resize requested", .{});
                    window_v1.sendPointerResizeRequested(seat_v1, data.edges);
                }
            }
            scheduled.pointer_resize_requested = null;

            if (new or scheduled.capture_session_count != sent.capture_session_count) {
                if (window_v1.getVersion() >= 5) {
                    window_v1.sendCaptureSessions(scheduled.capture_session_count);
                }
                sent.capture_session_count = scheduled.capture_session_count;
            }
        },
    }
}

pub fn makeInert(window: *Window) void {
    if (window.object) |window_v1| {
        window_v1.sendClosed();
        window_v1.setHandler(?*anyopaque, handleRequestInert, null, null);
        handleDestroy(window_v1, window);
    } else {
        assert(window.node.object == null);
    }
}

fn handleRequestInert(
    window_v1: *river.WindowV1,
    request: river.WindowV1.Request,
    _: ?*anyopaque,
) void {
    if (request == .destroy) window_v1.destroy();
}

fn handleDestroy(_: *river.WindowV1, window: *Window) void {
    window.object = null;
    window.wm_requested = .init;
    window.rendering_requested = .{
        .x = window.rendering_requested.x,
        .y = window.rendering_requested.y,
        .hidden = false,
        .border = .{},
        .clip = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .content_clip = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    };
    server.wm.dirtyWindowing();
    window.node.makeInert();
    inline for (.{ &window.decorations_above, &window.decorations_below }) |decorations| {
        var it = decorations.iterator(.forward);
        while (it.next()) |decoration| decoration.makeInert();
    }
}

fn handleRequest(
    window_v1: *river.WindowV1,
    request: river.WindowV1.Request,
    window: *Window,
) void {
    assert(window.object == window_v1);
    const wm_requested = &window.wm_requested;
    const rendering_requested = &window.rendering_requested;
    switch (request) {
        .destroy => window_v1.destroy(),
        .close => {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.close = true;
        },
        .get_node => |args| {
            if (window.node.object != null) {
                window_v1.postError(.node_exists, "window already has a node object");
                return;
            }
            window.node.createObject(window_v1.getClient(), window_v1.getVersion(), args.id);
        },
        .propose_dimensions => |args| {
            if (!server.wm.ensureWindowing()) return;
            if (args.width < 0 or args.height < 0) {
                window_v1.postError(.invalid_dimensions, "dimensions must be greater than or equal to 0 ");
                return;
            }
            wm_requested.dimensions = .{
                .width = @intCast(args.width),
                .height = @intCast(args.height),
            };
        },
        .hide => {
            if (!server.wm.ensureRendering()) return;
            rendering_requested.hidden = true;
        },
        .show => {
            if (!server.wm.ensureRendering()) return;
            rendering_requested.hidden = false;
        },
        .use_ssd => {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.ssd = true;
        },
        .use_csd => {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.ssd = false;
        },
        .set_borders => |args| {
            if (!server.wm.ensureRendering()) return;
            if (args.width < 0) {
                window_v1.postError(.invalid_border, "border width must be greater than or equal to 0 ");
                return;
            }
            rendering_requested.border = .{
                .edges = args.edges,
                .width = @intCast(args.width),
                .r = args.r,
                .g = args.g,
                .b = args.b,
                .a = args.a,
            };
        },
        .set_tiled => |args| {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.tiled = args.edges;
        },
        inline .get_decoration_above, .get_decoration_below => |args, req| {
            const above = req == .get_decoration_above;
            const surface = wlr.Surface.fromWlSurface(args.surface);
            const decoration = Decoration.create(
                window_v1.getClient(),
                window_v1.getVersion(),
                args.id,
                surface,
                if (above) window.decorations_above_tree else window.decorations_below_tree,
            ) catch |err| switch (err) {
                error.OutOfMemory, error.ResourceCreateFailed => {
                    window_v1.getClient().postNoMemory();
                    log.err("out of memory", .{});
                    return;
                },
                error.AlreadyHasRole => return,
            };
            if (above) {
                window.decorations_above.append(decoration);
            } else {
                window.decorations_below.append(decoration);
            }
        },
        .inform_resize_start => {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.resizing = true;
        },
        .inform_resize_end => {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.resizing = false;
        },
        .set_capabilities => |args| {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.capabilities = args.caps;
        },
        .inform_maximized => {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.maximized = true;
        },
        .inform_unmaximized => {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.maximized = false;
        },
        .inform_fullscreen => {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.inform_fullscreen = true;
        },
        .inform_not_fullscreen => {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.inform_fullscreen = false;
        },
        .fullscreen => |args| {
            if (!server.wm.ensureWindowing()) return;
            const data = args.output.getUserData() orelse return;
            const output: *Output = @ptrCast(@alignCast(data));
            wm_requested.fullscreen = output;
        },
        .exit_fullscreen => {
            if (!server.wm.ensureWindowing()) return;
            wm_requested.fullscreen = null;
        },
        .set_clip_box => |args| {
            if (!server.wm.ensureRendering()) return;
            if (args.width < 0 or args.height < 0) {
                window_v1.postError(.invalid_clip_box, "width/height must be greater than or equal to 0 ");
                return;
            }
            rendering_requested.clip = .{
                .x = args.x,
                .y = args.y,
                .width = args.width,
                .height = args.height,
            };
        },
        .set_content_clip_box => |args| {
            if (!server.wm.ensureRendering()) return;
            if (args.width < 0 or args.height < 0) {
                window_v1.postError(.invalid_clip_box, "width/height must be greater than or equal to 0 ");
                return;
            }
            rendering_requested.content_clip = .{
                .x = args.x,
                .y = args.y,
                .width = args.width,
                .height = args.height,
            };
        },
        .set_dimension_bounds => |args| {
            if (!server.wm.ensureWindowing()) return;
            if (args.max_width < 0 or args.max_height < 0) {
                window_v1.postError(.invalid_dimensions, "dimensions must be greater than or equal to 0 ");
                return;
            }
            wm_requested.bounds = .{
                .width = @intCast(args.max_width),
                .height = @intCast(args.max_height),
            };
        },
    }
}

/// Applies window management state from the window manager and sends a configure
/// to the window if necessary.
/// Returns true if the configure should be waited for by the transaction system.
pub fn manageFinish(window: *Window) bool {
    const wm_requested = &window.wm_requested;

    // This can happen if the window is destroyed after being sent to the wm but
    // before being mapped.
    if (window.impl == .destroying) {
        assert(window.state == .closing);
        return false;
    }

    switch (window.state) {
        .init => unreachable,
        .ready => {
            if (wm_requested.dimensions == null and wm_requested.fullscreen == null) {
                return false;
            }
            window.state = .initialized;
        },
        .initialized, .mapped => {},
        .closing => return false,
    }

    if (wm_requested.close) {
        window.close();
        wm_requested.close = false;
    }

    const activated = blk: {
        var it = server.wm.sent.seats.iterator(.forward);
        while (it.next()) |seat| {
            if (seat.focused == .window and seat.focused.window == window) {
                break :blk true;
            }
        }
        break :blk false;
    };

    if (window.wlr_toplevel_handle) |handle| {
        handle.setActivated(activated);
    }

    const width, const height = blk: {
        if (wm_requested.fullscreen) |output| {
            const width, const height = output.sent.dimensions();
            if (window.configure_sent.width != width or
                window.configure_sent.height != height)
            {
                window.configure_scheduled.width = width;
                window.configure_scheduled.height = height;
                window.rendering_scheduled.resend_dimensions = true;
                break :blk .{ width, height };
            }
        } else if (wm_requested.dimensions) |dimensions| {
            window.rendering_scheduled.resend_dimensions = true;
            break :blk .{ dimensions.width, dimensions.height };
        }
        break :blk .{ null, null };
    };
    wm_requested.dimensions = null;

    window.configure_scheduled = .{
        .width = width,
        .height = height,
        .bounds = wm_requested.bounds,
        .activated = activated,
        .ssd = wm_requested.ssd,
        .tiled = wm_requested.tiled,
        .capabilities = wm_requested.capabilities,
        .resizing = wm_requested.resizing,
        .maximized = wm_requested.maximized,
        .inform_fullscreen = wm_requested.inform_fullscreen,
    };

    const track_configure = switch (window.impl) {
        .toplevel => |*toplevel| toplevel.configure(),
        .xwayland => |*xwindow| xwindow.configure(),
        .destroying => unreachable,
    };

    if (track_configure and window.state == .mapped) {
        window.surfaces.save();
        window.sendFrameDone();
    }

    return track_configure;
}

pub fn renderStart(window: *Window) void {
    switch (window.impl) {
        .toplevel => |*toplevel| {
            switch (toplevel.configure_state) {
                .inflight, .acked => {
                    // The transaction has timed out for the xdg toplevel, which means a commit
                    // in response to the configure with the inflight width/height has not yet
                    // been made. It may seem that we should therefore leave the current.box
                    // width/height unchanged. However, this would in fact cause visual glitches.
                    //
                    // We must update the dimensions to the current geometry of the
                    // xdg toplevel here in order to handle the following series of events:
                    //
                    // 0. initial state: client has dimensions X
                    // 1. transaction A sends a configure of size Y
                    // 2. transaction A times out - saved surfaces are dropped
                    // 3. transaction B sends a configure of size Z
                    // 4. client commits buffer of size Y
                    // 5. transaction B times out - saved surfaces are dropped
                    //
                    // If we did not use the current geometry of the toplevel at this point
                    // we would be rendering the SSD border at initial size X but the surface
                    // would be rendered at size Y.
                    switch (toplevel.configure_state) {
                        .inflight => |serial| toplevel.configure_state = .{ .timed_out = serial },
                        .acked => toplevel.configure_state = .timed_out_acked,
                        else => unreachable,
                    }
                },
                .committed => {
                    toplevel.configure_state = .idle;
                },
                // A timed_out or timed_out_acked value is possible in the case of a
                // manage sequence followed by two render sequences for example.
                .idle, .timed_out, .timed_out_acked => {},
            }
            window.rendering_scheduled.width = @intCast(toplevel.geometry.width);
            window.rendering_scheduled.height = @intCast(toplevel.geometry.height);
        },
        .xwayland => |xwindow| {
            window.rendering_scheduled.width = xwindow.xsurface.width;
            window.rendering_scheduled.height = xwindow.xsurface.height;
        },
        .destroying => {},
    }

    const sent = &window.rendering_sent;
    const scheduled = &window.rendering_scheduled;

    // Check if mapped to handle timeout of the first configure sent.
    if (window.state == .mapped and
        (scheduled.resend_dimensions or
            scheduled.width != sent.width or scheduled.height != sent.height))
    {
        if (window.object) |window_v1| {
            window_v1.sendDimensions(scheduled.width, scheduled.height);
            window.rendering_scheduled.resend_dimensions = false;
        }
    }
    sent.width = scheduled.width;
    sent.height = scheduled.height;

    const presentation_hint = window.presentationHint();
    if (sent.presentation_hint != presentation_hint) {
        if (window.object) |window_v1| {
            if (window_v1.getVersion() >= 4) {
                window_v1.sendPresentationHint(presentation_hint);
            }
        }
        sent.presentation_hint = presentation_hint;
    }
}

fn presentationHint(window: *Window) river.OutputV1.PresentationMode {
    const root_surface = window.rootSurface() orelse return .vsync;
    return switch (server.tearing_control_manager.hintFromSurface(root_surface)) {
        .async => .async,
        .vsync => .vsync,
        _ => unreachable,
    };
}

pub fn renderFinish(window: *Window) void {
    const requested = &window.rendering_requested;

    // Disable the scene nodes to avoid temporary, intermediate wlroots scene
    // graph states that may cause wlroots to send unwanted output enter/leave
    // scale events for a temporary state that will never be rendered.
    //
    // TODO(wlroots) provide a way to batch changes to the scene graph.
    window.tree.node.setEnabled(false);
    window.popup_tree.node.setEnabled(false);

    window.box.width = window.rendering_sent.width;
    window.box.height = window.rendering_sent.height;

    var clip: wlr.Box = requested.clip;
    var content_clip: wlr.Box = requested.content_clip;
    if (window.wm_requested.fullscreen) |output| {
        window.box.x = output.sent.x;
        window.box.y = output.sent.y;
        window.fullscreen_background.node.setEnabled(true);
        const width, const height = output.sent.dimensions();
        window.fullscreen_background.setSize(width, height);
        clip = .{ .x = 0, .y = 0, .width = width, .height = height };
        content_clip = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        window.border.scene_buffer.node.setEnabled(false);
    } else {
        window.box.x = requested.x;
        window.box.y = requested.y;
        window.fullscreen_background.node.setEnabled(false);
        window.drawBorders();
    }
    window.tree.node.setPosition(window.box.x, window.box.y);
    window.popup_tree.node.setPosition(window.box.x, window.box.y);

    switch (window.impl) {
        .xwayland => |*xwindow| _ = xwindow.configure(),
        .toplevel, .destroying => {},
    }

    window.applySurfaceClip(&clip, &content_clip);
    inline for (.{ &window.decorations_above, &window.decorations_below }) |decorations| {
        var it = decorations.iterator(.forward);
        while (it.next()) |decoration| {
            decoration.renderFinish(&clip);
        }
    }

    // Keep the scene nodes disabled until the render sequence in which the first
    // dimensions event was sent is completed. If we enable the nodes before the
    // window is mapped, there may be an imperfect frame rendered after the window
    // commits its initial buffer and before the render sequence with the first
    // dimensions event is completed.
    // Keeping the nodes enabled while closing is necessary for frame perfection.
    const enabled = !requested.hidden and (window.state == .mapped or window.state == .closing);
    window.tree.node.setEnabled(enabled);
    window.popup_tree.node.setEnabled(enabled);
}

fn drawBorders(window: *Window) void {
    const requested = &window.rendering_requested;
    const border = &requested.border;
    const content_width: usize = @intCast(window.box.width);
    const content_height: usize = @intCast(window.box.height);
    const border_width = border.width;
    const edges = border.edges;
    const drawable = border_width != 0 and content_width != 0 and content_height != 0 and
        (edges.top or edges.bottom or edges.left or edges.right);

    // Mirror the old behavior: while the content is fully clipped away (e.g.
    // a closing animation), draw no borders either.
    var content_box: wlr.Box = .{
        .x = 0,
        .y = 0,
        .width = window.box.width,
        .height = window.box.height,
    };
    const fully_clipped = !requested.content_clip.empty() and
        !content_box.intersection(&content_box, &requested.content_clip);

    if (!drawable or fully_clipped) {
        window.border_rendered.valid = false;
        window.border.scene_buffer.setBuffer(null);
        window.border.scene_buffer.node.setEnabled(false);
        return;
    }

    // Skip the render and upload when nothing changed since the last render
    // sequence (this function runs for every window on every sequence).
    const cached = &window.border_rendered;
    if (cached.valid and cached.width == border.width and
        cached.r == border.r and cached.g == border.g and
        cached.b == border.b and cached.a == border.a and
        cached.edges == @as(u32, @bitCast(edges)) and
        cached.content_width == content_width and
        cached.content_height == content_height and
        cached.clip.x == requested.clip.x and cached.clip.y == requested.clip.y and
        cached.clip.width == requested.clip.width and cached.clip.height == requested.clip.height)
    {
        // Re-enable in case the node was disabled while fullscreen.
        window.border.scene_buffer.node.setEnabled(true);
        return;
    }

    const frame_width = content_width + 2 * border_width;
    const frame_height = content_height + 2 * border_width;
    // wlroots stores buffer sizes as c_int.
    if (frame_width > math.maxInt(c_int) or frame_height > math.maxInt(c_int)) {
        window.border_rendered.valid = false;
        window.border.scene_buffer.setBuffer(null);
        window.border.scene_buffer.node.setEnabled(false);
        return;
    }

    const frame = FrameBuffer.create(frame_width, frame_height) catch {
        std.log.err("out of memory drawing window borders", .{});
        return;
    };
    frame.fillFrame(border, content_width, content_height, &requested.clip);
    window.border.scene_buffer.node.setPosition(-@as(c_int, border_width), -@as(c_int, border_width));
    window.border.scene_buffer.setBuffer(&frame.base);
    // The scene buffer holds the one remaining reference to the frame.
    frame.base.drop();
    window.border.scene_buffer.node.setEnabled(true);

    cached.* = .{
        .valid = true,
        .width = border.width,
        .r = border.r,
        .g = border.g,
        .b = border.b,
        .a = border.a,
        .edges = @as(u32, @bitCast(edges)),
        .content_width = @intCast(content_width),
        .content_height = @intCast(content_height),
        .clip = requested.clip,
    };
}

fn applySurfaceClip(window: *Window, a: *const wlr.Box, b: *const wlr.Box) void {
    var surface_clip: wlr.Box = undefined;
    if (!a.empty() and !b.empty()) {
        if (!surface_clip.intersection(a, b)) {
            // Clip boxes are both non-empty but don't intersect, all window
            // content is clipped away.
            window.surfaces.setEnabled(false);
            return;
        }
    } else if (!a.empty()) {
        surface_clip = a.*;
    } else {
        surface_clip = b.*;
    }
    window.surfaces.setEnabled(true);
    switch (window.impl) {
        .toplevel => |toplevel| {
            surface_clip.x += toplevel.geometry.x;
            surface_clip.y += toplevel.geometry.y;
        },
        .xwayland, .destroying => {},
    }
    // wlroots asserts that a subsurface tree is present.
    if (!window.surfaces.tree.children.empty()) {
        window.surfaces.tree.node.subsurfaceTreeSetClip(&surface_clip);
    }
}

/// Returns null if the window is currently being destroyed and no longer has
/// an associated surface.
/// May also return null for Xwayland windows that are not currently mapped.
pub fn rootSurface(window: Window) ?*wlr.Surface {
    return switch (window.impl) {
        .toplevel => |toplevel| toplevel.wlr_toplevel.base.surface,
        .xwayland => |xwindow| xwindow.xsurface.surface,
        .destroying => null,
    };
}

pub fn sendFrameDone(window: Window) void {
    assert(window.state == .mapped);
    assert(window.impl != .destroying);

    var now = util.timestamp();
    window.rootSurface().?.sendFrameDone(&now);
}

pub fn close(window: Window) void {
    switch (window.impl) {
        .toplevel => |toplevel| toplevel.wlr_toplevel.sendClose(),
        .xwayland => |xwindow| xwindow.xsurface.close(),
        .destroying => {},
    }
}

pub fn destroyPopups(window: Window) void {
    switch (window.impl) {
        .toplevel => |toplevel| toplevel.destroyPopups(),
        .xwayland, .destroying => {},
    }
}

pub fn getParent(window: *Window) ?*Window {
    switch (window.impl) {
        .toplevel => |toplevel| {
            const wlr_parent = toplevel.wlr_toplevel.parent orelse return null;
            const parent: *XdgToplevel = @ptrCast(@alignCast(wlr_parent.base.data));
            return parent.window;
        },
        .xwayland => |xwindow| {
            const parent_xsurface = xwindow.xsurface.parent orelse return null;
            // It seems that the parent may be an Override Redirect window, which
            // have null data.
            const parent_data = parent_xsurface.data orelse return null;
            const parent_xwindow: *XwaylandWindow = @ptrCast(@alignCast(parent_data));
            return parent_xwindow.window;
        },
        .destroying => return null,
    }
}

pub fn unreliablePid(window: *Window) i32 {
    switch (window.impl) {
        .toplevel => |toplevel| {
            const client = toplevel.wlr_toplevel.base.surface.resource.getClient();
            return client.getCredentials().pid;
        },
        .xwayland => |xwindow| return xwindow.xsurface.pid,
        .destroying => unreachable,
    }
}

/// Return the current title of the window if any.
pub fn getTitle(window: Window) ?[*:0]const u8 {
    return switch (window.impl) {
        .toplevel => |toplevel| toplevel.wlr_toplevel.title,
        .xwayland => |xwindow| xwindow.xsurface.title,
        .destroying => unreachable,
    };
}

/// Return the current app_id of the window if any.
pub fn getAppId(window: Window) ?[*:0]const u8 {
    return switch (window.impl) {
        .toplevel => |toplevel| toplevel.wlr_toplevel.app_id,
        // X11 clients don't have an app_id but the class serves a similar role.
        .xwayland => |xwindow| xwindow.xsurface.class,
        .destroying => unreachable,
    };
}

/// Called by the impl when the surface is ready to be displayed
pub fn map(window: *Window) !void {
    log.debug("window '{?s}' mapped", .{window.getTitle()});
    assert(window.impl != .destroying);
    assert(window.state == .initialized);
    window.state = .mapped;
}

/// Called by the impl when the surface will no longer be displayed
pub fn unmap(window: *Window) void {
    log.debug("window '{?s}' unmapped", .{window.getTitle()});

    window.surfaces.save();

    assert(window.impl != .destroying);
    assert(window.state == .mapped);
    window.state = .closing;

    server.wm.dirtyWindowing();

    if (window.foreign_toplevel_handle) |handle| {
        handle.destroy();
        window.foreign_toplevel_handle = null;
    }

    if (window.wlr_toplevel_handle) |handle| {
        handle.destroy();
        window.wlr_toplevel_handle = null;
    }

    {
        var it = server.input_manager.seats.iterator(.forward);
        while (it.next()) |seat| {
            if (seat.focused == .window and seat.focused.window == window) {
                seat.focus(.none);
            }
        }
    }
}

pub fn notifyTitle(window: *Window) void {
    window.wm_scheduled.dirty_title = true;
    server.wm.dirtyWindowing();

    if (window.foreign_toplevel_handle) |handle| {
        handle.updateState(&.{
            .title = window.getTitle(),
            .app_id = window.getAppId(),
        });
    }
    if (window.wlr_toplevel_handle) |handle| {
        if (window.getTitle()) |title| handle.setTitle(title);
    }
}

pub fn notifyAppId(window: *Window) void {
    window.wm_scheduled.dirty_app_id = true;
    server.wm.dirtyWindowing();

    if (window.foreign_toplevel_handle) |handle| {
        handle.updateState(&.{
            .title = window.getTitle(),
            .app_id = window.getAppId(),
        });
    }
    if (window.wlr_toplevel_handle) |handle| {
        if (window.getAppId()) |app_id| handle.setAppId(app_id);
    }
}

test "rounded border corner coverage" {
    const testing = std.testing;
    // Fully outside the corner arc is cut away.
    try testing.expectEqual(@as(f64, 0), cornerCoverage(0, 0, 10));
    // Deep inside the border region is fully covered.
    try testing.expectEqual(@as(f64, 1), cornerCoverage(9, 9, 10));
    // The arc boundary is feathered over about one pixel.
    const partial = cornerCoverage(2, 3, 10);
    try testing.expect(partial > 0 and partial < 1);
    // The overflow-free radius bound keeps content corners inside the arc.
    try testing.expectEqual(@as(usize, 5), overflowFreeRadius(1));
    try testing.expectEqual(@as(usize, 8), overflowFreeRadius(2));
    try testing.expectEqual(@as(usize, 11), overflowFreeRadius(3));
}

test "border ring corner band spans the content corner" {
    const testing = std.testing;
    // W=50 H=30, bw=2, r=10 -> frame 54x34; content box [2,52)x[2,32).
    const ctx = BorderFillContext{
        .pixels = @ptrFromInt(0x1000),
        .fw = 54,
        .fh = 34,
        .bw = 2,
        .radius = 10,
        .frame_right = 52,
        .frame_bottom = 32,
        .edges = .{ .top = true, .bottom = true, .left = true, .right = true },
        .color = .{ 255, 255, 255, 255 },
    };
    // The arc band crosses the content corner, joining the strips.
    try testing.expect(ringCoverage(&ctx, 3, 3) > 0);
    // Deep inside the content corner (inside the ring's inner edge) is empty.
    try testing.expectEqual(@as(f64, 0), ringCoverage(&ctx, 5, 5));
    // The very corner is trimmed by the arc.
    try testing.expectEqual(@as(f64, 0), ringCoverage(&ctx, 0, 0));
    // Straight strip parts are solid.
    try testing.expectEqual(@as(f64, 1), ringCoverage(&ctx, 1, 20));
    // Inside the content box away from a corner there is no border.
    try testing.expectEqual(@as(f64, 0), ringCoverage(&ctx, 20, 20));
}
