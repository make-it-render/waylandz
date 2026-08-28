//! Anonymous shared memory: a memfd-backed, mmap'd region whose fd can be
//! passed to the compositor (wl_shm.create_pool) or any other peer.

fd: std.posix.fd_t,
data: []align(std.heap.page_size_min) u8,

pub fn init(size: usize) !@This() {
    const fd = try std.posix.memfd_create("mir-wayland-shm", std.posix.MFD.CLOEXEC);
    errdefer _ = linux.close(fd);

    switch (linux.errno(linux.ftruncate(fd, @intCast(size)))) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
    }

    const data = try std.posix.mmap(
        null,
        size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );

    return .{ .fd = fd, .data = data };
}

pub fn deinit(self: *@This()) void {
    std.posix.munmap(self.data);
    _ = linux.close(self.fd);
}

test "init maps a writable region backed by an fd" {
    var shm = try @This().init(4096);
    defer shm.deinit();

    try std.testing.expectEqual(@as(usize, 4096), shm.data.len);
    shm.data[0] = 0xAB;
    shm.data[4095] = 0xCD;
    try std.testing.expectEqual(@as(u8, 0xAB), shm.data[0]);
    try std.testing.expectEqual(@as(u8, 0xCD), shm.data[4095]);
    try std.testing.expect(shm.fd >= 0);
}

const std = @import("std");
const linux = std.os.linux;
