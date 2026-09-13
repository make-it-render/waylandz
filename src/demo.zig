//! Standalone demo: list the compositor's globals, open a decorated
//! xdg-toplevel window filled with a gradient, print input events, resize
//! with the window, and exit on close (or Escape). F toggles fullscreen.

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const environ = init.minimal.environ;

    var display = try wayland.Display.init(io, environ, allocator);
    defer display.deinit();
    try display.discoverGlobals(io);

    for (display.globals.items) |global| {
        log.info("global: {s} v{d}", .{ global.interface, global.version });
    }

    // Required globals.
    const compositor = try display.bind(display.findGlobal("wl_compositor") orelse return error.NoCompositor, .compositor, 4);
    const shm = try display.bind(display.findGlobal("wl_shm") orelse return error.NoShm, .shm, 1);
    const wm_base = try display.bind(display.findGlobal("xdg_wm_base") orelse return error.NoXdgWmBase, .wm_base, 1);

    // Optional globals — degrade gracefully.
    const seat: u32 = if (display.findGlobal("wl_seat")) |global| try display.bind(global, .seat, 5) else 0;
    const decoration_manager: u32 = if (display.findGlobal("zxdg_decoration_manager_v1")) |global| try display.bind(global, .decoration_manager, 1) else 0;

    // Surface -> xdg_surface -> toplevel, then the initial (buffer-less) commit.
    const surface = try display.newId(.surface);
    const xdg_surface = try display.newId(.xdg_surface);
    const toplevel = try display.newId(.toplevel);
    {
        const writer = display.acquire();
        defer display.release();
        try proto.wayland.compositor.createSurface(writer, compositor, surface);
        try proto.xdg_shell.wm_base.getXdgSurface(writer, wm_base, xdg_surface, surface);
        try proto.xdg_shell.xdg_surface.getToplevel(writer, xdg_surface, toplevel);
        try proto.xdg_shell.toplevel.setTitle(writer, toplevel, "waylandz demo");
        try proto.xdg_shell.toplevel.setAppId(writer, toplevel, "waylandz-demo");
    }
    if (decoration_manager != 0) {
        const decoration = try display.newId(.toplevel_decoration);
        const writer = display.acquire();
        defer display.release();
        try proto.decoration.manager.getToplevelDecoration(writer, decoration_manager, decoration, toplevel);
        try proto.decoration.toplevel_decoration.setMode(writer, decoration, proto.decoration.mode_server_side);
    }
    {
        const writer = display.acquire();
        defer display.release();
        try proto.wayland.surface.commit(writer, surface);
    }
    try display.flush();

    var width: u16 = 640;
    var height: u16 = 480;
    var framebuffer: ?Framebuffer = null;
    defer if (framebuffer) |*fb| fb.deinit(&display);

    var pointer_bound = false;
    var fullscreen = false;
    var running = true;
    while (running) {
        const event = try display.receive(io) orelse continue;
        switch (event) {
            .wm_base_ping => |serial| {
                {
                    const writer = display.acquire();
                    defer display.release();
                    try proto.xdg_shell.wm_base.pong(writer, wm_base, serial);
                }
                try display.flush();
            },
            .seat_capabilities => |capabilities| {
                if (!pointer_bound and capabilities.capabilities & proto.wayland.seat_capability_pointer != 0) {
                    pointer_bound = true;
                    const pointer = try display.newId(.pointer);
                    const keyboard = try display.newId(.keyboard);
                    const writer = display.acquire();
                    defer display.release();
                    try proto.wayland.seat.getPointer(writer, seat, pointer);
                    if (capabilities.capabilities & proto.wayland.seat_capability_keyboard != 0) {
                        try proto.wayland.seat.getKeyboard(writer, seat, keyboard);
                    }
                }
            },
            .toplevel_configure => |configure| {
                if (configure.width > 0 and configure.height > 0) {
                    width = @intCast(configure.width);
                    height = @intCast(configure.height);
                }
                fullscreen = configure.fullscreen;
            },
            .xdg_surface_configure => |configure| {
                {
                    const writer = display.acquire();
                    defer display.release();
                    try proto.xdg_shell.xdg_surface.ackConfigure(writer, configure.xdg_surface, configure.serial);
                }
                // (Re)allocate on size change or while the compositor still
                // owns the previous buffer, then present a fresh gradient.
                if (framebuffer) |*fb| {
                    if (fb.width != width or fb.height != height or fb.busy) {
                        fb.deinit(&display);
                        framebuffer = null;
                    }
                }
                if (framebuffer == null) {
                    framebuffer = try Framebuffer.init(&display, shm, width, height);
                }
                const fb = &framebuffer.?;
                fb.drawGradient();
                fb.busy = true;
                {
                    const writer = display.acquire();
                    defer display.release();
                    try proto.wayland.surface.attach(writer, surface, fb.buffer, 0, 0);
                    try proto.wayland.surface.damageBuffer(writer, surface, 0, 0, width, height);
                    try proto.wayland.surface.commit(writer, surface);
                }
                try display.flush();
                log.info("presented {d}x{d}", .{ width, height });
            },
            .buffer_release => |buffer_id| {
                if (framebuffer) |*fb| {
                    if (fb.buffer == buffer_id) fb.busy = false;
                }
            },
            .toplevel_close => running = false,
            .pointer_motion => |motion| {
                log.info("pointer: {d},{d}", .{ wayland.wire.fixedToInt(motion.x), wayland.wire.fixedToInt(motion.y) });
            },
            .pointer_button => |button| {
                log.info("button {x}: {s}", .{ button.button, if (button.state == proto.wayland.state_pressed) "pressed" else "released" });
            },
            .pointer_axis => |axis| {
                log.info("scroll axis {d}: {d:.2}", .{ axis.axis, wayland.wire.fixedToFloat(axis.value) });
            },
            .keyboard_key => |key| {
                log.info("key {d}: {s}", .{ key.key, if (key.state == proto.wayland.state_pressed) "pressed" else "released" });
                if (key.state != proto.wayland.state_pressed) continue;
                switch (key.key) {
                    1 => running = false, // Escape (evdev)
                    33 => { // F (evdev): toggle fullscreen
                        {
                            const writer = display.acquire();
                            defer display.release();
                            if (fullscreen) {
                                try proto.xdg_shell.toplevel.unsetFullscreen(writer, toplevel);
                            } else {
                                try proto.xdg_shell.toplevel.setFullscreen(writer, toplevel, 0);
                            }
                        }
                        try display.flush();
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
}

/// One shm-backed wl_buffer sized to the current window.
const Framebuffer = struct {
    shm: wayland.SharedMemory,
    pool: u32,
    buffer: u32,
    width: u16,
    height: u16,
    busy: bool = false,

    fn init(display: *wayland.Display, shm_id: u32, width: u16, height: u16) !Framebuffer {
        const stride: i32 = @as(i32, width) * 4;
        const size: usize = @as(usize, width) * height * 4;

        var shm = try wayland.SharedMemory.init(size);
        errdefer shm.deinit();

        const pool = try display.newId(.shm_pool);
        const create_pool = proto.wayland.shm.createPoolMessage(shm_id, pool, @intCast(size));
        try display.sendWithFd(&create_pool, shm.fd);

        const buffer = try display.newId(.buffer);
        {
            const writer = display.acquire();
            defer display.release();
            try proto.wayland.shm_pool.createBuffer(writer, pool, buffer, 0, width, height, stride, proto.wayland.format_xrgb8888);
        }

        return .{ .shm = shm, .pool = pool, .buffer = buffer, .width = width, .height = height };
    }

    fn deinit(self: *Framebuffer, display: *wayland.Display) void {
        {
            const writer = display.acquire();
            defer display.release();
            proto.wayland.buffer.destroy(writer, self.buffer) catch {};
            proto.wayland.shm_pool.destroy(writer, self.pool) catch {};
        }
        self.shm.deinit();
    }

    /// XRGB8888 little-endian: bytes are B,G,R,X.
    fn drawGradient(self: *Framebuffer) void {
        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            const green: u8 = @intCast(y * 255 / self.height);
            var x: usize = 0;
            while (x < self.width) : (x += 1) {
                const pixel = self.shm.data[(y * self.width + x) * 4 ..][0..4];
                pixel[0] = @intCast(x * 255 / self.width);
                pixel[1] = green;
                pixel[2] = 128;
                pixel[3] = 0;
            }
        }
    }
};

const std = @import("std");
const wayland = @import("wayland");
const proto = wayland.proto;

const log = std.log.scoped(.demo);
