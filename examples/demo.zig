// SPDX-License-Identifier: BSL-1.0

//! A tour of Fluxion D3D. Run it with `zig build example`.
//!
//! It opens the four Direct3D DLLs, says what it found in each, lists the
//! adapters, and then makes a Direct3D 11 device and a Direct3D 12 device on
//! the same adapter and asks both what they got. Nothing is drawn and no
//! window is opened; everything here is what a program does in the first
//! second of its life, before it decides which renderer to run.

const std = @import("std");
const Io = std.Io;
const d3d = @import("fluxion_d3d");

pub fn main(init: std.process.Init) !void {
    _ = init.arena;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout.interface;

    // --- the short version -------------------------------------------------
    // One call: opens all four DLLs, asks each what it can do, closes them
    // again. No device is created and nothing is left behind.
    try out.print("--- what this machine can do ---\n{f}\n", .{d3d.detect()});

    // --- what is actually in the DLLs --------------------------------------
    // Every entry point is fetched by name, and the ones that are not on every
    // Windows are bound as optionals. This is that list, machine by machine.
    try out.writeAll("\n--- entry points ---\n");

    var dxgi = d3d.Dxgi.load() catch {
        try out.writeAll("no dxgi.dll: there is no graphics stack here at all\n");
        return out.flush();
    };
    defer dxgi.unload();
    try out.print("dxgi.dll   CreateDXGIFactory2     {s}\n", .{present(dxgi.entries.CreateDXGIFactory2)});
    try out.print("           DXGIGetDebugInterface1 {s}\n", .{present(dxgi.entries.DXGIGetDebugInterface1)});

    var maybe_d3d11: ?d3d.D3d11 = d3d.D3d11.load() catch null;
    defer if (maybe_d3d11) |*library| library.unload();
    try out.print("d3d11.dll  {s}\n", .{if (maybe_d3d11 == null) "not present" else "loaded"});

    var maybe_d3d12: ?d3d.D3d12 = d3d.D3d12.load() catch null;
    defer if (maybe_d3d12) |*library| library.unload();
    if (maybe_d3d12) |library| {
        try out.print("d3d12.dll  D3D12GetDebugInterface {s}\n", .{present(library.entries.D3D12GetDebugInterface)});
        try out.print("           D3D12GetInterface      {s}\n", .{present(library.entries.D3D12GetInterface)});
    } else {
        try out.writeAll("d3d12.dll  not present: this is Windows 8.1 or older\n");
    }

    if (d3d.Compiler.load()) |loaded| {
        var library = loaded;
        defer library.unload();
        try out.print("d3dcompiler_47.dll  D3DDisassemble {s}\n", .{present(library.entries.D3DDisassemble)});
    } else |_| {
        try out.writeAll("d3dcompiler_47.dll  not present: shaders have to arrive compiled\n");
    }

    // --- the adapters ------------------------------------------------------
    const factory = try dxgi.createFactory(d3d.dxgi.IDXGIFactory1, .{});
    defer _ = d3d.release(factory);

    try out.writeAll("\n--- adapters ---\n");
    var walk = d3d.dxgi.adapters(factory);
    while (try walk.next()) |adapter| {
        // Every object that comes out of DXGI arrives with a reference taken
        // on this program's behalf, so every one needs giving back.
        defer _ = d3d.release(adapter);

        const description = try d3d.dxgi.describe(adapter);
        try out.print("{d}. {f}\n", .{ walk.index - 1, &description });

        // What each runtime would grant on this particular adapter, asked
        // through the query forms that create nothing.
        if (maybe_d3d11) |library| {
            const granted = library.highestLevel(.{ .adapter = @ptrCast(adapter) });
            try out.print("   direct3d 11 {f}\n", .{Level{ .value = granted }});
        }
        if (maybe_d3d12) |library| {
            const granted = library.highestSupported(@ptrCast(adapter));
            try out.print("   direct3d 12 {f}\n", .{Level{ .value = granted }});
        }
    }

    // --- a device on the software rasteriser -------------------------------
    // WARP is part of Windows, so this half of the tour prints the same thing
    // on a workstation and on a build server with no graphics card at all.
    const warp = d3d.dxgi.warpAdapter(factory) catch {
        try out.writeAll("\nno WARP adapter: this is older than Windows 10\n");
        return out.flush();
    };
    defer _ = d3d.release(warp);

    try out.print("\n--- a device on {s} ---\n", .{(try d3d.dxgi.describe(warp)).name()});

    if (maybe_d3d11) |library| {
        // Naming an adapter means the driver type has to be UNKNOWN. That is
        // not something to remember: `Driver` is a union, so the combination
        // that would be E_INVALIDARG cannot be written down.
        var device = try library.createDevice(.{ .driver = .{ .adapter = @ptrCast(warp) } });
        defer device.release();

        // `removedReason` is `S_OK` while the device still works, and says
        // which way it died once it does not.
        try out.print("direct3d 11   feature level {f}, still alive: {f}\n", .{
            device.level,
            device.removedReason(),
        });
    }

    if (maybe_d3d12) |library| {
        const device = try library.createDevice(.{ .adapter = @ptrCast(warp) });
        defer _ = d3d.release(device);

        // Direct3D 12 takes a floor rather than a list, so what the device
        // supports has to be asked for separately.
        try out.print("direct3d 12   feature level {f}, shader model {f}, {d} node\n", .{
            try d3d.d3d12.highestLevel(device),
            try d3d.d3d12.highestShaderModel(device),
            d3d.d3d12.nodeCount(device),
        });

        // A queue is where work goes. Reaching its timestamp frequency runs
        // through six levels of inherited vtable, which is the whole of the
        // COM layout rule in one call.
        const queue = try d3d.d3d12.createCommandQueue(device, .{});
        defer _ = d3d.release(queue);

        var frequency: u64 = 0;
        try queue.vtable.GetTimestampFrequency(queue, &frequency).check();
        try out.print("              queue timestamps at {d} Hz\n", .{frequency});
    }

    try out.flush();
}

fn present(entry: anytype) []const u8 {
    return if (entry == null) "missing" else "there";
}

/// A feature level that may not be there, printed as `none` when it is not.
const Level = struct {
    value: ?d3d.FeatureLevel,

    pub fn format(self: Level, w: *Io.Writer) Io.Writer.Error!void {
        if (self.value) |granted| return w.print("{f}", .{granted});
        try w.writeAll("none");
    }
};
