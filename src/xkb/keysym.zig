//! Keysym name resolution for the xkb_v1 keymap text format. Values follow
//! X11's keysymdef.h. The table covers what real layouts put on keys that
//! anywindow can act on — Latin-1, TTY/function/keypad/modifier keysyms, ISO
//! shifts, and dead keys; exotic names (XF86*, other scripts) resolve to
//! null and the key surfaces as an unknown-Key scancode, which is exactly
//! how the X11 backend treats them too.

pub const no_symbol: u32 = 0;

/// Resolve a keysym name from an xkb keymap to its numeric value. Null when
/// the name is not covered — callers should treat that as `no_symbol`.
pub fn fromName(name: []const u8) ?u32 {
    if (name.len == 0) return null;
    // Single characters name themselves: letters, digits (Latin-1 keysyms
    // equal their code points).
    if (name.len == 1) {
        const char = name[0];
        if (char >= 0x20 and char < 0x7F) return char;
        return null;
    }
    // "U" + hex is the Unicode form (U20AC); values above Latin-1 live at
    // 0x0100_0000 + code point.
    if (name[0] == 'U' and isHex(name[1..])) {
        const code_point = std.fmt.parseInt(u21, name[1..], 16) catch return null;
        if (code_point < 0x100) return code_point;
        return 0x0100_0000 + @as(u32, code_point);
    }
    // Raw hex form for keysyms without a name.
    if (std.mem.startsWith(u8, name, "0x")) {
        return std.fmt.parseInt(u32, name[2..], 16) catch null;
    }
    return names.get(name);
}

fn isHex(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |char| {
        switch (char) {
            '0'...'9', 'a'...'f', 'A'...'F' => {},
            else => return false,
        }
    }
    return true;
}

/// Keypad keysyms select the KEYPAD implicit type.
pub fn isKeypad(keysym: u32) bool {
    return keysym >= 0xFF80 and keysym <= 0xFFBD;
}

/// Lower/upper-case pair of the same letter (Latin-1 ranges) — the signal
/// for the ALPHABETIC implicit types.
pub fn isAlphaPair(lower: u32, upper: u32) bool {
    if (lower >= 'a' and lower <= 'z') return upper == lower - 0x20;
    if (lower >= 0xE0 and lower <= 0xFE and lower != 0xF7) return upper == lower - 0x20;
    return false;
}

const names = std.StaticStringMap(u32).initComptime(.{
    // Latin-1 punctuation (letters and digits resolve as single chars).
    .{ "space", 0x20 },          .{ "exclam", 0x21 },        .{ "quotedbl", 0x22 },
    .{ "numbersign", 0x23 },     .{ "dollar", 0x24 },        .{ "percent", 0x25 },
    .{ "ampersand", 0x26 },      .{ "apostrophe", 0x27 },    .{ "quoteright", 0x27 },
    .{ "parenleft", 0x28 },      .{ "parenright", 0x29 },    .{ "asterisk", 0x2A },
    .{ "plus", 0x2B },           .{ "comma", 0x2C },         .{ "minus", 0x2D },
    .{ "period", 0x2E },         .{ "slash", 0x2F },         .{ "colon", 0x3A },
    .{ "semicolon", 0x3B },      .{ "less", 0x3C },          .{ "equal", 0x3D },
    .{ "greater", 0x3E },        .{ "question", 0x3F },      .{ "at", 0x40 },
    .{ "bracketleft", 0x5B },    .{ "backslash", 0x5C },     .{ "bracketright", 0x5D },
    .{ "asciicircum", 0x5E },    .{ "underscore", 0x5F },    .{ "grave", 0x60 },
    .{ "quoteleft", 0x60 },      .{ "braceleft", 0x7B },     .{ "bar", 0x7C },
    .{ "braceright", 0x7D },     .{ "asciitilde", 0x7E },
    // Latin-1 high half — European layouts put these on base levels.
    .{ "nobreakspace", 0xA0 },   .{ "exclamdown", 0xA1 },    .{ "cent", 0xA2 },
    .{ "sterling", 0xA3 },       .{ "currency", 0xA4 },      .{ "yen", 0xA5 },
    .{ "brokenbar", 0xA6 },      .{ "section", 0xA7 },       .{ "diaeresis", 0xA8 },
    .{ "copyright", 0xA9 },      .{ "ordfeminine", 0xAA },   .{ "guillemotleft", 0xAB },
    .{ "notsign", 0xAC },        .{ "hyphen", 0xAD },        .{ "registered", 0xAE },
    .{ "macron", 0xAF },         .{ "degree", 0xB0 },        .{ "plusminus", 0xB1 },
    .{ "twosuperior", 0xB2 },    .{ "threesuperior", 0xB3 }, .{ "acute", 0xB4 },
    .{ "mu", 0xB5 },             .{ "paragraph", 0xB6 },     .{ "periodcentered", 0xB7 },
    .{ "cedilla", 0xB8 },        .{ "onesuperior", 0xB9 },   .{ "masculine", 0xBA },
    .{ "guillemotright", 0xBB }, .{ "onequarter", 0xBC },    .{ "onehalf", 0xBD },
    .{ "threequarters", 0xBE },  .{ "questiondown", 0xBF },
    .{ "Agrave", 0xC0 },         .{ "Aacute", 0xC1 },        .{ "Acircumflex", 0xC2 },
    .{ "Atilde", 0xC3 },         .{ "Adiaeresis", 0xC4 },    .{ "Aring", 0xC5 },
    .{ "AE", 0xC6 },             .{ "Ccedilla", 0xC7 },      .{ "Egrave", 0xC8 },
    .{ "Eacute", 0xC9 },         .{ "Ecircumflex", 0xCA },   .{ "Ediaeresis", 0xCB },
    .{ "Igrave", 0xCC },         .{ "Iacute", 0xCD },        .{ "Icircumflex", 0xCE },
    .{ "Idiaeresis", 0xCF },     .{ "ETH", 0xD0 },           .{ "Ntilde", 0xD1 },
    .{ "Ograve", 0xD2 },         .{ "Oacute", 0xD3 },        .{ "Ocircumflex", 0xD4 },
    .{ "Otilde", 0xD5 },         .{ "Odiaeresis", 0xD6 },    .{ "multiply", 0xD7 },
    .{ "Oslash", 0xD8 },         .{ "Ooblique", 0xD8 },      .{ "Ugrave", 0xD9 },
    .{ "Uacute", 0xDA },         .{ "Ucircumflex", 0xDB },   .{ "Udiaeresis", 0xDC },
    .{ "Yacute", 0xDD },         .{ "THORN", 0xDE },         .{ "ssharp", 0xDF },
    .{ "agrave", 0xE0 },         .{ "aacute", 0xE1 },        .{ "acircumflex", 0xE2 },
    .{ "atilde", 0xE3 },         .{ "adiaeresis", 0xE4 },    .{ "aring", 0xE5 },
    .{ "ae", 0xE6 },             .{ "ccedilla", 0xE7 },      .{ "egrave", 0xE8 },
    .{ "eacute", 0xE9 },         .{ "ecircumflex", 0xEA },   .{ "ediaeresis", 0xEB },
    .{ "igrave", 0xEC },         .{ "iacute", 0xED },        .{ "icircumflex", 0xEE },
    .{ "idiaeresis", 0xEF },     .{ "eth", 0xF0 },           .{ "ntilde", 0xF1 },
    .{ "ograve", 0xF2 },         .{ "oacute", 0xF3 },        .{ "ocircumflex", 0xF4 },
    .{ "otilde", 0xF5 },         .{ "odiaeresis", 0xF6 },    .{ "division", 0xF7 },
    .{ "oslash", 0xF8 },         .{ "ooblique", 0xF8 },      .{ "ugrave", 0xF9 },
    .{ "uacute", 0xFA },         .{ "ucircumflex", 0xFB },   .{ "udiaeresis", 0xFC },
    .{ "yacute", 0xFD },         .{ "thorn", 0xFE },         .{ "ydiaeresis", 0xFF },
    // TTY function keys.
    .{ "BackSpace", 0xFF08 },    .{ "Tab", 0xFF09 },         .{ "Linefeed", 0xFF0A },
    .{ "Clear", 0xFF0B },        .{ "Return", 0xFF0D },      .{ "Pause", 0xFF13 },
    .{ "Scroll_Lock", 0xFF14 },  .{ "Sys_Req", 0xFF15 },     .{ "Escape", 0xFF1B },
    .{ "Delete", 0xFFFF },       .{ "Multi_key", 0xFF20 },
    // Navigation and editing.
    .{ "Home", 0xFF50 },         .{ "Left", 0xFF51 },        .{ "Up", 0xFF52 },
    .{ "Right", 0xFF53 },        .{ "Down", 0xFF54 },        .{ "Prior", 0xFF55 },
    .{ "Page_Up", 0xFF55 },      .{ "Next", 0xFF56 },        .{ "Page_Down", 0xFF56 },
    .{ "End", 0xFF57 },          .{ "Begin", 0xFF58 },       .{ "Select", 0xFF60 },
    .{ "Print", 0xFF61 },        .{ "Execute", 0xFF62 },     .{ "Insert", 0xFF63 },
    .{ "Undo", 0xFF65 },         .{ "Redo", 0xFF66 },        .{ "Menu", 0xFF67 },
    .{ "Find", 0xFF68 },         .{ "Cancel", 0xFF69 },      .{ "Help", 0xFF6A },
    .{ "Break", 0xFF6B },        .{ "Mode_switch", 0xFF7E }, .{ "Num_Lock", 0xFF7F },
    // Keypad.
    .{ "KP_Space", 0xFF80 },     .{ "KP_Tab", 0xFF89 },      .{ "KP_Enter", 0xFF8D },
    .{ "KP_F1", 0xFF91 },        .{ "KP_F2", 0xFF92 },       .{ "KP_F3", 0xFF93 },
    .{ "KP_F4", 0xFF94 },        .{ "KP_Home", 0xFF95 },     .{ "KP_Left", 0xFF96 },
    .{ "KP_Up", 0xFF97 },        .{ "KP_Right", 0xFF98 },    .{ "KP_Down", 0xFF99 },
    .{ "KP_Prior", 0xFF9A },     .{ "KP_Page_Up", 0xFF9A },  .{ "KP_Next", 0xFF9B },
    .{ "KP_Page_Down", 0xFF9B }, .{ "KP_End", 0xFF9C },      .{ "KP_Begin", 0xFF9D },
    .{ "KP_Insert", 0xFF9E },    .{ "KP_Delete", 0xFF9F },   .{ "KP_Equal", 0xFFBD },
    .{ "KP_Multiply", 0xFFAA },  .{ "KP_Add", 0xFFAB },      .{ "KP_Separator", 0xFFAC },
    .{ "KP_Subtract", 0xFFAD },  .{ "KP_Decimal", 0xFFAE },  .{ "KP_Divide", 0xFFAF },
    .{ "KP_0", 0xFFB0 },         .{ "KP_1", 0xFFB1 },        .{ "KP_2", 0xFFB2 },
    .{ "KP_3", 0xFFB3 },         .{ "KP_4", 0xFFB4 },        .{ "KP_5", 0xFFB5 },
    .{ "KP_6", 0xFFB6 },         .{ "KP_7", 0xFFB7 },        .{ "KP_8", 0xFFB8 },
    .{ "KP_9", 0xFFB9 },
    // Function keys.
    .{ "F1", 0xFFBE },  .{ "F2", 0xFFBF },  .{ "F3", 0xFFC0 },  .{ "F4", 0xFFC1 },
    .{ "F5", 0xFFC2 },  .{ "F6", 0xFFC3 },  .{ "F7", 0xFFC4 },  .{ "F8", 0xFFC5 },
    .{ "F9", 0xFFC6 },  .{ "F10", 0xFFC7 }, .{ "F11", 0xFFC8 }, .{ "F12", 0xFFC9 },
    .{ "F13", 0xFFCA }, .{ "F14", 0xFFCB }, .{ "F15", 0xFFCC }, .{ "F16", 0xFFCD },
    .{ "F17", 0xFFCE }, .{ "F18", 0xFFCF }, .{ "F19", 0xFFD0 }, .{ "F20", 0xFFD1 },
    .{ "F21", 0xFFD2 }, .{ "F22", 0xFFD3 }, .{ "F23", 0xFFD4 }, .{ "F24", 0xFFD5 },
    // Modifiers.
    .{ "Shift_L", 0xFFE1 },   .{ "Shift_R", 0xFFE2 },   .{ "Control_L", 0xFFE3 },
    .{ "Control_R", 0xFFE4 }, .{ "Caps_Lock", 0xFFE5 }, .{ "Shift_Lock", 0xFFE6 },
    .{ "Meta_L", 0xFFE7 },    .{ "Meta_R", 0xFFE8 },    .{ "Alt_L", 0xFFE9 },
    .{ "Alt_R", 0xFFEA },     .{ "Super_L", 0xFFEB },   .{ "Super_R", 0xFFEC },
    .{ "Hyper_L", 0xFFED },   .{ "Hyper_R", 0xFFEE },
    // ISO extensions.
    .{ "ISO_Lock", 0xFE01 },          .{ "ISO_Level2_Latch", 0xFE02 },
    .{ "ISO_Level3_Shift", 0xFE03 },  .{ "ISO_Level3_Latch", 0xFE04 },
    .{ "ISO_Level3_Lock", 0xFE05 },   .{ "ISO_Level5_Shift", 0xFE11 },
    .{ "ISO_Level5_Latch", 0xFE12 },  .{ "ISO_Level5_Lock", 0xFE13 },
    .{ "ISO_Left_Tab", 0xFE20 },      .{ "ISO_Next_Group", 0xFE08 },
    .{ "ISO_Prev_Group", 0xFE0A },    .{ "ISO_First_Group", 0xFE0C },
    .{ "ISO_Last_Group", 0xFE0E },    .{ "ISO_Enter", 0xFE34 },
    // Dead keys — European layouts have them on AltGr levels.
    .{ "dead_grave", 0xFE50 },      .{ "dead_acute", 0xFE51 },
    .{ "dead_circumflex", 0xFE52 }, .{ "dead_tilde", 0xFE53 },
    .{ "dead_macron", 0xFE54 },     .{ "dead_breve", 0xFE55 },
    .{ "dead_abovedot", 0xFE56 },   .{ "dead_diaeresis", 0xFE57 },
    .{ "dead_abovering", 0xFE58 },  .{ "dead_doubleacute", 0xFE59 },
    .{ "dead_caron", 0xFE5A },      .{ "dead_cedilla", 0xFE5B },
    .{ "dead_ogonek", 0xFE5C },     .{ "dead_iota", 0xFE5D },
    .{ "dead_belowdot", 0xFE60 },   .{ "dead_hook", 0xFE61 },
    .{ "dead_horn", 0xFE62 },       .{ "dead_stroke", 0xFE63 },
    .{ "dead_belowcomma", 0xFE6E }, .{ "dead_currency", 0xFE6F },
    .{ "dead_greek", 0xFE8C },
    // Placeholders.
    .{ "NoSymbol", 0 },             .{ "VoidSymbol", 0xFFFFFF },
    .{ "any", 0 },                  .{ "Any", 0 },
});

test "single characters and digits name themselves" {
    try std.testing.expectEqual(@as(?u32, 'a'), fromName("a"));
    try std.testing.expectEqual(@as(?u32, 'Q'), fromName("Q"));
    try std.testing.expectEqual(@as(?u32, '7'), fromName("7"));
}

test "named keysyms resolve" {
    try std.testing.expectEqual(@as(?u32, 0x21), fromName("exclam"));
    try std.testing.expectEqual(@as(?u32, 0xE9), fromName("eacute"));
    try std.testing.expectEqual(@as(?u32, 0xFF0D), fromName("Return"));
    try std.testing.expectEqual(@as(?u32, 0xFFB7), fromName("KP_7"));
    try std.testing.expectEqual(@as(?u32, 0xFE03), fromName("ISO_Level3_Shift"));
}

test "unicode and hex forms" {
    try std.testing.expectEqual(@as(?u32, 0x0100_20AC), fromName("U20AC"));
    try std.testing.expectEqual(@as(?u32, 0xE9), fromName("U00E9"));
    try std.testing.expectEqual(@as(?u32, 0x1008FF12), fromName("0x1008FF12"));
    try std.testing.expectEqual(@as(?u32, null), fromName("XF86AudioMute"));
}

test "classification helpers" {
    try std.testing.expect(isKeypad(0xFFB0));
    try std.testing.expect(!isKeypad(0xFF0D));
    try std.testing.expect(isAlphaPair('a', 'A'));
    try std.testing.expect(isAlphaPair(0xE9, 0xC9)); // eacute/Eacute
    try std.testing.expect(!isAlphaPair('1', '!'));
}

const std = @import("std");
