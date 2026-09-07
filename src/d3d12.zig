// SPDX-License-Identifier: BSL-1.0

//! `d3d12.dll`: the device, what it can do, and the queue that work goes to.
//!
//! Direct3D 12 hands back the bookkeeping the 11 runtime did - memory,
//! synchronisation, resource state - in exchange for the driver overhead that
//! came with it. None of that is a loader's business. What is: the DLL is not
//! on every Windows, the device may refuse an adapter Direct3D 11 accepted, and
//! the debug layer lives behind an optional Windows feature.
//!
//! ```zig
//! var d3d12 = try D3d12.load();
//! defer d3d12.unload();
//!
//! const device = try d3d12.createDevice(.{});
//! defer _ = com.release(device);
//! std.debug.print("up to {f}\n", .{try highestLevel(device)});
//! ```
//!
//! **Asking before creating.** `D3D12CreateDevice` with no output pointer
//! answers the question and creates nothing, returning `S_FALSE` for yes. That
//! is `supports`, and it is the cheap way to find the adapter worth using
//! before committing to one.
//!
//! **Structs returned by value.** Several methods return a small struct rather
//! than writing through a pointer, and how that is passed differs between the
//! compiler Microsoft built the runtime with and everyone else. It is the
//! oldest bug in third-party Direct3D 12 bindings: the call appears to work and
//! the handle is rubbish. Every such slot is left undeclared below, with a
//! note - reachable by declaring it yourself with the ABI checked, not by
//! accident.

const std = @import("std");
const testing = std.testing;

const com = @import("com.zig");
const dll = @import("dll.zig");
const dxgi = @import("dxgi.zig");
const Guid = @import("guid.zig").Guid;
const hresult = @import("hresult.zig");
const level = @import("level.zig");

const FeatureLevel = level.FeatureLevel;
const Hresult = hresult.Hresult;
const Error = hresult.Error;
const IUnknown = com.IUnknown;

// -------------------------------------------------------------------------
// The library
// -------------------------------------------------------------------------

/// `d3d12.dll`, loaded, with its entry points resolved.
pub const D3d12 = struct {
    library: dll.Library,
    entries: Entries,

    pub const Entries = struct {
        /// With `device_out` null this creates nothing and answers `S_FALSE`
        /// if it would have succeeded. See `supports`.
        D3D12CreateDevice: *const fn (
            adapter: ?*IUnknown,
            minimum_feature_level: FeatureLevel,
            riid: *const Guid,
            device_out: ?*?*anyopaque,
        ) callconv(.winapi) Hresult,
        /// Only answers when the Graphics Tools optional feature is installed,
        /// which is why it is bound as an optional and why `debugLayer`
        /// reports `error.Unsupported` rather than failing to load.
        D3D12GetDebugInterface: ?*const fn (
            riid: *const Guid,
            debug_out: *?*anyopaque,
        ) callconv(.winapi) Hresult = null,
        /// Turns a root signature description into the blob a device will
        /// accept. Version 1.0 only; the versioned call below does the rest.
        D3D12SerializeRootSignature: ?*const fn (
            desc: *const RootSignatureDesc,
            version: RootSignatureVersion,
            blob_out: *?*ID3DBlob,
            error_blob_out: ?*?*ID3DBlob,
        ) callconv(.winapi) Hresult = null,
        /// Windows 10 1703 and later.
        D3D12SerializeVersionedRootSignature: ?*const fn (
            desc: *const anyopaque,
            blob_out: *?*ID3DBlob,
            error_blob_out: ?*?*ID3DBlob,
        ) callconv(.winapi) Hresult = null,
        /// Switches on features that are not shipped yet, and which need
        /// Developer Mode. Every one of them can change or vanish.
        D3D12EnableExperimentalFeatures: ?*const fn (
            count: u32,
            iids: [*]const Guid,
            configurations: ?[*]const ?*anyopaque,
            configuration_sizes: ?[*]const u32,
        ) callconv(.winapi) Hresult = null,
        /// Windows 10 1809. How the Agility SDK is told which redistributable
        /// runtime to load, among other things.
        D3D12GetInterface: ?*const fn (
            clsid: *const Guid,
            riid: *const Guid,
            out: ?*?*anyopaque,
        ) callconv(.winapi) Hresult = null,
    };

    pub const LoadError = dll.OpenError || error{SymbolNotFound};

    /// `error.LibraryNotFound` on anything older than Windows 10, where there
    /// is no `d3d12.dll` to find. That is the ordinary answer on such a
    /// machine, and the reason to fall back to `d3d11` rather than to stop.
    pub fn load() LoadError!D3d12 {
        var library = try dll.Library.openSystem("d3d12.dll");
        errdefer library.close();
        return .{ .library = library, .entries = try library.bind(Entries) };
    }

    /// Give the module back. Every device made through it must be released
    /// first.
    pub fn unload(self: *D3d12) void {
        self.library.close();
        self.* = undefined;
    }

    /// Would this adapter give a Direct3D 12 device at this level? Nothing is
    /// created and nothing has to be released.
    ///
    /// A null adapter means the default one. The minimum cannot be below
    /// `11_0`: there is no Direct3D 12 under it.
    pub fn supports(self: D3d12, adapter: ?*dxgi.IDXGIAdapter, minimum: FeatureLevel) bool {
        const result = self.entries.D3D12CreateDevice(
            @ptrCast(adapter),
            minimum,
            com.iidOf(ID3D12Device),
            null,
        );
        return result.succeeded();
    }

    /// The highest level a device on this adapter would be granted, found
    /// without making one.
    ///
    /// `supports` answers yes or no for a floor, so asking it for each level
    /// from the top down and taking the first yes gives the ceiling. Null
    /// means no Direct3D 12 device at all on this adapter.
    pub fn highestSupported(self: D3d12, adapter: ?*dxgi.IDXGIAdapter) ?FeatureLevel {
        for (FeatureLevel.atOrAbove(.@"11_0")) |candidate| {
            if (self.supports(adapter, candidate)) return candidate;
        }
        return null;
    }

    /// Is the debug layer installed on this machine?
    ///
    /// Asks for the interface and gives it straight back, so nothing is
    /// switched on - which is what makes this safe to call from a report.
    /// `enableDebugLayer` is the one that changes something.
    pub fn debugLayerAvailable(self: D3d12) bool {
        const get = self.entries.D3D12GetDebugInterface orelse return false;
        var raw: ?*anyopaque = null;
        const debug = com.received(ID3D12Debug, get(com.iidOf(ID3D12Debug), &raw), raw) catch
            return false;
        _ = com.release(debug);
        return true;
    }

    pub const DeviceOptions = struct {
        /// The adapter to run on, or null for the default one. Take it from
        /// `dxgi` - `dxgi.warpAdapter` for the software rasteriser, which is
        /// how Direct3D 12 runs on a machine with no capable card.
        adapter: ?*dxgi.IDXGIAdapter = null,
        /// The lowest level that will do. Unlike Direct3D 11 there is no list
        /// and no negotiation: the device is made at whatever the adapter
        /// supports, or not at all. `highestLevel` asks what that was.
        minimum: FeatureLevel = .@"11_0",
    };

    pub fn createDevice(self: D3d12, options: DeviceOptions) Error!*ID3D12Device {
        var raw: ?*anyopaque = null;
        const result = self.entries.D3D12CreateDevice(
            @ptrCast(options.adapter),
            options.minimum,
            com.iidOf(ID3D12Device),
            &raw,
        );
        return com.received(ID3D12Device, result, raw);
    }

    /// Switch on the debug layer, for this process, before any device is made.
    /// It must be before: a device created first does not get it.
    ///
    /// `error.Unsupported` when the Graphics Tools feature is not installed,
    /// which is the ordinary state of a machine that is not a developer's.
    /// Treat it as "no debug layer today" rather than as a failure.
    pub fn enableDebugLayer(self: D3d12) Error!void {
        const get = self.entries.D3D12GetDebugInterface orelse return error.Unsupported;
        var raw: ?*anyopaque = null;
        const debug = try com.received(ID3D12Debug, get(com.iidOf(ID3D12Debug), &raw), raw);
        defer _ = com.release(debug);
        debug.vtable.EnableDebugLayer(debug);
    }
};

// -------------------------------------------------------------------------
// Asking a device what it is
// -------------------------------------------------------------------------

/// The highest feature level this device supports, which is not the one it was
/// created with: `createDevice` takes a floor, and the device may be well
/// above it.
///
/// Walks down the ladder the way `d3d11.highestLevel` does, because a runtime
/// that has never heard of a level in the list refuses the whole query rather
/// than ignoring the entry.
pub fn highestLevel(device: *ID3D12Device) Error!FeatureLevel {
    var levels: []const FeatureLevel = FeatureLevel.atOrAbove(.@"11_0");
    while (levels.len > 0) : (levels = levels[1..]) {
        var data: FeatureDataFeatureLevels = .{
            .count = @intCast(levels.len),
            .requested = levels.ptr,
            .highest_supported = .@"11_0",
        };
        const result = device.vtable.CheckFeatureSupport(
            device,
            .feature_levels,
            &data,
            @sizeOf(FeatureDataFeatureLevels),
        );
        if (result == .e_invalidarg) continue;
        try result.check();
        return data.highest_supported;
    }
    return error.Unsupported;
}

/// The highest shader model the runtime and the driver both understand.
///
/// The query is in-out: it is told the highest model the caller knows and
/// answers with the highest both agree on - except on an older runtime, which
/// refuses a model it has never heard of outright, so this walks down until
/// one is accepted.
pub fn highestShaderModel(device: *ID3D12Device) Error!ShaderModel {
    for (ShaderModel.all) |candidate| {
        var data: FeatureDataShaderModel = .{ .highest = candidate };
        const result = device.vtable.CheckFeatureSupport(
            device,
            .shader_model,
            &data,
            @sizeOf(FeatureDataShaderModel),
        );
        if (result == .e_invalidarg) continue;
        try result.check();
        return data.highest;
    }
    return error.Unsupported;
}

/// How many physical adapters this one device drives. One, on anything that is
/// not a workstation with linked cards.
pub fn nodeCount(device: *ID3D12Device) u32 {
    return device.vtable.GetNodeCount(device);
}

/// Make a queue for work of one kind. Every command list executes on a queue,
/// and a device with no queue can do nothing but allocate.
pub fn createCommandQueue(
    device: *ID3D12Device,
    desc: CommandQueueDesc,
) Error!*ID3D12CommandQueue {
    var raw: ?*anyopaque = null;
    const result = device.vtable.CreateCommandQueue(
        device,
        &desc,
        com.iidOf(ID3D12CommandQueue),
        &raw,
    );
    return com.received(ID3D12CommandQueue, result, raw);
}

// -------------------------------------------------------------------------
// Types the calls above take and return
// -------------------------------------------------------------------------

/// `D3D12_FEATURE`. Non-exhaustive: there are forty or so and they arrive with
/// every Windows release. The two named here are the ones this module asks.
pub const Feature = enum(u32) {
    options = 0,
    architecture = 1,
    feature_levels = 2,
    format_support = 3,
    multisample_quality_levels = 4,
    format_info = 5,
    gpu_virtual_address_support = 6,
    shader_model = 7,
    _,
};

/// `D3D12_FEATURE_DATA_FEATURE_LEVELS`. In and out in one struct, which is how
/// every `CheckFeatureSupport` query is shaped.
pub const FeatureDataFeatureLevels = extern struct {
    count: u32,
    requested: [*]const FeatureLevel,
    highest_supported: FeatureLevel,
};

/// `D3D12_FEATURE_DATA_SHADER_MODEL`. One field, read and written.
pub const FeatureDataShaderModel = extern struct {
    highest: ShaderModel,
};

/// `D3D_SHADER_MODEL`. The high nibble is the major version and the low one
/// the minor, so `sm_6_5` is 0x65 and the values sort.
pub const ShaderModel = enum(u32) {
    sm_5_1 = 0x51,
    sm_6_0 = 0x60,
    sm_6_1 = 0x61,
    sm_6_2 = 0x62,
    sm_6_3 = 0x63,
    sm_6_4 = 0x64,
    sm_6_5 = 0x65,
    sm_6_6 = 0x66,
    sm_6_7 = 0x67,
    sm_6_8 = 0x68,
    _,

    /// Highest first, which is the order the query has to be tried in.
    pub const all = [_]ShaderModel{
        .sm_6_8, .sm_6_7, .sm_6_6, .sm_6_5, .sm_6_4,
        .sm_6_3, .sm_6_2, .sm_6_1, .sm_6_0, .sm_5_1,
    };

    pub fn major(self: ShaderModel) u8 {
        return @intCast(@intFromEnum(self) >> 4 & 0xF);
    }

    pub fn minor(self: ShaderModel) u8 {
        return @intCast(@intFromEnum(self) & 0xF);
    }

    pub fn format(self: ShaderModel, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}.{d}", .{ self.major(), self.minor() });
    }
};

/// `D3D12_COMMAND_LIST_TYPE`: what a queue accepts.
pub const CommandListType = enum(i32) {
    /// Everything: draws, dispatches and copies.
    direct = 0,
    /// A recorded fragment, replayed inside a direct list.
    bundle = 1,
    /// Dispatches only, on hardware that runs them alongside graphics.
    compute = 2,
    /// Copies only, usually on a separate engine that runs while the rest of
    /// the card draws.
    copy = 3,
    video_decode = 4,
    video_process = 5,
    video_encode = 6,
    _,
};

/// `D3D12_COMMAND_QUEUE_PRIORITY`. Realtime needs a privilege the process
/// usually does not have.
pub const CommandQueuePriority = enum(i32) {
    normal = 0,
    high = 100,
    global_realtime = 10_000,
    _,
};

/// `D3D12_COMMAND_QUEUE_FLAGS`.
pub const CommandQueueFlags = packed struct(u32) {
    /// Let work on this queue run past the watchdog. For long compute, and a
    /// good way to make a machine stop responding.
    disable_gpu_timeout: bool = false,
    _reserved: u31 = 0,
};

/// `D3D12_COMMAND_QUEUE_DESC`.
pub const CommandQueueDesc = extern struct {
    type: CommandListType = .direct,
    priority: CommandQueuePriority = .normal,
    flags: CommandQueueFlags = .{},
    /// Which adapter in a linked set. Zero, unless `nodeCount` says otherwise.
    node_mask: u32 = 0,
};

/// `D3D_ROOT_SIGNATURE_VERSION`.
pub const RootSignatureVersion = enum(u32) {
    v1_0 = 0x1,
    v1_1 = 0x2,
    v1_2 = 0x3,
    _,
};

/// `D3D12_ROOT_SIGNATURE_DESC`, with the two arrays left as opaque pointers.
///
/// Describing actual root parameters means a dozen more structs and is a job
/// for a renderer, not a loader. What this is good for is the empty signature
/// - no parameters, no samplers - which is what a compute pipeline that binds
/// everything through a heap needs, and which is enough to check that the
/// serialiser is really there.
pub const RootSignatureDesc = extern struct {
    parameter_count: u32 = 0,
    parameters: ?*const anyopaque = null,
    static_sampler_count: u32 = 0,
    static_samplers: ?*const anyopaque = null,
    flags: u32 = 0,
};

/// `D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT`, the one
/// flag a graphics root signature almost always sets.
pub const root_signature_allow_input_assembler_input_layout: u32 = 0x1;

// -------------------------------------------------------------------------
// The interfaces
// -------------------------------------------------------------------------

/// A lump of bytes the runtime allocated. Defined in `com`, because the
/// shader compiler and both runtimes all hand them back.
pub const ID3DBlob = com.ID3DBlob;

/// `ID3D12Object`: everything Direct3D 12 makes.
pub const ID3D12Object = extern struct {
    vtable: *const VTable,

    pub const iid = Guid.parseComptime("{C4FEC28F-7966-4E95-9F94-F431CB56C3B8}");

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        GetPrivateData: *const anyopaque,
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        /// A name for the debug layer and for a graphics debugger to show.
        /// Costs nothing in a release build and saves an afternoon in a debug
        /// one.
        SetName: *const fn (*ID3D12Object, [*:0]const u16) callconv(.winapi) Hresult,
    };
};

/// `ID3D12DeviceChild`: everything a device makes.
pub const ID3D12DeviceChild = extern struct {
    vtable: *const VTable,

    pub const iid = Guid.parseComptime("{905DB94B-A00C-4140-9DF5-2B64CA9EA357}");

    pub const VTable = extern struct {
        base: ID3D12Object.VTable,
        GetDevice: *const fn (
            *ID3D12DeviceChild,
            *const Guid,
            ?*?*anyopaque,
        ) callconv(.winapi) Hresult,
    };
};

/// `ID3D12Pageable`: a device child the driver may move in and out of video
/// memory. Adds nothing of its own; it exists so `MakeResident` has a type to
/// take.
pub const ID3D12Pageable = extern struct {
    vtable: *const VTable,

    pub const iid = Guid.parseComptime("{63EE58FB-1268-4835-86DA-F008CE62F0D6}");

    pub const VTable = extern struct {
        base: ID3D12DeviceChild.VTable,
    };
};

/// `ID3D12Device`.
pub const ID3D12Device = extern struct {
    vtable: *const VTable,

    pub const iid = Guid.parseComptime("{189819F1-1DB6-4B57-BE54-1821339B85F7}");

    pub const VTable = extern struct {
        base: ID3D12Object.VTable,
        GetNodeCount: *const fn (*ID3D12Device) callconv(.winapi) u32,
        CreateCommandQueue: *const fn (
            *ID3D12Device,
            *const CommandQueueDesc,
            *const Guid,
            *?*anyopaque,
        ) callconv(.winapi) Hresult,
        CreateCommandAllocator: *const anyopaque,
        CreateGraphicsPipelineState: *const anyopaque,
        CreateComputePipelineState: *const anyopaque,
        CreateCommandList: *const anyopaque,
        /// Every "what can this card do" question, through one call and a
        /// struct per question. See `Feature`.
        CheckFeatureSupport: *const fn (
            *ID3D12Device,
            Feature,
            *anyopaque,
            u32,
        ) callconv(.winapi) Hresult,
        CreateDescriptorHeap: *const anyopaque,
        GetDescriptorHandleIncrementSize: *const fn (*ID3D12Device, u32) callconv(.winapi) u32,
        CreateRootSignature: *const anyopaque,
        CreateConstantBufferView: *const anyopaque,
        CreateShaderResourceView: *const anyopaque,
        CreateUnorderedAccessView: *const anyopaque,
        CreateRenderTargetView: *const anyopaque,
        CreateDepthStencilView: *const anyopaque,
        CreateSampler: *const anyopaque,
        CopyDescriptors: *const anyopaque,
        CopyDescriptorsSimple: *const anyopaque,
        /// Returns a struct by value. See the module comment.
        GetResourceAllocationInfo: *const anyopaque,
        /// Returns a struct by value. See the module comment.
        GetCustomHeapProperties: *const anyopaque,
        CreateCommittedResource: *const anyopaque,
        CreateHeap: *const anyopaque,
        CreatePlacedResource: *const anyopaque,
        CreateReservedResource: *const anyopaque,
        CreateSharedHandle: *const anyopaque,
        OpenSharedHandle: *const anyopaque,
        OpenSharedHandleByName: *const anyopaque,
        MakeResident: *const anyopaque,
        Evict: *const anyopaque,
        CreateFence: *const anyopaque,
        /// Why the device stopped working, or `s_ok` while it still does.
        GetDeviceRemovedReason: *const fn (*ID3D12Device) callconv(.winapi) Hresult,
        GetCopyableFootprints: *const anyopaque,
        CreateQueryHeap: *const anyopaque,
        SetStablePowerState: *const anyopaque,
        CreateCommandSignature: *const anyopaque,
        GetResourceTiling: *const anyopaque,
        /// Returns a struct by value. See the module comment - and note that
        /// `dxgi.Description.luid` is the same number, read from the adapter
        /// through a call that writes into a pointer.
        GetAdapterLuid: *const anyopaque,
    };
};

/// `ID3D12CommandQueue`.
///
/// The vtable stops after `GetTimestampFrequency`. `GetClockCalibration` and
/// `GetDesc` follow it, and `GetDesc` returns a struct by value - see the
/// module comment.
pub const ID3D12CommandQueue = extern struct {
    vtable: *const VTable,

    pub const iid = Guid.parseComptime("{0EC870A6-5D7E-4C22-8CFC-5BAAE07616ED}");

    pub const VTable = extern struct {
        base: ID3D12Pageable.VTable,
        UpdateTileMappings: *const anyopaque,
        CopyTileMappings: *const anyopaque,
        ExecuteCommandLists: *const anyopaque,
        SetMarker: *const anyopaque,
        BeginEvent: *const anyopaque,
        EndEvent: *const anyopaque,
        /// Raise a fence to `value` once everything queued before it is done.
        Signal: *const fn (*ID3D12CommandQueue, *IUnknown, u64) callconv(.winapi) Hresult,
        /// Stop the queue until a fence reaches `value`.
        Wait: *const fn (*ID3D12CommandQueue, *IUnknown, u64) callconv(.winapi) Hresult,
        /// Ticks per second for the timestamps this queue writes. The number
        /// that turns a GPU timestamp into a duration.
        GetTimestampFrequency: *const fn (*ID3D12CommandQueue, *u64) callconv(.winapi) Hresult,
    };
};

/// `ID3D12Debug`: one method, and the only thing the debug layer needs.
pub const ID3D12Debug = extern struct {
    vtable: *const VTable,

    pub const iid = Guid.parseComptime("{344488B7-6846-474B-B989-F027448245E0}");

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        EnableDebugLayer: *const fn (*ID3D12Debug) callconv(.winapi) void,
    };
};

// -------------------------------------------------------------------------
// Tests
//
// A machine with no Direct3D 12 card still runs all of these, because WARP is
// a Direct3D 12 adapter and ships with Windows. A machine older than Windows
// 10 has no `d3d12.dll` and skips, which is the honest outcome.
// -------------------------------------------------------------------------

fn loadOrSkip() !D3d12 {
    return D3d12.load() catch |err| switch (err) {
        error.LibraryNotFound => error.SkipZigTest,
        else => err,
    };
}

/// A device on the software rasteriser, which needs no card and no driver.
fn warpDeviceOrSkip(d3d12: D3d12, dxgi_lib: *dxgi.Dxgi) !*ID3D12Device {
    const factory = try dxgi_lib.createFactory(dxgi.IDXGIFactory1, .{});
    defer _ = com.release(factory);

    const warp = dxgi.warpAdapter(factory) catch return error.SkipZigTest;
    defer _ = com.release(warp);

    return d3d12.createDevice(.{ .adapter = @ptrCast(warp) }) catch return error.SkipZigTest;
}

test "loading the library" {
    var d3d12 = try loadOrSkip();
    defer d3d12.unload();

    // Windows 10 1703 and later, so anything this decade.
    try testing.expect(d3d12.entries.D3D12SerializeRootSignature != null);
}

test "asking whether an adapter would work, without making anything" {
    var d3d12 = try loadOrSkip();
    defer d3d12.unload();

    var dxgi_lib = dxgi.Dxgi.load() catch return error.SkipZigTest;
    defer dxgi_lib.unload();

    const factory = try dxgi_lib.createFactory(dxgi.IDXGIFactory1, .{});
    defer _ = com.release(factory);

    const warp = dxgi.warpAdapter(factory) catch return error.SkipZigTest;
    defer _ = com.release(warp);

    // WARP implements Direct3D 12 in full.
    try testing.expect(d3d12.supports(@ptrCast(warp), .@"11_0"));
    // And nothing above the ladder, which is the other half of the answer
    // being real rather than always yes.
    try testing.expect(!d3d12.supports(@ptrCast(warp), @enumFromInt(0xF000)));

    // The ceiling, from the same question asked repeatedly - and it is the
    // same number a real device reports.
    const ceiling = d3d12.highestSupported(@ptrCast(warp)).?;
    try testing.expect(ceiling.atLeast(.@"11_0"));

    const device = try d3d12.createDevice(.{ .adapter = @ptrCast(warp) });
    defer _ = com.release(device);
    try testing.expectEqual(ceiling, try highestLevel(device));
}

test "a device on the software rasteriser" {
    var d3d12 = try loadOrSkip();
    defer d3d12.unload();
    var dxgi_lib = dxgi.Dxgi.load() catch return error.SkipZigTest;
    defer dxgi_lib.unload();

    const device = try warpDeviceOrSkip(d3d12, &dxgi_lib);
    defer _ = com.release(device);

    try testing.expect((try highestLevel(device)).atLeast(.@"11_0"));
    try testing.expect((try highestShaderModel(device)).major() >= 5);
    // One adapter, unless this is a workstation with linked cards.
    try testing.expect(nodeCount(device) >= 1);
    try testing.expectEqual(Hresult.s_ok, device.vtable.GetDeviceRemovedReason(device));

    // A descriptor's size is decided by the driver and is never zero.
    try testing.expect(device.vtable.GetDescriptorHandleIncrementSize(device, 0) > 0);
}

test "a queue to put work on" {
    var d3d12 = try loadOrSkip();
    defer d3d12.unload();
    var dxgi_lib = dxgi.Dxgi.load() catch return error.SkipZigTest;
    defer dxgi_lib.unload();

    const device = try warpDeviceOrSkip(d3d12, &dxgi_lib);
    defer _ = com.release(device);

    const queue = try createCommandQueue(device, .{});
    defer _ = com.release(queue);

    // The timestamp frequency is what turns a GPU timestamp into a duration,
    // and reaching it through six levels of inherited vtable is the check
    // that the layout above is right.
    var frequency: u64 = 0;
    try queue.vtable.GetTimestampFrequency(queue, &frequency).check();
    try testing.expect(frequency > 0);

    // A queue is a device child, and knows what made it.
    const child: *ID3D12DeviceChild = @ptrCast(queue);
    var owner: ?*anyopaque = null;
    try child.vtable.GetDevice(child, com.iidOf(ID3D12Device), &owner).check();
    try testing.expectEqual(@as(*anyopaque, @ptrCast(device)), owner.?);
    _ = com.release(@as(*ID3D12Device, @ptrCast(@alignCast(owner.?))));

    // And an object, so it can be named for a debugger.
    const object: *ID3D12Object = @ptrCast(queue);
    try object.vtable.SetName(object, std.unicode.utf8ToUtf16LeStringLiteral("fluxion test queue")).check();
}

test "a compute queue is a different queue" {
    var d3d12 = try loadOrSkip();
    defer d3d12.unload();
    var dxgi_lib = dxgi.Dxgi.load() catch return error.SkipZigTest;
    defer dxgi_lib.unload();

    const device = try warpDeviceOrSkip(d3d12, &dxgi_lib);
    defer _ = com.release(device);

    const graphics = try createCommandQueue(device, .{ .type = .direct });
    defer _ = com.release(graphics);
    const compute = try createCommandQueue(device, .{ .type = .compute, .priority = .high });
    defer _ = com.release(compute);
    try testing.expect(graphics != compute);
}

test "serialising the empty root signature" {
    var d3d12 = try loadOrSkip();
    defer d3d12.unload();

    const serialize = d3d12.entries.D3D12SerializeRootSignature orelse return error.SkipZigTest;

    var blob: ?*ID3DBlob = null;
    var errors: ?*ID3DBlob = null;
    const result = serialize(&.{}, .v1_0, &blob, &errors);
    if (errors) |e| _ = com.release(e);
    try result.check();

    const bytes = blob.?.bytes();
    defer _ = com.release(blob.?);

    // A serialised root signature is a DXBC container, which says so in its
    // first four bytes. No device is needed to produce one, which is why this
    // runs on any machine at all.
    try testing.expect(bytes.len > 4);
    try testing.expectEqualStrings("DXBC", bytes[0..4]);
}

test "the debug layer, if this machine has it" {
    var d3d12 = try loadOrSkip();
    defer d3d12.unload();

    // Both outcomes are correct: a developer machine has the Graphics Tools
    // feature and an ordinary one does not.
    d3d12.enableDebugLayer() catch |err| switch (err) {
        error.Unsupported, error.ModuleNotFound, error.FileNotFound => return,
        else => return err,
    };
}

test "shader models sort and print" {
    try testing.expectEqual(@as(u8, 6), ShaderModel.sm_6_5.major());
    try testing.expectEqual(@as(u8, 5), ShaderModel.sm_6_5.minor());
    try testing.expect(@intFromEnum(ShaderModel.sm_6_8) > @intFromEnum(ShaderModel.sm_5_1));

    // Highest first, which is the order the query has to be tried in.
    for (ShaderModel.all[1..], 0..) |model, i| {
        try testing.expect(@intFromEnum(ShaderModel.all[i]) > @intFromEnum(model));
    }

    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings("6.5", try std.fmt.bufPrint(&buffer, "{f}", .{ShaderModel.sm_6_5}));
    try testing.expectEqualStrings("5.1", try std.fmt.bufPrint(&buffer, "{f}", .{ShaderModel.sm_5_1}));
}

test "the descriptions the runtime reads are shaped as it expects" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(CommandQueueDesc));
    try testing.expectEqual(@as(u32, 1), @as(u32, @bitCast(CommandQueueFlags{ .disable_gpu_timeout = true })));
    try testing.expectEqual(@as(i32, 100), @intFromEnum(CommandQueuePriority.high));
    try testing.expectEqual(@as(u32, 2), @intFromEnum(Feature.feature_levels));
    try testing.expectEqual(@as(u32, 7), @intFromEnum(Feature.shader_model));
}
