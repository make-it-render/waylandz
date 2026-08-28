//! Request marshallers for fractional-scale-v1 (staging): the compositor
//! tells each surface its preferred fractional scale as a numerator over 120
//! (wp_fractional_scale_v1.preferred_scale, decoded in event.zig). Only
//! useful together with viewporter — a fractional buffer scale cannot be
//! expressed with wl_surface.set_buffer_scale.

const std = @import("std");
const wire = @import("wire.zig");

/// The protocol's fixed denominator: a preferred_scale of 120 means 1.0.
pub const denominator: u32 = 120;

pub const manager = struct {
    pub fn destroy(writer: *std.Io.Writer, manager_id: u32) !void {
        try wire.writeNoArgs(writer, manager_id, 0);
    }

    pub fn getFractionalScale(writer: *std.Io.Writer, manager_id: u32, fractional_scale_id: u32, surface_id: u32) !void {
        try wire.writeHeader(writer, manager_id, 1, 16);
        try wire.writeUint(writer, fractional_scale_id);
        try wire.writeUint(writer, surface_id);
    }
};

pub const fractional_scale = struct {
    pub fn destroy(writer: *std.Io.Writer, fractional_scale_id: u32) !void {
        try wire.writeNoArgs(writer, fractional_scale_id, 0);
    }
};

test "get_fractional_scale marshals manager, extension, surface" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try manager.getFractionalScale(&writer, 6, 11, 3);

    const header = wire.parseHeader(buffer[0..8].*);
    try std.testing.expectEqual(@as(u32, 6), header.object_id);
    try std.testing.expectEqual(@as(u16, 1), header.opcode);
    try std.testing.expectEqual(@as(usize, header.size), writer.end);

    var args = wire.ArgReader{ .bytes = buffer[8..writer.end] };
    try std.testing.expectEqual(@as(u32, 11), try args.uint());
    try std.testing.expectEqual(@as(u32, 3), try args.uint());
}
