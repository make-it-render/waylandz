//! Client-side object-id allocation. Wayland object ids are integers: id 1 is
//! wl_display, the client allocates 2 .. 0xfeffffff, and the server owns ids
//! above that. Freed ids are recycled only after the server acknowledges the
//! destruction with wl_display.delete_id.

next: u32 = first_client_id,
free_list: std.ArrayList(u32) = .empty,

/// wl_display is implicitly bound to id 1 on every connection.
pub const display_id: u32 = 1;

const first_client_id: u32 = 2;
const max_client_id: u32 = 0xfeff_ffff;

pub fn alloc(self: *@This()) !u32 {
    if (self.free_list.pop()) |id| return id;
    if (self.next > max_client_id) return error.OutOfObjectIds;
    const id = self.next;
    self.next += 1;
    return id;
}

/// Recycle an id. Call only when the server sends wl_display.delete_id —
/// recycling earlier can collide with in-flight events for the old object.
pub fn free(self: *@This(), allocator: std.mem.Allocator, id: u32) void {
    // Best-effort: if the append fails the id is simply never reused.
    self.free_list.append(allocator, id) catch {};
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    self.free_list.deinit(allocator);
}

test "allocates sequentially from 2" {
    var ids: @This() = .{};
    defer ids.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 2), try ids.alloc());
    try testing.expectEqual(@as(u32, 3), try ids.alloc());
    try testing.expectEqual(@as(u32, 4), try ids.alloc());
}

test "freed ids are recycled" {
    var ids: @This() = .{};
    defer ids.deinit(testing.allocator);

    const a = try ids.alloc();
    const b = try ids.alloc();
    ids.free(testing.allocator, a);
    try testing.expectEqual(a, try ids.alloc());
    try testing.expectEqual(b + 1, try ids.alloc());
}

const std = @import("std");
const testing = std.testing;
