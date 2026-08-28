//! Request marshallers for viewporter (stable): per-surface crop and scale.
//! Paired with fractional-scale-v1 for HiDPI — the buffer is rendered at
//! physical size and the viewport destination maps it to the surface's
//! logical size. Optional global — degrade to set_buffer_scale (integer
//! scales) when absent.

const std = @import("std");
const wire = @import("wire.zig");

pub const manager = struct {
    pub fn destroy(writer: *std.Io.Writer, viewporter_id: u32) !void {
        try wire.writeNoArgs(writer, viewporter_id, 0);
    }

    pub fn getViewport(writer: *std.Io.Writer, viewporter_id: u32, viewport_id: u32, surface_id: u32) !void {
        try wire.writeHeader(writer, viewporter_id, 1, 16);
        try wire.writeUint(writer, viewport_id);
        try wire.writeUint(writer, surface_id);
    }
};

pub const viewport = struct {
    pub fn destroy(writer: *std.Io.Writer, viewport_id: u32) !void {
        try wire.writeNoArgs(writer, viewport_id, 0);
    }

    /// Both -1 unsets the destination. Zero or other negative values are a
    /// protocol error.
    pub fn setDestination(writer: *std.Io.Writer, viewport_id: u32, width: i32, height: i32) !void {
        try wire.writeHeader(writer, viewport_id, 2, 16);
        try wire.writeInt(writer, width);
        try wire.writeInt(writer, height);
    }
};

test "get_viewport marshals manager, viewport, surface" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try manager.getViewport(&writer, 4, 9, 3);

    const header = wire.parseHeader(buffer[0..8].*);
    try std.testing.expectEqual(@as(u32, 4), header.object_id);
    try std.testing.expectEqual(@as(u16, 1), header.opcode);
    try std.testing.expectEqual(@as(usize, header.size), writer.end);

    var args = wire.ArgReader{ .bytes = buffer[8..writer.end] };
    try std.testing.expectEqual(@as(u32, 9), try args.uint());
    try std.testing.expectEqual(@as(u32, 3), try args.uint());
}

test "set_destination marshals signed extents" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try viewport.setDestination(&writer, 9, -1, -1);

    const header = wire.parseHeader(buffer[0..8].*);
    try std.testing.expectEqual(@as(u16, 2), header.opcode);
    var args = wire.ArgReader{ .bytes = buffer[8..writer.end] };
    try std.testing.expectEqual(@as(i32, -1), try args.int());
    try std.testing.expectEqual(@as(i32, -1), try args.int());
}
