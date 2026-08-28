//! Request marshallers for xdg-toplevel-icon-v1 (staging): a per-window icon
//! from wl_shm pixel buffers. Optional global — setIcon degrades to the
//! app_id/.desktop mechanism when absent. The icon buffer must be square
//! ARGB8888; both the icon object and its buffer may be destroyed as soon as
//! set_icon has been sent (the compositor keeps its own copy). set_icon is
//! double-buffered state, applied on the toplevel's next wl_surface.commit.

const std = @import("std");
const wire = @import("wire.zig");

pub const manager = struct {
    pub fn destroy(writer: *std.Io.Writer, manager_id: u32) !void {
        try wire.writeNoArgs(writer, manager_id, 0);
    }

    pub fn createIcon(writer: *std.Io.Writer, manager_id: u32, icon_id: u32) !void {
        try wire.writeHeader(writer, manager_id, 1, 12);
        try wire.writeUint(writer, icon_id);
    }

    /// icon_id 0 clears the toplevel's icon.
    pub fn setIcon(writer: *std.Io.Writer, manager_id: u32, toplevel_id: u32, icon_id: u32) !void {
        try wire.writeHeader(writer, manager_id, 2, 16);
        try wire.writeUint(writer, toplevel_id);
        try wire.writeUint(writer, icon_id);
    }
};

pub const icon = struct {
    pub fn destroy(writer: *std.Io.Writer, icon_id: u32) !void {
        try wire.writeNoArgs(writer, icon_id, 0);
    }

    pub fn setName(writer: *std.Io.Writer, icon_id: u32, name: []const u8) !void {
        const size = wire.header_size + wire.stringSize(name);
        try wire.writeHeader(writer, icon_id, 1, size);
        try wire.writeString(writer, name);
    }

    pub fn addBuffer(writer: *std.Io.Writer, icon_id: u32, buffer_id: u32, scale: i32) !void {
        try wire.writeHeader(writer, icon_id, 2, 16);
        try wire.writeUint(writer, buffer_id);
        try wire.writeInt(writer, scale);
    }
};

test "set_icon marshals toplevel then icon" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try manager.setIcon(&writer, 6, 8, 14);

    const header = wire.parseHeader(buffer[0..8].*);
    try std.testing.expectEqual(@as(u32, 6), header.object_id);
    try std.testing.expectEqual(@as(u16, 2), header.opcode);
    try std.testing.expectEqual(@as(usize, header.size), writer.end);

    var args = wire.ArgReader{ .bytes = buffer[8..writer.end] };
    try std.testing.expectEqual(@as(u32, 8), try args.uint());
    try std.testing.expectEqual(@as(u32, 14), try args.uint());
}

test "add_buffer marshals buffer then scale" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try icon.addBuffer(&writer, 14, 20, 1);

    const header = wire.parseHeader(buffer[0..8].*);
    try std.testing.expectEqual(@as(u16, 2), header.opcode);
    var args = wire.ArgReader{ .bytes = buffer[8..writer.end] };
    try std.testing.expectEqual(@as(u32, 20), try args.uint());
    try std.testing.expectEqual(@as(i32, 1), try args.int());
}
