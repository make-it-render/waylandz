//! A connected Wayland client: socket, buffered request writer, object-id
//! registry, discovered globals, and the receive/dispatch loop.
//!
//! Threading contract (mirrors the recvloop model): exactly one task calls
//! `receive` at a time; any thread may marshal requests between `acquire` /
//! `release`. The one mutex guards the writer, the id allocator, the object
//! map, and the globals list. The receive path itself also writes (pong,
//! ack_configure), so those replies go through the same lock.

io: std.Io,
allocator: std.mem.Allocator,
stream: std.Io.net.Stream,
writer_buffer: []u8,
net_writer: *std.Io.net.Stream.Writer,
mutex: std.Io.Mutex = .init,
ids: ObjectIds = .{},
objects: std.AutoHashMapUnmanaged(u32, Interface) = .empty,
globals: std.ArrayList(Global) = .empty,
registry_id: u32 = 0,
body_buffer: [wire.max_message_size]u8 = undefined,
/// Descriptors that arrived as SCM_RIGHTS, in wire order, waiting for the
/// event that declares them (wl_keyboard.keymap). Touched only by the
/// receive task, like body_buffer.
pending_fds: std.ArrayList(std.posix.fd_t) = .empty,

/// One interface advertised by the compositor's registry.
pub const Global = struct {
    name: u32,
    interface: []const u8,
    version: u32,
};

pub fn init(io: std.Io, environ: std.process.Environ, allocator: std.mem.Allocator) !@This() {
    const stream = try socket.connect(io, environ);
    errdefer stream.close(io);

    const writer_buffer = try allocator.alloc(u8, 4096);
    errdefer allocator.free(writer_buffer);
    const net_writer = try allocator.create(std.Io.net.Stream.Writer);
    errdefer allocator.destroy(net_writer);
    net_writer.* = stream.writer(io, writer_buffer);

    var self: @This() = .{
        .io = io,
        .allocator = allocator,
        .stream = stream,
        .writer_buffer = writer_buffer,
        .net_writer = net_writer,
    };
    try self.objects.put(allocator, ObjectIds.display_id, .display);
    return self;
}

pub fn deinit(self: *@This()) void {
    self.net_writer.interface.flush() catch {};
    self.stream.close(self.io);
    for (self.globals.items) |global| {
        self.allocator.free(global.interface);
    }
    self.globals.deinit(self.allocator);
    self.objects.deinit(self.allocator);
    self.ids.deinit(self.allocator);
    for (self.pending_fds.items) |fd| {
        _ = std.os.linux.close(fd);
    }
    self.pending_fds.deinit(self.allocator);
    self.allocator.free(self.writer_buffer);
    self.allocator.destroy(self.net_writer);
}

/// Lock the connection and return the request writer. Pair with `release`.
/// Marshal any number of requests in between; nothing hits the wire until
/// `flush` (or the buffer fills).
pub fn acquire(self: *@This()) *std.Io.Writer {
    self.mutex.lockUncancelable(self.io);
    return &self.net_writer.interface;
}

pub fn release(self: *@This()) void {
    self.mutex.unlock(self.io);
}

/// Drain buffered requests to the socket.
pub fn flush(self: *@This()) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.flushLocked();
}

fn flushLocked(self: *@This()) !void {
    self.net_writer.interface.flush() catch |err| {
        if (self.net_writer.err) |net_err| {
            log.err("Net error: {any}", .{net_err});
            return net_err;
        }
        return err;
    };
}

/// Allocate an object id and register the interface its events decode as.
/// Call before marshalling the request that creates the object.
pub fn newId(self: *@This(), interface: Interface) !u32 {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const id = try self.ids.alloc();
    try self.objects.put(self.allocator, id, interface);
    return id;
}

/// Drop a server-created object (a wl_data_offer) from the map after sending
/// its destroy request. The server acknowledges only client ids with
/// delete_id, so nothing else would ever remove it; its id is not recycled
/// since it was never ours to allocate.
pub fn forgetServerObject(self: *@This(), id: u32) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    _ = self.objects.remove(id);
}

/// Send one fully-encoded message with an fd attached as SCM_RIGHTS
/// (wl_shm.create_pool, wl_data_offer.receive). Flushes buffered requests
/// first so wire order is preserved.
pub fn sendWithFd(self: *@This(), bytes: []const u8, fd: std.posix.fd_t) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.flushLocked();
    try socket.sendWithFd(self.stream.socket.handle, bytes, fd);
}

/// Fetch the registry and block until the initial burst of globals has
/// arrived. Call once after init, before binding anything.
pub fn discoverGlobals(self: *@This(), io: std.Io) !void {
    self.registry_id = try self.newId(.registry);
    {
        const writer = self.acquire();
        defer self.release();
        try protocol.wayland.display.getRegistry(writer, self.registry_id);
    }
    try self.roundtrip(io);
}

pub fn findGlobal(self: *@This(), interface_name: []const u8) ?Global {
    for (self.globals.items) |global| {
        if (std.mem.eql(u8, global.interface, interface_name)) return global;
    }
    return null;
}

/// Bind a discovered global, clamping `version` to what the server offers.
/// Returns the new object id.
pub fn bind(self: *@This(), global: Global, interface: Interface, version: u32) !u32 {
    const id = try self.newId(interface);
    const writer = self.acquire();
    defer self.release();
    try protocol.wayland.registry.bind(writer, self.registry_id, global.name, global.interface, @min(version, global.version), id);
    return id;
}

/// Send wl_display.sync and flush; returns the callback id whose
/// `callback_done` marks everything before it as processed.
pub fn sync(self: *@This(), io: std.Io) !u32 {
    _ = io;
    const callback_id = try self.newId(.callback);
    {
        const writer = self.acquire();
        defer self.release();
        try protocol.wayland.display.sync(writer, callback_id);
    }
    try self.flush();
    return callback_id;
}

/// Block until the server has processed everything sent so far. Events
/// surfaced in the meantime are dropped — setup-time only, before an event
/// loop owns `receive`.
pub fn roundtrip(self: *@This(), io: std.Io) !void {
    const callback_id = try self.sync(io);
    while (true) {
        const event = try self.receive(io) orelse continue;
        switch (event) {
            .callback_done => |done| if (done.callback_id == callback_id) return,
            .keyboard_keymap => |keymap| {
                _ = std.os.linux.close(keymap.fd);
                log.debug("roundtrip dropping keymap event (fd closed)", .{});
            },
            .data_source_send => |send| {
                _ = std.os.linux.close(send.fd);
                log.debug("roundtrip dropping data_source send (fd closed)", .{});
            },
            else => log.debug("roundtrip dropping event: {s}", .{@tagName(event)}),
        }
    }
}

/// Read and decode one message. Returns null when the message was consumed
/// internally (protocol bookkeeping) or skipped as irrelevant. The socket
/// read blocks through `io`, so a task blocked here is io-cancelable.
/// Returned string slices point into the read buffer — valid until the next
/// receive. Only one task may call receive at a time.
pub fn receive(self: *@This(), io: std.Io) !?Event {
    var header_bytes: [wire.header_size]u8 = undefined;
    try self.receiveBytes(io, &header_bytes);
    const header = wire.parseHeader(header_bytes);
    if (header.size < wire.header_size) return error.MalformedMessage;
    const body_len = header.size - wire.header_size;
    if (body_len > self.body_buffer.len) return error.MessageTooLarge;
    const body = self.body_buffer[0..body_len];
    try self.receiveBytes(io, body);

    const interface = blk: {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        break :blk self.objects.get(header.object_id);
    } orelse {
        // Normal after destroying an object: events already in flight for
        // the old id keep arriving until the server's delete_id.
        log.debug("Event for unknown object {d} opcode {d}", .{ header.object_id, header.opcode });
        return null;
    };

    var event = try protocol.event.parse(interface, header.opcode, header.object_id, body) orelse return null;

    switch (event) {
        // Events whose declared fd argument travels out of band: attach the
        // next queued descriptor. Ownership passes to the caller.
        .keyboard_keymap => |*keymap| {
            if (self.pending_fds.items.len == 0) return error.MissingFileDescriptor;
            keymap.fd = self.pending_fds.orderedRemove(0);
        },
        .data_source_send => |*send| {
            if (self.pending_fds.items.len == 0) return error.MissingFileDescriptor;
            send.fd = self.pending_fds.orderedRemove(0);
        },
        // The one object the server creates for us. Register it now: its
        // own events (the mime types it offers) are already on their way.
        .data_offer_new => |new| {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            try self.objects.put(self.allocator, new.offer, .data_offer);
        },
        else => {},
    }

    switch (event) {
        .display_error => |e| {
            log.err("Protocol error on object {d}: code {d}: {s}", .{ e.object_id, e.code, e.message });
            return error.WaylandProtocolError;
        },
        .delete_id => |id| {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            _ = self.objects.remove(id);
            // Only our own ids go back to the allocator; the server's range
            // never came from it.
            if (ObjectIds.isClientId(id)) self.ids.free(self.allocator, id);
            return null;
        },
        .registry_global => |global| {
            const interface_copy = try self.allocator.dupe(u8, global.interface);
            errdefer self.allocator.free(interface_copy);
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            try self.globals.append(self.allocator, .{
                .name = global.name,
                .interface = interface_copy,
                .version = global.version,
            });
            return null;
        },
        .registry_global_remove => |name| {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            for (self.globals.items, 0..) |global, index| {
                if (global.name == name) {
                    self.allocator.free(global.interface);
                    _ = self.globals.swapRemove(index);
                    break;
                }
            }
            return null;
        },
        else => return event,
    }
}

/// Room for a cmsghdr plus this many descriptors — more than any one
/// Wayland message legitimately carries.
const max_fds_per_read = 8;
const control_size = cmsgAlign(@sizeOf(std.os.linux.cmsghdr)) + cmsgAlign(max_fds_per_read * @sizeOf(i32));

fn cmsgAlign(size: usize) usize {
    return std.mem.alignForward(usize, size, @sizeOf(usize));
}

/// Read exactly `buffer.len` bytes, blocking until they all arrive. Exact
/// reads only — no read-ahead that could strand bytes between messages.
///
/// Every read supplies an ancillary buffer: a plain read at the moment an
/// SCM_RIGHTS payload arrives would make the kernel close the descriptors,
/// silently losing the keymap fd. Reads still block through `io`, so the
/// receive task stays cancelable.
fn receiveBytes(self: *@This(), io: std.Io, buffer: []u8) !void {
    var received: usize = 0;
    while (received < buffer.len) {
        var control: [control_size]u8 align(@alignOf(std.os.linux.cmsghdr)) = undefined;
        var message: std.Io.net.IncomingMessage = .{
            .from = undefined,
            .data = undefined,
            .control = &control,
            .flags = undefined,
        };
        const maybe_err, const count = self.stream.socket.receiveManyTimeout(
            io,
            (&message)[0..1],
            buffer[received..],
            .{},
            .none,
        );
        if (maybe_err) |err| return err;
        if (count == 0) continue;
        // The kernel discards descriptors it cannot fit rather than queueing
        // them, so a truncated control message means they are already gone.
        if (message.flags.ctrunc) return error.ControlMessageTruncated;
        try self.collectFds(message.control);
        if (message.data.len == 0) return error.ConnectionClosed;
        received += message.data.len;
    }
}

/// Walk a control buffer and queue every SCM_RIGHTS descriptor found.
fn collectFds(self: *@This(), control: []const u8) !void {
    const header_size = cmsgAlign(@sizeOf(std.os.linux.cmsghdr));
    var offset: usize = 0;
    while (offset + @sizeOf(std.os.linux.cmsghdr) <= control.len) {
        const header: *align(1) const std.os.linux.cmsghdr = @ptrCast(control[offset..].ptr);
        if (header.len < header_size or offset + header.len > control.len) break;

        if (header.level == std.posix.SOL.SOCKET and header.type == std.posix.SCM.RIGHTS) {
            const payload = control[offset + header_size .. offset + header.len];
            var index: usize = 0;
            while (index + @sizeOf(i32) <= payload.len) : (index += @sizeOf(i32)) {
                // The array is not guaranteed aligned, so read it byte-wise.
                const fd = std.mem.readInt(i32, payload[index..][0..4], native_endian);
                errdefer _ = std.os.linux.close(fd);
                try self.pending_fds.append(self.allocator, fd);
            }
        }
        offset += cmsgAlign(header.len);
    }
}

test "connect and discover globals" {
    // The test environ is empty, so this exercises the live path only when a
    // compositor is reachable through defaults; otherwise it skips. The demo
    // binary is the real end-to-end check (it gets the process environ).
    const environ: std.process.Environ = .empty;
    var display = @This().init(testing.io, environ, testing.allocator) catch return;
    defer display.deinit();

    try display.discoverGlobals(testing.io);

    // Every compositor advertises at least wl_compositor and wl_shm.
    try testing.expect(display.findGlobal("wl_compositor") != null);
    try testing.expect(display.findGlobal("wl_shm") != null);
}

const std = @import("std");
const testing = std.testing;
const native_endian = @import("builtin").cpu.arch.endian();

const socket = @import("wire/socket.zig");
const ObjectIds = @import("wire/object.zig");
const wire = @import("protocol/wire.zig");
const protocol = struct {
    const wayland = @import("protocol/wayland.zig");
    const event = @import("protocol/event.zig");
};
const Interface = @import("protocol/event.zig").Interface;
const Event = @import("protocol/event.zig").Event;

const log = std.log.scoped(.wayland);
