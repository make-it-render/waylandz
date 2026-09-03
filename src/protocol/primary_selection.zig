//! Request marshallers for wp-primary-selection-unstable-v1
//! (`zwp_primary_selection_device_manager_v1` and the device, source and
//! offer it creates): the selection that middle-click pastes. The four
//! objects mirror the core data-device ones (`data_device.zig`) without the
//! drag-and-drop half, so the opcodes are shifted down.

const std = @import("std");
const wire = @import("wire.zig");

pub const manager = struct {
    pub fn createSource(writer: *std.Io.Writer, manager_id: u32, source_id: u32) !void {
        try wire.writeHeader(writer, manager_id, 0, 12);
        try wire.writeUint(writer, source_id);
    }

    pub fn getDevice(writer: *std.Io.Writer, manager_id: u32, device_id: u32, seat_id: u32) !void {
        try wire.writeHeader(writer, manager_id, 1, 16);
        try wire.writeUint(writer, device_id);
        try wire.writeUint(writer, seat_id);
    }

    pub fn destroy(writer: *std.Io.Writer, manager_id: u32) !void {
        try wire.writeNoArgs(writer, manager_id, 2);
    }
};

pub const source = struct {
    /// Announce one mime type the source can deliver. Repeat per type.
    pub fn offer(writer: *std.Io.Writer, source_id: u32, mime_type: []const u8) !void {
        const size = wire.header_size + wire.stringSize(mime_type);
        try wire.writeHeader(writer, source_id, 0, size);
        try wire.writeString(writer, mime_type);
    }

    pub fn destroy(writer: *std.Io.Writer, source_id: u32) !void {
        try wire.writeNoArgs(writer, source_id, 1);
    }
};

pub const device = struct {
    /// Make `source_id` the seat's primary selection; 0 clears it. `serial`
    /// must be from a recent input event, or the compositor ignores the request.
    pub fn setSelection(writer: *std.Io.Writer, device_id: u32, source_id: u32, serial: u32) !void {
        try wire.writeHeader(writer, device_id, 0, 16);
        try wire.writeUint(writer, source_id);
        try wire.writeUint(writer, serial);
    }

    pub fn destroy(writer: *std.Io.Writer, device_id: u32) !void {
        try wire.writeNoArgs(writer, device_id, 1);
    }
};

/// Offers are server-created: their ids arrive in `data_offer` events, and
/// destroying one gets no `delete_id`, so the caller drops the id from its
/// object map itself (`Display.forgetServerObject`).
pub const offer = struct {
    /// `receive` carries the pipe's write end as an fd, which travels out of
    /// band. This encodes the message into `buffer` and returns the bytes to
    /// hand to `Display.sendWithFd` together with the descriptor.
    pub fn receiveMessage(buffer: []u8, offer_id: u32, mime_type: []const u8) ![]u8 {
        const size = wire.header_size + wire.stringSize(mime_type);
        if (size > buffer.len) return error.NoSpaceLeft;
        var writer = std.Io.Writer.fixed(buffer);
        try wire.writeHeader(&writer, offer_id, 0, size);
        try wire.writeString(&writer, mime_type);
        return buffer[0..writer.end];
    }

    pub fn destroy(writer: *std.Io.Writer, offer_id: u32) !void {
        try wire.writeNoArgs(writer, offer_id, 1);
    }
};

test "get_device marshals device then seat" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try manager.getDevice(&writer, 18, 21, 4);

    const header = wire.parseHeader(buffer[0..8].*);
    try std.testing.expectEqual(@as(u32, 18), header.object_id);
    try std.testing.expectEqual(@as(u16, 1), header.opcode);
    try std.testing.expectEqual(@as(usize, header.size), writer.end);

    var args = wire.ArgReader{ .bytes = buffer[8..writer.end] };
    try std.testing.expectEqual(@as(u32, 21), try args.uint());
    try std.testing.expectEqual(@as(u32, 4), try args.uint());
}

test "create_source and the destroys use the shifted opcodes" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try manager.createSource(&writer, 18, 22);
    try std.testing.expectEqual(@as(u16, 0), wire.parseHeader(buffer[0..8].*).opcode);
    try std.testing.expectEqual(@as(u16, 12), wire.parseHeader(buffer[0..8].*).size);

    var writer2 = std.Io.Writer.fixed(&buffer);
    try source.destroy(&writer2, 22);
    try std.testing.expectEqual(@as(u16, 1), wire.parseHeader(buffer[0..8].*).opcode);

    var writer3 = std.Io.Writer.fixed(&buffer);
    try device.destroy(&writer3, 21);
    try std.testing.expectEqual(@as(u16, 1), wire.parseHeader(buffer[0..8].*).opcode);

    var writer4 = std.Io.Writer.fixed(&buffer);
    try offer.destroy(&writer4, 0xff000003);
    try std.testing.expectEqual(@as(u16, 1), wire.parseHeader(buffer[0..8].*).opcode);

    var writer5 = std.Io.Writer.fixed(&buffer);
    try manager.destroy(&writer5, 18);
    try std.testing.expectEqual(@as(u16, 2), wire.parseHeader(buffer[0..8].*).opcode);
}

test "offer marshals the mime type as a string" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try source.offer(&writer, 22, "text/plain;charset=utf-8");

    const header = wire.parseHeader(buffer[0..8].*);
    try std.testing.expectEqual(@as(u16, 0), header.opcode);
    try std.testing.expectEqual(@as(usize, header.size), writer.end);
    var args = wire.ArgReader{ .bytes = buffer[8..writer.end] };
    try std.testing.expectEqualStrings("text/plain;charset=utf-8", try args.string());
}

test "set_selection is opcode 0 and marshals source then serial" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try device.setSelection(&writer, 21, 22, 777);

    const header = wire.parseHeader(buffer[0..8].*);
    try std.testing.expectEqual(@as(u16, 0), header.opcode);
    try std.testing.expectEqual(@as(u16, 16), header.size);
    var args = wire.ArgReader{ .bytes = buffer[8..writer.end] };
    try std.testing.expectEqual(@as(u32, 22), try args.uint());
    try std.testing.expectEqual(@as(u32, 777), try args.uint());
}

test "receive message is opcode 0 and sized for the fd send" {
    var buffer: [64]u8 = undefined;
    const bytes = try offer.receiveMessage(&buffer, 0xff000003, "text/plain");

    const header = wire.parseHeader(bytes[0..8].*);
    try std.testing.expectEqual(@as(u32, 0xff000003), header.object_id);
    try std.testing.expectEqual(@as(u16, 0), header.opcode);
    try std.testing.expectEqual(@as(usize, header.size), bytes.len);
    var args = wire.ArgReader{ .bytes = bytes[8..] };
    try std.testing.expectEqualStrings("text/plain", try args.string());

    var small: [8]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, offer.receiveMessage(&small, 1, "text/plain"));
}
