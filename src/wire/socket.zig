//! Unix-socket transport: connect to the Wayland display socket and send
//! messages with SCM_RIGHTS file-descriptor passing. Protocol-neutral — this
//! layer moves bytes and fds, nothing else (also intended for pipewirez).

const std = @import("std");

const log = std.log.scoped(.wayland);

/// Connect to the Wayland display socket.
/// $WAYLAND_DISPLAY names the socket (default "wayland-0"). An absolute path
/// is used as-is; otherwise the socket lives in $XDG_RUNTIME_DIR.
pub fn connect(io: std.Io, environ: std.process.Environ) !std.Io.net.Stream {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const display = environ.getPosix("WAYLAND_DISPLAY") orelse "wayland-0";
    const runtime_dir = environ.getPosix("XDG_RUNTIME_DIR");
    const path = try socketPath(display, runtime_dir, &buffer);

    log.debug("Socket path: {s}", .{path});

    const unix_addr = try std.Io.net.UnixAddress.init(path);
    const stream = try unix_addr.connect(io);

    log.debug("Connected", .{});

    return stream;
}

/// Resolve the socket path from $WAYLAND_DISPLAY / $XDG_RUNTIME_DIR values.
fn socketPath(display: []const u8, runtime_dir: ?[]const u8, buffer: []u8) ![]const u8 {
    if (display.len == 0) return error.InvalidWaylandDisplay;

    if (display[0] == '/') {
        if (display.len > buffer.len) return error.SocketPathTooLong;
        @memcpy(buffer[0..display.len], display);
        return buffer[0..display.len];
    }

    const dir = runtime_dir orelse return error.NoXdgRuntimeDir;
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ dir, display }) catch return error.SocketPathTooLong;
}

/// Send `bytes` with `fd` attached as SCM_RIGHTS ancillary data.
/// The ancillary payload rides on the first byte; if the kernel accepts a
/// short write, the remainder is sent as plain data. The caller must ensure
/// any buffered writer for the same socket is flushed first, so message
/// ordering on the wire is preserved.
pub fn sendWithFd(handle: std.posix.socket_t, bytes: []const u8, fd: std.posix.fd_t) !void {
    // Single-fd SCM_RIGHTS control message: cmsghdr followed by the fd,
    // padded out to the platform's cmsg alignment.
    const Control = extern struct {
        header: linux.cmsghdr,
        fd: std.posix.fd_t,
        padding: i32 = 0,
    };
    const control = Control{
        .header = .{
            .len = @offsetOf(Control, "fd") + @sizeOf(std.posix.fd_t),
            .level = std.posix.SOL.SOCKET,
            .type = std.posix.SCM.RIGHTS,
        },
        .fd = fd,
    };

    const iov = [1]std.posix.iovec_const{.{ .base = bytes.ptr, .len = bytes.len }};
    const msg = linux.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &control,
        .controllen = @sizeOf(Control),
        .flags = 0,
    };

    var sent: usize = 0;
    while (true) {
        const rc = linux.sendmsg(handle, &msg, linux.MSG.NOSIGNAL);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                sent = rc;
                break;
            },
            .INTR => continue,
            .AGAIN => {
                try waitWritable(handle);
                continue;
            },
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }

    // The fd was delivered with the first byte; finish any remainder plainly.
    while (sent < bytes.len) {
        sent += try sendPlain(handle, bytes[sent..]);
    }
}

fn sendPlain(handle: std.posix.socket_t, bytes: []const u8) !usize {
    while (true) {
        const rc = linux.write(handle, bytes.ptr, bytes.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            .AGAIN => {
                try waitWritable(handle);
                continue;
            },
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

fn waitWritable(handle: std.posix.socket_t) !void {
    var fds = [1]std.posix.pollfd{.{ .fd = handle, .events = std.posix.POLL.OUT, .revents = 0 }};
    _ = try std.posix.poll(&fds, -1);
}

test "socketPath: relative display joins runtime dir" {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try socketPath("wayland-0", "/run/user/1000", &buffer);
    try std.testing.expectEqualStrings("/run/user/1000/wayland-0", path);
}

test "socketPath: absolute display used as-is" {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try socketPath("/tmp/custom-socket", "/run/user/1000", &buffer);
    try std.testing.expectEqualStrings("/tmp/custom-socket", path);
}

test "socketPath: relative display without runtime dir fails" {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try std.testing.expectError(error.NoXdgRuntimeDir, socketPath("wayland-0", null, &buffer));
}

test "sendWithFd passes a file descriptor over a socketpair" {
    // Create a socketpair, send one end a byte + a memfd, receive it back and
    // verify the fd still works. Pure kernel plumbing — no compositor needed.
    var pair: [2]i32 = undefined;
    switch (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &pair))) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    defer _ = linux.close(pair[0]);
    defer _ = linux.close(pair[1]);

    const memfd = try std.posix.memfd_create("waylandz-test", std.posix.MFD.CLOEXEC);
    defer _ = linux.close(memfd);

    try sendWithFd(pair[0], "hello", memfd);

    var data_buffer: [16]u8 = undefined;
    var control_buffer: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    var iov = [1]std.posix.iovec{.{ .base = &data_buffer, .len = data_buffer.len }};
    var msg = linux.msghdr{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &control_buffer,
        .controllen = control_buffer.len,
        .flags = 0,
    };
    const rc = linux.recvmsg(pair[1], &msg, 0);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => return error.UnexpectedRecvError,
    }
    try std.testing.expectEqualStrings("hello", data_buffer[0..rc]);

    const header: *const linux.cmsghdr = @ptrCast(@alignCast(&control_buffer));
    try std.testing.expectEqual(std.posix.SOL.SOCKET, header.level);
    try std.testing.expectEqual(std.posix.SCM.RIGHTS, header.type);
    const received_fd: *align(1) const i32 = @ptrCast(control_buffer[@sizeOf(linux.cmsghdr)..][0..4]);
    try std.testing.expect(received_fd.* >= 0);
    _ = linux.close(received_fd.*);
}

const linux = std.os.linux;
