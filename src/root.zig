//! Pure-Zig Wayland client library. Raw protocol over the Unix socket — no
//! libwayland, no libxkbcommon. Two layers:
//!
//!  - `wire/*`: protocol-neutral transport (socket + SCM_RIGHTS fd passing,
//!    shared memory, object ids) — also the foundation for pipewirez.
//!  - `protocol/*` + `Display`: the Wayland display protocol itself.

comptime {
    if (builtin.os.tag != .linux) @compileError("waylandz only supports Linux");
}

/// Connected client: registry, globals, request writer, event dispatch.
pub const Display = @import("display.zig");

// Wire core — protocol-neutral, shared with pipewirez.
pub const socket = @import("wire/socket.zig");
pub const SharedMemory = @import("wire/shm.zig");
pub const ObjectIds = @import("wire/object.zig");

// Wayland protocol: wire format, request marshallers, event decoding.
pub const wire = @import("protocol/wire.zig");
pub const proto = struct {
    pub const wayland = @import("protocol/wayland.zig");
    pub const xdg_shell = @import("protocol/xdg_shell.zig");
    pub const decoration = @import("protocol/decoration.zig");
    pub const cursor_shape = @import("protocol/cursor_shape.zig");
    pub const viewporter = @import("protocol/viewporter.zig");
    pub const fractional_scale = @import("protocol/fractional_scale.zig");
    pub const pointer_constraints = @import("protocol/pointer_constraints.zig");
    pub const toplevel_icon = @import("protocol/toplevel_icon.zig");
    pub const data_device = @import("protocol/data_device.zig");
    pub const primary_selection = @import("protocol/primary_selection.zig");
};

pub const Interface = @import("protocol/event.zig").Interface;
pub const Event = @import("protocol/event.zig").Event;

// XKB keymap parsing (wl_keyboard.keymap payloads).
pub const xkb = struct {
    pub const Keymap = @import("xkb/keymap.zig");
    pub const keysym = @import("xkb/keysym.zig");
};

test {
    _ = Display;
    _ = socket;
    _ = SharedMemory;
    _ = ObjectIds;
    _ = wire;
    _ = proto.wayland;
    _ = proto.xdg_shell;
    _ = proto.decoration;
    _ = proto.cursor_shape;
    _ = proto.viewporter;
    _ = proto.fractional_scale;
    _ = proto.pointer_constraints;
    _ = proto.toplevel_icon;
    _ = proto.data_device;
    _ = proto.primary_selection;
    _ = @import("protocol/event.zig");
    _ = xkb.Keymap;
    _ = xkb.keysym;
}

const builtin = @import("builtin");
