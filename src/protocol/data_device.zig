//! Request marshallers for the core data-device objects (wayland.xml):
//! `wl_data_device_manager`, `wl_data_device`, `wl_data_source` and
//! `wl_data_offer`, for both the clipboard and drag and drop.

const std = @import("std");
const wire = @import("wire.zig");

/// The mime types a text clipboard offers and takes, best first.
pub const mime_utf8 = "text/plain;charset=utf-8";
pub const mime_text_plain = "text/plain";
pub const mime_utf8_string = "UTF8_STRING";
pub const mime_text = "TEXT";
pub const mime_string = "STRING";
pub const text_mime_types = [_][]const u8{ mime_utf8, mime_text_plain, mime_utf8_string, mime_text, mime_string };
/// The mime type a file drag carries: `file://` URIs, one per line.
pub const mime_uri_list = "text/uri-list";

/// `wl_data_device_manager.dnd_action` bits (version 3).
pub const dnd_action_none: u32 = 0;
pub const dnd_action_copy: u32 = 1;
pub const dnd_action_move: u32 = 2;
pub const dnd_action_ask: u32 = 4;

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

    /// The `dnd_action` bits a drag source allows; version 3, and required
    /// before `start_drag` on a drag source.
    pub fn setActions(writer: *std.Io.Writer, source_id: u32, actions: u32) !void {
        try wire.writeHeader(writer, source_id, 2, 12);
        try wire.writeUint(writer, actions);
    }
};

pub const device = struct {
    /// Begin a drag of `source_id` (0 for a drag with no data) from
    /// `origin_id`, showing `icon_id` under the pointer (0 for none).
    /// `serial` must be the one of the button press that started the
    /// implicit grab, or the compositor ignores the request.
    pub fn startDrag(writer: *std.Io.Writer, device_id: u32, source_id: u32, origin_id: u32, icon_id: u32, serial: u32) !void {
        try wire.writeHeader(writer, device_id, 0, 24);
        try wire.writeUint(writer, source_id);
        try wire.writeUint(writer, origin_id);
        try wire.writeUint(writer, icon_id);
        try wire.writeUint(writer, serial);
    }

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
    /// Tell the compositor which of a drag offer's mime types the target
    /// takes, or null for none: on version 3 that is what decides the drop.
    /// `serial` is the one of the `enter` event.
    pub fn accept(writer: *std.Io.Writer, offer_id: u32, serial: u32, mime_type: ?[]const u8) !void {
        const string_size: u16 = if (mime_type) |mime| wire.stringSize(mime) else 4;
        try wire.writeHeader(writer, offer_id, 0, wire.header_size + 4 + string_size);
        try wire.writeUint(writer, serial);
        if (mime_type) |mime| {
            try wire.writeString(writer, mime);
        } else {
            // A null string is a zero length and nothing else.
            try wire.writeUint(writer, 0);
        }
    }

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

    /// The drop succeeded and every transfer is done; the source gets
    /// `dnd_finished`. Version 3. Only after a drop was accepted and an
    /// `action` other than none arrived, or the compositor raises an error.
    pub fn finish(writer: *std.Io.Writer, offer_id: u32) !void {
        try wire.writeNoArgs(writer, offer_id, 3);
    }

    /// The `dnd_action` bits the target can perform and the one it prefers;
    /// version 3.
    pub fn setActions(writer: *std.Io.Writer, offer_id: u32, actions: u32, preferred: u32) !void {
        try wire.writeHeader(writer, offer_id, 4, 16);
        try wire.writeUint(writer, actions);
        try wire.writeUint(writer, preferred);
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

test "start_drag marshals source, origin, icon then serial" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try device.startDrag(&writer, 10, 12, 3, 0, 4242);

    const header = wire.parseHeader(buffer[0..8].*);
    try std.testing.expectEqual(@as(u32, 10), header.object_id);
    try std.testing.expectEqual(@as(u16, 0), header.opcode);
    try std.testing.expectEqual(@as(u16, 24), header.size);
    try std.testing.expectEqual(@as(usize, 24), writer.end);
    var args = wire.ArgReader{ .bytes = buffer[8..writer.end] };
    try std.testing.expectEqual(@as(u32, 12), try args.uint());
    try std.testing.expectEqual(@as(u32, 3), try args.uint());
    try std.testing.expectEqual(@as(u32, 0), try args.uint());
    try std.testing.expectEqual(@as(u32, 4242), try args.uint());
}

test "source set_actions is opcode 2 with the action bits" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try source.setActions(&writer, 12, dnd_action_copy | dnd_action_move);

    const header = wire.parseHeader(buffer[0..8].*);
    try std.testing.expectEqual(@as(u16, 2), header.opcode);
    try std.testing.expectEqual(@as(u16, 12), header.size);
    var args = wire.ArgReader{ .bytes = buffer[8..writer.end] };
    try std.testing.expectEqual(@as(u32, 3), try args.uint());
}

test "offer accept marshals the serial and a mime type, or a null string" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try offer.accept(&writer, 0xff000001, 99, mime_uri_list);

    const header = wire.parseHeader(buffer[0..8].*);
    try std.testing.expectEqual(@as(u32, 0xff000001), header.object_id);
    try std.testing.expectEqual(@as(u16, 0), header.opcode);
    try std.testing.expectEqual(@as(usize, header.size), writer.end);
    var args = wire.ArgReader{ .bytes = buffer[8..writer.end] };
    try std.testing.expectEqual(@as(u32, 99), try args.uint());
    try std.testing.expectEqualStrings(mime_uri_list, try args.string());

    var writer2 = std.Io.Writer.fixed(&buffer);
    try offer.accept(&writer2, 0xff000001, 99, null);
    const header2 = wire.parseHeader(buffer[0..8].*);
    try std.testing.expectEqual(@as(u16, 16), header2.size);
    try std.testing.expectEqual(@as(usize, 16), writer2.end);
    var args2 = wire.ArgReader{ .bytes = buffer[8..writer2.end] };
    try std.testing.expectEqual(@as(u32, 99), try args2.uint());
    try std.testing.expectEqualStrings("", try args2.string());
}

test "offer finish and set_actions use opcodes 3 and 4" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try offer.finish(&writer, 0xff000001);
    try std.testing.expectEqual(@as(u16, 3), wire.parseHeader(buffer[0..8].*).opcode);
    try std.testing.expectEqual(@as(u16, 8), wire.parseHeader(buffer[0..8].*).size);

    var writer2 = std.Io.Writer.fixed(&buffer);
    try offer.setActions(&writer2, 0xff000001, dnd_action_copy, dnd_action_copy);
    const header = wire.parseHeader(buffer[0..8].*);
    try std.testing.expectEqual(@as(u16, 4), header.opcode);
    try std.testing.expectEqual(@as(u16, 16), header.size);
    var args = wire.ArgReader{ .bytes = buffer[8..writer2.end] };
    try std.testing.expectEqual(dnd_action_copy, try args.uint());
    try std.testing.expectEqual(dnd_action_copy, try args.uint());
}
