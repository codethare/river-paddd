// SPDX-FileCopyrightText: © 2025 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

/// Configuration and pure logic for touchpad gesture → key injection.
///
/// The reserved keysyms are matched by keysym directly (see Seat.injectGestureKey),
/// so they do not need to exist in any client keymap.
const GestureConfig = @This();

const std = @import("std");
const math = std.math;
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

/// What a gesture triggers: a synthesized key press or an evdev mouse button.
pub const Target = union(enum) {
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

    /// Accumulated swipe delta below which (in both axes) fingers are treated
    /// as resting in place and fire nothing.
    swipe_threshold: f64 = 10,

    /// Accumulated scale past which a pinch counts as in (1 - threshold) or
    /// out (1 + threshold).
    pinch_threshold: f64 = 0.05,

    /// Radius in pixels of the rounded corners drawn on window borders. Clamped
    /// per window so the content's square corners stay inside the arc.
    border_radius: u31 = 10,

    /// Swipe targets, indexed by [finger index][direction].
    swipe: [2][4]?Target = .{
        .{ .{ .key = .F1 }, .{ .key = .F2 }, .{ .key = .F3 }, .{ .key = .F4 } },
        .{ .{ .key = .F5 }, .{ .key = .F6 }, .{ .key = .F7 }, .{ .key = .F8 } },
    },

    /// Hold targets, indexed by finger index.
    hold: [2]?Target = .{
        .{ .button = 0x113 }, // BTN_SIDE
        .{ .key = .F10 },
    },

    /// Pinch targets, indexed by [finger index][PinchDirection].
    pinch: [2][2]?Target = .{
        .{ null, null },
        .{ .{ .key = .F12 }, .{ .key = .F11 } },
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

/// Resolve the swipe direction from the accumulated physical delta, honoring
/// the touchpad's natural scroll sense. Returns null when the swipe is too
/// small to be intentional, per `threshold`.
pub fn resolveDirection(dx: f64, dy: f64, natural_scroll: bool, threshold: f64) ?Direction {
    var ddx = dx;
    var ddy = dy;
    if (natural_scroll) {
        ddx = -ddx;
        ddy = -ddy;
    }

    if (@abs(ddx) <= threshold and @abs(ddy) <= threshold) return null;

    return if (@abs(ddx) > @abs(ddy))
        (if (ddx > 0) .right else .left)
    else
        (if (ddy > 0) .down else .up);
}

/// True when the accumulated scale is a deliberate pinch-in.
pub fn isPinchIn(scale: f64, threshold: f64) bool {
    return scale <= 1.0 - threshold;
}

/// True when the accumulated scale is a deliberate pinch-out.
pub fn isPinchOut(scale: f64, threshold: f64) bool {
    return scale >= 1.0 + threshold;
}

pub const ParseError = error{
    ExpectedEquals,
    UnknownKey,
    UnknownValue,
    InvalidKeysym,
    InvalidButton,
    InvalidThreshold,
    InvalidRadius,
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

/// The path resolved by the first load(), kept so that reload() does not need
/// the environment again.
var config_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
var config_path: ?[]const u8 = null;

/// Read the gesture config file and apply it to `config`. A missing file
/// leaves the defaults in place; a malformed line is logged and skipped.
pub fn load(config: *Config, io: Io, environ: std.process.Environ) void {
    if (config_path == null) {
        config_path = configPath(environ, &config_path_buffer);
    }
    reload(config, io);
}

/// Re-read the file loaded by load(), e.g. on SIGHUP. Does nothing before the
/// first load(). The caller must be on the event loop thread, which is the only
/// thread that reads the config.
pub fn reload(config: *Config, io: Io) void {
    const path = config_path orelse return;

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

    if (std.mem.eql(u8, key, "swipe_threshold")) {
        config.swipe_threshold = try parseThreshold(value);
        return;
    }

    if (std.mem.eql(u8, key, "pinch_threshold")) {
        config.pinch_threshold = try parseThreshold(value);
        return;
    }

    if (std.mem.eql(u8, key, "border_radius")) {
        config.border_radius = std.fmt.parseInt(u31, value, 0) catch return error.InvalidRadius;
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
        config.swipe[try fingerIndexFromChar(key[0])][@intFromEnum(direction)] = try parseTarget(value);
        return;
    }

    // Holds: hold3, hold4
    if (std.mem.startsWith(u8, key, "hold") and key.len == 5) {
        config.hold[try fingerIndexFromChar(key[4])] = try parseTarget(value);
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
        config.pinch[try fingerIndexFromChar(key[5])][@intFromEnum(direction)] = try parseTarget(value);
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

fn parseKeysym(value: []const u8) ParseError!xkb.Keysym {
    var name: [64]u8 = undefined;
    if (value.len >= name.len) return error.InvalidKeysym;
    @memcpy(name[0..value.len], value);
    name[value.len] = 0;

    const keysym = xkb.Keysym.fromName(name[0..value.len :0], .case_insensitive);
    if (keysym == .NoSymbol) return error.InvalidKeysym;
    return keysym;
}

/// Parse a positive gesture threshold. Non-finite and non-positive values are
/// rejected so that a typo cannot silently disable a gesture.
fn parseThreshold(value: []const u8) ParseError!f64 {
    const threshold = std.fmt.parseFloat(f64, value) catch return error.InvalidThreshold;
    if (!math.isFinite(threshold) or threshold <= 0) return error.InvalidThreshold;
    return threshold;
}

/// Parse `none`, `button:<evdev code>` or a keysym name.
fn parseTarget(value: []const u8) ParseError!?Target {
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
    try parseLine(&config, "3right = button:0x116");
    try parseLine(&config, "4right = none");
    try parseLine(&config, "hold3 = button:0x114");
    try parseLine(&config, "hold4 = Return");
    try parseLine(&config, "pinch4out = Escape");
    try parseLine(&config, "pinch3in = button:0x110");
    try parseLine(&config, "pinch4in = none");

    try testing.expect(!config.enabled);
    try testing.expectEqual(@as(?Target, .{ .key = .F5 }), config.swipe[0][@intFromEnum(Direction.up)]);
    try testing.expectEqual(@as(?Target, .{ .button = 0x116 }), config.swipe[0][@intFromEnum(Direction.right)]);
    try testing.expectEqual(@as(?Target, null), config.swipe[1][@intFromEnum(Direction.right)]);
    try testing.expectEqual(@as(u32, 0x114), config.hold[0].?.button);
    try testing.expectEqual(xkb.Keysym.Return, config.hold[1].?.key);
    try testing.expectEqual(
        @as(?Target, .{ .key = .Escape }),
        config.pinch[1][@intFromEnum(PinchDirection.out)],
    );
    try testing.expectEqual(
        @as(?Target, .{ .button = 0x110 }),
        config.pinch[0][@intFromEnum(PinchDirection.in)],
    );
    try testing.expectEqual(@as(?Target, null), config.pinch[1][@intFromEnum(PinchDirection.in)]);

    // Untouched entries keep their defaults.
    try testing.expectEqual(@as(?Target, .{ .key = .F2 }), config.swipe[0][@intFromEnum(Direction.down)]);
    try testing.expectEqual(@as(?Target, .{ .key = .F5 }), config.swipe[1][@intFromEnum(Direction.up)]);
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
    try testing.expectEqual(@as(?Target, .{ .key = .F5 }), config.swipe[0][@intFromEnum(Direction.up)]);
    // The bad line is skipped, later lines still apply.
    try testing.expectEqual(@as(u32, 0x114), config.hold[1].?.button);
}

test "reload re-reads the file that load resolved" {
    const testing = std.testing;
    const io = std.Io.Threaded.global_single_threaded.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Point the module at a file we control instead of going through the
    // environment; load() resolves the same way.
    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = dir_buffer[0..try tmp.dir.realPath(io, &dir_buffer)];
    config_path = try std.fmt.bufPrint(&config_path_buffer, "{s}/gestures.conf", .{dir_path});

    var config: Config = default_config;

    // No file yet: the defaults stay in place.
    reload(&config, io);
    try testing.expectEqual(@as(u31, 10), config.border_radius);

    try tmp.dir.writeFile(io, .{
        .sub_path = "gestures.conf",
        .data = "border_radius = 3\n3up = F13\n",
    });
    reload(&config, io);
    try testing.expectEqual(@as(u31, 3), config.border_radius);
    try testing.expectEqual(@as(?Target, .{ .key = .F13 }), config.swipe[0][@intFromEnum(Direction.up)]);

    // An edited file is picked up by the next reload, and entries it no longer
    // mentions keep the value the previous reload set.
    try tmp.dir.writeFile(io, .{ .sub_path = "gestures.conf", .data = "border_radius = 7\n" });
    reload(&config, io);
    try testing.expectEqual(@as(u31, 7), config.border_radius);
    try testing.expectEqual(@as(?Target, .{ .key = .F13 }), config.swipe[0][@intFromEnum(Direction.up)]);
}

test "gesture config takes a border radius" {
    const testing = std.testing;

    var config = default_config;
    try testing.expectEqual(@as(u31, 10), config.border_radius);

    try parseLine(&config, "border_radius = 12");
    try testing.expectEqual(@as(u31, 12), config.border_radius);

    // 0 is allowed: square corners are a choice, not a typo.
    try parseLine(&config, "border_radius = 0");
    try testing.expectEqual(@as(u31, 0), config.border_radius);

    try testing.expectError(error.InvalidRadius, parseLine(&config, "border_radius = round"));
    try testing.expectError(error.InvalidRadius, parseLine(&config, "border_radius = -1"));
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
    try testing.expectError(error.InvalidButton, parseLine(&config, "3left = button:zzz"));
    try testing.expectError(error.InvalidThreshold, parseLine(&config, "swipe_threshold = soon"));
    try testing.expectError(error.InvalidThreshold, parseLine(&config, "swipe_threshold = -1"));
    try testing.expectError(error.InvalidThreshold, parseLine(&config, "pinch_threshold = 0"));

    try testing.expect(config.enabled);
    try testing.expectEqual(@as(?Target, .{ .key = .F1 }), config.swipe[0][@intFromEnum(Direction.up)]);
    try testing.expectEqual(@as(u32, 0x113), config.hold[0].?.button);
    try testing.expectEqual(@as(f64, 10), config.swipe_threshold);
    try testing.expectEqual(@as(f64, 0.05), config.pinch_threshold);
}

test "gesture config takes custom thresholds" {
    const testing = std.testing;

    var config = default_config;
    try parseLine(&config, "swipe_threshold = 25.5");
    try parseLine(&config, "pinch_threshold = 0.2");

    try testing.expectEqual(@as(f64, 25.5), config.swipe_threshold);
    try testing.expectEqual(@as(f64, 0.2), config.pinch_threshold);

    // The thresholds are what resolveDirection and the pinch tests use.
    try testing.expectEqual(
        @as(?Direction, null),
        resolveDirection(20, 0, false, config.swipe_threshold),
    );
    try testing.expectEqual(
        @as(?Direction, .right),
        resolveDirection(30, 0, false, config.swipe_threshold),
    );
    try testing.expect(isPinchIn(0.7, config.pinch_threshold));
    try testing.expect(!isPinchIn(0.9, config.pinch_threshold));
    try testing.expect(isPinchOut(1.3, config.pinch_threshold));
    try testing.expect(!isPinchOut(1.1, config.pinch_threshold));
}
