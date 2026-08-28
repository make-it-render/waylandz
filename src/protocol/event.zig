//! Incoming-event decoding: the Interface tag every live object id maps to,
//! the Event union receive() produces, and the (interface, opcode) -> Event
//! parser. Events we will never act on parse to null and are skipped.

const std = @import("std");
const wire = @import("wire.zig");
const wayland = @import("wayland.zig");

const log = std.log.scoped(.wayland);

/// What kind of object an id refers to; drives event dispatch.
pub const Interface = enum {
    display,
    registry,
    callback,
    compositor,
    surface,
    region,
    shm,
    shm_pool,
    buffer,
    seat,
    pointer,
    keyboard,
    output,
    wm_base,
    xdg_surface,
    toplevel,
    decoration_manager,
    toplevel_decoration,
    cursor_shape_manager,
    cursor_shape_device,
    viewporter,
    viewport,
    fractional_scale_manager,
    fractional_scale,
    pointer_constraints,
    confined_pointer,
    locked_pointer,
    icon_manager,
    icon,
};

/// One decoded server event. String slices borrow the connection's read
/// buffer and are only valid until the next receive.
pub const Event = union(enum) {
    display_error: struct { object_id: u32, code: u32, message: []const u8 },
    delete_id: u32,
    registry_global: struct { name: u32, interface: []const u8, version: u32 },
    registry_global_remove: u32,
    callback_done: struct { callback_id: u32, data: u32 },
    shm_format: u32,
    buffer_release: u32,
    seat_capabilities: struct { seat_id: u32, capabilities: u32 },
    pointer_enter: struct { serial: u32, surface: u32, x: wire.Fixed, y: wire.Fixed },
    pointer_leave: struct { serial: u32, surface: u32 },
    pointer_motion: struct { time: u32, x: wire.Fixed, y: wire.Fixed },
    pointer_button: struct { serial: u32, time: u32, button: u32, state: u32 },
    pointer_axis: struct { time: u32, axis: u32, value: wire.Fixed },
    pointer_frame: void,
    /// The fd is not in the byte stream — Display.receive attaches the
    /// SCM_RIGHTS descriptor that rode along. The receiver owns it.
    keyboard_keymap: struct { format: u32, size: u32, fd: std.posix.fd_t = -1 },
    keyboard_enter: struct { serial: u32, surface: u32 },
    keyboard_leave: struct { serial: u32, surface: u32 },
    keyboard_key: struct { serial: u32, time: u32, key: u32, state: u32 },
    keyboard_modifiers: struct { depressed: u32, latched: u32, locked: u32, group: u32 },
    surface_enter: struct { surface: u32, output: u32 },
    surface_preferred_buffer_scale: struct { surface: u32, factor: i32 },
    fractional_scale_preferred: struct { fractional_scale: u32, scale120: u32 },
    output_scale: struct { output: u32, factor: i32 },
    wm_base_ping: u32,
    xdg_surface_configure: struct { xdg_surface: u32, serial: u32 },
    toplevel_configure: struct {
        toplevel: u32,
        width: i32,
        height: i32,
        maximized: bool,
        fullscreen: bool,
        activated: bool,
    },
    toplevel_close: u32,
    decoration_configure: struct { decoration: u32, mode: u32 },
};

/// Decode one message body. Returns null for events that carry nothing we
/// act on (they are parsed or skipped wholesale, never misinterpreted).
pub fn parse(interface: Interface, opcode: u16, object_id: u32, body: []const u8) !?Event {
    var args = wire.ArgReader{ .bytes = body };
    switch (interface) {
        .display => switch (opcode) {
            0 => return .{ .display_error = .{
                .object_id = try args.uint(),
                .code = try args.uint(),
                .message = try args.string(),
            } },
            1 => return .{ .delete_id = try args.uint() },
            else => {},
        },
        .registry => switch (opcode) {
            0 => return .{ .registry_global = .{
                .name = try args.uint(),
                .interface = try args.string(),
                .version = try args.uint(),
            } },
            1 => return .{ .registry_global_remove = try args.uint() },
            else => {},
        },
        .callback => switch (opcode) {
            0 => return .{ .callback_done = .{ .callback_id = object_id, .data = try args.uint() } },
            else => {},
        },
        .shm => switch (opcode) {
            0 => return .{ .shm_format = try args.uint() },
            else => {},
        },
        .buffer => switch (opcode) {
            0 => return .{ .buffer_release = object_id },
            else => {},
        },
        .surface => switch (opcode) {
            0 => return .{ .surface_enter = .{ .surface = object_id, .output = try args.uint() } },
            2 => return .{ .surface_preferred_buffer_scale = .{ .surface = object_id, .factor = try args.int() } },
            else => {}, // leave, preferred_buffer_transform
        },
        .seat => switch (opcode) {
            0 => return .{ .seat_capabilities = .{ .seat_id = object_id, .capabilities = try args.uint() } },
            else => {}, // name
        },
        .pointer => switch (opcode) {
            0 => return .{ .pointer_enter = .{
                .serial = try args.uint(),
                .surface = try args.uint(),
                .x = try args.fixed(),
                .y = try args.fixed(),
            } },
            1 => return .{ .pointer_leave = .{ .serial = try args.uint(), .surface = try args.uint() } },
            2 => return .{ .pointer_motion = .{
                .time = try args.uint(),
                .x = try args.fixed(),
                .y = try args.fixed(),
            } },
            3 => return .{ .pointer_button = .{
                .serial = try args.uint(),
                .time = try args.uint(),
                .button = try args.uint(),
                .state = try args.uint(),
            } },
            4 => return .{ .pointer_axis = .{
                .time = try args.uint(),
                .axis = try args.uint(),
                .value = try args.fixed(),
            } },
            5 => return .{ .pointer_frame = {} },
            else => {}, // axis_source/stop/discrete/value120/... — v1 uses plain axis
        },
        .keyboard => switch (opcode) {
            0 => return .{ .keyboard_keymap = .{ .format = try args.uint(), .size = try args.uint() } },
            1 => {
                const serial = try args.uint();
                const surface = try args.uint();
                return .{ .keyboard_enter = .{ .serial = serial, .surface = surface } };
            },
            2 => return .{ .keyboard_leave = .{ .serial = try args.uint(), .surface = try args.uint() } },
            3 => return .{ .keyboard_key = .{
                .serial = try args.uint(),
                .time = try args.uint(),
                .key = try args.uint(),
                .state = try args.uint(),
            } },
            4 => {
                _ = try args.uint(); // serial
                return .{ .keyboard_modifiers = .{
                    .depressed = try args.uint(),
                    .latched = try args.uint(),
                    .locked = try args.uint(),
                    .group = try args.uint(),
                } };
            },
            else => {}, // repeat_info
        },
        .output => switch (opcode) {
            3 => return .{ .output_scale = .{ .output = object_id, .factor = try args.int() } },
            else => {}, // geometry/mode/done/name/description
        },
        .wm_base => switch (opcode) {
            0 => return .{ .wm_base_ping = try args.uint() },
            else => {},
        },
        .xdg_surface => switch (opcode) {
            0 => return .{ .xdg_surface_configure = .{ .xdg_surface = object_id, .serial = try args.uint() } },
            else => {},
        },
        .toplevel => switch (opcode) {
            0 => {
                const width = try args.int();
                const height = try args.int();
                const states = try args.array();
                var maximized = false;
                var fullscreen = false;
                var activated = false;
                var i: usize = 0;
                while (i + 4 <= states.len) : (i += 4) {
                    switch (std.mem.readInt(u32, states[i..][0..4], .little)) {
                        1 => maximized = true,
                        2 => fullscreen = true,
                        4 => activated = true,
                        else => {},
                    }
                }
                return .{ .toplevel_configure = .{
                    .toplevel = object_id,
                    .width = width,
                    .height = height,
                    .maximized = maximized,
                    .fullscreen = fullscreen,
                    .activated = activated,
                } };
            },
            1 => return .{ .toplevel_close = object_id },
            else => {}, // configure_bounds, wm_capabilities
        },
        .toplevel_decoration => switch (opcode) {
            0 => return .{ .decoration_configure = .{ .decoration = object_id, .mode = try args.uint() } },
            else => {},
        },
        .fractional_scale => switch (opcode) {
            0 => return .{ .fractional_scale_preferred = .{ .fractional_scale = object_id, .scale120 = try args.uint() } },
            else => {},
        },
        // Interfaces with no events (or none we act on: the pointer stays
        // usable whether or not a constraint is active, and icon_size/done
        // are advisory).
        .compositor,
        .region,
        .shm_pool,
        .decoration_manager,
        .cursor_shape_manager,
        .cursor_shape_device,
        .viewporter,
        .viewport,
        .fractional_scale_manager,
        .pointer_constraints,
        .confined_pointer,
        .locked_pointer,
        .icon_manager,
        .icon,
        => {},
    }
    log.debug("Skipping event: {s} opcode {d}", .{ @tagName(interface), opcode });
    return null;
}

test "parses toplevel configure states array" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try wire.writeInt(&writer, 800);
    try wire.writeInt(&writer, 600);
    try wire.writeUint(&writer, 8); // states array: fullscreen + activated
    try wire.writeUint(&writer, 2);
    try wire.writeUint(&writer, 4);

    const event = (try parse(.toplevel, 0, 7, buffer[0..writer.end])).?;
    const configure = event.toplevel_configure;
    try std.testing.expectEqual(@as(i32, 800), configure.width);
    try std.testing.expectEqual(@as(i32, 600), configure.height);
    try std.testing.expect(configure.fullscreen);
    try std.testing.expect(configure.activated);
    try std.testing.expect(!configure.maximized);
    try std.testing.expectEqual(@as(u32, 7), configure.toplevel);
}

test "parses registry global" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try wire.writeUint(&writer, 12);
    try wire.writeString(&writer, "wl_compositor");
    try wire.writeUint(&writer, 6);

    const event = (try parse(.registry, 0, 2, buffer[0..writer.end])).?;
    try std.testing.expectEqual(@as(u32, 12), event.registry_global.name);
    try std.testing.expectEqualStrings("wl_compositor", event.registry_global.interface);
    try std.testing.expectEqual(@as(u32, 6), event.registry_global.version);
}

test "unknown opcodes are skipped, not errors" {
    try std.testing.expectEqual(@as(?Event, null), try parse(.surface, 1, 3, &[4]u8{ 0, 0, 0, 0 }));
    try std.testing.expectEqual(@as(?Event, null), try parse(.pointer, 9, 4, &[8]u8{ 0, 0, 0, 0, 1, 0, 0, 0 }));
}

test "parses surface enter and preferred_buffer_scale" {
    var buffer: [8]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try wire.writeUint(&writer, 21); // output id

    const enter = (try parse(.surface, 0, 3, buffer[0..writer.end])).?;
    try std.testing.expectEqual(@as(u32, 3), enter.surface_enter.surface);
    try std.testing.expectEqual(@as(u32, 21), enter.surface_enter.output);

    var writer2 = std.Io.Writer.fixed(&buffer);
    try wire.writeInt(&writer2, 2);
    const preferred = (try parse(.surface, 2, 3, buffer[0..writer2.end])).?;
    try std.testing.expectEqual(@as(i32, 2), preferred.surface_preferred_buffer_scale.factor);
}

test "parses fractional preferred_scale as 120ths" {
    var buffer: [8]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try wire.writeUint(&writer, 180); // 1.5x

    const event = (try parse(.fractional_scale, 0, 11, buffer[0..writer.end])).?;
    try std.testing.expectEqual(@as(u32, 11), event.fractional_scale_preferred.fractional_scale);
    try std.testing.expectEqual(@as(u32, 180), event.fractional_scale_preferred.scale120);
}
