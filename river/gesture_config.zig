// SPDX-FileCopyrightText: © 2025 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

/// Configuration and pure logic for touchpad swipe → key injection.
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
/// 4 fingers: up=F5 down=F6 (left/right unmapped)
pub const reserved = [2][4]?xkb.Keysym{
    .{ .F1, .F2, .F3, .F4 },
    .{ .F5, .F6, null, null },
};

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
    try testing.expect(reserved[1][@intFromEnum(Direction.left)] == null);
    try testing.expect(reserved[1][@intFromEnum(Direction.right)] == null);
}
