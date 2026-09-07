// SPDX-License-Identifier: CC0-1.0

//! Fluxion D3D - loading Direct3D 11 and 12 at run time, and finding out what
//! the machine will actually give you.
//!
//! Nine pieces:
//!
//!   `dll`       opening a system DLL and binding a struct of entry points
//!   `guid`      the 128-bit name COM gives an interface, parsed at compile time
//!   `hresult`   the number every COM call returns, and the Zig error for it
//!   `com`       calling through a vtable, and the reference counting with it
//!   `level`     feature levels: how much of Direct3D a card actually does
//!   `dxgi`      `dxgi.dll`: the factory, the adapters, what they are
//!   `d3d11`     `d3d11.dll`: device, immediate context, granted level
//!   `d3d12`     `d3d12.dll`: device, what it supports, the command queue
//!   `compiler`  `d3dcompiler_47.dll`: HLSL in, bytecode out
//!
//! The four DLLs share one shape, so moving between them is a change of name
//! and nothing else:
//!
//!   `load` / `unload`   open the DLL and resolve its entry points
//!   `entries`           the entry points, with the optional ones as optionals
//!   `library`           the module itself, for a symbol this library missed
//!
//! Direct3D is not linked, it is loaded: `d3d12.dll` is missing on Windows
//! before 10, `CreateDXGIFactory2` on Windows before 8.1, and the debug layers
//! on any machine where nobody installed them. A program that imports those
//! symbols the ordinary way fails to start rather than falling back. So every
//! entry point here is fetched by name and every optional one is an optional,
//! and the whole library allocates nothing.
//!
//! `detect` is the short version: it opens all four, asks each what it can
//! do, and closes them again without creating a device or leaving anything
//! behind.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

comptime {
    if (builtin.os.tag != .windows) @compileError(
        "fluxion-d3d loads Windows system DLLs, so it builds only for a Windows target. " ++
            "Cross-compiling to one from anywhere is fine: -Dtarget=x86_64-windows. " ++
            "The `guid`, `hresult` and `level` modules have no Windows in them and can be " ++
            "imported on their own.",
    );
}

pub const dll = @import("dll.zig");
pub const guid = @import("guid.zig");
pub const hresult = @import("hresult.zig");
pub const com = @import("com.zig");
pub const level = @import("level.zig");
pub const dxgi = @import("dxgi.zig");
pub const d3d11 = @import("d3d11.zig");
pub const d3d12 = @import("d3d12.zig");
pub const compiler = @import("compiler.zig");

/// A loaded DLL and its entry points. See `dll`.
pub const Library = dll.Library;

/// The 128-bit name of a COM interface. See `guid`.
pub const Guid = guid.Guid;

/// What a COM call returns. See `hresult`.
pub const Hresult = hresult.Hresult;

/// Every error a failing `Hresult` becomes. See `hresult`.
pub const Error = hresult.Error;

/// The interface every COM object implements. See `com`.
pub const IUnknown = com.IUnknown;

/// How much of Direct3D a piece of hardware does. See `level`.
pub const FeatureLevel = level.FeatureLevel;

/// `dxgi.dll`. See `dxgi`.
pub const Dxgi = dxgi.Dxgi;

/// `d3d11.dll`. See `d3d11`.
pub const D3d11 = d3d11.D3d11;

/// `d3d12.dll`. See `d3d12`.
pub const D3d12 = d3d12.D3d12;

/// `d3dcompiler_47.dll`. See `compiler`.
pub const Compiler = compiler.Compiler;

/// A lump of bytes the runtime allocated. See `com`.
pub const ID3DBlob = com.ID3DBlob;

/// Shorthand for `Guid.parseComptime`, so an interface identifier reads as
/// `d3d.iid("{189819F1-...}")`.
pub fn iid(comptime text: []const u8) Guid {
    return Guid.parseComptime(text);
}

/// Shorthand for `com.release`: give a reference back, and answer with the
/// count that is left.
pub fn release(object: anytype) u32 {
    return com.release(object);
}

/// Shorthand for `com.releaseAll`, for the end of a function that acquired a
/// handful of objects.
pub fn releaseAll(objects: anytype) void {
    com.releaseAll(objects);
}

// -------------------------------------------------------------------------
// What this machine can do
// -------------------------------------------------------------------------

/// The answer `detect` gives: what the four DLLs on this machine will do,
/// found out by asking them.
pub const Support = struct {
    /// `dxgi.dll` loaded and made a factory. False means there is no graphics
    /// stack here at all, which happens in a container and on a stripped-down
    /// server install.
    dxgi: bool = false,
    /// How many adapters DXGI lists, software ones included.
    adapters: u32 = 0,
    /// How many of those are real hardware. Zero with `dxgi` true is an
    /// ordinary state: the Basic Render Driver is still an adapter.
    hardware_adapters: u32 = 0,
    /// Presenting without waiting for the vertical blank. Needs Windows 10
    /// and a driver that agrees.
    tearing: bool = false,
    /// The highest Direct3D 11 level the default hardware adapter reports, or
    /// null if there is no hardware Direct3D 11 device to be had.
    d3d11: ?FeatureLevel = null,
    /// The same for Direct3D 12. Null on a Windows with no `d3d12.dll`, and
    /// on hardware that does not reach `11_0` under it.
    d3d12: ?FeatureLevel = null,
    /// Direct3D 12 on WARP, the rasteriser Windows implements in software.
    /// Present whatever the hardware is, which is what makes Direct3D 12 code
    /// runnable on a machine with no capable card and on a build server.
    d3d12_warp: ?FeatureLevel = null,
    /// The Graphics Tools feature is installed, so the Direct3D 12 debug layer
    /// can be switched on.
    d3d12_debug_layer: bool = false,
    /// `d3dcompiler_47.dll` is here, so HLSL can be turned into bytecode
    /// without shipping a compiler. False on a server install.
    compiler: bool = false,

    pub fn format(self: Support, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("dxgi          {s}, {d} adapter{s} ({d} hardware)\n", .{
            if (self.dxgi) "yes" else "no",
            self.adapters,
            if (self.adapters == 1) "" else "s",
            self.hardware_adapters,
        });
        try w.print("tearing       {s}\n", .{if (self.tearing) "yes" else "no"});
        try w.writeAll("direct3d 11   ");
        if (self.d3d11) |granted| try w.print("{f}\n", .{granted}) else try w.writeAll("none\n");
        try w.writeAll("direct3d 12   ");
        if (self.d3d12) |granted| try w.print("{f}", .{granted}) else try w.writeAll("none");
        if (self.d3d12_warp) |warp| try w.print("  (warp {f})", .{warp});
        try w.writeAll("\ndebug layer   ");
        try w.writeAll(if (self.d3d12_debug_layer) "installed" else "not installed");
        try w.writeAll("\nhlsl compiler ");
        try w.writeAll(if (self.compiler) "installed" else "not installed");
    }
};

/// Open all four DLLs, ask each what it can do, and close them again.
///
/// Nothing is created and nothing is left behind: the feature levels come from
/// the query forms of the create calls, which negotiate and then stop, and the
/// debug layer is asked for and given straight back rather than switched on.
/// A missing DLL is an answer here rather than a failure, which is why this
/// cannot fail.
pub fn detect() Support {
    var support: Support = .{};

    // Loaded first, because the DXGI walk below wants to ask it about WARP.
    var maybe_d3d12: ?D3d12 = D3d12.load() catch null;
    defer if (maybe_d3d12) |*loaded| loaded.unload();
    if (maybe_d3d12) |loaded| {
        support.d3d12_debug_layer = loaded.debugLayerAvailable();
        support.d3d12 = loaded.highestSupported(null);
    }

    if (D3d11.load()) |loaded| {
        var library = loaded;
        defer library.unload();
        support.d3d11 = library.highestLevel(.hardware);
    } else |_| {}

    if (Compiler.load()) |loaded| {
        var library = loaded;
        defer library.unload();
        support.compiler = true;
    } else |_| {}

    if (Dxgi.load()) |loaded| {
        var library = loaded;
        defer library.unload();

        if (library.createFactory(dxgi.IDXGIFactory1, .{})) |factory| {
            defer _ = com.release(factory);
            support.dxgi = true;
            support.tearing = dxgi.allowsTearing(factory);

            var walk = dxgi.adapters(factory);
            while (walk.next() catch null) |adapter| {
                defer _ = com.release(adapter);
                support.adapters += 1;
                const description = dxgi.describe(adapter) catch continue;
                if (!description.software) support.hardware_adapters += 1;
            }

            if (maybe_d3d12) |loaded12| {
                if (dxgi.warpAdapter(factory)) |warp| {
                    defer _ = com.release(warp);
                    support.d3d12_warp = loaded12.highestSupported(@ptrCast(warp));
                } else |_| {}
            }
        } else |_| {}
    } else |_| {}

    return support;
}

test {
    // Pull each module in so `zig build test` runs its tests too.
    _ = dll;
    _ = guid;
    _ = hresult;
    _ = com;
    _ = level;
    _ = dxgi;
    _ = d3d11;
    _ = d3d12;
    _ = compiler;
}

test "what this machine can do" {
    const support = detect();

    // Whatever the machine is, the report has to be self-consistent.
    try testing.expect(support.hardware_adapters <= support.adapters);
    if (!support.dxgi) try testing.expectEqual(@as(u32, 0), support.adapters);
    if (support.d3d12) |granted| try testing.expect(granted.supportsD3d12());
    if (support.d3d12_warp) |warp| try testing.expect(warp.supportsD3d12());
    // A machine with a Direct3D 12 device has a Direct3D 11 one too: 12 needs
    // 11_0 hardware, and every such card has an 11 driver.
    if (support.d3d12 != null) try testing.expect(support.d3d11 != null);

    // And it prints, which is what it is for.
    var buffer: [512]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{f}", .{support});
    try testing.expect(std.mem.indexOf(u8, text, "direct3d 12") != null);
}

test "the pieces compose" {
    // One adapter, two APIs on it, and every reference given back.
    var dxgi_library = Dxgi.load() catch return error.SkipZigTest;
    defer dxgi_library.unload();

    const factory = try dxgi_library.createFactory(dxgi.IDXGIFactory1, .{});
    defer _ = release(factory);

    // WARP, so this runs with no graphics card in the machine.
    const adapter = dxgi.warpAdapter(factory) catch return error.SkipZigTest;
    defer _ = release(adapter);

    const description = try dxgi.describe(adapter);
    try testing.expect(description.software);
    try testing.expectEqual(dxgi.Vendor.microsoft, description.vendor);

    // Direct3D 11 on it. Naming an adapter is what makes the driver type
    // UNKNOWN, which `Driver` arranges and nothing else can get wrong.
    var d3d11_library = D3d11.load() catch return error.SkipZigTest;
    defer d3d11_library.unload();

    var device11 = try d3d11_library.createDevice(.{ .driver = .{ .adapter = @ptrCast(adapter) } });
    defer device11.release();
    try testing.expect(device11.level.atLeast(.@"11_0"));

    // And Direct3D 12 on the same adapter at the same time, which is allowed:
    // the two runtimes are independent.
    var d3d12_library = D3d12.load() catch return error.SkipZigTest;
    defer d3d12_library.unload();

    const device12 = d3d12_library.createDevice(.{ .adapter = @ptrCast(adapter) }) catch
        return error.SkipZigTest;
    defer _ = release(device12);

    const queue = try d3d12.createCommandQueue(device12, .{});
    defer _ = release(queue);

    // Both agree about the hardware they are running on, because it is the
    // same hardware.
    try testing.expect((try d3d12.highestLevel(device12)).atLeast(device11.level));
}

test "shorthands" {
    try testing.expect(iid("{00000000-0000-0000-C000-000000000046}").eql(IUnknown.iid));
    try testing.expectEqual(Guid.parseComptime("{189819F1-1DB6-4B57-BE54-1821339B85F7}"), d3d12.ID3D12Device.iid);
    try testing.expectEqual(Hresult.s_ok, @as(Hresult, @enumFromInt(0)));
    try testing.expect(FeatureLevel.@"12_1".atLeast(.@"11_0"));
}
