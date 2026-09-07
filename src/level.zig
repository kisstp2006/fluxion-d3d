// SPDX-License-Identifier: BSL-1.0

//! Feature levels: how much of Direct3D a piece of hardware actually does.
//!
//! A feature level is not a version of the API. It is a fixed bundle of
//! capabilities - shader model, texture size, render targets, compute shaders -
//! that a card either meets in full or not at all. Direct3D 11 and 12 are two
//! APIs over the same ladder, which is why the same `12_0` appears in both.
//!
//! Both create calls take a level and answer with one: the 11 call takes a
//! list, tries it in order, and reports what it settled on; the 12 call takes
//! the lowest that will do and fails below it. Two things follow, and both
//! bite:
//!
//!   * The list must be in descending order. It is tried in order, not sorted,
//!     so a list that starts at `11_0` gets `11_0` on a card that could have
//!     done `12_1`.
//!   * A level the runtime has never heard of is `E_INVALIDARG`, not a level
//!     that gets skipped: passing `12_2` to a Windows 8 machine fails the whole
//!     call. The answer is to try the long list and, on `E_INVALIDARG`, a
//!     shorter one - which is what `range` is for.
//!
//! Passing no list means "whatever this runtime knows", which changes from one
//! Windows to the next. A program wanting the same answer everywhere passes its
//! own list.

const std = @import("std");
const testing = std.testing;

/// `D3D_FEATURE_LEVEL`. The numbers are the SDK's, and they sort: a higher
/// value is a strictly larger set of capabilities, so `atLeast` is a
/// comparison and nothing more.
///
/// Non-exhaustive, because the ladder grows: a future `13_0` from a newer
/// runtime still arrives as a `FeatureLevel` and still compares correctly.
pub const FeatureLevel = enum(u32) {
    /// `1_0_CORE`: compute and copy only, no raster pipeline. What a machine
    /// learning accelerator or a compute-only device reports. It sits below
    /// everything else here, which is also where it sorts.
    core_1_0 = 0x1000,
    @"9_1" = 0x9100,
    @"9_2" = 0x9200,
    @"9_3" = 0x9300,
    @"10_0" = 0xA000,
    @"10_1" = 0xA100,
    /// The floor for Direct3D 12: `D3D12CreateDevice` refuses anything lower.
    @"11_0" = 0xB000,
    @"11_1" = 0xB100,
    @"12_0" = 0xC000,
    @"12_1" = 0xC100,
    @"12_2" = 0xC200,
    _,

    /// Every level above, highest first - which is the order both create calls
    /// want a list in.
    pub const all = [_]FeatureLevel{
        .@"12_2", .@"12_1", .@"12_0",
        .@"11_1", .@"11_0", .@"10_1",
        .@"10_0", .@"9_3",  .@"9_2",
        .@"9_1",
    };

    /// The lowest level Direct3D 12 will give a device for.
    pub const d3d12_minimum: FeatureLevel = .@"11_0";

    /// 11 in `11_0`.
    pub fn major(self: FeatureLevel) u8 {
        return @intCast(@intFromEnum(self) >> 12);
    }

    /// 0 in `11_0`.
    pub fn minor(self: FeatureLevel) u8 {
        return @intCast(@intFromEnum(self) >> 8 & 0xF);
    }

    /// Does this level include everything `other` promises? The ladder is
    /// totally ordered, so this really is just `>=`.
    pub fn atLeast(self: FeatureLevel, other: FeatureLevel) bool {
        return @intFromEnum(self) >= @intFromEnum(other);
    }

    /// Could `D3D12CreateDevice` succeed at this level? A card that reports
    /// `10_1` under Direct3D 11 has no Direct3D 12 device to give.
    pub fn supportsD3d12(self: FeatureLevel) bool {
        return self.atLeast(d3d12_minimum);
    }

    /// `12_1`. The `1_0_CORE` level prints under its SDK name rather than as
    /// `1_0`, because that is not what it is called anywhere else.
    pub fn format(self: FeatureLevel, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self == .core_1_0) return w.writeAll("1_0_CORE");
        try w.print("{d}_{d}", .{ self.major(), self.minor() });
    }

    /// Read `11_0`, `11.0` or `1_0_core`, in either case. Null for anything
    /// else - including a well-formed pair of numbers that is not a level, so
    /// `13_7` does not quietly become a value nothing supports.
    pub fn parse(text: []const u8) ?FeatureLevel {
        if (std.ascii.eqlIgnoreCase(text, "1_0_core")) return .core_1_0;

        const split = std.mem.indexOfAny(u8, text, "_.") orelse return null;
        const high = std.fmt.parseInt(u8, text[0..split], 10) catch return null;
        const low = std.fmt.parseInt(u8, text[split + 1 ..], 10) catch return null;
        if (high > 15 or low > 15) return null;

        const value = @as(u32, high) << 12 | @as(u32, low) << 8;
        for (all) |candidate| {
            if (@intFromEnum(candidate) == value) return candidate;
        }
        return null;
    }

    /// The list to hand a create call: every level from `highest` down to
    /// `lowest`, in that order.
    ///
    /// A comptime slice of a constant array, so it costs nothing at run time
    /// and the bounds are checked at build:
    ///
    /// ```zig
    /// // Everything this program can use, best first.
    /// const wanted = FeatureLevel.range(.@"12_1", .@"11_0");
    /// // And the fallback for a runtime that predates 12_1.
    /// const older = FeatureLevel.range(.@"11_0", .@"11_0");
    /// ```
    pub fn range(comptime highest: FeatureLevel, comptime lowest: FeatureLevel) []const FeatureLevel {
        return comptime blk: {
            if (!highest.atLeast(lowest)) @compileError(
                "fluxion-d3d: feature level range runs the wrong way; highest comes first",
            );
            var from: ?usize = null;
            var to: ?usize = null;
            for (all, 0..) |candidate, i| {
                if (candidate == highest) from = i;
                if (candidate == lowest) to = i;
            }
            const start = from orelse @compileError(
                "fluxion-d3d: not a listed feature level: " ++ @tagName(highest),
            );
            const end = to orelse @compileError(
                "fluxion-d3d: not a listed feature level: " ++ @tagName(lowest),
            );
            const frozen = all[start .. end + 1].*;
            break :blk &frozen;
        };
    }

    /// Everything from the top of the ladder down to `lowest`. The list to
    /// pass when the program wants the best available and has a floor below
    /// which it would rather fail than run.
    pub fn atOrAbove(comptime lowest: FeatureLevel) []const FeatureLevel {
        return range(all[0], lowest);
    }
};

test "the ladder is ordered" {
    try testing.expect(FeatureLevel.@"12_1".atLeast(.@"11_0"));
    try testing.expect(FeatureLevel.@"11_0".atLeast(.@"11_0"));
    try testing.expect(!FeatureLevel.@"10_1".atLeast(.@"11_0"));

    // `all` is descending, which is the order the create calls need.
    for (FeatureLevel.all[1..], 0..) |level, i| {
        try testing.expect(FeatureLevel.all[i].atLeast(level));
        try testing.expect(FeatureLevel.all[i] != level);
    }

    // The compute-only level sits below all of them.
    for (FeatureLevel.all) |level| {
        try testing.expect(level.atLeast(.core_1_0));
    }
}

test "major and minor" {
    try testing.expectEqual(@as(u8, 11), FeatureLevel.@"11_0".major());
    try testing.expectEqual(@as(u8, 0), FeatureLevel.@"11_0".minor());
    try testing.expectEqual(@as(u8, 12), FeatureLevel.@"12_2".major());
    try testing.expectEqual(@as(u8, 2), FeatureLevel.@"12_2".minor());
    try testing.expectEqual(@as(u8, 9), FeatureLevel.@"9_3".major());
    try testing.expectEqual(@as(u8, 3), FeatureLevel.@"9_3".minor());
}

test "what Direct3D 12 will take" {
    try testing.expect(FeatureLevel.@"11_0".supportsD3d12());
    try testing.expect(FeatureLevel.@"12_2".supportsD3d12());
    // A card that tops out here has a Direct3D 11 device and no 12 one, which
    // is worth saying before the create call rather than after it.
    try testing.expect(!FeatureLevel.@"10_1".supportsD3d12());
    try testing.expect(!FeatureLevel.core_1_0.supportsD3d12());
}

test "text goes round" {
    var buffer: [32]u8 = undefined;
    for (FeatureLevel.all) |level| {
        const text = try std.fmt.bufPrint(&buffer, "{f}", .{level});
        try testing.expectEqual(level, FeatureLevel.parse(text).?);
    }

    try testing.expectEqualStrings("11_0", try std.fmt.bufPrint(&buffer, "{f}", .{FeatureLevel.@"11_0"}));
    try testing.expectEqualStrings("12_2", try std.fmt.bufPrint(&buffer, "{f}", .{FeatureLevel.@"12_2"}));
    try testing.expectEqualStrings("1_0_CORE", try std.fmt.bufPrint(&buffer, "{f}", .{FeatureLevel.core_1_0}));

    // A dot reads too, since that is how people say it out loud.
    try testing.expectEqual(FeatureLevel.@"11_1", FeatureLevel.parse("11.1").?);
    try testing.expectEqual(FeatureLevel.core_1_0, FeatureLevel.parse("1_0_CORE").?);
}

test "text that is not a level" {
    try testing.expectEqual(@as(?FeatureLevel, null), FeatureLevel.parse(""));
    try testing.expectEqual(@as(?FeatureLevel, null), FeatureLevel.parse("11"));
    try testing.expectEqual(@as(?FeatureLevel, null), FeatureLevel.parse("eleven_zero"));
    // Well formed, and still not a level anything supports.
    try testing.expectEqual(@as(?FeatureLevel, null), FeatureLevel.parse("13_7"));
    try testing.expectEqual(@as(?FeatureLevel, null), FeatureLevel.parse("11_9"));
}

test "the list a create call wants" {
    const wanted = FeatureLevel.range(.@"12_1", .@"11_0");
    try testing.expectEqualSlices(FeatureLevel, &.{
        .@"12_1", .@"12_0", .@"11_1", .@"11_0",
    }, wanted);

    // One level is a list of one, which is the fallback after E_INVALIDARG.
    try testing.expectEqualSlices(FeatureLevel, &.{.@"11_0"}, FeatureLevel.range(.@"11_0", .@"11_0"));

    // And the whole ladder, which is what `atOrAbove` at the bottom gives.
    try testing.expectEqualSlices(FeatureLevel, &FeatureLevel.all, FeatureLevel.atOrAbove(.@"9_1"));
    try testing.expectEqual(@as(usize, 5), FeatureLevel.atOrAbove(.@"11_0").len);
}

test "a level from a newer runtime still behaves" {
    // Nothing here knows what this is, and everything still works: it sorts
    // above 12_2, it prints, and it does not pretend to be a known value.
    const future: FeatureLevel = @enumFromInt(0xD000);
    try testing.expect(future.atLeast(.@"12_2"));
    try testing.expect(future.supportsD3d12());
    try testing.expectEqual(@as(u8, 13), future.major());

    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("13_0", try std.fmt.bufPrint(&buffer, "{f}", .{future}));
}
