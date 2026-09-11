// SPDX-FileCopyrightText: © 2025 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

/// Pure touchpad gesture state machine.
///
/// Owns the per-device state of the gestures taken over for key injection and
/// decides what to do for each event, returning an `Action` for the seat to
/// execute. It never touches the compositor, so it can be unit tested on its
/// own.
const Gesture = @This();

const std = @import("std");
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const GestureConfig = @import("gesture_config.zig");

const log = std.log.scoped(.input);

/// Per-device state of a taken-over touchpad gesture.
pub const DeviceState = struct {
    swipe: struct {
        fingers: u32 = 0,
        dx: f64 = 0,
        dy: f64 = 0,
    } = .{},
    hold: struct {
        fingers: u32 = 0,
        /// hold_end arrived cancelled (superseded by movement): the held press
        /// stays down while the superseding swipe/pinch drives the op; its end
        /// releases the press when the fingers lift.
        bridging: bool = false,
    } = .{},
    pinch: struct {
        fingers: u32 = 0,
        scale: f64 = 1,
    } = .{},
};

/// What the seat should do after a gesture event.
pub const Action = union(enum) {
    none,
    /// Forward the event to the focused client, exactly as before.
    forward,
    /// Synthesize a press of this key.
    key: xkb.Keysym,
    /// Synthesize a press of this evdev button code.
    button: u32,
    /// Move the cursor (and the seat op) by this delta, as part of a bridged drag.
    drag: struct { dx: f64, dy: f64 },
};

/// A gesture action plus whether the press in flight must be released first: a
/// hold can be superseded while its press is still down.
pub const Effects = struct {
    release: bool = false,
    action: Action = .none,
};

pub const Gestures = struct {
    alloc: std.mem.Allocator,

    /// Per-device state, keyed by the device that generated the gesture.
    devices: std.AutoArrayHashMapUnmanaged(*wlr.InputDevice, DeviceState) = .empty,

    pub fn init(alloc: std.mem.Allocator) Gestures {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Gestures) void {
        self.devices.deinit(self.alloc);
        self.* = undefined;
    }

    /// Drop the state of a device that is going away. A press still in flight
    /// is released by the seat's normal flush once no device holds a press.
    pub fn forget(self: *Gestures, wlr_device: *wlr.InputDevice) void {
        _ = self.devices.swapRemove(wlr_device);
    }

    /// True while any device holds a sustained press (including a bridged drag).
    pub fn held(self: *const Gestures) bool {
        var it = self.devices.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.hold.fingers != 0 or entry.value_ptr.hold.bridging) return true;
        }
        return false;
    }

    /// State of a device, created on demand by a begin event.
    fn deviceState(self: *Gestures, wlr_device: *wlr.InputDevice) ?*DeviceState {
        const gop = self.devices.getOrPut(self.alloc, wlr_device) catch |err| {
            log.err("out of memory tracking gesture device: {s}", .{@errorName(err)});
            return null;
        };
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr;
    }

    /// State of a device, if it has any (update/end events).
    fn deviceStateFor(self: *Gestures, wlr_device: *wlr.InputDevice) ?*DeviceState {
        return self.devices.getPtr(wlr_device);
    }

    pub fn swipeBegin(self: *Gestures, wlr_device: *wlr.InputDevice, fingers: u32) Effects {
        if (!GestureConfig.enabled or GestureConfig.fingerIndex(fingers) == null) {
            return .{ .action = .forward };
        }
        const state = self.deviceState(wlr_device) orelse return .{ .action = .forward };
        // A superseding swipe continues the drag in progress; it must not start
        // a fresh (F-key) swipe.
        if (!state.hold.bridging) state.swipe = .{ .fingers = fingers };
        return .{};
    }

    pub fn swipeUpdate(self: *Gestures, wlr_device: *wlr.InputDevice, dx: f64, dy: f64) Effects {
        const state = self.deviceStateFor(wlr_device) orelse return .{ .action = .forward };
        if (state.hold.bridging) return .{ .action = .{ .drag = .{ .dx = dx, .dy = dy } } };
        if (state.swipe.fingers != 0) {
            state.swipe.dx += dx;
            state.swipe.dy += dy;
            return .{};
        }
        return .{ .action = .forward };
    }

    pub fn swipeEnd(self: *Gestures, wlr_device: *wlr.InputDevice, cancelled: bool, natural_scroll: bool) Effects {
        const state = self.deviceStateFor(wlr_device) orelse return .{ .action = .forward };
        if (state.hold.bridging) {
            // The superseding gesture ended: the fingers lifted, end the drag.
            state.hold = .{};
            return .{ .release = true };
        }

        const fingers = state.swipe.fingers;
        const dx = state.swipe.dx;
        const dy = state.swipe.dy;
        state.swipe = .{};

        if (fingers == 0) return .{ .action = .forward };
        if (cancelled) return .{};

        const fingers_index = GestureConfig.fingerIndex(fingers) orelse return .{};
        const direction = GestureConfig.resolveDirection(dx, dy, natural_scroll) orelse return .{};
        const keysym = GestureConfig.reserved[fingers_index][@intFromEnum(direction)] orelse return .{};
        return .{ .action = .{ .key = keysym } };
    }

    pub fn holdBegin(self: *Gestures, wlr_device: *wlr.InputDevice, fingers: u32) Effects {
        if (!GestureConfig.enabled or GestureConfig.fingerIndex(fingers) == null) {
            return .{ .action = .forward };
        }
        const state = self.deviceState(wlr_device) orelse return .{ .action = .forward };
        // A second hold on the same device while one is active ends the first
        // cleanly; holds on other devices are independent.
        const release = state.hold.fingers != 0 or state.hold.bridging;
        state.hold = .{ .fingers = fingers };

        const target = GestureConfig.hold_reserved[GestureConfig.fingerIndex(fingers).?] orelse {
            return .{ .release = release };
        };
        return .{ .release = release, .action = switch (target) {
            .key => |keysym| .{ .key = keysym },
            .button => |button| .{ .button = button },
        } };
    }

    pub fn holdEnd(
        self: *Gestures,
        wlr_device: *wlr.InputDevice,
        cancelled: bool,
        press_in_flight: bool,
    ) Effects {
        const state = self.deviceStateFor(wlr_device) orelse return .{ .action = .forward };
        const fingers = state.hold.fingers;
        state.hold = .{};

        if (fingers == 0) return .{ .action = .forward };

        if (cancelled and press_in_flight) {
            // The hold was superseded by finger movement: libinput sends a
            // cancelling hold_end before the swipe/pinch that now follows. Keep
            // the press down and ride it out — the deltas drive the op (drag)
            // and the superseding gesture's end releases the press.
            state.hold = .{ .fingers = fingers, .bridging = true };
            return .{};
        }

        // Fingers lifted: release the press held since hold_begin. A hold lasts
        // well past one manage cycle, so the press has been acked.
        return .{ .release = true };
    }

    pub fn pinchBegin(self: *Gestures, wlr_device: *wlr.InputDevice, fingers: u32) Effects {
        if (!GestureConfig.enabled or GestureConfig.fingerIndex(fingers) == null) {
            return .{ .action = .forward };
        }
        const state = self.deviceState(wlr_device) orelse return .{ .action = .forward };
        // A superseding pinch continues the drag in progress; don't start a
        // fresh (F11/F12) pinch.
        if (!state.hold.bridging) state.pinch = .{ .fingers = fingers };
        return .{};
    }

    pub fn pinchUpdate(self: *Gestures, wlr_device: *wlr.InputDevice, scale: f64) Effects {
        const state = self.deviceStateFor(wlr_device) orelse return .{ .action = .forward };
        if (state.hold.bridging) return .{}; // swallowed, part of the drag
        if (state.pinch.fingers != 0) {
            // libinput scales are relative to the previous event, so multiply.
            state.pinch.scale *= scale;
            return .{};
        }
        return .{ .action = .forward };
    }

    pub fn pinchEnd(self: *Gestures, wlr_device: *wlr.InputDevice, cancelled: bool) Effects {
        const state = self.deviceStateFor(wlr_device) orelse return .{ .action = .forward };
        if (state.hold.bridging) {
            // The superseding gesture ended: the fingers lifted, end the drag.
            state.hold = .{};
            return .{ .release = true };
        }

        const fingers = state.pinch.fingers;
        const scale = state.pinch.scale;
        state.pinch = .{};

        if (fingers == 0) return .{ .action = .forward };
        if (cancelled) return .{};

        // Pinch in or out; sub-threshold pinches are consumed without firing.
        const direction: GestureConfig.PinchDirection = if (GestureConfig.isPinchIn(scale))
            .in
        else if (GestureConfig.isPinchOut(scale))
            .out
        else
            return .{};

        const fingers_index = GestureConfig.fingerIndex(fingers) orelse return .{};
        const keysym = GestureConfig.pinch_reserved[fingers_index][@intFromEnum(direction)] orelse return .{};
        return .{ .action = .{ .key = keysym } };
    }
};

const device_a: *wlr.InputDevice = @ptrFromInt(0x1000);
const device_b: *wlr.InputDevice = @ptrFromInt(0x2000);

fn expectKey(effects: Gesture.Effects, keysym: xkb.Keysym) !void {
    try std.testing.expect(effects.action == .key);
    try std.testing.expectEqual(keysym, effects.action.key);
    try std.testing.expect(!effects.release);
}

fn expectButton(effects: Gesture.Effects, button: u32) !void {
    try std.testing.expect(effects.action == .button);
    try std.testing.expectEqual(button, effects.action.button);
    try std.testing.expect(!effects.release);
}

test "swipe fires the mapped key and ignores noise" {
    var gestures = Gestures.init(std.testing.allocator);
    defer gestures.deinit();

    // A three finger swipe left fires F3.
    try std.testing.expect(gestures.swipeBegin(device_a, 3).action == .none);
    try std.testing.expect(gestures.swipeUpdate(device_a, -50, 0).action == .none);
    try expectKey(gestures.swipeEnd(device_a, false, false), .F3);

    // A four finger swipe down fires F6, natural scroll flips it to F5.
    try std.testing.expect(gestures.swipeBegin(device_a, 4).action == .none);
    try std.testing.expect(gestures.swipeUpdate(device_a, 0, 50).action == .none);
    try expectKey(gestures.swipeEnd(device_a, false, false), .F6);
    try std.testing.expect(gestures.swipeBegin(device_a, 4).action == .none);
    try std.testing.expect(gestures.swipeUpdate(device_a, 0, 50).action == .none);
    try expectKey(gestures.swipeEnd(device_a, false, true), .F5);

    // Fingers resting in place fire nothing.
    try std.testing.expect(gestures.swipeBegin(device_a, 3).action == .none);
    try std.testing.expect(gestures.swipeUpdate(device_a, 2, -2).action == .none);
    try std.testing.expect(gestures.swipeEnd(device_a, false, false).action == .none);

    // A cancelled swipe fires nothing either.
    try std.testing.expect(gestures.swipeBegin(device_a, 3).action == .none);
    try std.testing.expect(gestures.swipeUpdate(device_a, -50, 0).action == .none);
    try std.testing.expect(gestures.swipeEnd(device_a, true, false).action == .none);
}

test "hold presses, bridges, drags and releases" {
    var gestures = Gestures.init(std.testing.allocator);
    defer gestures.deinit();

    // A three finger hold presses the side mouse button.
    try expectButton(gestures.holdBegin(device_a, 3), 0x113);
    try std.testing.expect(gestures.held());

    // Finger movement supersedes the hold: the press stays down and the swipe
    // deltas become drag deltas.
    const superseded = gestures.holdEnd(device_a, true, true);
    try std.testing.expect(!superseded.release);
    try std.testing.expect(superseded.action == .none);
    try std.testing.expect(gestures.held());
    try std.testing.expect(gestures.swipeBegin(device_a, 3).action == .none);
    const drag = gestures.swipeUpdate(device_a, 7, -3);
    try std.testing.expect(drag.action == .drag);
    try std.testing.expectEqual(@as(f64, 7), drag.action.drag.dx);
    try std.testing.expectEqual(@as(f64, -3), drag.action.drag.dy);

    // The superseding swipe ends when the fingers lift: release the press.
    const ended = gestures.swipeEnd(device_a, false, false);
    try std.testing.expect(ended.release);
    try std.testing.expect(ended.action == .none);
    try std.testing.expect(!gestures.held());
}

test "hold releases when the fingers lift or nothing is pressed" {
    var gestures = Gestures.init(std.testing.allocator);
    defer gestures.deinit();

    // Lifting the fingers releases the press.
    try expectKey(gestures.holdBegin(device_a, 4), .F10);
    try std.testing.expect(gestures.holdEnd(device_a, false, true).release);

    // A cancelled hold without a press in flight still releases (nothing is
    // pressed, so the release is a no-op for the seat).
    try expectButton(gestures.holdBegin(device_a, 3), 0x113);
    try std.testing.expect(gestures.holdEnd(device_a, true, false).release);
}

test "devices keep independent state" {
    var gestures = Gestures.init(std.testing.allocator);
    defer gestures.deinit();

    // device_a is dragging, device_b swipes on its own.
    try expectButton(gestures.holdBegin(device_a, 3), 0x113);
    try std.testing.expect(!gestures.holdEnd(device_a, true, true).release);
    try std.testing.expect(gestures.swipeBegin(device_b, 3).action == .none);
    try std.testing.expect(gestures.swipeUpdate(device_b, 20, 0).action == .none);
    // device_b's deltas are not drag deltas for device_a's drag.
    try std.testing.expect(gestures.swipeUpdate(device_a, 5, 0).action == .drag);
    try expectKey(gestures.swipeEnd(device_b, false, false), .F4);
    // device_a's bridged drag is still alive.
    try std.testing.expect(gestures.held());

    // Forgetting a device drops its state and its drag.
    gestures.forget(device_a);
    try std.testing.expect(!gestures.held());
    try std.testing.expect(gestures.swipeUpdate(device_a, 5, 0).action == .forward);
}

test "pinch maps to keys and unmapped pinches are consumed" {
    var gestures = Gestures.init(std.testing.allocator);
    defer gestures.deinit();

    // Four finger pinch in fires F12, pinch out fires F11.
    try std.testing.expect(gestures.pinchBegin(device_a, 4).action == .none);
    try std.testing.expect(gestures.pinchUpdate(device_a, 0.8).action == .none);
    try expectKey(gestures.pinchEnd(device_a, false), .F12);
    try std.testing.expect(gestures.pinchBegin(device_a, 4).action == .none);
    try std.testing.expect(gestures.pinchUpdate(device_a, 1.2).action == .none);
    try expectKey(gestures.pinchEnd(device_a, false), .F11);

    // A three finger pinch is consumed without firing.
    try std.testing.expect(gestures.pinchBegin(device_a, 3).action == .none);
    try std.testing.expect(gestures.pinchUpdate(device_a, 0.5).action == .none);
    try std.testing.expect(gestures.pinchEnd(device_a, false).action == .none);
}

test "untaken finger counts are forwarded" {
    var gestures = Gestures.init(std.testing.allocator);
    defer gestures.deinit();

    try std.testing.expect(gestures.swipeBegin(device_a, 2).action == .forward);
    try std.testing.expect(gestures.swipeUpdate(device_a, 5, 5).action == .forward);
    try std.testing.expect(gestures.swipeEnd(device_a, false, false).action == .forward);
    try std.testing.expect(gestures.holdBegin(device_a, 5).action == .forward);
    try std.testing.expect(gestures.holdEnd(device_a, false, false).action == .forward);
    try std.testing.expect(gestures.pinchBegin(device_a, 2).action == .forward);
    try std.testing.expect(gestures.pinchUpdate(device_a, 1.1).action == .forward);
    try std.testing.expect(gestures.pinchEnd(device_a, false).action == .forward);
}
