//! Request marshallers for the core protocol (wayland.xml). Each function
//! writes one complete message into the (mutex-guarded) connection writer.
//! Opcodes and argument order follow the canonical XML.

const std = @import("std");
const wire = @import("wire.zig");

/// wl_shm.format values (only the two every compositor must support).
pub const format_argb8888: u32 = 0;
pub const format_xrgb8888: u32 = 1;

/// wl_seat.capability bits.
pub const seat_capability_pointer: u32 = 1;
pub const seat_capability_keyboard: u32 = 2;

/// wl_pointer.button_state / wl_keyboard.key_state.
pub const state_released: u32 = 0;
pub const state_pressed: u32 = 1;

/// wl_pointer.axis values.
pub const axis_vertical: u32 = 0;
pub const axis_horizontal: u32 = 1;

pub const display = struct {
    /// wl_display is implicitly id 1 on every connection.
    pub const id: u32 = 1;

    pub fn sync(writer: *std.Io.Writer, callback_id: u32) !void {
        try wire.writeHeader(writer, id, 0, 12);
        try wire.writeUint(writer, callback_id);
    }

    pub fn getRegistry(writer: *std.Io.Writer, registry_id: u32) !void {
        try wire.writeHeader(writer, id, 1, 12);
        try wire.writeUint(writer, registry_id);
    }
};

pub const registry = struct {
    /// An untyped new_id (wl_registry.bind's) is marshalled as the interface
    /// name string + version + the id itself.
    pub fn bind(writer: *std.Io.Writer, registry_id: u32, name: u32, interface: []const u8, version: u32, new_id: u32) !void {
        const size = wire.header_size + 4 + wire.stringSize(interface) + 4 + 4;
        try wire.writeHeader(writer, registry_id, 0, size);
        try wire.writeUint(writer, name);
        try wire.writeString(writer, interface);
        try wire.writeUint(writer, version);
        try wire.writeUint(writer, new_id);
    }
};

pub const compositor = struct {
    pub fn createSurface(writer: *std.Io.Writer, compositor_id: u32, surface_id: u32) !void {
        try wire.writeHeader(writer, compositor_id, 0, 12);
        try wire.writeUint(writer, surface_id);
    }
};

pub const shm = struct {
    /// wl_shm.create_pool carries an fd, which travels out of band via
    /// SCM_RIGHTS. This returns the encoded message bytes; send them with
    /// `wire/socket.sendWithFd` after flushing the connection writer, so wire
    /// order is preserved.
    pub fn createPoolMessage(shm_id: u32, pool_id: u32, size: i32) [16]u8 {
        var bytes: [16]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        wire.writeHeader(&writer, shm_id, 0, 16) catch unreachable;
        wire.writeUint(&writer, pool_id) catch unreachable;
        wire.writeInt(&writer, size) catch unreachable;
        return bytes;
    }
};

pub const shm_pool = struct {
    pub fn createBuffer(writer: *std.Io.Writer, pool_id: u32, buffer_id: u32, offset: i32, width: i32, height: i32, stride: i32, format: u32) !void {
        try wire.writeHeader(writer, pool_id, 0, 32);
        try wire.writeUint(writer, buffer_id);
        try wire.writeInt(writer, offset);
        try wire.writeInt(writer, width);
        try wire.writeInt(writer, height);
        try wire.writeInt(writer, stride);
        try wire.writeUint(writer, format);
    }

    pub fn destroy(writer: *std.Io.Writer, pool_id: u32) !void {
        try wire.writeNoArgs(writer, pool_id, 1);
    }
};

pub const buffer = struct {
    pub fn destroy(writer: *std.Io.Writer, buffer_id: u32) !void {
        try wire.writeNoArgs(writer, buffer_id, 0);
    }
};

pub const surface = struct {
    pub fn destroy(writer: *std.Io.Writer, surface_id: u32) !void {
        try wire.writeNoArgs(writer, surface_id, 0);
    }

    /// buffer_id 0 means "no buffer" (detach content).
    pub fn attach(writer: *std.Io.Writer, surface_id: u32, buffer_id: u32, x: i32, y: i32) !void {
        try wire.writeHeader(writer, surface_id, 1, 20);
        try wire.writeUint(writer, buffer_id);
        try wire.writeInt(writer, x);
        try wire.writeInt(writer, y);
    }

    /// Surface-local damage; prefer `damageBuffer` on compositors that
    /// advertise wl_compositor >= 4.
    pub fn damage(writer: *std.Io.Writer, surface_id: u32, x: i32, y: i32, width: i32, height: i32) !void {
        try wire.writeHeader(writer, surface_id, 2, 24);
        try wire.writeInt(writer, x);
        try wire.writeInt(writer, y);
        try wire.writeInt(writer, width);
        try wire.writeInt(writer, height);
    }

    pub fn frame(writer: *std.Io.Writer, surface_id: u32, callback_id: u32) !void {
        try wire.writeHeader(writer, surface_id, 3, 12);
        try wire.writeUint(writer, callback_id);
    }

    pub fn commit(writer: *std.Io.Writer, surface_id: u32) !void {
        try wire.writeNoArgs(writer, surface_id, 6);
    }

    pub fn setBufferScale(writer: *std.Io.Writer, surface_id: u32, scale: i32) !void {
        try wire.writeHeader(writer, surface_id, 8, 12);
        try wire.writeInt(writer, scale);
    }

    /// Buffer-coordinate damage (wl_surface since version 4).
    pub fn damageBuffer(writer: *std.Io.Writer, surface_id: u32, x: i32, y: i32, width: i32, height: i32) !void {
        try wire.writeHeader(writer, surface_id, 9, 24);
        try wire.writeInt(writer, x);
        try wire.writeInt(writer, y);
        try wire.writeInt(writer, width);
        try wire.writeInt(writer, height);
    }
};

pub const seat = struct {
    pub fn getPointer(writer: *std.Io.Writer, seat_id: u32, pointer_id: u32) !void {
        try wire.writeHeader(writer, seat_id, 0, 12);
        try wire.writeUint(writer, pointer_id);
    }

    pub fn getKeyboard(writer: *std.Io.Writer, seat_id: u32, keyboard_id: u32) !void {
        try wire.writeHeader(writer, seat_id, 1, 12);
        try wire.writeUint(writer, keyboard_id);
    }
};

pub const pointer = struct {
    /// surface_id 0 hides the cursor.
    pub fn setCursor(writer: *std.Io.Writer, pointer_id: u32, serial: u32, surface_id: u32, hotspot_x: i32, hotspot_y: i32) !void {
        try wire.writeHeader(writer, pointer_id, 0, 24);
        try wire.writeUint(writer, serial);
        try wire.writeUint(writer, surface_id);
        try wire.writeInt(writer, hotspot_x);
        try wire.writeInt(writer, hotspot_y);
    }
};

test "registry bind marshals the untyped new_id" {
    var buffer_bytes: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer_bytes);
    try registry.bind(&writer, 2, 14, "wl_compositor", 4, 3);

    const header = wire.parseHeader(buffer_bytes[0..8].*);
    try std.testing.expectEqual(@as(u32, 2), header.object_id);
    try std.testing.expectEqual(@as(u16, 0), header.opcode);
    try std.testing.expectEqual(@as(usize, header.size), writer.end);

    var args = wire.ArgReader{ .bytes = buffer_bytes[8..writer.end] };
    try std.testing.expectEqual(@as(u32, 14), try args.uint());
    try std.testing.expectEqualStrings("wl_compositor", try args.string());
    try std.testing.expectEqual(@as(u32, 4), try args.uint());
    try std.testing.expectEqual(@as(u32, 3), try args.uint());
}

test "create_pool message is exactly 16 bytes with trailing size" {
    const bytes = shm.createPoolMessage(5, 9, 1024);
    const header = wire.parseHeader(bytes[0..8].*);
    try std.testing.expectEqual(@as(u32, 5), header.object_id);
    try std.testing.expectEqual(@as(u16, 0), header.opcode);
    try std.testing.expectEqual(@as(u16, 16), header.size);
    try std.testing.expectEqual(@as(u32, 9), std.mem.readInt(u32, bytes[8..12], .little));
    try std.testing.expectEqual(@as(i32, 1024), std.mem.readInt(i32, bytes[12..16], .little));
}
