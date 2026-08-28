//! Request marshallers for xdg-decoration-unstable-v1: server-side window
//! decorations. Optional global — degrade to an undecorated window when the
//! compositor doesn't advertise it.

const std = @import("std");
const wire = @import("wire.zig");

/// zxdg_toplevel_decoration_v1.mode values.
pub const mode_client_side: u32 = 1;
pub const mode_server_side: u32 = 2;

pub const manager = struct {
    pub fn getToplevelDecoration(writer: *std.Io.Writer, manager_id: u32, decoration_id: u32, toplevel_id: u32) !void {
        try wire.writeHeader(writer, manager_id, 1, 16);
        try wire.writeUint(writer, decoration_id);
        try wire.writeUint(writer, toplevel_id);
    }
};

pub const toplevel_decoration = struct {
    pub fn destroy(writer: *std.Io.Writer, decoration_id: u32) !void {
        try wire.writeNoArgs(writer, decoration_id, 0);
    }

    pub fn setMode(writer: *std.Io.Writer, decoration_id: u32, mode: u32) !void {
        try wire.writeHeader(writer, decoration_id, 1, 12);
        try wire.writeUint(writer, mode);
    }
};
