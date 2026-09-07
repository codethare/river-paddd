// SPDX-FileCopyrightText: © 2026 codethare
// SPDX-License-Identifier: GPL-3.0-only

/// Configuration and pure logic for touchpad gesture → key injection.
///
/// Bindings are matched by keysym directly (see Seat.injectGestureKey), so the
/// reserved keysyms do not need to exist in any client keymap.
const GestureConfig = @This();

const std = @import("std");
const xkb = @import("xkbcommon");

/// Master switch: when true, 3/4-finger swipes are taken over by the compositor
/// and no longer forwarded to apps as pointer gestures, even when unbound.
/// ponytail: hardcoded until a river control protocol exists.
pub const enabled = true;

/// Finger count → index into `reserved`: 3 fingers → 0, 4 fingers → 1.
pub fn fingerIndex(fingers: u32) ?usize {
    return switch (fingers) {
        3 => 0,
        4 => 1,
        else => null,
    };
}

pub const Direction = enum {
    up,
    down,
    left,
    right,
};

/// Fingers resting in place (accidental touch) fires nothing.
const min_swipe_delta = 10.0;

/// Resolve the swipe direction from the accumulated physical delta, honoring
/// the touchpad's natural scroll sense. Returns null when the swipe is too
/// small to be intentional.
pub fn resolveDirection(dx: f64, dy: f64, natural_scroll: bool) ?Direction {
    var ddx = dx;
    var ddy = dy;
    if (natural_scroll) {
        ddx = -ddx;
        ddy = -ddy;
    }

    if (@abs(ddx) <= min_swipe_delta and @abs(ddy) <= min_swipe_delta) return null;

    return if (@abs(ddx) > @abs(ddy))
        (if (ddx > 0) .right else .left)
    else
        (if (ddy > 0) .down else .up);
}

/// Reserved keysyms, indexed by [finger index][direction]. null entries are
/// consumed but fire nothing:
/// 3 fingers: up=F1 down=F2 left=F3 right=F4
/// 4 fingers: up=F5 down=F6 left=F7 right=F8
pub const reserved = [2][4]?xkb.Keysym{
    .{ .F1, .F2, .F3, .F4 },
    .{ .F5, .F6, .F7, .F8 },
};

/// Keysyms pressed while a 3/4-finger hold is active, indexed by fingerIndex;
/// the key is released at hold_end (sustained command):
/// 3 fingers: F9, 4 fingers: F10.
pub const hold_reserved = [2]?xkb.Keysym{ .F9, .F10 };

pub const PinchDirection = enum {
    in,
    out,
};

/// Keysyms for a 3/4-finger pinch, indexed by [finger index][PinchDirection].
/// null entries are consumed but fire nothing:
/// 3 fingers: unmapped; 4 fingers: out=F11 (张开), in=F12.
pub const pinch_reserved = [2][2]?xkb.Keysym{
    .{ null, null },
    .{ .F12, .F11 },
};

/// Accumulated gesture scale below/above which a pinch counts as in/out.
const min_scale_delta = 0.05;

/// True when the accumulated scale is a deliberate pinch-in (捏合).
pub fn isPinchIn(scale: f64) bool {
    return scale <= 1.0 - min_scale_delta;
}

/// True when the accumulated scale is a deliberate pinch-out (张开).
pub fn isPinchOut(scale: f64) bool {
    return scale >= 1.0 + min_scale_delta;
}

test "finger index, direction resolution and reserved table" {
    const testing = std.testing;

    try testing.expectEqual(@as(?usize, 0), fingerIndex(3));
    try testing.expectEqual(@as(?usize, 1), fingerIndex(4));
    try testing.expect(fingerIndex(2) == null);
    try testing.expect(fingerIndex(5) == null);

    try testing.expectEqual(Direction.up, resolveDirection(0, -50, false).?);
    try testing.expectEqual(Direction.down, resolveDirection(0, 50, false).?);
    try testing.expectEqual(Direction.left, resolveDirection(-80, 10, false).?);
    try testing.expectEqual(Direction.right, resolveDirection(80, -10, false).?);
    // Natural scroll inverts both axes sense.
    try testing.expectEqual(Direction.up, resolveDirection(0, 50, true).?);
    try testing.expectEqual(Direction.left, resolveDirection(80, 10, true).?);
    // Sub-threshold swipe fires nothing.
    try testing.expect(resolveDirection(3, -3, false) == null);

    try testing.expectEqual(xkb.Keysym.F1, reserved[0][@intFromEnum(Direction.up)].?);
    try testing.expectEqual(xkb.Keysym.F4, reserved[0][@intFromEnum(Direction.right)].?);
    try testing.expectEqual(xkb.Keysym.F5, reserved[1][@intFromEnum(Direction.up)].?);
    try testing.expectEqual(xkb.Keysym.F6, reserved[1][@intFromEnum(Direction.down)].?);
    try testing.expectEqual(xkb.Keysym.F7, reserved[1][@intFromEnum(Direction.left)].?);
    try testing.expectEqual(xkb.Keysym.F8, reserved[1][@intFromEnum(Direction.right)].?);

    try testing.expectEqual(xkb.Keysym.F9, hold_reserved[0].?);
    try testing.expectEqual(xkb.Keysym.F10, hold_reserved[1].?);

    try testing.expect(pinch_reserved[0][@intFromEnum(PinchDirection.in)] == null);
    try testing.expect(pinch_reserved[0][@intFromEnum(PinchDirection.out)] == null);
    try testing.expectEqual(xkb.Keysym.F12, pinch_reserved[1][@intFromEnum(PinchDirection.in)].?);
    try testing.expectEqual(xkb.Keysym.F11, pinch_reserved[1][@intFromEnum(PinchDirection.out)].?);

    try testing.expect(isPinchIn(0.8));
    try testing.expect(!isPinchIn(1.0));
    try testing.expect(!isPinchIn(1.1));
    try testing.expect(!isPinchIn(0.98));

    try testing.expect(isPinchOut(1.2));
    try testing.expect(!isPinchOut(1.0));
    try testing.expect(!isPinchOut(0.9));
    try testing.expect(!isPinchOut(1.02));
}
