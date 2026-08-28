//! Wayland wire format: every message is an 8-byte header (object id, then
//! size<<16 | opcode) followed by 32-bit-aligned arguments, all little-endian.
//! File descriptors are never in the byte stream — they travel as SCM_RIGHTS
//! ancillary data (see wire/socket.zig).

const std = @import("std");

pub const header_size = 8;

/// Wayland caps messages at 4096 bytes including the header.
pub const max_message_size = 4096;

/// 24.8 signed fixed-point, used for pointer coordinates and scroll values.
pub const Fixed = i32;

pub fn fixedToInt(value: Fixed) i32 {
    return value >> 8;
}

pub fn fixedToFloat(value: Fixed) f32 {
    return @as(f32, @floatFromInt(value)) / 256.0;
}

pub const Header = struct {
    object_id: u32,
    opcode: u16,
    size: u16,
};

pub fn parseHeader(bytes: [header_size]u8) Header {
    const word = std.mem.readInt(u32, bytes[4..8], .little);
    return .{
        .object_id = std.mem.readInt(u32, bytes[0..4], .little),
        .opcode = @truncate(word),
        .size = @truncate(word >> 16),
    };
}

pub fn writeHeader(writer: *std.Io.Writer, object_id: u32, opcode: u16, size: u16) !void {
    try writer.writeInt(u32, object_id, .little);
    try writer.writeInt(u32, (@as(u32, size) << 16) | opcode, .little);
}

/// A request that is just a header — destroy, commit, and friends.
pub fn writeNoArgs(writer: *std.Io.Writer, object_id: u32, opcode: u16) !void {
    try writeHeader(writer, object_id, opcode, header_size);
}

pub fn writeUint(writer: *std.Io.Writer, value: u32) !void {
    try writer.writeInt(u32, value, .little);
}

pub fn writeInt(writer: *std.Io.Writer, value: i32) !void {
    try writer.writeInt(i32, value, .little);
}

/// Strings are a u32 length (including the terminating NUL), the bytes, a
/// NUL, then padding to 32-bit alignment.
pub fn writeString(writer: *std.Io.Writer, value: []const u8) !void {
    const len: u32 = @intCast(value.len + 1);
    try writer.writeInt(u32, len, .little);
    try writer.writeAll(value);
    const padding = [4]u8{ 0, 0, 0, 0 };
    try writer.writeAll(padding[0 .. alignUp4(len) - value.len]);
}

/// On-wire size of a string argument, for request size computation.
pub fn stringSize(value: []const u8) u16 {
    return @intCast(4 + alignUp4(value.len + 1));
}

fn alignUp4(len: usize) usize {
    return (len + 3) & ~@as(usize, 3);
}

/// Sequential reader over a message body. Slices returned by `string`/`array`
/// borrow from the body buffer and are only valid until the next message is
/// read into it.
pub const ArgReader = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn uint(self: *ArgReader) !u32 {
        if (self.pos + 4 > self.bytes.len) return error.MalformedMessage;
        const value = std.mem.readInt(u32, self.bytes[self.pos..][0..4], .little);
        self.pos += 4;
        return value;
    }

    pub fn int(self: *ArgReader) !i32 {
        return @bitCast(try self.uint());
    }

    pub fn fixed(self: *ArgReader) !Fixed {
        return @bitCast(try self.uint());
    }

    pub fn string(self: *ArgReader) ![]const u8 {
        const len = try self.uint();
        if (len == 0) return ""; // null string
        const padded = alignUp4(len);
        if (self.pos + padded > self.bytes.len) return error.MalformedMessage;
        const value = self.bytes[self.pos..][0 .. len - 1];
        self.pos += padded;
        return value;
    }

    pub fn array(self: *ArgReader) ![]const u8 {
        const len = try self.uint();
        const padded = alignUp4(len);
        if (self.pos + padded > self.bytes.len) return error.MalformedMessage;
        const value = self.bytes[self.pos..][0..len];
        self.pos += padded;
        return value;
    }
};

test "header round-trip" {
    var buffer: [header_size]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeHeader(&writer, 42, 7, 20);

    const header = parseHeader(buffer);
    try std.testing.expectEqual(@as(u32, 42), header.object_id);
    try std.testing.expectEqual(@as(u16, 7), header.opcode);
    try std.testing.expectEqual(@as(u16, 20), header.size);
}

test "string argument is NUL-terminated and padded" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    // "hello" -> len 6 (incl NUL), payload padded to 8.
    try writeString(&writer, "hello");
    try std.testing.expectEqual(@as(usize, 12), writer.end);
    try std.testing.expectEqual(@as(u32, 6), std.mem.readInt(u32, buffer[0..4], .little));
    try std.testing.expectEqualStrings("hello", buffer[4..9]);
    try std.testing.expectEqual(@as(u8, 0), buffer[9]);
    try std.testing.expectEqual(@as(u16, 12), stringSize("hello"));

    // Exact multiple: "abc" -> len 4, no extra padding beyond the NUL.
    var writer2 = std.Io.Writer.fixed(&buffer);
    try writeString(&writer2, "abc");
    try std.testing.expectEqual(@as(usize, 8), writer2.end);
}

test "ArgReader parses uint, string, and array in sequence" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeUint(&writer, 99);
    try writeString(&writer, "wl_shm");
    try writeUint(&writer, 2); // array of 2 bytes
    try writer.writeAll("ab");
    try writer.writeAll(&[2]u8{ 0, 0 });

    var args = ArgReader{ .bytes = buffer[0..writer.end] };
    try std.testing.expectEqual(@as(u32, 99), try args.uint());
    try std.testing.expectEqualStrings("wl_shm", try args.string());
    try std.testing.expectEqualStrings("ab", try args.array());
}

test "ArgReader rejects truncated args" {
    var args = ArgReader{ .bytes = &[2]u8{ 1, 2 } };
    try std.testing.expectError(error.MalformedMessage, args.uint());
}

test "fixed point conversion" {
    try std.testing.expectEqual(@as(i32, 3), fixedToInt(3 * 256 + 128));
    try std.testing.expectEqual(@as(f32, 3.5), fixedToFloat(3 * 256 + 128));
    try std.testing.expectEqual(@as(i32, -3), fixedToInt(-(2 * 256 + 128)));
}
