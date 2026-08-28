//! Request marshallers for xdg-shell (stable): window roles, configure
//! handshake, and toplevel state.

const std = @import("std");
const wire = @import("wire.zig");

/// xdg_toplevel.state values found in configure's states array.
pub const state_maximized: u32 = 1;
pub const state_fullscreen: u32 = 2;
pub const state_resizing: u32 = 3;
pub const state_activated: u32 = 4;

pub const wm_base = struct {
    pub fn destroy(writer: *std.Io.Writer, wm_base_id: u32) !void {
        try wire.writeNoArgs(writer, wm_base_id, 0);
    }

    pub fn getXdgSurface(writer: *std.Io.Writer, wm_base_id: u32, xdg_surface_id: u32, surface_id: u32) !void {
        try wire.writeHeader(writer, wm_base_id, 2, 16);
        try wire.writeUint(writer, xdg_surface_id);
        try wire.writeUint(writer, surface_id);
    }

    /// Mandatory liveness reply to xdg_wm_base.ping — miss it and the
    /// compositor may deem the client unresponsive.
    pub fn pong(writer: *std.Io.Writer, wm_base_id: u32, serial: u32) !void {
        try wire.writeHeader(writer, wm_base_id, 3, 12);
        try wire.writeUint(writer, serial);
    }
};

pub const xdg_surface = struct {
    pub fn destroy(writer: *std.Io.Writer, xdg_surface_id: u32) !void {
        try wire.writeNoArgs(writer, xdg_surface_id, 0);
    }

    pub fn getToplevel(writer: *std.Io.Writer, xdg_surface_id: u32, toplevel_id: u32) !void {
        try wire.writeHeader(writer, xdg_surface_id, 1, 12);
        try wire.writeUint(writer, toplevel_id);
    }

    /// Every xdg_surface.configure must be acked before the next commit.
    pub fn ackConfigure(writer: *std.Io.Writer, xdg_surface_id: u32, serial: u32) !void {
        try wire.writeHeader(writer, xdg_surface_id, 4, 12);
        try wire.writeUint(writer, serial);
    }
};

pub const toplevel = struct {
    pub fn destroy(writer: *std.Io.Writer, toplevel_id: u32) !void {
        try wire.writeNoArgs(writer, toplevel_id, 0);
    }

    pub fn setTitle(writer: *std.Io.Writer, toplevel_id: u32, title: []const u8) !void {
        try wire.writeHeader(writer, toplevel_id, 2, wire.header_size + wire.stringSize(title));
        try wire.writeString(writer, title);
    }

    pub fn setAppId(writer: *std.Io.Writer, toplevel_id: u32, app_id: []const u8) !void {
        try wire.writeHeader(writer, toplevel_id, 3, wire.header_size + wire.stringSize(app_id));
        try wire.writeString(writer, app_id);
    }

    /// output_id 0 lets the compositor pick the output.
    pub fn setFullscreen(writer: *std.Io.Writer, toplevel_id: u32, output_id: u32) !void {
        try wire.writeHeader(writer, toplevel_id, 11, 12);
        try wire.writeUint(writer, output_id);
    }

    pub fn unsetFullscreen(writer: *std.Io.Writer, toplevel_id: u32) !void {
        try wire.writeNoArgs(writer, toplevel_id, 12);
    }
};
