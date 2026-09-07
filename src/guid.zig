// SPDX-License-Identifier: CC0-1.0

//! The 128-bit name COM gives to an interface.
//!
//! Every call that hands back a COM object takes the identifier of the
//! interface it is being asked for - `IID_ID3D12Device`, `IID_IDXGIFactory6` -
//! and returns a pointer only if the object implements it. So a binding to
//! Direct3D needs GUIDs before it needs anything else, and it needs them to be
//! byte-for-byte right: a wrong IID is not a compile error, it is
//! `E_NOINTERFACE` at run time and a null pointer to find the cause of.
//!
//! `parseComptime` reads the form the headers and the documentation write, so
//! an IID can be copied out of `d3d12.h` and pasted in, and a typo is a
//! compile error rather than something to debug:
//!
//! ```zig
//! pub const iid = Guid.parseComptime("{189819F1-1DB6-4B57-BE54-1821339B85F7}");
//! ```
//!
//! A `Guid` is four fields, not sixteen bytes, because that is what the C
//! `GUID` is: three integers and eight loose bytes. Storing it that way means
//! the struct is right on any machine, and it means the *byte* order - the
//! part everyone gets wrong - has to be asked for, through `toBytes` and
//! `Layout`.

const std = @import("std");
const testing = std.testing;

/// Layout-compatible with the C `GUID` and with `std.os.windows.GUID`, so a
/// pointer to one can be passed straight to any function that wants the other.
pub const Guid = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,

    /// `GUID_NULL`. Not a valid interface identifier; useful as a sentinel.
    pub const zero: Guid = .{ .data1 = 0, .data2 = 0, .data3 = 0, .data4 = @splat(0) };

    /// The length of the braced text form, which is what `toString` writes.
    pub const string_len: usize = 38;

    pub const ParseError = error{
        /// A character that is neither a hex digit nor punctuation where
        /// punctuation may go.
        InvalidCharacter,
        /// Not 32 hex digits in the `8-4-4-4-12` grouping.
        InvalidFormat,
    };

    /// Read `{189819F1-1DB6-4B57-BE54-1821339B85F7}`, or the same without the
    /// braces. Either case reads; the four dashes are required, because where
    /// they fall is the only thing that says where one field ends and the next
    /// begins.
    pub fn parse(text: []const u8) ParseError!Guid {
        var body = text;
        if (body.len == string_len and body[0] == '{' and body[body.len - 1] == '}') {
            body = body[1 .. body.len - 1];
        }
        if (body.len != 36) return error.InvalidFormat;
        for ([_]usize{ 8, 13, 18, 23 }) |dash| {
            if (body[dash] != '-') return error.InvalidFormat;
        }

        // 32 hex digits, in the order they are written. The grouping is
        // 8-4-4-4-12, and the last two groups both feed `data4`, which is why
        // the dash at 23 does not begin a new field.
        var digits: [32]u8 = undefined;
        var n: usize = 0;
        for (body) |char| {
            if (char == '-') continue;
            digits[n] = std.fmt.charToDigit(char, 16) catch return error.InvalidCharacter;
            n += 1;
        }

        var self: Guid = undefined;
        self.data1 = @intCast(packDigits(digits[0..8]));
        self.data2 = @intCast(packDigits(digits[8..12]));
        self.data3 = @intCast(packDigits(digits[12..16]));
        for (&self.data4, 0..) |*byte, i| {
            byte.* = digits[16 + i * 2] << 4 | digits[17 + i * 2];
        }
        return self;
    }

    /// Fold a run of hex digits into one integer, most significant first. The
    /// result is a number, so nothing here depends on the machine's byte
    /// order - which is the whole reason `Guid` holds fields and not bytes.
    fn packDigits(digits: []const u8) u32 {
        var value: u32 = 0;
        for (digits) |digit| value = value << 4 | digit;
        return value;
    }

    /// Parse at compile time, so a malformed literal is a compile error rather
    /// than something to handle at run time. This is the one to use for an
    /// IID, which is always a literal.
    pub fn parseComptime(comptime text: []const u8) Guid {
        const parsed = comptime blk: {
            break :blk parse(text) catch
                @compileError("fluxion-d3d: not a guid: " ++ text);
        };
        return parsed;
    }

    /// Two GUIDs name the same interface. `std.meta.eql` does the same thing;
    /// this exists so call sites read as prose.
    pub fn eql(a: Guid, b: Guid) bool {
        return a.data1 == b.data1 and a.data2 == b.data2 and
            a.data3 == b.data3 and std.mem.eql(u8, &a.data4, &b.data4);
    }

    /// Which way round the sixteen bytes go. The same GUID has two byte forms
    /// in the wild, and the difference is a real source of bugs when an
    /// identifier crosses between a Microsoft format and anything else.
    pub const Layout = enum {
        /// The three integer fields in the machine's own order, which on every
        /// machine Windows runs on is little-endian. This is what `@bitCast`ing
        /// a `GUID` gives, what a RIFF chunk holds, and what Windows means by
        /// the bytes of a GUID.
        guid,
        /// The three integer fields big-endian, so the sixteen bytes read in
        /// the same order as the text. This is a UUID as RFC 9562 defines it,
        /// and what almost everything outside Windows means.
        uuid,
    };

    /// The sixteen bytes, in whichever of the two orders the format at hand
    /// uses. `data4` is the same either way: it is bytes already, not a number.
    pub fn toBytes(self: Guid, layout: Layout) [16]u8 {
        const order: std.builtin.Endian = switch (layout) {
            .guid => .little,
            .uuid => .big,
        };
        var bytes: [16]u8 = undefined;
        std.mem.writeInt(u32, bytes[0..4], self.data1, order);
        std.mem.writeInt(u16, bytes[4..6], self.data2, order);
        std.mem.writeInt(u16, bytes[6..8], self.data3, order);
        @memcpy(bytes[8..16], &self.data4);
        return bytes;
    }

    /// The inverse of `toBytes`. Pass the layout the bytes came in, not the
    /// one you wish they had come in.
    pub fn fromBytes(bytes: [16]u8, layout: Layout) Guid {
        const order: std.builtin.Endian = switch (layout) {
            .guid => .little,
            .uuid => .big,
        };
        return .{
            .data1 = std.mem.readInt(u32, bytes[0..4], order),
            .data2 = std.mem.readInt(u16, bytes[4..6], order),
            .data3 = std.mem.readInt(u16, bytes[6..8], order),
            .data4 = bytes[8..16].*,
        };
    }

    /// The braced upper-case form, which is how the registry, the SDK headers
    /// and the Direct3D documentation all write an IID. `parse` reads it back,
    /// and reads the lower-case and unbraced forms too.
    pub fn toString(self: Guid) [string_len]u8 {
        var out: [string_len]u8 = undefined;
        out[0] = '{';
        out[string_len - 1] = '}';
        out[9] = '-';
        out[14] = '-';
        out[19] = '-';
        out[24] = '-';
        writeHex(out[1..9], self.data1);
        writeHex(out[10..14], self.data2);
        writeHex(out[15..19], self.data3);
        writeHex(out[20..24], std.mem.readInt(u16, self.data4[0..2], .big));
        var tail: u48 = 0;
        for (self.data4[2..8]) |byte| tail = tail << 8 | byte;
        writeHex(out[25..37], tail);
        return out;
    }

    /// One hex digit per slot in `out`, most significant first, upper case.
    fn writeHex(out: []u8, value: anytype) void {
        const upper = "0123456789ABCDEF";
        for (out, 0..) |*slot, i| {
            const shift: std.math.Log2Int(@TypeOf(value)) = @intCast((out.len - 1 - i) * 4);
            slot.* = upper[@as(usize, @intCast((value >> shift) & 0xF))];
        }
    }

    pub fn format(self: Guid, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(&self.toString());
    }
};

test "the identifier of IUnknown, field by field" {
    // The one every COM interface derives from, and the one worth checking by
    // hand: if the grouping were wrong, this is where it would show.
    const iid = Guid.parseComptime("{00000000-0000-0000-C000-000000000046}");
    try testing.expectEqual(@as(u32, 0), iid.data1);
    try testing.expectEqual(@as(u16, 0), iid.data2);
    try testing.expectEqual(@as(u16, 0), iid.data3);
    try testing.expectEqualSlices(u8, &.{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 }, &iid.data4);
}

test "a real Direct3D identifier" {
    // IID_ID3D12Device, as `d3d12.h` writes it.
    const iid = Guid.parseComptime("{189819F1-1DB6-4B57-BE54-1821339B85F7}");
    try testing.expectEqual(@as(u32, 0x189819F1), iid.data1);
    try testing.expectEqual(@as(u16, 0x1DB6), iid.data2);
    try testing.expectEqual(@as(u16, 0x4B57), iid.data3);
    try testing.expectEqualSlices(u8, &.{ 0xBE, 0x54, 0x18, 0x21, 0x33, 0x9B, 0x85, 0xF7 }, &iid.data4);
}

test "text goes round" {
    const text = "{189819F1-1DB6-4B57-BE54-1821339B85F7}";
    const iid = try Guid.parse(text);
    try testing.expectEqualStrings(text, &iid.toString());

    // Lower case and no braces read the same.
    const same = try Guid.parse("189819f1-1db6-4b57-be54-1821339b85f7");
    try testing.expect(iid.eql(same));
    try testing.expectEqualStrings(text, &same.toString());
}

test "formatting" {
    var buffer: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{f}", .{Guid.zero});
    try testing.expectEqualStrings("{00000000-0000-0000-0000-000000000000}", text);
}

test "malformed text is refused" {
    try testing.expectError(error.InvalidFormat, Guid.parse(""));
    try testing.expectError(error.InvalidFormat, Guid.parse("189819F1-1DB6-4B57-BE54-1821339B85F"));
    // The dashes are load-bearing: without them the grouping is a guess.
    try testing.expectError(error.InvalidFormat, Guid.parse("189819F11DB64B57BE541821339B85F7"));
    try testing.expectError(error.InvalidCharacter, Guid.parse("189819G1-1DB6-4B57-BE54-1821339B85F7"));
    // A brace on one end only.
    try testing.expectError(error.InvalidFormat, Guid.parse("{189819F1-1DB6-4B57-BE54-1821339B85F7"));
}

test "the two byte layouts differ, and each goes round" {
    const iid = Guid.parseComptime("{189819F1-1DB6-4B57-BE54-1821339B85F7}");

    // As a UUID: the bytes read in the order the text is written.
    const uuid_bytes = iid.toBytes(.uuid);
    try testing.expectEqualSlices(u8, &.{
        0x18, 0x98, 0x19, 0xF1, 0x1D, 0xB6, 0x4B, 0x57,
        0xBE, 0x54, 0x18, 0x21, 0x33, 0x9B, 0x85, 0xF7,
    }, &uuid_bytes);

    // As a GUID: the first three fields turn round, the last eight bytes do
    // not. That is the difference which makes one identifier look like two on
    // either side of a file format.
    const guid_bytes = iid.toBytes(.guid);
    try testing.expectEqualSlices(u8, &.{
        0xF1, 0x19, 0x98, 0x18, 0xB6, 0x1D, 0x57, 0x4B,
        0xBE, 0x54, 0x18, 0x21, 0x33, 0x9B, 0x85, 0xF7,
    }, &guid_bytes);

    try testing.expect(iid.eql(Guid.fromBytes(uuid_bytes, .uuid)));
    try testing.expect(iid.eql(Guid.fromBytes(guid_bytes, .guid)));
    // Reading one layout as the other is exactly the bug this enum is here to
    // stop: it parses, it just names a different interface.
    try testing.expect(!iid.eql(Guid.fromBytes(guid_bytes, .uuid)));
}

test "layout compatible with the C GUID" {
    // Passing a `*const Guid` where a `REFIID` is wanted is only sound if the
    // two structs agree, so check the shape rather than assume it.
    const WindowsGuid = std.os.windows.GUID;
    try testing.expectEqual(@sizeOf(WindowsGuid), @sizeOf(Guid));
    try testing.expectEqual(@alignOf(WindowsGuid), @alignOf(Guid));
    try testing.expectEqual(@offsetOf(WindowsGuid, "Data4"), @offsetOf(Guid, "data4"));

    const iid = Guid.parseComptime("{189819F1-1DB6-4B57-BE54-1821339B85F7}");
    const as_windows: WindowsGuid = @bitCast(iid);
    try testing.expectEqual(@as(u32, 0x189819F1), as_windows.Data1);
}

test "equality" {
    const a = Guid.parseComptime("{00000000-0000-0000-C000-000000000046}");
    const b = Guid.parseComptime("{00000000-0000-0000-C000-000000000047}");
    try testing.expect(a.eql(a));
    try testing.expect(!a.eql(b));
    try testing.expect(!a.eql(Guid.zero));
}
