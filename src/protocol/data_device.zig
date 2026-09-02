//! Request marshallers for the core data-device objects (wayland.xml):
//! `wl_data_device_manager`, `wl_data_device`, `wl_data_source` and
//! `wl_data_offer`, as far as the clipboard needs them. The drag-and-drop
//! requests on the same objects are not covered.

const std = @import("std");
const wire = @import("wire.zig");

/// The mime types a text clipboard offers and takes, best first.
pub const mime_utf8 = "text/plain;charset=utf-8";
pub const mime_text_plain = "text/plain";
pub const mime_utf8_string = "UTF8_STRING";
pub const mime_text = "TEXT";
pub const mime_string = "STRING";
pub const text_mime_types = [_][]const u8{ mime_utf8, mime_text_plain, mime_utf8_string, mime_text, mime_string };

pub const manager = struct {
    pub fn createDataSource(writer: *std.Io.Writer, manager_id: u32, source_id: u32) !void {
        try wire.writeHeader(writer, manager_id, 0, 12);
        try wire.writeUint(writer, source_id);
    }

    pub fn getDataDevice(writer: *std.Io.Writer, manager_id: u32, device_id: u32, seat_id: u32) !void {
        try wire.writeHeader(writer, manager_id, 1, 16);
        try wire.writeUint(writer, device_id);
        try wire.writeUint(writer, seat_id);
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
    /// Make `source_id` the seat's selection; 0 clears it. `serial` must be
    /// from a recent input event, or the compositor ignores the request.
    pub fn setSelection(writer: *std.Io.Writer, device_id: u32, source_id: u32, serial: u32) !void {
        try wire.writeHeader(writer, device_id, 1, 16);
        try wire.writeUint(writer, source_id);
        try wire.writeUint(writer, serial);
    }

    /// wl_data_device version 2 and up.
    pub fn release(writer: *std.Io.Writer, device_id: u32) !void {
        try wire.writeNoArgs(writer, device_id, 2);
    }
};

/// Offers are server-created: their ids arrive in `wl_data_device.data_offer`
/// events, and destroying one gets no `delete_id`, so the caller drops the id
/// from its object map itself (`Display.forgetServerObject`).
pub const offer = struct {
    /// `receive` carries the pipe's write end as an fd, which travels out of
    /// band. This encodes the message into `buffer` and returns the bytes to
    /// hand to `Display.sendWithFd` together with the descriptor.
    pub fn receiveMessage(buffer: []u8, offer_id: u32, mime_type: []const u8) ![]u8 {
        const size = wire.header_size + wire.stringSize(mime_type);
        if (size > buffer.len) return error.NoSpaceLeft;
        var writer = std.Io.Writer.fixed(buffer);
        try wire.writeHeader(&writer, offer_id, 1, size);
        try wire.writeString(&writer, mime_type);
        return buffer[0..writer.end];
    }

    pub fn destroy(writer: *std.Io.Writer, offer_id: u32) !void {
        try wire.writeNoArgs(writer, offer_id, 2);
    }
};

test "get_data_device marshals device then seat" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try manager.getDataDevice(&writer, 5, 9, 4);

    const header = wire.parseHeader(buffer[0..8].*);
    try std.testing.expectEqual(@as(u32, 5), header.object_id);
    try std.testing.expectEqual(@as(u16, 1), header.opcode);
    try std.testing.expectEqual(@as(usize, header.size), writer.end);

    var args = wire.ArgReader{ .bytes = buffer[8..writer.end] };
    try std.testing.expectEqual(@as(u32, 9), try args.uint());
    try std.testing.expectEqual(@as(u32, 4), try args.uint());
}

test "offer marshals the mime type as a string" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try source.offer(&writer, 12, mime_utf8);

    const header = wire.parseHeader(buffer[0..8].*);
    try std.testing.expectEqual(@as(u16, 0), header.opcode);
    try std.testing.expectEqual(@as(usize, header.size), writer.end);
    var args = wire.ArgReader{ .bytes = buffer[8..writer.end] };
    try std.testing.expectEqualStrings(mime_utf8, try args.string());
}

test "set_selection marshals source then serial" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try device.setSelection(&writer, 10, 12, 777);

    const header = wire.parseHeader(buffer[0..8].*);
    try std.testing.expectEqual(@as(u16, 1), header.opcode);
    try std.testing.expectEqual(@as(u16, 16), header.size);
    var args = wire.ArgReader{ .bytes = buffer[8..writer.end] };
    try std.testing.expectEqual(@as(u32, 12), try args.uint());
    try std.testing.expectEqual(@as(u32, 777), try args.uint());
}

test "receive message is sized for the fd send" {
    var buffer: [64]u8 = undefined;
    const bytes = try offer.receiveMessage(&buffer, 0xff000001, mime_text_plain);

    const header = wire.parseHeader(bytes[0..8].*);
    try std.testing.expectEqual(@as(u32, 0xff000001), header.object_id);
    try std.testing.expectEqual(@as(u16, 1), header.opcode);
    try std.testing.expectEqual(@as(usize, header.size), bytes.len);
    var args = wire.ArgReader{ .bytes = bytes[8..] };
    try std.testing.expectEqualStrings(mime_text_plain, try args.string());

    var small: [8]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, offer.receiveMessage(&small, 1, mime_text_plain));
}
