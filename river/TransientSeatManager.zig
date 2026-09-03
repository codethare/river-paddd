// SPDX-FileCopyrightText: © 2026 The River Developers
// SPDX-License-Identifier: GPL-3.0-only

const TSManager = @This();

const std = @import("std");
const assert = std.debug.assert;
const fmt = std.fmt;
const math = std.math;
const mem = std.mem;
const wl = @import("wayland").server.wl;
const ext = @import("wayland").server.ext;

const server = &@import("main.zig").server;

const Seat = @import("Seat.zig");

const log = std.log.scoped(.input);

global: *wl.Global,
objects: wl.list.Head(ext.TransientSeatManagerV1, null),
seats: wl.list.Head(ext.TransientSeatV1, null),
suffix: u32 = 0,

pub fn init(manager: *TSManager) !void {
    manager.* = .{
        .global = try wl.Global.create(server.wl_server, ext.TransientSeatManagerV1, 1, *TSManager, manager, bind),
        .objects = undefined,
        .seats = undefined,
    };
    manager.objects.init();
    manager.seats.init();
}

pub fn deinit(manager: *TSManager) void {
    assert(manager.objects.empty());
    assert(manager.seats.empty());
}

fn bind(client: *wl.Client, tsm: *TSManager, version: u32, id: u32) void {
    const tsm_v1 = ext.TransientSeatManagerV1.create(client, version, id) catch {
        client.postNoMemory();
        log.err("out of memory", .{});
        return;
    };
    tsm_v1.setHandler(*TSManager, handleRequest, handleDestroy, tsm);
    tsm.objects.append(tsm_v1);
}

fn handleRequest(tsm_v1: *ext.TransientSeatManagerV1, req: ext.TransientSeatManagerV1.Request, tsm: *TSManager) void {
    switch (req) {
        .create => |id| {
            transientCreate(tsm_v1, id.seat, tsm.suffix) catch {
                tsm_v1.postNoMemory();
                log.err("no memory", .{});
            };
            log.debug("created transient seat with id {}", .{tsm.suffix});
            tsm.suffix +%= 1;
        },
        .destroy => {
            tsm_v1.destroy();
        },
    }
}

fn handleDestroy(tsm_v1: *ext.TransientSeatManagerV1, _: *TSManager) void {
    tsm_v1.getLink().remove();
}

pub fn transientCreate(manager: *ext.TransientSeatManagerV1, id: u32, suffix: u32) !void {
    const transient = try ext.TransientSeatV1.create(manager.getClient(), manager.getVersion(), id);
    transient.setHandler(*const void, transientHandleRequest, transientHandleDestroy, &{});
    errdefer transient.sendDenied(); // if we error here we deny seat creation

    server.input_manager.transient_seat_manager.seats.append(transient);

    // +1 for the sentinel
    var buf: [1 + fmt.count("transient-{}", .{math.maxInt(u32)})]u8 = undefined;
    const name = std.fmt.bufPrintSentinel(&buf, "transient-{}", .{suffix}, 0) catch unreachable;

    { // we refuse to create a transient seat if our magically chosen name is already taken...
        var it = server.input_manager.seats.safeIterator(.forward);
        while (it.next()) |seat| if (mem.orderZ(u8, seat.wlr_seat.name, name) == .eq) return error.AlreadyFound;
    }

    try Seat.create(name, transient);
}

fn transientHandleRequest(transient: *ext.TransientSeatV1, req: ext.TransientSeatV1.Request, _: *const void) void {
    switch (req) {
        .destroy => transient.destroy(),
    }
}

fn transientHandleDestroy(transient: *ext.TransientSeatV1, _: *const void) void {
    // the transient seat dies with us
    var it = server.input_manager.seats.safeIterator(.forward);
    while (it.next()) |seat| if (seat.transient == transient) {
        seat.transient = null;
        seat.destroying = true;
        server.wm.dirtyWindowing();
        break;
    };

    transient.getLink().remove();
}
