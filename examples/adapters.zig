// SPDX-License-Identifier: BSL-1.0

//! Every adapter this machine has, and what each runtime would grant on it.
//!
//! Run it with `zig build example-adapters`.
//!
//! Nothing here creates a device. Both runtimes have a query form of their
//! create call - one that negotiates and then stops - so the whole report
//! costs a few milliseconds and leaves nothing behind. That is what a program
//! wants at startup, before it has decided which adapter to run on.

const std = @import("std");
const Io = std.Io;
const d3d = @import("fluxion_d3d");

const com = d3d.com;
const dxgi = d3d.dxgi;

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout.interface;

    var dxgi_library = d3d.Dxgi.load() catch {
        try out.writeAll("no dxgi.dll: there is no graphics stack on this machine\n");
        return out.flush();
    };
    defer dxgi_library.unload();

    var maybe_d3d11: ?d3d.D3d11 = d3d.D3d11.load() catch null;
    defer if (maybe_d3d11) |*library| library.unload();
    var maybe_d3d12: ?d3d.D3d12 = d3d.D3d12.load() catch null;
    defer if (maybe_d3d12) |*library| library.unload();

    const factory = try dxgi_library.createFactory(dxgi.IDXGIFactory1, .{});
    defer _ = com.release(factory);

    var walk = dxgi.adapters(factory);
    while (try walk.next()) |adapter| {
        defer _ = com.release(adapter);
        const description = try dxgi.describe(adapter);

        try out.print("\n{d}. {s}\n", .{ walk.index - 1, description.name() });
        try out.print("   vendor        {t} (0x{X:0>4}), device 0x{X:0>4}, revision {d}\n", .{
            description.vendor,
            @intFromEnum(description.vendor),
            description.device_id,
            description.revision,
        });
        try out.print("   memory        {d} MiB on the card, {d} MiB shared\n", .{
            description.dedicated_video_memory >> 20,
            description.shared_system_memory >> 20,
        });
        // A LUID is how another API - or another process - is told to use
        // this same physical device, and it lasts until the machine reboots.
        try out.print("   luid          0x{X:0>16}\n", .{@as(u64, @bitCast(description.luid.value()))});
        try out.print("   kind          {s}{s}\n", .{
            if (description.software) "software" else "hardware",
            if (description.remote) ", remote" else "",
        });

        if (maybe_d3d11) |library| {
            const granted = library.highestLevel(.{ .adapter = @ptrCast(adapter) });
            try out.writeAll("   direct3d 11   ");
            if (granted) |level| try out.print("{f}\n", .{level}) else try out.writeAll("none\n");
        }
        if (maybe_d3d12) |library| {
            const granted = library.highestSupported(@ptrCast(adapter));
            try out.writeAll("   direct3d 12   ");
            if (granted) |level| try out.print("{f}\n", .{level}) else try out.writeAll("none\n");
        }
    }

    // --- what DXGI would pick --------------------------------------------
    // The supported way to say "the discrete card" rather than reading the
    // descriptions and guessing from the memory sizes. Needs IDXGIFactory6,
    // so Windows 10 1803 and later.
    try out.writeAll("\npreferences\n");
    for ([_]dxgi.GpuPreference{ .high_performance, .minimum_power }) |preference| {
        try out.print("   {t:<17} ", .{preference});
        if (dxgi.adapterByPreference(factory, 0, preference)) |chosen| {
            defer _ = com.release(chosen);
            try out.print("{s}\n", .{(try dxgi.describe(chosen)).name()});
        } else |err| switch (err) {
            error.NoInterface => try out.writeAll("needs IDXGIFactory6, which this Windows has not got\n"),
            else => try out.print("{t}\n", .{err}),
        }
    }

    try out.print("   {s:<17} {s}\n", .{
        "software",
        if (dxgi.warpAdapter(factory)) |warp| blk: {
            defer _ = com.release(warp);
            break :blk (try dxgi.describe(warp)).name();
        } else |_| "no WARP adapter: older than Windows 10",
    });

    // Tearing is a property of the whole stack rather than of one adapter,
    // which is why it is reported here and not above.
    try out.print("\ntearing        {s}\n", .{
        if (dxgi.allowsTearing(factory)) "allowed" else "not allowed",
    });

    try out.flush();
}
