// SPDX-License-Identifier: CC0-1.0

//! Which entry points and which interface versions this Windows actually has.
//!
//! Run it with `zig build example-entrypoints`.
//!
//! This is the report the whole library exists to make possible. Every line is
//! a thing that is present on some Windows and absent on others, and a program
//! that imported any of them the ordinary way would not have started on the
//! machines where the answer is "missing" - the loader would have refused it
//! before `main`, naming an entry point and offering no way to carry on.
//!
//! Two kinds of question are asked here, and they are answered differently. An
//! entry point is a name in a DLL, so `GetProcAddress` decides. An interface
//! is a version of an object, so the object decides, through `QueryInterface`
//! - and `error.NoInterface` from that is the answer, not a fault.

const std = @import("std");
const Io = std.Io;
const d3d = @import("fluxion_d3d");

const com = d3d.com;
const dxgi = d3d.dxgi;

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout.interface;

    // --- the DLLs ---------------------------------------------------------
    try out.writeAll("libraries\n");
    for ([_][:0]const u8{
        "dxgi.dll",
        "d3d11.dll",
        "d3d12.dll",
        "d3dcompiler_47.dll",
        "d3d9.dll",
    }) |name| {
        // Every one of these is loaded from System32 and from nowhere else,
        // which is what stops a file dropped next to the program being loaded
        // instead.
        if (d3d.Library.openSystem(name)) |opened| {
            var library = opened;
            defer library.close();
            try out.print("   {s:<20} there\n", .{name});
        } else |_| {
            try out.print("   {s:<20} missing\n", .{name});
        }
    }

    // --- the entry points inside them -------------------------------------
    try out.writeAll("\nentry points\n");

    if (d3d.Dxgi.load()) |loaded| {
        var library = loaded;
        defer library.unload();
        try report(out, "dxgi.dll", library.entries);
    } else |_| {}

    if (d3d.D3d11.load()) |loaded| {
        var library = loaded;
        defer library.unload();
        try report(out, "d3d11.dll", library.entries);
    } else |_| {}

    if (d3d.D3d12.load()) |loaded| {
        var library = loaded;
        defer library.unload();
        try report(out, "d3d12.dll", library.entries);
    } else |_| {}

    if (d3d.Compiler.load()) |loaded| {
        var library = loaded;
        defer library.unload();
        try report(out, "d3dcompiler_47.dll", library.entries);
    } else |_| {}

    // --- the interface versions -------------------------------------------
    // Each of these arrived in a different Windows, and a factory implements
    // every one up to its own. Asking is how a program finds out which
    // Windows it is running on without asking Windows.
    var dxgi_library = d3d.Dxgi.load() catch return out.flush();
    defer dxgi_library.unload();

    const factory = try dxgi_library.createFactory(dxgi.IDXGIFactory1, .{});
    defer _ = com.release(factory);

    try out.writeAll("\ndxgi interfaces\n");
    inline for (.{
        .{ "IDXGIFactory", dxgi.IDXGIFactory, "Windows Vista" },
        .{ "IDXGIFactory1", dxgi.IDXGIFactory1, "Windows 7" },
        .{ "IDXGIFactory2", dxgi.IDXGIFactory2, "Windows 8" },
        .{ "IDXGIFactory3", dxgi.IDXGIFactory3, "Windows 8.1" },
        .{ "IDXGIFactory4", dxgi.IDXGIFactory4, "Windows 10" },
        .{ "IDXGIFactory5", dxgi.IDXGIFactory5, "Windows 10 1607" },
        .{ "IDXGIFactory6", dxgi.IDXGIFactory6, "Windows 10 1803" },
    }) |entry| {
        try out.print("   {s:<15} {s:<8} {s}\n", .{
            entry[0],
            if (com.implements(factory, entry[1])) "yes" else "no",
            entry[2],
        });
    }

    // The identifier itself, which is the thing that has to be byte-for-byte
    // right for any of the above to work at all.
    try out.print("\nIID_IDXGIFactory6 {f}\n", .{dxgi.IDXGIFactory6.iid});

    try out.flush();
}

/// Walk an entry point table and say which of its fields resolved.
///
/// The table is a struct of function pointers, so the field names *are* the
/// export names - there is no second list to print from and no way for the
/// two to disagree.
fn report(out: *Io.Writer, library: []const u8, entries: anytype) !void {
    try out.print("   {s}\n", .{library});
    inline for (@typeInfo(@TypeOf(entries)).@"struct".fields) |field| {
        const value = @field(entries, field.name);
        const present = if (@typeInfo(field.type) == .optional) value != null else true;
        try out.print("      {s:<38} {s}\n", .{
            field.name,
            if (present) "there" else "missing",
        });
    }
}
