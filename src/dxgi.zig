// SPDX-License-Identifier: CC0-1.0

//! `dxgi.dll`: the factory, the adapters it lists, and what they are.
//!
//! DXGI is the part of the stack that has nothing to do with drawing. It knows
//! which graphics adapters exist, which monitors hang off them, how a back
//! buffer reaches the screen, and how a device is told it has been lost.
//! Direct3D 11 and Direct3D 12 both sit on it, which is why finding out what a
//! machine can do starts here and not in either of them.
//!
//! ```zig
//! var dxgi = try Dxgi.load();
//! defer dxgi.unload();
//!
//! const factory = try dxgi.createFactory(IDXGIFactory1, .{});
//! defer _ = com.release(factory);
//!
//! var it = adapters(factory);
//! while (try it.next()) |adapter| {
//!     defer _ = com.release(adapter);
//!     const desc = try describe(adapter);
//!     std.debug.print("{f}\n", .{desc});
//! }
//! ```
//!
//! **Versions.** DXGI has been extended eight times and each extension is a
//! new interface rather than a new function, so what a machine can do is found
//! out by asking an object whether it is also something newer -
//! `com.queryInterface(factory, IDXGIFactory6)` - and taking `NoInterface` for
//! an answer. `IDXGIFactory1` is the floor: it has been in every Windows since
//! 7. Tearing control needs `IDXGIFactory5`, and picking the discrete GPU by
//! name rather than by guessing at its description needs `IDXGIFactory6`.

const std = @import("std");
const testing = std.testing;

const com = @import("com.zig");
const dll = @import("dll.zig");
const Guid = @import("guid.zig").Guid;
const hresult = @import("hresult.zig");

const Hresult = hresult.Hresult;
const Error = hresult.Error;
const IUnknown = com.IUnknown;

/// A `BOOL`: zero is false and anything else is true, which is not the same
/// shape as a Zig `bool` and so is kept as the integer it is.
const Bool = c_int;

// -------------------------------------------------------------------------
// The library
// -------------------------------------------------------------------------

/// `dxgi.dll`, loaded, with its entry points resolved.
pub const Dxgi = struct {
    library: dll.Library,
    entries: Entries,

    /// What `dxgi.dll` exports, and when each one arrived.
    pub const Entries = struct {
        /// Windows 7. The one to use: it is everywhere, and the factory it
        /// makes can be asked for any newer interface.
        CreateDXGIFactory1: *const fn (*const Guid, *?*anyopaque) callconv(.winapi) Hresult,
        /// Windows Vista. Still exported, and superseded: a factory from this
        /// one does not notice adapters being added or removed.
        CreateDXGIFactory: ?*const fn (*const Guid, *?*anyopaque) callconv(.winapi) Hresult = null,
        /// Windows 8.1, and the only way to ask for the DXGI debug layer.
        CreateDXGIFactory2: ?*const fn (u32, *const Guid, *?*anyopaque) callconv(.winapi) Hresult = null,
        /// Windows 8.1, and only when the Graphics Tools feature is installed.
        DXGIGetDebugInterface1: ?*const fn (u32, *const Guid, *?*anyopaque) callconv(.winapi) Hresult = null,
    };

    pub const LoadError = dll.OpenError || error{SymbolNotFound};

    pub fn load() LoadError!Dxgi {
        var library = try dll.Library.openSystem("dxgi.dll");
        errdefer library.close();
        return .{ .library = library, .entries = try library.bind(Entries) };
    }

    /// Give the module back. Every factory made through it must be released
    /// first: the code they call lives in the DLL.
    pub fn unload(self: *Dxgi) void {
        self.library.close();
        self.* = undefined;
    }

    pub const FactoryOptions = struct {
        /// Turn on DXGI's own debug messages. Needs `CreateDXGIFactory2`,
        /// which is Windows 8.1 and later, so asking for it on anything older
        /// is `error.Unsupported` rather than a factory without it - a debug
        /// flag that silently did nothing would be worse than a failure.
        debug: bool = false,
    };

    /// Make a factory, as whichever interface is wanted. `IDXGIFactory1` is
    /// the safe request; anything newer fails on a Windows that predates it,
    /// which is a fine way to find out, and `com.queryInterface` is the other
    /// way.
    pub fn createFactory(self: Dxgi, comptime T: type, options: FactoryOptions) Error!*T {
        var raw: ?*anyopaque = null;
        const result = if (options.debug) blk: {
            const create = self.entries.CreateDXGIFactory2 orelse return error.Unsupported;
            break :blk create(create_factory_debug, com.iidOf(T), &raw);
        } else self.entries.CreateDXGIFactory1(com.iidOf(T), &raw);
        return com.received(T, result, raw);
    }
};

/// `DXGI_CREATE_FACTORY_DEBUG`.
const create_factory_debug: u32 = 0x1;

// -------------------------------------------------------------------------
// Walking the adapters
// -------------------------------------------------------------------------

/// Every adapter DXGI knows about, in its own order - which puts the one the
/// desktop is drawn on first and is otherwise not a ranking.
///
/// Each adapter comes with a reference already taken, so each needs its own
/// `release`. Stopping early is fine; the iterator holds nothing.
pub const Adapters = struct {
    factory: *IDXGIFactory1,
    index: u32 = 0,

    pub fn next(self: *Adapters) Error!?*IDXGIAdapter1 {
        var adapter: ?*IDXGIAdapter1 = null;
        const result = self.factory.vtable.EnumAdapters1(self.factory, self.index, &adapter);
        // Running off the end is how enumeration stops, not a failure.
        if (result == .dxgi_error_not_found) return null;
        try result.check();
        self.index += 1;
        return adapter orelse error.NullPointer;
    }
};

pub fn adapters(factory: *IDXGIFactory1) Adapters {
    return .{ .factory = factory };
}

/// The WARP adapter: the rasteriser Windows implements in software, which
/// draws the same picture as hardware would, slowly, on a machine with no
/// usable GPU at all. It is what makes Direct3D 12 testable on a build server.
///
/// Needs `IDXGIFactory4`, so Windows 10 and later.
pub fn warpAdapter(factory: *IDXGIFactory1) Error!*IDXGIAdapter1 {
    const factory4 = try com.queryInterface(factory, IDXGIFactory4);
    defer _ = com.release(factory4);

    var raw: ?*anyopaque = null;
    const result = factory4.vtable.EnumWarpAdapter(factory4, com.iidOf(IDXGIAdapter1), &raw);
    return com.received(IDXGIAdapter1, result, raw);
}

/// The `index`th adapter in the order `preference` asks for, rather than in
/// DXGI's own order. This is the supported way to say "the discrete card, not
/// the one built into the processor"; the old way was to read the
/// descriptions and guess from the memory sizes.
///
/// Needs `IDXGIFactory6`, so Windows 10 1803 and later. `error.NotFound` at
/// the end of the list, as with `Adapters`.
pub fn adapterByPreference(
    factory: *IDXGIFactory1,
    index: u32,
    preference: GpuPreference,
) Error!*IDXGIAdapter1 {
    const factory6 = try com.queryInterface(factory, IDXGIFactory6);
    defer _ = com.release(factory6);

    var raw: ?*anyopaque = null;
    const result = factory6.vtable.EnumAdapterByGpuPreference(
        factory6,
        index,
        preference,
        com.iidOf(IDXGIAdapter1),
        &raw,
    );
    return com.received(IDXGIAdapter1, result, raw);
}

/// Can this machine present without waiting for the vertical blank? The
/// question every swap chain since Windows 10 wants answered before it picks
/// its flags, and the answer is a property of the whole stack rather than of
/// one adapter.
///
/// False on anything older than `IDXGIFactory5`, which is the right answer:
/// a runtime that cannot be asked cannot do it.
pub fn allowsTearing(factory: *IDXGIFactory1) bool {
    const factory5 = com.queryInterface(factory, IDXGIFactory5) catch return false;
    defer _ = com.release(factory5);

    var allowed: Bool = 0;
    const result = factory5.vtable.CheckFeatureSupport(
        factory5,
        .present_allow_tearing,
        &allowed,
        @sizeOf(Bool),
    );
    return result.succeeded() and allowed != 0;
}

// -------------------------------------------------------------------------
// What an adapter is
// -------------------------------------------------------------------------

/// An adapter, in a shape that is convenient rather than one that matches a C
/// struct: the name as UTF-8, the memory sizes widened to `u64` so a 32-bit
/// build reports the same numbers, and the flags unpacked.
pub const Description = struct {
    /// UTF-8. Three bytes per UTF-16 code unit is the worst case for anything
    /// inside the basic plane, and a surrogate pair costs four bytes for two
    /// units, so this is always enough.
    name_buffer: [3 * 128]u8,
    name_len: usize,
    vendor: Vendor,
    device_id: u32,
    revision: u32,
    /// Memory on the card itself.
    dedicated_video_memory: u64,
    /// System memory set aside for the card at boot, which a card with its own
    /// memory does not have.
    dedicated_system_memory: u64,
    /// System memory the card may borrow.
    shared_system_memory: u64,
    /// Locally unique, for this boot only. The handle to pass when another API
    /// - `EnumAdapterByLuid`, or Vulkan - has to be told to use this same
    /// physical device.
    luid: Luid,
    /// No hardware behind it. WARP and the Microsoft Basic Render Driver both
    /// say so here, and both will make a device that works.
    software: bool,
    /// Not attached to this session's display.
    remote: bool,

    /// The name the driver reports, as UTF-8.
    pub fn name(self: *const Description) []const u8 {
        return self.name_buffer[0..self.name_len];
    }

    pub fn format(self: *const Description, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s} [{t} {X:0>4}]", .{ self.name(), self.vendor, self.device_id });
        if (self.dedicated_video_memory != 0) {
            try w.print(" {d} MiB", .{self.dedicated_video_memory >> 20});
        }
        if (self.software) try w.writeAll(" (software)");
        if (self.remote) try w.writeAll(" (remote)");
    }
};

/// Read an adapter's description. Nothing is allocated: the name is copied
/// into the returned value.
pub fn describe(adapter: *IDXGIAdapter1) Error!Description {
    var raw: AdapterDesc1 = undefined;
    try adapter.vtable.GetDesc1(adapter, &raw).check();

    // The description is a fixed 128-unit field padded with zeros, not a
    // counted string, so the end has to be found.
    const wide = std.mem.sliceTo(&raw.description, 0);

    var self: Description = .{
        .name_buffer = undefined,
        .name_len = 0,
        .vendor = @enumFromInt(raw.vendor_id),
        .device_id = raw.device_id,
        .revision = raw.revision,
        .dedicated_video_memory = raw.dedicated_video_memory,
        .dedicated_system_memory = raw.dedicated_system_memory,
        .shared_system_memory = raw.shared_system_memory,
        .luid = raw.adapter_luid,
        .software = raw.flags.software,
        .remote = raw.flags.remote,
    };
    // A driver that reports a malformed name is not worth failing over, so an
    // unconvertible one simply comes back empty.
    self.name_len = std.unicode.utf16LeToUtf8(&self.name_buffer, wide) catch 0;
    return self;
}

/// The PCI vendor identifier the driver reports. Non-exhaustive: this is the
/// PCI-SIG list, and anybody can appear on it.
pub const Vendor = enum(u32) {
    amd = 0x1002,
    imagination = 0x1010,
    nvidia = 0x10DE,
    arm = 0x13B5,
    /// WARP and the Basic Render Driver, which are Windows itself.
    microsoft = 0x1414,
    qualcomm = 0x5143,
    intel = 0x8086,
    _,
};

/// `LUID`. Unique for as long as the machine stays up, and no longer.
pub const Luid = extern struct {
    low: u32,
    high: i32,

    /// The two halves as the single number other APIs usually want.
    pub fn value(self: Luid) i64 {
        return @as(i64, self.high) << 32 | self.low;
    }

    pub fn eql(a: Luid, b: Luid) bool {
        return a.low == b.low and a.high == b.high;
    }
};

/// `DXGI_ADAPTER_FLAG`.
pub const AdapterFlags = packed struct(u32) {
    remote: bool = false,
    software: bool = false,
    _reserved: u30 = 0,
};

/// `DXGI_ADAPTER_DESC1`, exactly as the C header lays it out.
pub const AdapterDesc1 = extern struct {
    description: [128]u16,
    vendor_id: u32,
    device_id: u32,
    subsystem_id: u32,
    revision: u32,
    dedicated_video_memory: usize,
    dedicated_system_memory: usize,
    shared_system_memory: usize,
    adapter_luid: Luid,
    flags: AdapterFlags,
};

/// `DXGI_GPU_PREFERENCE`.
pub const GpuPreference = enum(u32) {
    /// DXGI's own order, which is what `Adapters` walks.
    unspecified = 0,
    /// The integrated part first, for a program that would rather save power.
    minimum_power = 1,
    /// The discrete card first.
    high_performance = 2,
};

/// `DXGI_FEATURE`. One member so far.
pub const Feature = enum(u32) {
    present_allow_tearing = 0,
    _,
};

/// `DXGI_MWA_*`: what DXGI should stop doing to a window behind the
/// application's back. `no_alt_enter` is the one almost everybody wants, since
/// the alternative is DXGI changing the display mode on a keystroke.
pub const WindowAssociation = packed struct(u32) {
    no_window_changes: bool = false,
    no_alt_enter: bool = false,
    no_print_screen: bool = false,
    _reserved: u29 = 0,
};

// -------------------------------------------------------------------------
// The interfaces
//
// Each vtable holds its base as its first field, which is the layout C++
// gives them, so a derived pointer is a base pointer and no slot is written
// out twice. Slots this library does not call keep their names and are typed
// as opaque pointers: the layout stays right, and reaching one of them means
// declaring it properly first.
// -------------------------------------------------------------------------

/// `IDXGIObject`: everything in DXGI, including the factory, is one.
pub const IDXGIObject = extern struct {
    vtable: *const VTable,

    pub const iid = Guid.parseComptime("{AEC22FB8-76F3-4639-9BE0-28EB43A67A2E}");

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        GetPrivateData: *const anyopaque,
        /// The object that made this one: an adapter's factory, an output's
        /// adapter.
        GetParent: *const fn (*IDXGIObject, *const Guid, *?*anyopaque) callconv(.winapi) Hresult,
    };
};

/// `IDXGIAdapter`: one graphics adapter.
pub const IDXGIAdapter = extern struct {
    vtable: *const VTable,

    pub const iid = Guid.parseComptime("{2411E7E1-12AC-4CCF-BD14-9798E8534DC0}");

    pub const VTable = extern struct {
        base: IDXGIObject.VTable,
        EnumOutputs: *const anyopaque,
        GetDesc: *const anyopaque,
        /// Whether a runtime is supported at all, and which driver version
        /// implements it. Pass `IID_ID3D11Device` or `IID_ID3D10Device`; there
        /// is no identifier for Direct3D 12, which is what
        /// `d3d12.supports` exists for.
        CheckInterfaceSupport: *const fn (
            *IDXGIAdapter,
            *const Guid,
            *i64,
        ) callconv(.winapi) Hresult,
    };
};

/// `IDXGIAdapter1`: the same adapter, with a description that includes the
/// software flag.
pub const IDXGIAdapter1 = extern struct {
    vtable: *const VTable,

    pub const iid = Guid.parseComptime("{29038F61-3839-4626-91FD-086879011A05}");

    pub const VTable = extern struct {
        base: IDXGIAdapter.VTable,
        GetDesc1: *const fn (*IDXGIAdapter1, *AdapterDesc1) callconv(.winapi) Hresult,
    };
};

/// `IDXGIFactory`. Superseded by `IDXGIFactory1` and kept because the vtable
/// of every later factory begins with it.
pub const IDXGIFactory = extern struct {
    vtable: *const VTable,

    pub const iid = Guid.parseComptime("{7B7166EC-21C7-44AE-B21A-C9AE321AE369}");

    pub const VTable = extern struct {
        base: IDXGIObject.VTable,
        EnumAdapters: *const anyopaque,
        /// Stop DXGI intercepting keystrokes on a window. Passing a null
        /// window undoes the association.
        MakeWindowAssociation: *const fn (
            *IDXGIFactory,
            ?*anyopaque,
            WindowAssociation,
        ) callconv(.winapi) Hresult,
        GetWindowAssociation: *const anyopaque,
        CreateSwapChain: *const anyopaque,
        CreateSoftwareAdapter: *const anyopaque,
    };
};

/// `IDXGIFactory1`: Windows 7, and the floor everything here assumes.
pub const IDXGIFactory1 = extern struct {
    vtable: *const VTable,

    pub const iid = Guid.parseComptime("{770AAE78-F26F-4DBA-A829-253C83D1B387}");

    pub const VTable = extern struct {
        base: IDXGIFactory.VTable,
        EnumAdapters1: *const fn (
            *IDXGIFactory1,
            u32,
            *?*IDXGIAdapter1,
        ) callconv(.winapi) Hresult,
        /// False once an adapter has been added or removed since this factory
        /// was made, which is the signal to throw it away and make another.
        IsCurrent: *const fn (*IDXGIFactory1) callconv(.winapi) Bool,
    };
};

/// `IDXGIFactory2`: Windows 8. Swap chains for windows and for composition.
pub const IDXGIFactory2 = extern struct {
    vtable: *const VTable,

    pub const iid = Guid.parseComptime("{50C83A1C-E072-4C48-87B0-3630FA36A6D0}");

    pub const VTable = extern struct {
        base: IDXGIFactory1.VTable,
        IsWindowedStereoEnabled: *const anyopaque,
        CreateSwapChainForHwnd: *const anyopaque,
        CreateSwapChainForCoreWindow: *const anyopaque,
        GetSharedResourceAdapterLuid: *const anyopaque,
        RegisterStereoStatusWindow: *const anyopaque,
        RegisterStereoStatusEvent: *const anyopaque,
        UnregisterStereoStatus: *const anyopaque,
        RegisterOcclusionStatusWindow: *const anyopaque,
        RegisterOcclusionStatusEvent: *const anyopaque,
        UnregisterOcclusionStatus: *const anyopaque,
        CreateSwapChainForComposition: *const anyopaque,
    };
};

/// `IDXGIFactory3`: Windows 8.1. Reports the flags it was created with.
pub const IDXGIFactory3 = extern struct {
    vtable: *const VTable,

    pub const iid = Guid.parseComptime("{25483823-CD46-4C7D-86CA-47AA95B837BD}");

    pub const VTable = extern struct {
        base: IDXGIFactory2.VTable,
        GetCreationFlags: *const fn (*IDXGIFactory3) callconv(.winapi) u32,
    };
};

/// `IDXGIFactory4`: Windows 10. Adapters by identity rather than by position.
pub const IDXGIFactory4 = extern struct {
    vtable: *const VTable,

    pub const iid = Guid.parseComptime("{1BC6EA02-EF36-464F-BF0C-21CA39E5168A}");

    pub const VTable = extern struct {
        base: IDXGIFactory3.VTable,
        /// The adapter another API is already using, found by the identifier
        /// they both understand.
        EnumAdapterByLuid: *const fn (
            *IDXGIFactory4,
            Luid,
            *const Guid,
            *?*anyopaque,
        ) callconv(.winapi) Hresult,
        /// The software rasteriser. Always there, whatever the hardware is.
        EnumWarpAdapter: *const fn (
            *IDXGIFactory4,
            *const Guid,
            *?*anyopaque,
        ) callconv(.winapi) Hresult,
    };
};

/// `IDXGIFactory5`: Windows 10 1607. Where tearing support is reported.
pub const IDXGIFactory5 = extern struct {
    vtable: *const VTable,

    pub const iid = Guid.parseComptime("{7632E1F5-EE65-4DCA-87FD-84CD75F8838D}");

    pub const VTable = extern struct {
        base: IDXGIFactory4.VTable,
        CheckFeatureSupport: *const fn (
            *IDXGIFactory5,
            Feature,
            *anyopaque,
            u32,
        ) callconv(.winapi) Hresult,
    };
};

/// `IDXGIFactory6`: Windows 10 1803. Adapters in an order that means
/// something.
pub const IDXGIFactory6 = extern struct {
    vtable: *const VTable,

    pub const iid = Guid.parseComptime("{C1B6694F-FF09-44A9-B03C-77900A0A1D17}");

    pub const VTable = extern struct {
        base: IDXGIFactory5.VTable,
        EnumAdapterByGpuPreference: *const fn (
            *IDXGIFactory6,
            u32,
            GpuPreference,
            *const Guid,
            *?*anyopaque,
        ) callconv(.winapi) Hresult,
    };
};

/// `IDXGIDevice`: what a Direct3D device looks like from DXGI's side. Getting
/// it out of a device is how a program reaches the adapter that device is
/// actually running on.
pub const IDXGIDevice = extern struct {
    vtable: *const VTable,

    pub const iid = Guid.parseComptime("{54EC77FA-1377-44E6-8C32-88FD5F44C84C}");

    pub const VTable = extern struct {
        base: IDXGIObject.VTable,
        GetAdapter: *const fn (*IDXGIDevice, *?*IDXGIAdapter) callconv(.winapi) Hresult,
        CreateSurface: *const anyopaque,
        QueryResourceResidency: *const anyopaque,
        SetGPUThreadPriority: *const anyopaque,
        GetGPUThreadPriority: *const anyopaque,
    };
};

// -------------------------------------------------------------------------
// Tests
//
// `dxgi.dll` is part of every Windows since Vista, so these run for real:
// they load it, make a factory and walk the adapters. A machine with no
// adapter at all still passes - the list is simply empty - but a machine
// without DXGI skips, since there is nothing here to test.
// -------------------------------------------------------------------------

fn loadOrSkip() !Dxgi {
    return Dxgi.load() catch |err| switch (err) {
        error.LibraryNotFound => error.SkipZigTest,
        else => err,
    };
}

test "loading the library" {
    var dxgi = try loadOrSkip();
    defer dxgi.unload();

    // Vista's entry point is still exported, and 8.1's is there on anything
    // this decade - but neither is required, which is the point of binding
    // them as optionals.
    try testing.expect(dxgi.entries.CreateDXGIFactory != null);
}

test "making a factory" {
    var dxgi = try loadOrSkip();
    defer dxgi.unload();

    const factory = try dxgi.createFactory(IDXGIFactory1, .{});
    defer _ = com.release(factory);

    // A fresh factory has not missed anything yet.
    try testing.expect(factory.vtable.IsCurrent(factory) != 0);
}

test "walking the adapters" {
    var dxgi = try loadOrSkip();
    defer dxgi.unload();

    const factory = try dxgi.createFactory(IDXGIFactory1, .{});
    defer _ = com.release(factory);

    var seen: u32 = 0;
    var it = adapters(factory);
    while (try it.next()) |adapter| {
        defer _ = com.release(adapter);
        seen += 1;

        const desc = try describe(adapter);
        // Every driver names itself, and the name is the thing a person reads.
        try testing.expect(desc.name_len > 0);
        // A LUID is unique, so it is not zero.
        try testing.expect(desc.luid.value() != 0);
    }

    // Enumeration stops and stays stopped.
    try testing.expectEqual(@as(?*IDXGIAdapter1, null), try it.next());
    try testing.expectEqual(seen, it.index);
}

test "the software adapter is always there" {
    var dxgi = try loadOrSkip();
    defer dxgi.unload();

    const factory = try dxgi.createFactory(IDXGIFactory1, .{});
    defer _ = com.release(factory);

    // Needs IDXGIFactory4, and a machine older than Windows 10 has nothing to
    // answer with.
    const warp = warpAdapter(factory) catch |err| switch (err) {
        error.NoInterface, error.NotFound => return error.SkipZigTest,
        else => return err,
    };
    defer _ = com.release(warp);

    const desc = try describe(warp);
    // WARP is Windows itself, so it is Microsoft's and it has no hardware.
    try testing.expectEqual(Vendor.microsoft, desc.vendor);
    try testing.expect(desc.software);
    try testing.expect(desc.name_len > 0);
}

test "asking a factory what it also is" {
    var dxgi = try loadOrSkip();
    defer dxgi.unload();

    const factory = try dxgi.createFactory(IDXGIFactory1, .{});
    defer _ = com.release(factory);

    // Each of these is a different Windows, and a machine that has one has
    // every earlier one. A wrong identifier would show up here as an
    // interface that a modern Windows claims not to implement.
    if (com.implements(factory, IDXGIFactory6)) {
        try testing.expect(com.implements(factory, IDXGIFactory5));
        try testing.expect(com.implements(factory, IDXGIFactory4));
        try testing.expect(com.implements(factory, IDXGIFactory3));
        try testing.expect(com.implements(factory, IDXGIFactory2));
    }
    // And every one of them is an IDXGIObject and an IUnknown.
    try testing.expect(com.implements(factory, IDXGIObject));
    try testing.expect(com.implements(factory, IUnknown));

    // Whatever the answers were, asking did not lose the factory.
    try testing.expect(factory.vtable.IsCurrent(factory) != 0);

    // Tearing is a property of the runtime, and either answer is a real one.
    _ = allowsTearing(factory);
}

test "the debug factory needs the entry point that carries the flag" {
    var dxgi = try loadOrSkip();
    defer dxgi.unload();

    if (dxgi.entries.CreateDXGIFactory2 == null) {
        // Windows 8 or older: the flag cannot be passed, and asking for it
        // fails rather than quietly producing a factory without it.
        try testing.expectError(error.Unsupported, dxgi.createFactory(IDXGIFactory1, .{ .debug = true }));
        return;
    }

    // Otherwise the call is made, and DXGI decides. Without the Graphics
    // Tools feature installed it refuses, which is not this library's failure.
    const factory = dxgi.createFactory(IDXGIFactory1, .{ .debug = true }) catch return;
    defer _ = com.release(factory);

    const factory3 = try com.queryInterface(factory, IDXGIFactory3);
    defer _ = com.release(factory3);
    try testing.expectEqual(create_factory_debug, factory3.vtable.GetCreationFlags(factory3));
}

test "the descriptions of the structs the driver writes into" {
    // These are filled in by code this library did not compile, so their shape
    // has to match the header exactly rather than approximately.
    try testing.expectEqual(@as(usize, 256), @offsetOf(AdapterDesc1, "vendor_id"));
    try testing.expectEqual(@as(usize, 8), @sizeOf(Luid));
    // DXGI_ADAPTER_FLAG_REMOTE is 1 and DXGI_ADAPTER_FLAG_SOFTWARE is 2, so
    // the two bools are in that order and nothing precedes them.
    try testing.expectEqual(@as(u32, 1), @as(u32, @bitCast(AdapterFlags{ .remote = true })));
    try testing.expectEqual(@as(u32, 2), @as(u32, @bitCast(AdapterFlags{ .software = true })));
}

test "a description reads as a line of text" {
    var desc: Description = .{
        .name_buffer = undefined,
        .name_len = 0,
        .vendor = .nvidia,
        .device_id = 0x2484,
        .revision = 0xA1,
        .dedicated_video_memory = 8 << 30,
        .dedicated_system_memory = 0,
        .shared_system_memory = 16 << 30,
        .luid = .{ .low = 0x1234, .high = 0 },
        .software = false,
        .remote = false,
    };
    const name = "A Card With A Long Marketing Name";
    @memcpy(desc.name_buffer[0..name.len], name);
    desc.name_len = name.len;

    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "A Card With A Long Marketing Name [nvidia 2484] 8192 MiB",
        try std.fmt.bufPrint(&buffer, "{f}", .{&desc}),
    );

    desc.software = true;
    desc.dedicated_video_memory = 0;
    desc.vendor = .microsoft;
    desc.name_len = 0;
    try testing.expectEqualStrings(
        " [microsoft 2484] (software)",
        try std.fmt.bufPrint(&buffer, "{f}", .{&desc}),
    );
}
