//! Request marshallers for pointer-constraints-unstable-v1: confine the
//! pointer to a surface (anywindow's grabCursor) or lock it in place.
//! Optional global — grab degrades to a no-op when absent.

const std = @import("std");
const wire = @import("wire.zig");

/// zwp_pointer_constraints_v1.lifetime values.
pub const lifetime_oneshot: u32 = 1;
pub const lifetime_persistent: u32 = 2;

pub const constraints = struct {
    pub fn destroy(writer: *std.Io.Writer, constraints_id: u32) !void {
        try wire.writeNoArgs(writer, constraints_id, 0);
    }

    /// region_id 0 means the surface's whole input region. Only one
    /// constraint may exist per surface+pointer pair, or the compositor
    /// raises already_constrained.
    pub fn lockPointer(writer: *std.Io.Writer, constraints_id: u32, locked_id: u32, surface_id: u32, pointer_id: u32, region_id: u32, lifetime: u32) !void {
        try wire.writeHeader(writer, constraints_id, 1, 28);
        try wire.writeUint(writer, locked_id);
        try wire.writeUint(writer, surface_id);
        try wire.writeUint(writer, pointer_id);
        try wire.writeUint(writer, region_id);
        try wire.writeUint(writer, lifetime);
    }

    /// region_id 0 means the surface's whole input region.
    pub fn confinePointer(writer: *std.Io.Writer, constraints_id: u32, confined_id: u32, surface_id: u32, pointer_id: u32, region_id: u32, lifetime: u32) !void {
        try wire.writeHeader(writer, constraints_id, 2, 28);
        try wire.writeUint(writer, confined_id);
        try wire.writeUint(writer, surface_id);
        try wire.writeUint(writer, pointer_id);
        try wire.writeUint(writer, region_id);
        try wire.writeUint(writer, lifetime);
    }
};

pub const confined_pointer = struct {
    pub fn destroy(writer: *std.Io.Writer, confined_id: u32) !void {
        try wire.writeNoArgs(writer, confined_id, 0);
    }
};

pub const locked_pointer = struct {
    pub fn destroy(writer: *std.Io.Writer, locked_id: u32) !void {
        try wire.writeNoArgs(writer, locked_id, 0);
    }
};

test "confine_pointer marshals all five arguments in order" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try constraints.confinePointer(&writer, 5, 12, 3, 7, 0, lifetime_persistent);

    const header = wire.parseHeader(buffer[0..8].*);
    try std.testing.expectEqual(@as(u32, 5), header.object_id);
    try std.testing.expectEqual(@as(u16, 2), header.opcode);
    try std.testing.expectEqual(@as(usize, header.size), writer.end);

    var args = wire.ArgReader{ .bytes = buffer[8..writer.end] };
    try std.testing.expectEqual(@as(u32, 12), try args.uint());
    try std.testing.expectEqual(@as(u32, 3), try args.uint());
    try std.testing.expectEqual(@as(u32, 7), try args.uint());
    try std.testing.expectEqual(@as(u32, 0), try args.uint());
    try std.testing.expectEqual(lifetime_persistent, try args.uint());
}
