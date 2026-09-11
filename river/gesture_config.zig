// SPDX-FileCopyrightText: © 2025 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

/// Configuration and pure logic for touchpad gesture → key injection.
///
/// The reserved keysyms are matched by keysym directly (see Seat.injectGestureKey),
/// so they do not need to exist in any client keymap.
const GestureConfig = @This();

const std = @import("std");
const Io = std.Io;
const xkb = @import("xkbcommon");

const log = std.log.scoped(.input);

pub const Direction = enum {
    up,
    down,
    left,
    right,
};

pub const PinchDirection = enum {
    in,
    out,
};

pub const HoldTarget = union(enum) {
    key: xkb.Keysym,
    /// evdev button code (linux/input-event-codes.h BTN_*), e.g. BTN_SIDE = 0x113.
    button: u32,
};

/// Runtime mapping, initialized to the compiled-in defaults below and
/// optionally overridden by `$XDG_CONFIG_HOME/river/gestures.conf`.
pub const Config = struct {
    /// Master switch: when true, 3/4-finger swipes are taken over by the
    /// compositor and no longer forwarded to apps as pointer gestures, even
    /// when unbound.
    enabled: bool = true,

    /// Swipe keysyms, indexed by [finger index][direction].
    swipe: [2][4]?xkb.Keysym = .{
        .{ .F1, .F2, .F3, .F4 },
        .{ .F5, .F6, .F7, .F8 },
    },

    /// Hold targets, indexed by finger index.
    hold: [2]?HoldTarget = .{
        .{ .button = 0x113 }, // BTN_SIDE
        .{ .key = .F10 },
    },

    /// Pinch keysyms, indexed by [finger index][PinchDirection].
    pinch: [2][2]?xkb.Keysym = .{
        .{ null, null },
        .{ .F12, .F11 },
    },
};

/// The compiled-in defaults, e.g. for a missing config file and for tests.
pub const default_config: Config = .{};

/// Finger count → index into the tables: 3 fingers → 0, 4 fingers → 1.
pub fn fingerIndex(fingers: u32) ?usize {
    return switch (fingers) {
        3 => 0,
        4 => 1,
        else => null,
    };
}

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

/// Accumulated gesture scale below/above which a pinch counts as in/out.
const min_scale_delta = 0.05;

/// True when the accumulated scale is a deliberate pinch-in.
pub fn isPinchIn(scale: f64) bool {
    return scale <= 1.0 - min_scale_delta;
}

/// True when the accumulated scale is a deliberate pinch-out.
pub fn isPinchOut(scale: f64) bool {
    return scale >= 1.0 + min_scale_delta;
}

pub const ParseError = error{
    ExpectedEquals,
    UnknownKey,
    UnknownValue,
    InvalidKeysym,
    InvalidButton,
};

/// Path of the gesture config file, per the XDG base directory specification.
/// Returns null when neither XDG_CONFIG_HOME nor HOME is set.
fn configPath(environ: std.process.Environ, buffer: []u8) ?[]const u8 {
    if (environ.getPosix("XDG_CONFIG_HOME")) |xdg_config_home| {
        return std.fmt.bufPrint(buffer, "{s}/river/gestures.conf", .{xdg_config_home}) catch null;
    }
    if (environ.getPosix("HOME")) |home| {
        return std.fmt.bufPrint(buffer, "{s}/.config/river/gestures.conf", .{home}) catch null;
    }
    return null;
}

/// Read the gesture config file and apply it to `config`. A missing file
/// leaves the defaults in place; a malformed line is logged and skipped.
pub fn load(config: *Config, io: Io, environ: std.process.Environ) void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = configPath(environ, &path_buffer) orelse return;

    var buffer: [64 * 1024]u8 = undefined;
    const contents = Io.Dir.cwd().readFile(io, path, &buffer) catch |err| switch (err) {
        error.FileNotFound => {
            log.debug("no gesture config at {s}", .{path});
            return;
        },
        else => {
            log.err("failed to read gesture config {s}: {t}", .{ path, err });
            return;
        },
    };
    if (contents.len == buffer.len) {
        log.warn("gesture config {s} is too large, some lines were ignored", .{path});
    }
    parse(config, contents);
}

/// Apply the contents of a gesture config file. A malformed line is logged and
/// skipped so that the remaining lines still take effect.
pub fn parse(config: *Config, contents: []const u8) void {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var line_number: usize = 0;
    while (lines.next()) |line| {
        line_number += 1;
        parseLine(config, line) catch |err| {
            log.warn("gestures.conf:{d}: {t}", .{ line_number, err });
        };
    }
}

/// Apply one `key = value` line. Blank lines and `#` comments are ignored.
pub fn parseLine(config: *Config, line: []const u8) ParseError!void {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return;

    const equals = std.mem.indexOfScalar(u8, trimmed, '=') orelse return error.ExpectedEquals;
    const key = std.mem.trim(u8, trimmed[0..equals], " \t");
    const value = std.mem.trim(u8, trimmed[equals + 1 ..], " \t");

    if (std.mem.eql(u8, key, "enabled")) {
        config.enabled = if (std.mem.eql(u8, value, "true"))
            true
        else if (std.mem.eql(u8, value, "false"))
            false
        else
            return error.UnknownValue;
        return;
    }

    // Swipes: 3up, 3down, 3left, 3right, 4up, ...
    if (key.len > 1 and (key[0] == '3' or key[0] == '4')) {
        const direction: Direction = if (std.mem.eql(u8, key[1..], "up"))
            .up
        else if (std.mem.eql(u8, key[1..], "down"))
            .down
        else if (std.mem.eql(u8, key[1..], "left"))
            .left
        else if (std.mem.eql(u8, key[1..], "right"))
            .right
        else
            return error.UnknownKey;
        config.swipe[try fingerIndexFromChar(key[0])][@intFromEnum(direction)] = try parseKeysymOrNone(value);
        return;
    }

    // Holds: hold3, hold4
    if (std.mem.startsWith(u8, key, "hold") and key.len == 5) {
        config.hold[try fingerIndexFromChar(key[4])] = try parseHoldTarget(value);
        return;
    }

    // Pinches: pinch3in, pinch3out, pinch4in, pinch4out
    if (std.mem.startsWith(u8, key, "pinch") and key.len > 6) {
        const direction: PinchDirection = if (std.mem.eql(u8, key[6..], "in"))
            .in
        else if (std.mem.eql(u8, key[6..], "out"))
            .out
        else
            return error.UnknownKey;
        config.pinch[try fingerIndexFromChar(key[5])][@intFromEnum(direction)] = try parseKeysymOrNone(value);
        return;
    }

    return error.UnknownKey;
}

fn fingerIndexFromChar(char: u8) ParseError!usize {
    return switch (char) {
        '3' => 0,
        '4' => 1,
        else => error.UnknownKey,
    };
}

/// Parse a keysym name (xkbcommon names, case insensitive) or `none` to unmap.
fn parseKeysymOrNone(value: []const u8) ParseError!?xkb.Keysym {
    if (std.mem.eql(u8, value, "none")) return null;
    return try parseKeysym(value);
}

fn parseKeysym(value: []const u8) ParseError!xkb.Keysym {
    var name: [64]u8 = undefined;
    if (value.len >= name.len) return error.InvalidKeysym;
    @memcpy(name[0..value.len], value);
    name[value.len] = 0;

    const keysym = xkb.Keysym.fromName(name[0..value.len :0], .case_insensitive);
    if (keysym == .NoSymbol) return error.InvalidKeysym;
    return keysym;
}

/// Parse `none`, `button:<evdev code>` or a keysym name.
fn parseHoldTarget(value: []const u8) ParseError!?HoldTarget {
    if (std.mem.eql(u8, value, "none")) return null;
    if (std.mem.startsWith(u8, value, "button:")) {
        const code = std.fmt.parseInt(u32, value["button:".len..], 0) catch return error.InvalidButton;
        return .{ .button = code };
    }
    return .{ .key = try parseKeysym(value) };
}

test "gesture config remaps single entries" {
    const testing = std.testing;

    var config = default_config;
    try parseLine(&config, "# a comment");
    try parseLine(&config, "");
    try parseLine(&config, "  enabled = false  ");
    try parseLine(&config, "3up = F5");
    try parseLine(&config, "4right = none");
    try parseLine(&config, "hold3 = button:0x114");
    try parseLine(&config, "hold4 = Return");
    try parseLine(&config, "pinch4out = Escape");
    try parseLine(&config, "pinch4in = none");

    try testing.expect(!config.enabled);
    try testing.expectEqual(@as(?xkb.Keysym, .F5), config.swipe[0][@intFromEnum(Direction.up)]);
    try testing.expectEqual(@as(?xkb.Keysym, null), config.swipe[1][@intFromEnum(Direction.right)]);
    try testing.expectEqual(@as(u32, 0x114), config.hold[0].?.button);
    try testing.expectEqual(xkb.Keysym.Return, config.hold[1].?.key);
    try testing.expectEqual(
        @as(?xkb.Keysym, .Escape),
        config.pinch[1][@intFromEnum(PinchDirection.out)],
    );
    try testing.expectEqual(@as(?xkb.Keysym, null), config.pinch[1][@intFromEnum(PinchDirection.in)]);

    // Untouched entries keep their defaults.
    try testing.expectEqual(@as(?xkb.Keysym, .F2), config.swipe[0][@intFromEnum(Direction.down)]);
    try testing.expectEqual(@as(?xkb.Keysym, .F5), config.swipe[1][@intFromEnum(Direction.up)]);
}

test "gesture config parses a whole file and skips bad lines" {
    const testing = std.testing;

    var config = default_config;
    parse(&config,
        \\# gestures
        \\enabled = false
        \\3up = F5
        \\bogus = F1
        \\hold4 = button:0x114
        \\
    );

    try testing.expect(!config.enabled);
    try testing.expectEqual(@as(?xkb.Keysym, .F5), config.swipe[0][@intFromEnum(Direction.up)]);
    // The bad line is skipped, later lines still apply.
    try testing.expectEqual(@as(u32, 0x114), config.hold[1].?.button);
}

test "gesture config rejects malformed lines without changing the defaults" {
    const testing = std.testing;

    var config = default_config;
    try testing.expectError(error.ExpectedEquals, parseLine(&config, "3up F1"));
    try testing.expectError(error.UnknownKey, parseLine(&config, "5up = F1"));
    try testing.expectError(error.UnknownKey, parseLine(&config, "3side = F1"));
    try testing.expectError(error.UnknownKey, parseLine(&config, "pinch4side = F1"));
    try testing.expectError(error.UnknownValue, parseLine(&config, "enabled = maybe"));
    try testing.expectError(error.InvalidKeysym, parseLine(&config, "3up = NotAKeysym"));
    try testing.expectError(error.InvalidButton, parseLine(&config, "hold3 = button:zzz"));

    try testing.expect(config.enabled);
    try testing.expectEqual(@as(?xkb.Keysym, .F1), config.swipe[0][@intFromEnum(Direction.up)]);
    try testing.expectEqual(@as(u32, 0x113), config.hold[0].?.button);
}
