//! Parsed XKB keymap: the xkb_v1 text a Wayland compositor sends with
//! wl_keyboard.keymap (the format libxkbcommon serializes), reduced to what
//! key-event translation needs — keycode -> per-group, per-level keysyms,
//! the key types that pick a level from the modifier state, and the real
//! bitmasks behind the virtual modifiers (Alt, Super, NumLock, LevelThree).
//!
//! Not implemented, by design: actions and indicators (the compositor owns
//! modifier state and sends it in wl_keyboard.modifiers — clients only
//! decode), compose/dead-key sequences (no text-input event to feed), and
//! key repeat (also compositor policy on Wayland).

arena: std.heap.ArenaAllocator,
min_keycode: u32 = 8,
max_keycode: u32 = 255,
/// Indexed by keycode - min_keycode; a key with no groups is unmapped.
keys: []Key = &.{},
types: []Type = &.{},
group_names: [][]const u8 = &.{},
/// Real-modifier bitmasks (bits 0-7: Shift, Lock, Control, Mod1-Mod5)
/// resolved from the keymap's virtual modifiers, with the de-facto pc
/// defaults when a keymap leaves one unbound.
alt_mask: u8 = mask_mod1,
super_mask: u8 = mask_mod4,
num_lock_mask: u8 = mask_mod2,
level_three_mask: u8 = mask_mod5,

pub const mask_shift: u8 = 0x01;
pub const mask_lock: u8 = 0x02;
pub const mask_control: u8 = 0x04;
pub const mask_mod1: u8 = 0x08;
pub const mask_mod2: u8 = 0x10;
pub const mask_mod3: u8 = 0x20;
pub const mask_mod4: u8 = 0x40;
pub const mask_mod5: u8 = 0x80;

const Key = struct {
    groups: []Group = &.{},
};

const Group = struct {
    type_index: u32,
    syms: []u32,
};

const Type = struct {
    mask: u8,
    entries: []MapEntry,
};

const MapEntry = struct {
    mods: u8,
    level: u32,
};

/// Parse a serialized keymap. The text is not retained — everything needed
/// is copied into the keymap's arena.
pub fn parse(allocator: std.mem.Allocator, text: []const u8) !@This() {
    var self: @This() = .{ .arena = .init(allocator) };
    errdefer self.arena.deinit();

    var temp_arena: std.heap.ArenaAllocator = .init(allocator);
    defer temp_arena.deinit();

    var builder: Builder = .{
        .allocator = temp_arena.allocator(),
        .scanner = .{ .text = text },
    };
    builder.parseKeymap() catch |err| {
        const pos = @min(builder.scanner.pos, text.len);
        log.warn("keymap parse failed at byte {d}, near: \"{s}\"", .{ pos, text[pos -| 60..@min(text.len, pos + 40)] });
        return err;
    };
    try builder.build(&self);
    return self;
}

pub fn deinit(self: *@This()) void {
    self.arena.deinit();
}

/// Resolve one key event: modifier state (real bits, depressed|latched|
/// locked) and effective group to a keysym. Returns 0 (NoSymbol) for
/// unmapped keys.
pub fn keysym(self: *const @This(), keycode: u32, mods: u8, group: u32) u32 {
    if (keycode < self.min_keycode or keycode > self.max_keycode) return 0;
    const key = self.keys[keycode - self.min_keycode];
    if (key.groups.len == 0) return 0;

    // Out-of-range groups wrap — the default XKB policy.
    const key_group = key.groups[group % key.groups.len];
    const key_type = self.types[key_group.type_index];

    var level: u32 = 0;
    const masked = mods & key_type.mask;
    for (key_type.entries) |entry| {
        if (entry.mods == masked) {
            level = entry.level;
            break;
        }
    }
    if (level >= key_group.syms.len) return 0;
    return key_group.syms[level];
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

/// Symbolic modifier mask while parsing: bits 0-7 are the real modifiers,
/// bits 8+ index the virtual_modifiers declaration list.
const SymbolicMask = u32;

const Builder = struct {
    allocator: std.mem.Allocator,
    scanner: Scanner,

    min_keycode: u32 = 8,
    max_keycode: u32 = 255,
    keycodes: std.StringHashMapUnmanaged(u32) = .empty,
    aliases: std.StringHashMapUnmanaged([]const u8) = .empty,
    vmods: std.ArrayList([]const u8) = .empty,
    /// Mappings declared inline (`Hyper=0x4000`, `Alt=Mod1`), by name: the
    /// real bits bind directly, bits 8+ name other virtual modifiers.
    vmod_mappings: std.StringHashMapUnmanaged(SymbolicMask) = .empty,
    raw_types: std.ArrayList(RawType) = .empty,
    interprets: std.ArrayList(Interpret) = .empty,
    raw_keys: std.ArrayList(RawKey) = .empty,
    /// Key name -> real modifier bits, from modifier_map statements.
    modmap: std.StringHashMapUnmanaged(u8) = .empty,
    group_names: std.ArrayList([]const u8) = .empty,
    /// Running default for interprets without their own useModMapMods.
    interpret_level_one_default: bool = false,

    const RawType = struct {
        name: []const u8,
        mask: SymbolicMask = 0,
        entries: std.ArrayList(RawEntry) = .empty,
    };

    const RawEntry = struct {
        mask: SymbolicMask,
        level: u32,
    };

    const Interpret = struct {
        keysym: u32,
        vmod_index: u32,
        /// useModMapMods=level1: the key's modifier_map bits count only when
        /// this keysym sits at group 1, level 1 of the key. Without it, a
        /// match anywhere on the key binds (AnyLevel).
        level_one_only: bool,
    };

    const RawKey = struct {
        name: []const u8,
        /// Explicit type name per group; index 0 doubles as "all groups"
        /// when `type=` appears without a group subscript.
        explicit_types: [max_groups]?[]const u8 = @splat(null),
        explicit_type_all: ?[]const u8 = null,
        groups: [max_groups]?[]u32 = @splat(null),
    };

    const max_groups = 4;

    fn parseKeymap(self: *Builder) !void {
        try self.scanner.expectIdent("xkb_keymap");
        try self.scanner.expectPunct('{');
        while (true) {
            const token = try self.scanner.next();
            switch (token) {
                .punct => |char| if (char == '}') break else return error.MalformedKeymap,
                .ident => |section| {
                    // Section name then optional quoted name, then a block.
                    if (try self.scanner.peekIsString()) _ = try self.scanner.nextString();
                    try self.scanner.expectPunct('{');
                    if (std.mem.eql(u8, section, "xkb_keycodes")) {
                        try self.parseKeycodes();
                    } else if (std.mem.eql(u8, section, "xkb_types")) {
                        try self.parseTypes();
                    } else if (std.mem.eql(u8, section, "xkb_compatibility")) {
                        try self.parseCompat();
                    } else if (std.mem.eql(u8, section, "xkb_symbols")) {
                        try self.parseSymbols();
                    } else {
                        try self.scanner.skipBlockBody();
                    }
                    try self.scanner.expectPunct(';');
                },
                else => return error.MalformedKeymap,
            }
        }
    }

    fn parseKeycodes(self: *Builder) !void {
        while (true) {
            const token = try self.scanner.next();
            switch (token) {
                .punct => |char| if (char == '}') return else return error.MalformedKeymap,
                .keyname => |name| {
                    try self.scanner.expectPunct('=');
                    const code = try self.scanner.nextNumber();
                    try self.keycodes.put(self.allocator, name, code);
                    try self.scanner.expectPunct(';');
                },
                .ident => |ident| {
                    if (std.mem.eql(u8, ident, "minimum")) {
                        try self.scanner.expectPunct('=');
                        self.min_keycode = try self.scanner.nextNumber();
                        try self.scanner.expectPunct(';');
                    } else if (std.mem.eql(u8, ident, "maximum")) {
                        try self.scanner.expectPunct('=');
                        self.max_keycode = try self.scanner.nextNumber();
                        try self.scanner.expectPunct(';');
                    } else if (std.mem.eql(u8, ident, "alias")) {
                        const alias = try self.scanner.nextKeyname();
                        try self.scanner.expectPunct('=');
                        const target = try self.scanner.nextKeyname();
                        try self.aliases.put(self.allocator, alias, target);
                        try self.scanner.expectPunct(';');
                    } else {
                        try self.scanner.skipStatement(); // indicator and friends
                    }
                },
                else => return error.MalformedKeymap,
            }
        }
    }

    fn parseTypes(self: *Builder) !void {
        while (true) {
            const token = try self.scanner.next();
            switch (token) {
                .punct => |char| if (char == '}') return else return error.MalformedKeymap,
                .ident => |ident| {
                    if (std.mem.eql(u8, ident, "virtual_modifiers")) {
                        try self.parseVirtualModifiers();
                    } else if (std.mem.eql(u8, ident, "type")) {
                        try self.parseType();
                    } else {
                        try self.scanner.skipStatement();
                    }
                },
                else => return error.MalformedKeymap,
            }
        }
    }

    fn parseVirtualModifiers(self: *Builder) !void {
        while (true) {
            const name = try self.scanner.nextIdent();
            if (self.vmodIndex(name) == null) {
                try self.vmods.append(self.allocator, name);
            }
            var token = try self.scanner.next();
            if (token == .punct and token.punct == '=') {
                // libxkbcommon 1.8+ writes the mapping inline: a mask in hex
                // (bit n+8 is virtual modifier n) or a `+` expression of names.
                var mapping: SymbolicMask = 0;
                token = try self.scanner.next();
                while (true) {
                    switch (token) {
                        .number => |value| mapping |= value,
                        .ident => |modifier| mapping |= try self.modifierBit(modifier),
                        .punct => |char| switch (char) {
                            '+' => {},
                            ',', ';' => break,
                            else => return error.MalformedKeymap,
                        },
                        else => return error.MalformedKeymap,
                    }
                    token = try self.scanner.next();
                }
                try self.vmod_mappings.put(self.allocator, name, mapping);
            }
            switch (token) {
                .punct => |char| switch (char) {
                    ',' => continue,
                    ';' => return,
                    else => return error.MalformedKeymap,
                },
                else => return error.MalformedKeymap,
            }
        }
    }

    fn vmodIndex(self: *Builder, name: []const u8) ?u32 {
        for (self.vmods.items, 0..) |vmod, index| {
            if (std.mem.eql(u8, vmod, name)) return @intCast(index);
        }
        return null;
    }

    fn parseType(self: *Builder) !void {
        const name = try self.scanner.nextString();
        try self.scanner.expectPunct('{');
        var raw_type: RawType = .{ .name = name };

        while (true) {
            const token = try self.scanner.next();
            switch (token) {
                .punct => |char| if (char == '}') break else return error.MalformedKeymap,
                .ident => |field| {
                    if (std.mem.eql(u8, field, "modifiers")) {
                        try self.scanner.expectPunct('=');
                        raw_type.mask = try self.parseSymbolicMask(';');
                    } else if (std.mem.eql(u8, field, "map")) {
                        try self.scanner.expectPunct('[');
                        const mask = try self.parseSymbolicMask(']');
                        try self.scanner.expectPunct('=');
                        const level = try self.scanner.nextNumber();
                        if (level == 0) return error.MalformedKeymap;
                        try self.scanner.expectPunct(';');
                        try raw_type.entries.append(self.allocator, .{ .mask = mask, .level = level - 1 });
                    } else {
                        try self.scanner.skipStatement(); // preserve, level_name
                    }
                },
                else => return error.MalformedKeymap,
            }
        }
        try self.scanner.expectPunct(';');
        try self.raw_types.append(self.allocator, raw_type);
    }

    /// A `A+B+C` modifier expression, consumed up to (and including) the
    /// given terminator. `none` is the empty mask.
    fn parseSymbolicMask(self: *Builder, terminator: u8) !SymbolicMask {
        var mask: SymbolicMask = 0;
        while (true) {
            const token = try self.scanner.next();
            switch (token) {
                .ident => |name| mask |= try self.modifierBit(name),
                .punct => |char| {
                    if (char == terminator) return mask;
                    if (char != '+') return error.MalformedKeymap;
                },
                else => return error.MalformedKeymap,
            }
        }
    }

    fn modifierBit(self: *Builder, name: []const u8) !SymbolicMask {
        if (std.ascii.eqlIgnoreCase(name, "none")) return 0;
        if (std.ascii.eqlIgnoreCase(name, "shift")) return mask_shift;
        if (std.ascii.eqlIgnoreCase(name, "lock")) return mask_lock;
        if (std.ascii.eqlIgnoreCase(name, "control")) return mask_control;
        if (std.ascii.eqlIgnoreCase(name, "mod1")) return mask_mod1;
        if (std.ascii.eqlIgnoreCase(name, "mod2")) return mask_mod2;
        if (std.ascii.eqlIgnoreCase(name, "mod3")) return mask_mod3;
        if (std.ascii.eqlIgnoreCase(name, "mod4")) return mask_mod4;
        if (std.ascii.eqlIgnoreCase(name, "mod5")) return mask_mod5;
        if (self.vmodIndex(name)) |index| return @as(SymbolicMask, 0x100) << @intCast(index);
        // An undeclared virtual modifier: declare it implicitly, unbound.
        try self.vmods.append(self.allocator, name);
        return @as(SymbolicMask, 0x100) << @intCast(self.vmods.items.len - 1);
    }

    fn parseCompat(self: *Builder) !void {
        while (true) {
            const token = try self.scanner.next();
            switch (token) {
                .punct => |char| if (char == '}') return else return error.MalformedKeymap,
                .ident => |ident| {
                    if (std.mem.eql(u8, ident, "virtual_modifiers")) {
                        try self.parseVirtualModifiers();
                    } else if (std.mem.eql(u8, ident, "interpret")) {
                        try self.parseInterpret();
                    } else {
                        try self.scanner.skipStatement(); // indicator, group, defaults
                    }
                },
                else => return error.MalformedKeymap,
            }
        }
    }

    fn parseInterpret(self: *Builder) !void {
        // Either a defaults statement (interpret.field= ...;) or a real
        // entry (interpret Keysym+Predicate(...) { ... };).
        if (try self.scanner.peekIsPunct('.')) {
            try self.scanner.expectPunct('.');
            const field = try self.scanner.nextIdent();
            if (std.mem.eql(u8, field, "useModMapMods")) {
                try self.scanner.expectPunct('=');
                const value = try self.scanner.nextIdent();
                self.interpret_level_one_default = std.ascii.eqlIgnoreCase(value, "level1");
                try self.scanner.expectPunct(';');
            } else {
                try self.scanner.skipStatement();
            }
            return;
        }
        // Newer dumps write a keysym without a name as a hex number.
        const sym: u32 = switch (try self.scanner.next()) {
            .ident => |name| keysyms.fromName(name) orelse 0,
            .number => |value| value,
            else => return error.MalformedKeymap,
        };

        // Skip the optional +Predicate(args) part of the header.
        while (!try self.scanner.peekIsPunct('{')) {
            const token = try self.scanner.next();
            if (token == .end) return error.MalformedKeymap;
        }
        try self.scanner.expectPunct('{');

        var vmod_index: ?u32 = null;
        var level_one_only = self.interpret_level_one_default;
        while (true) {
            const token = try self.scanner.next();
            switch (token) {
                .punct => |char| if (char == '}') break else return error.MalformedKeymap,
                .ident => |field| {
                    if (std.mem.eql(u8, field, "virtualModifier")) {
                        try self.scanner.expectPunct('=');
                        const name = try self.scanner.nextIdent();
                        if (self.vmodIndex(name) == null) {
                            try self.vmods.append(self.allocator, name);
                        }
                        vmod_index = self.vmodIndex(name);
                        try self.scanner.expectPunct(';');
                    } else if (std.mem.eql(u8, field, "useModMapMods")) {
                        try self.scanner.expectPunct('=');
                        const value = try self.scanner.nextIdent();
                        level_one_only = std.ascii.eqlIgnoreCase(value, "level1");
                        try self.scanner.expectPunct(';');
                    } else {
                        try self.scanner.skipStatement(); // action, repeat, ...
                    }
                },
                else => return error.MalformedKeymap,
            }
        }
        try self.scanner.expectPunct(';');

        if (vmod_index) |index| {
            if (sym != 0) try self.interprets.append(self.allocator, .{
                .keysym = sym,
                .vmod_index = index,
                .level_one_only = level_one_only,
            });
        }
    }

    fn parseSymbols(self: *Builder) !void {
        while (true) {
            const token = try self.scanner.next();
            switch (token) {
                .punct => |char| if (char == '}') return else return error.MalformedKeymap,
                .ident => |ident| {
                    if (std.mem.eql(u8, ident, "key")) {
                        try self.parseKey();
                    } else if (std.mem.eql(u8, ident, "modifier_map")) {
                        try self.parseModifierMap();
                    } else if (std.mem.eql(u8, ident, "name")) {
                        try self.parseGroupName();
                    } else {
                        try self.scanner.skipStatement();
                    }
                },
                else => return error.MalformedKeymap,
            }
        }
    }

    fn parseGroupName(self: *Builder) !void {
        try self.scanner.expectPunct('[');
        const group = try self.parseGroupRef();
        try self.scanner.expectPunct(']');
        try self.scanner.expectPunct('=');
        const name = try self.scanner.nextString();
        try self.scanner.expectPunct(';');

        while (self.group_names.items.len <= group) {
            try self.group_names.append(self.allocator, "");
        }
        self.group_names.items[group] = name;
    }

    /// Group1 / group1 / plain number, to a zero-based index.
    fn parseGroupRef(self: *Builder) !u32 {
        const token = try self.scanner.next();
        switch (token) {
            .number => |value| {
                if (value == 0) return error.MalformedKeymap;
                return value - 1;
            },
            .ident => |name| {
                if (!std.ascii.startsWithIgnoreCase(name, "group")) return error.MalformedKeymap;
                const value = std.fmt.parseInt(u32, name["group".len..], 10) catch return error.MalformedKeymap;
                if (value == 0) return error.MalformedKeymap;
                return value - 1;
            },
            else => return error.MalformedKeymap,
        }
    }

    fn parseKey(self: *Builder) !void {
        var raw_key: RawKey = .{ .name = try self.scanner.nextKeyname() };
        try self.scanner.expectPunct('{');

        var bare_group: u32 = 0;
        while (true) {
            // One comma-separated item per iteration.
            if (try self.scanner.peekIsPunct('[')) {
                try self.scanner.expectPunct('[');
                const syms = try self.parseSymList();
                if (bare_group < max_groups) raw_key.groups[bare_group] = syms;
                bare_group += 1;
            } else {
                const field = try self.scanner.nextIdent();
                if (std.mem.eql(u8, field, "symbols")) {
                    try self.scanner.expectPunct('[');
                    const group = try self.parseGroupRef();
                    try self.scanner.expectPunct(']');
                    try self.scanner.expectPunct('=');
                    try self.scanner.expectPunct('[');
                    const syms = try self.parseSymList();
                    if (group < max_groups) raw_key.groups[group] = syms;
                    if (group >= bare_group) bare_group = group + 1;
                } else if (std.mem.eql(u8, field, "type")) {
                    if (try self.scanner.peekIsPunct('[')) {
                        try self.scanner.expectPunct('[');
                        const group = try self.parseGroupRef();
                        try self.scanner.expectPunct(']');
                        try self.scanner.expectPunct('=');
                        const type_name = try self.scanner.nextString();
                        if (group < max_groups) raw_key.explicit_types[group] = type_name;
                    } else {
                        try self.scanner.expectPunct('=');
                        raw_key.explicit_type_all = try self.scanner.nextString();
                    }
                } else {
                    // actions[...], virtualMods, repeat, group policy — skip
                    // the item wholesale (balanced through any brackets).
                    try self.scanner.skipItem();
                }
            }

            const token = try self.scanner.next();
            switch (token) {
                .punct => |char| switch (char) {
                    ',' => continue,
                    '}' => break,
                    else => return error.MalformedKeymap,
                },
                else => return error.MalformedKeymap,
            }
        }
        try self.scanner.expectPunct(';');
        try self.raw_keys.append(self.allocator, raw_key);
    }

    /// Keysym list after '['; consumes the closing ']'. Multi-keysym levels
    /// ({ a, b }) keep their first keysym.
    fn parseSymList(self: *Builder) ![]u32 {
        var syms: std.ArrayList(u32) = .empty;
        while (true) {
            const token = try self.scanner.next();
            switch (token) {
                .punct => |char| switch (char) {
                    ']' => return syms.items,
                    ',' => continue,
                    '{' => {
                        var first: ?u32 = null;
                        while (true) {
                            const inner = try self.scanner.next();
                            switch (inner) {
                                .ident => |name| {
                                    if (first == null) first = keysyms.fromName(name) orelse 0;
                                },
                                .number => |value| {
                                    if (first == null) first = numberKeysym(value);
                                },
                                .punct => |inner_char| if (inner_char == '}') break,
                                else => return error.MalformedKeymap,
                            }
                        }
                        try syms.append(self.allocator, first orelse 0);
                    },
                    else => return error.MalformedKeymap,
                },
                .ident => |name| try syms.append(self.allocator, keysyms.fromName(name) orelse 0),
                .number => |value| try syms.append(self.allocator, numberKeysym(value)),
                else => return error.MalformedKeymap,
            }
        }
    }

    /// A bare digit in a keysym list is the digit keysym's name ("1" is
    /// 0x31); genuinely numeric keysyms are dumped in 0x hex form, whose
    /// values never land in 0-9.
    fn numberKeysym(value: u32) u32 {
        if (value <= 9) return '0' + value;
        return value;
    }

    fn parseModifierMap(self: *Builder) !void {
        const mod_name = try self.scanner.nextIdent();
        const bit: u8 = @intCast(try self.modifierBit(mod_name) & 0xFF);
        try self.scanner.expectPunct('{');
        while (true) {
            const token = try self.scanner.next();
            switch (token) {
                .keyname => |name| {
                    const entry = try self.modmap.getOrPutValue(self.allocator, name, 0);
                    entry.value_ptr.* |= bit;
                },
                .punct => |char| switch (char) {
                    ',' => continue,
                    '}' => break,
                    else => return error.MalformedKeymap,
                },
                else => return error.MalformedKeymap,
            }
        }
        try self.scanner.expectPunct(';');
    }

    // -----------------------------------------------------------------------
    // Resolution: symbolic masks to real bits, raw keys to the final table.
    // -----------------------------------------------------------------------

    fn build(self: *Builder, keymap: *Keymap) !void {
        const allocator = keymap.arena.allocator();

        // Bind virtual modifiers: an interpret names the vmod, the keys
        // carrying its keysym name the real modifier through modifier_map.
        const vmod_real = try self.allocator.alloc(u8, self.vmods.items.len);
        @memset(vmod_real, 0);
        for (self.vmods.items, vmod_real) |name, *real| {
            const mapping = self.vmod_mappings.get(name) orelse continue;
            real.* = @truncate(mapping);
        }
        for (self.interprets.items) |interpret| {
            for (self.raw_keys.items) |raw_key| {
                const real = self.modmap.get(self.resolveAlias(raw_key.name)) orelse
                    self.modmap.get(raw_key.name) orelse continue;
                const matches = if (interpret.level_one_only)
                    keyLevelOneSym(raw_key) == interpret.keysym
                else
                    keyCarries(raw_key, interpret.keysym);
                if (!matches) continue;
                vmod_real[interpret.vmod_index] |= real;
            }
        }
        self.foldVirtualReferences(vmod_real);

        keymap.min_keycode = self.min_keycode;
        keymap.max_keycode = self.max_keycode;
        if (self.vmodMask(vmod_real, "Alt")) |mask| keymap.alt_mask = mask;
        if (self.vmodMask(vmod_real, "Super")) |mask| keymap.super_mask = mask;
        if (self.vmodMask(vmod_real, "NumLock")) |mask| keymap.num_lock_mask = mask;
        if (self.vmodMask(vmod_real, "LevelThree")) |mask| keymap.level_three_mask = mask;

        // Materialize types, dropping map entries that reference unbound
        // virtual modifiers (they could otherwise shadow the base level).
        keymap.types = try allocator.alloc(Type, self.raw_types.items.len);
        for (self.raw_types.items, keymap.types) |raw_type, *final_type| {
            var entries: std.ArrayList(MapEntry) = .empty;
            for (raw_type.entries.items) |raw_entry| {
                const resolved = resolveMask(raw_entry.mask, vmod_real) orelse continue;
                try entries.append(self.allocator, .{ .mods = resolved, .level = raw_entry.level });
            }
            const mask = resolveMask(raw_type.mask, vmod_real) orelse 0;
            final_type.* = .{
                .mask = mask,
                .entries = try allocator.dupe(MapEntry, entries.items),
            };
        }

        // Group names.
        keymap.group_names = try allocator.alloc([]const u8, self.group_names.items.len);
        for (self.group_names.items, keymap.group_names) |name, *slot| {
            slot.* = try allocator.dupe(u8, name);
        }

        // Keys.
        if (self.max_keycode < self.min_keycode) return error.MalformedKeymap;
        keymap.keys = try allocator.alloc(Key, self.max_keycode - self.min_keycode + 1);
        @memset(keymap.keys, .{});
        for (self.raw_keys.items) |raw_key| {
            const keycode = self.keycodes.get(self.resolveAlias(raw_key.name)) orelse
                self.keycodes.get(raw_key.name) orelse continue;
            if (keycode < self.min_keycode or keycode > self.max_keycode) continue;

            var group_count: usize = 0;
            for (raw_key.groups, 0..) |group, index| {
                if (group != null) group_count = index + 1;
            }
            if (group_count == 0) continue;

            const groups = try allocator.alloc(Group, group_count);
            for (groups, 0..) |*slot, index| {
                const syms = raw_key.groups[index] orelse &[_]u32{};
                const type_name = raw_key.explicit_types[index] orelse raw_key.explicit_type_all;
                slot.* = .{
                    .type_index = self.typeIndex(type_name orelse implicitTypeName(syms)),
                    .syms = try allocator.dupe(u32, syms),
                };
            }
            keymap.keys[keycode - self.min_keycode] = .{ .groups = groups };
        }
    }

    /// A mapping may name other virtual modifiers (bits 8+); merge their real
    /// bits until nothing changes. A modifier mapped to itself adds nothing.
    fn foldVirtualReferences(self: *Builder, vmod_real: []u8) void {
        var changed = true;
        var rounds: usize = 0;
        while (changed and rounds < vmod_real.len) : (rounds += 1) {
            changed = false;
            for (self.vmods.items, 0..) |name, index| {
                const mapping = self.vmod_mappings.get(name) orelse continue;
                var bits = mapping >> 8;
                var other: usize = 0;
                while (bits != 0) : ({
                    bits >>= 1;
                    other += 1;
                }) {
                    if (bits & 1 == 0 or other == index or other >= vmod_real.len) continue;
                    const merged = vmod_real[index] | vmod_real[other];
                    if (merged != vmod_real[index]) {
                        vmod_real[index] = merged;
                        changed = true;
                    }
                }
            }
        }
    }

    fn resolveAlias(self: *Builder, name: []const u8) []const u8 {
        return self.aliases.get(name) orelse name;
    }

    fn vmodMask(self: *Builder, vmod_real: []const u8, name: []const u8) ?u8 {
        const index = self.vmodIndex(name) orelse return null;
        if (vmod_real[index] == 0) return null;
        return vmod_real[index];
    }

    /// Null when the mask references an unbound virtual modifier.
    fn resolveMask(mask: SymbolicMask, vmod_real: []const u8) ?u8 {
        var real: u8 = @truncate(mask);
        var vmod_bits = mask >> 8;
        var index: usize = 0;
        while (vmod_bits != 0) : ({
            vmod_bits >>= 1;
            index += 1;
        }) {
            if (vmod_bits & 1 == 0) continue;
            if (index >= vmod_real.len or vmod_real[index] == 0) return null;
            real |= vmod_real[index];
        }
        return real;
    }

    fn keyCarries(raw_key: RawKey, sym: u32) bool {
        for (raw_key.groups) |group| {
            const syms = group orelse continue;
            for (syms) |candidate| {
                if (candidate == sym) return true;
            }
        }
        return false;
    }

    /// The group 1, level 1 keysym — what a level1-restricted interpret
    /// matches against.
    fn keyLevelOneSym(raw_key: RawKey) u32 {
        const syms = raw_key.groups[0] orelse return 0;
        if (syms.len == 0) return 0;
        return syms[0];
    }

    fn typeIndex(self: *Builder, name: []const u8) u32 {
        for (self.raw_types.items, 0..) |raw_type, index| {
            if (std.mem.eql(u8, raw_type.name, name)) return @intCast(index);
        }
        // A dump always defines the canonical types it references; if one is
        // missing anyway, TWO_LEVEL keeps Shift working and 0 is the final
        // fallback.
        if (!std.mem.eql(u8, name, "TWO_LEVEL")) return self.typeIndex("TWO_LEVEL");
        return 0;
    }

    /// The canonical implicit type for a key without an explicit one, per
    /// xkbcomp's FindAutomaticType.
    fn implicitTypeName(syms: []const u32) []const u8 {
        switch (syms.len) {
            0, 1 => return "ONE_LEVEL",
            2 => {
                if (keysyms.isAlphaPair(syms[0], syms[1])) return "ALPHABETIC";
                if (keysyms.isKeypad(syms[0]) or keysyms.isKeypad(syms[1])) return "KEYPAD";
                return "TWO_LEVEL";
            },
            3, 4 => {
                if (keysyms.isKeypad(syms[0]) or keysyms.isKeypad(syms[1])) return "FOUR_LEVEL_KEYPAD";
                if (keysyms.isAlphaPair(syms[0], syms[1])) {
                    if (syms.len == 4 and keysyms.isAlphaPair(syms[2], syms[3])) return "FOUR_LEVEL_ALPHABETIC";
                    return "FOUR_LEVEL_SEMIALPHABETIC";
                }
                return "FOUR_LEVEL";
            },
            else => return "FOUR_LEVEL",
        }
    }
};

// ---------------------------------------------------------------------------
// Tokenizer
// ---------------------------------------------------------------------------

const Token = union(enum) {
    ident: []const u8,
    keyname: []const u8,
    string: []const u8,
    number: u32,
    punct: u8,
    end,
};

const Scanner = struct {
    text: []const u8,
    pos: usize = 0,

    fn skipGaps(self: *Scanner) void {
        while (self.pos < self.text.len) {
            const char = self.text[self.pos];
            if (char == ' ' or char == '\t' or char == '\n' or char == '\r') {
                self.pos += 1;
            } else if (char == '/' and self.pos + 1 < self.text.len and self.text[self.pos + 1] == '/') {
                while (self.pos < self.text.len and self.text[self.pos] != '\n') self.pos += 1;
            } else if (char == '#') {
                while (self.pos < self.text.len and self.text[self.pos] != '\n') self.pos += 1;
            } else {
                return;
            }
        }
    }

    fn next(self: *Scanner) !Token {
        self.skipGaps();
        if (self.pos >= self.text.len) return .end;
        const char = self.text[self.pos];
        switch (char) {
            '{', '}', '[', ']', '(', ')', '=', ',', ';', '+', '-', '.', '!', '*' => {
                self.pos += 1;
                return .{ .punct = char };
            },
            '<' => {
                const start = self.pos + 1;
                const close = std.mem.indexOfScalarPos(u8, self.text, start, '>') orelse return error.MalformedKeymap;
                self.pos = close + 1;
                return .{ .keyname = self.text[start..close] };
            },
            '"' => {
                const start = self.pos + 1;
                const close = std.mem.indexOfScalarPos(u8, self.text, start, '"') orelse return error.MalformedKeymap;
                self.pos = close + 1;
                return .{ .string = self.text[start..close] };
            },
            '0'...'9' => {
                const start = self.pos;
                if (char == '0' and self.pos + 1 < self.text.len and (self.text[self.pos + 1] == 'x' or self.text[self.pos + 1] == 'X')) {
                    self.pos += 2;
                    while (self.pos < self.text.len and std.ascii.isHex(self.text[self.pos])) self.pos += 1;
                    const value = std.fmt.parseInt(u32, self.text[start + 2 .. self.pos], 16) catch return error.MalformedKeymap;
                    return .{ .number = value };
                }
                while (self.pos < self.text.len and std.ascii.isDigit(self.text[self.pos])) self.pos += 1;
                // "0x"-less identifiers never start with a digit, but keysym
                // names can be pure digits ("0".."9") — those arrive here and
                // number/keysym ambiguity is harmless: the values coincide
                // only for single digits, which parseSymList treats by value.
                const value = std.fmt.parseInt(u32, self.text[start..self.pos], 10) catch return error.MalformedKeymap;
                return .{ .number = value };
            },
            else => {
                if (!isIdentChar(char)) return error.MalformedKeymap;
                const start = self.pos;
                while (self.pos < self.text.len and isIdentChar(self.text[self.pos])) self.pos += 1;
                return .{ .ident = self.text[start..self.pos] };
            },
        }
    }

    fn isIdentChar(char: u8) bool {
        return std.ascii.isAlphanumeric(char) or char == '_';
    }

    fn peekIsPunct(self: *Scanner, char: u8) !bool {
        const saved = self.pos;
        const token = try self.next();
        self.pos = saved;
        return token == .punct and token.punct == char;
    }

    fn peekIsString(self: *Scanner) !bool {
        const saved = self.pos;
        const token = self.next() catch {
            self.pos = saved;
            return false;
        };
        self.pos = saved;
        return token == .string;
    }

    fn nextIdent(self: *Scanner) ![]const u8 {
        const token = try self.next();
        if (token != .ident) return error.MalformedKeymap;
        return token.ident;
    }

    fn nextString(self: *Scanner) ![]const u8 {
        const token = try self.next();
        if (token != .string) return error.MalformedKeymap;
        return token.string;
    }

    fn nextNumber(self: *Scanner) !u32 {
        const token = try self.next();
        if (token != .number) return error.MalformedKeymap;
        return token.number;
    }

    fn nextKeyname(self: *Scanner) ![]const u8 {
        const token = try self.next();
        if (token != .keyname) return error.MalformedKeymap;
        return token.keyname;
    }

    fn expectIdent(self: *Scanner, expected: []const u8) !void {
        const actual = try self.nextIdent();
        if (!std.mem.eql(u8, actual, expected)) return error.MalformedKeymap;
    }

    fn expectPunct(self: *Scanner, expected: u8) !void {
        const token = try self.next();
        if (token != .punct or token.punct != expected) return error.MalformedKeymap;
    }

    /// Consume through the terminating ';' of the current statement,
    /// balancing any brackets on the way.
    fn skipStatement(self: *Scanner) !void {
        var depth: usize = 0;
        while (true) {
            const token = try self.next();
            switch (token) {
                .punct => |char| switch (char) {
                    '{', '[', '(' => depth += 1,
                    '}', ']', ')' => {
                        if (depth == 0) return error.MalformedKeymap;
                        depth -= 1;
                    },
                    ';' => if (depth == 0) return,
                    else => {},
                },
                .end => return error.MalformedKeymap,
                else => {},
            }
        }
    }

    /// Consume up to (not including) the ',' or '}' ending a key item,
    /// balancing brackets.
    fn skipItem(self: *Scanner) !void {
        var depth: usize = 0;
        while (true) {
            const saved = self.pos;
            const token = try self.next();
            switch (token) {
                .punct => |char| switch (char) {
                    '{', '[', '(' => depth += 1,
                    ']', ')' => {
                        if (depth == 0) return error.MalformedKeymap;
                        depth -= 1;
                    },
                    '}' => {
                        if (depth == 0) {
                            self.pos = saved;
                            return;
                        }
                        depth -= 1;
                    },
                    ',' => if (depth == 0) {
                        self.pos = saved;
                        return;
                    },
                    else => {},
                },
                .end => return error.MalformedKeymap,
                else => {},
            }
        }
    }

    /// Consume a whole block body after its '{', leaving the terminating
    /// ';' for the caller.
    fn skipBlockBody(self: *Scanner) !void {
        var depth: usize = 1;
        while (depth > 0) {
            const token = try self.next();
            switch (token) {
                .punct => |char| switch (char) {
                    '{' => depth += 1,
                    '}' => depth -= 1,
                    else => {},
                },
                .end => return error.MalformedKeymap,
                else => {},
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const kwin_us = @embedFile("testdata/kwin-us.xkb");
const kwin_us_fr = @embedFile("testdata/kwin-us-fr.xkb");
const kwin_us_2026 = @embedFile("testdata/kwin-us-2026.xkb");

test "parses the keymap a 2026 kwin serializes" {
    var keymap = try parse(testing.allocator, kwin_us_2026);
    defer keymap.deinit();

    try testing.expectEqual(@as(u32, 'a'), keymap.keysym(38, 0, 0));
    try testing.expectEqual(@as(u32, 'A'), keymap.keysym(38, mask_shift, 0));
    try testing.expectEqual(@as(u32, '!'), keymap.keysym(10, mask_shift, 0));
    try testing.expectEqual(@as(u32, 0xFF0D), keymap.keysym(36, 0, 0));
}

test "parses a real kwin keymap: alphabetic and two-level keys" {
    var keymap = try parse(testing.allocator, kwin_us);
    defer keymap.deinit();

    // <AC01> = 38 is a/A (ALPHABETIC): shift and caps both give 'A',
    // shift+caps cancels back to 'a'.
    try testing.expectEqual(@as(u32, 'a'), keymap.keysym(38, 0, 0));
    try testing.expectEqual(@as(u32, 'A'), keymap.keysym(38, mask_shift, 0));
    try testing.expectEqual(@as(u32, 'A'), keymap.keysym(38, mask_lock, 0));
    try testing.expectEqual(@as(u32, 'a'), keymap.keysym(38, mask_shift | mask_lock, 0));

    // <AE01> = 10 is 1/exclam (TWO_LEVEL): caps does not shift digits.
    try testing.expectEqual(@as(u32, '1'), keymap.keysym(10, 0, 0));
    try testing.expectEqual(@as(u32, '!'), keymap.keysym(10, mask_shift, 0));
    try testing.expectEqual(@as(u32, '1'), keymap.keysym(10, mask_lock, 0));

    // <RTRN> = 36.
    try testing.expectEqual(@as(u32, 0xFF0D), keymap.keysym(36, 0, 0));
}

test "keypad keys honor NumLock through the virtual modifier" {
    var keymap = try parse(testing.allocator, kwin_us);
    defer keymap.deinit();

    // NumLock resolved from the modifier_map (Mod2).
    try testing.expectEqual(mask_mod2, keymap.num_lock_mask);
    try testing.expectEqual(mask_mod1, keymap.alt_mask);
    try testing.expectEqual(mask_mod4, keymap.super_mask);
    try testing.expectEqual(mask_mod5, keymap.level_three_mask);

    // <KP7> = 79 is KP_Home/KP_7 (KEYPAD type).
    try testing.expectEqual(@as(u32, 0xFF95), keymap.keysym(79, 0, 0));
    try testing.expectEqual(@as(u32, 0xFFB7), keymap.keysym(79, mask_mod2, 0));
}

test "two-group keymap resolves per group with AltGr levels" {
    var keymap = try parse(testing.allocator, kwin_us_fr);
    defer keymap.deinit();

    try testing.expectEqual(@as(usize, 2), keymap.group_names.len);
    try testing.expectEqualStrings("English (US)", keymap.group_names[0]);

    // <AD01> = 24: q/Q in US, a/A/ae/AE in French.
    try testing.expectEqual(@as(u32, 'q'), keymap.keysym(24, 0, 0));
    try testing.expectEqual(@as(u32, 'Q'), keymap.keysym(24, mask_shift, 0));
    try testing.expectEqual(@as(u32, 'a'), keymap.keysym(24, 0, 1));
    try testing.expectEqual(@as(u32, 'A'), keymap.keysym(24, mask_shift, 1));
    // AltGr (LevelThree = Mod5) selects level 3: ae ligature.
    try testing.expectEqual(@as(u32, 0xE6), keymap.keysym(24, mask_mod5, 1));
    try testing.expectEqual(@as(u32, 0xC6), keymap.keysym(24, mask_shift | mask_mod5, 1));

    // French digit row: unshifted is punctuation, shift gives the digit.
    // <AE03> = 12: quotedbl/3/numbersign/sterling.
    try testing.expectEqual(@as(u32, '"'), keymap.keysym(12, 0, 1));
    try testing.expectEqual(@as(u32, '3'), keymap.keysym(12, mask_shift, 1));
    try testing.expectEqual(@as(u32, '#'), keymap.keysym(12, mask_mod5, 1));

    // Groups wrap for out-of-range indices.
    try testing.expectEqual(@as(u32, 'q'), keymap.keysym(24, 0, 2));
}

test "unmapped and out-of-range keycodes return NoSymbol" {
    var keymap = try parse(testing.allocator, kwin_us);
    defer keymap.deinit();

    try testing.expectEqual(@as(u32, 0), keymap.keysym(7, 0, 0));
    try testing.expectEqual(@as(u32, 0), keymap.keysym(100_000, 0, 0));
}

test "malformed input errors instead of crashing" {
    try testing.expectError(error.MalformedKeymap, parse(testing.allocator, "xkb_keymap { xkb_keycodes {"));
    try testing.expectError(error.MalformedKeymap, parse(testing.allocator, "nonsense"));
    var empty = try parse(testing.allocator, "xkb_keymap { };");
    empty.deinit();
}

const std = @import("std");
const testing = std.testing;
const Keymap = @This();
const keysyms = @import("keysym.zig");
const log = std.log.scoped(.xkb);
