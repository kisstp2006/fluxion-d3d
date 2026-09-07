// SPDX-License-Identifier: CC0-1.0

//! Saving what came out of the GPU, so an example with a window in it can be
//! looked at without one.
//!
//! `render11.Offscreen` renders into a texture and reads the pixels back, which
//! is how the tests check that a triangle landed where it should. The same
//! pixels are worth keeping when the question is "what does it look like"
//! rather than "is this pixel red", and a PNG is the shortest way from a byte
//! array to something anybody can open.
//!
//! Nothing here is Direct3D, and nothing here is part of the library.
//!
//! The encoder is the minimum a PNG needs: one `IHDR`, one `IDAT` holding a
//! zlib stream of the rows, one `IEND`, and a CRC on each. Every row is
//! prefixed with a zero, which is PNG's way of saying "this row is not
//! predicted from the one above" - the filters that make PNGs small are worth
//! having in an image library and are not worth having here.

const std = @import("std");
const Io = std.Io;

/// Write `width` by `height` pixels as a PNG.
///
/// `pixels` is RGBA, eight bits a channel, `row_pitch` bytes from one row to
/// the next - which is not the same as `width * 4`, because a driver pads its
/// rows to suit itself. The alpha is dropped: these are opaque frames, and
/// three channels is a quarter less to compress.
pub fn writePng(
    gpa: std.mem.Allocator,
    io: Io,
    path: []const u8,
    width: u32,
    height: u32,
    pixels: []const u8,
    row_pitch: usize,
) !void {
    // The rows, each behind the filter byte PNG puts in front of it, and with
    // the alpha channel dropped on the way.
    const row_bytes = 1 + width * 3;
    const raw = try gpa.alloc(u8, row_bytes * height);
    defer gpa.free(raw);

    for (0..height) |y| {
        const destination = raw[y * row_bytes ..][0..row_bytes];
        destination[0] = 0; // filter 0: this row is not predicted from another
        const source = pixels[y * row_pitch ..][0 .. width * 4];
        for (0..width) |x| @memcpy(destination[1 + x * 3 ..][0..3], source[x * 4 ..][0..3]);
    }

    // ... deflated, in the zlib wrapper PNG asks for. The sink is sized for
    // the case where compression achieves nothing, which is the only bound
    // that holds for arbitrary pixels.
    const scratch = try gpa.alloc(u8, raw.len + 64 * 1024);
    defer gpa.free(scratch);
    var deflated: Io.Writer = .fixed(scratch);

    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);

    var compress: std.compress.flate.Compress = try .init(&deflated, window, .zlib, .default);
    try compress.writer.writeAll(raw);
    try compress.finish();

    var file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var out = file.writer(io, &buffer);
    const w = &out.interface;

    try w.writeAll(&signature);

    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], width, .big);
    std.mem.writeInt(u32, header[4..8], height, .big);
    header[8] = 8; // bits per channel
    header[9] = 2; // colour type 2: red, green and blue, no alpha
    header[10] = 0; // the only compression method there is
    header[11] = 0; // the only filter method there is
    header[12] = 0; // not interlaced
    try writeChunk(w, "IHDR", &header);

    try writeChunk(w, "IDAT", deflated.buffered());
    try writeChunk(w, "IEND", "");

    try w.flush();
}

const signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };

/// Length, type, data, and a CRC over the type and the data - which is every
/// chunk in the format.
fn writeChunk(w: *Io.Writer, comptime kind: *const [4]u8, data: []const u8) !void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(kind);
    try w.writeAll(data);

    var crc = crc32(kind);
    crc = crc32Continue(crc, data);
    try w.writeInt(u32, crc, .big);
}

/// CRC-32, the one PNG uses, which is the one everything uses.
fn crc32(bytes: []const u8) u32 {
    return crc32Continue(0, bytes);
}

fn crc32Continue(previous: u32, bytes: []const u8) u32 {
    var state = ~previous;
    for (bytes) |byte| {
        state = crc_table[(state ^ byte) & 0xFF] ^ (state >> 8);
    }
    return ~state;
}

/// One byte's worth of polynomial division, precomputed at compile time. The
/// polynomial is the reflected 0xEDB88320, which is what every 32-bit CRC in
/// the wild means by CRC-32.
const crc_table: [256]u32 = blk: {
    @setEvalBranchQuota(10_000);
    var table: [256]u32 = undefined;
    for (&table, 0..) |*slot, i| {
        var remainder: u32 = @intCast(i);
        for (0..8) |_| {
            remainder = if (remainder & 1 != 0)
                (remainder >> 1) ^ 0xEDB88320
            else
                remainder >> 1;
        }
        slot.* = remainder;
    }
    break :blk table;
};

test "the check value every CRC-32 agrees on" {
    try std.testing.expectEqual(@as(u32, 0xCBF43926), crc32("123456789"));
    try std.testing.expectEqual(@as(u32, 0), crc32(""));
}

test "a chunk carries its own length and checksum" {
    var buffer: [64]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try writeChunk(&writer, "IEND", "");

    // Four bytes of length, four of type, no data, four of CRC - and the CRC
    // of an empty IEND is the one every PNG in the world ends with.
    const written = writer.buffered();
    try std.testing.expectEqual(@as(usize, 12), written.len);
    try std.testing.expectEqualSlices(u8, &.{
        0, 0, 0, 0, 'I', 'E', 'N', 'D', 0xAE, 0x42, 0x60, 0x82,
    }, written);
}
