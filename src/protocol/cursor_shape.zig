//! Request marshallers for cursor-shape-v1: named cursor shapes without any
//! cursor-theme loading. Optional global — degrade to hide-only cursor
//! control when absent.

const std = @import("std");
const wire = @import("wire.zig");

/// wp_cursor_shape_device_v1.shape values (subset used by anywindow).
pub const Shape = enum(u32) {
    default = 1,
    pointer = 4,
    crosshair = 8,
    text = 9,
    move = 13,
    not_allowed = 15,
    ew_resize = 26,
    ns_resize = 27,
};

pub const manager = struct {
    pub fn getPointer(writer: *std.Io.Writer, manager_id: u32, device_id: u32, pointer_id: u32) !void {
        try wire.writeHeader(writer, manager_id, 1, 16);
        try wire.writeUint(writer, device_id);
        try wire.writeUint(writer, pointer_id);
    }
};

pub const device = struct {
    pub fn destroy(writer: *std.Io.Writer, device_id: u32) !void {
        try wire.writeNoArgs(writer, device_id, 0);
    }

    pub fn setShape(writer: *std.Io.Writer, device_id: u32, serial: u32, shape: Shape) !void {
        try wire.writeHeader(writer, device_id, 1, 16);
        try wire.writeUint(writer, serial);
        try wire.writeUint(writer, @intFromEnum(shape));
    }
};
