// SPDX-License-Identifier: BSL-1.0

//! `d3d11.dll`: a device, the context that drives it, and the feature level
//! the two of them settled on.
//!
//! The older of the two APIs and the easier one to get a picture out of: the
//! runtime does the work Direct3D 12 hands back to the program. It also still
//! runs on hardware from 2009, which is why a program that wants to run
//! everywhere starts here and asks for 12 only when it can use it.
//!
//! ```zig
//! var d3d11 = try D3d11.load();
//! defer d3d11.unload();
//!
//! var device = try d3d11.createDevice(.{});
//! defer device.release();
//! std.debug.print("feature level {f}\n", .{device.level});
//! ```
//!
//! **What `createDevice` will not let you say.** `D3D11CreateDevice` takes both
//! an adapter and a driver type, and naming an adapter means the driver type
//! has to be `UNKNOWN` - getting it wrong is `E_INVALIDARG` with no
//! explanation. `Driver` is a union, so the bad combination cannot be written.
//!
//! **The debug layer.** `flags.debug` needs the D3D11 SDK layers, an optional
//! Windows feature absent from an ordinary machine. Without them the call fails
//! with `error.SdkComponentMissing`, and the usual answer is to ask again:
//!
//! ```zig
//! var device = d3d11.createDevice(.{ .flags = .{ .debug = true } }) catch |err| switch (err) {
//!     error.SdkComponentMissing => try d3d11.createDevice(.{}),
//!     else => return err,
//! };
//! ```

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

/// `D3D11_SDK_VERSION`. A version of the header rather than of the runtime,
/// and it has been 7 since Direct3D 11 shipped. The runtime checks it and
/// refuses anything else.
pub const sdk_version: u32 = 7;

// -------------------------------------------------------------------------
// The library
// -------------------------------------------------------------------------

/// `d3d11.dll`, loaded, with its entry points resolved.
pub const D3d11 = struct {
    library: dll.Library,
    entries: Entries,

    pub const Entries = struct {
        D3D11CreateDevice: *const fn (
            adapter: ?*dxgi.IDXGIAdapter,
            driver_type: DriverType,
            software: ?*anyopaque,
            flags: CreateFlags,
            feature_levels: ?[*]const FeatureLevel,
            feature_level_count: u32,
            sdk_version: u32,
            device_out: ?*?*ID3D11Device,
            level_out: ?*FeatureLevel,
            context_out: ?*?*ID3D11DeviceContext,
        ) callconv(.winapi) Hresult,
        /// The same call with a swap chain description bolted on. Superseded
        /// by making the device and then asking `IDXGIFactory2` for the swap
        /// chain, which is the only way to get the newer swap effects - so the
        /// two swap chain parameters are left opaque here rather than dragging
        /// `DXGI_SWAP_CHAIN_DESC` into a loader.
        D3D11CreateDeviceAndSwapChain: ?*const fn (
            adapter: ?*dxgi.IDXGIAdapter,
            driver_type: DriverType,
            software: ?*anyopaque,
            flags: CreateFlags,
            feature_levels: ?[*]const FeatureLevel,
            feature_level_count: u32,
            sdk_version: u32,
            swap_chain_desc: ?*const anyopaque,
            swap_chain_out: ?*?*anyopaque,
            device_out: ?*?*ID3D11Device,
            level_out: ?*FeatureLevel,
            context_out: ?*?*ID3D11DeviceContext,
        ) callconv(.winapi) Hresult = null,
    };

    pub const LoadError = dll.OpenError || error{SymbolNotFound};

    pub fn load() LoadError!D3d11 {
        var library = try dll.Library.openSystem("d3d11.dll");
        errdefer library.close();
        return .{ .library = library, .entries = try library.bind(Entries) };
    }

    /// Give the module back. Every device made through it must be released
    /// first.
    pub fn unload(self: *D3d11) void {
        self.library.close();
        self.* = undefined;
    }

    pub const DeviceOptions = struct {
        driver: Driver = .hardware,
        flags: CreateFlags = .{},
        /// Tried in the order given, and the first one the hardware meets is
        /// the one granted. See `level` for why the order matters and why a
        /// level the runtime has never heard of fails the whole call.
        levels: []const FeatureLevel = FeatureLevel.atOrAbove(.@"11_0"),
    };

    /// Make a device and its immediate context.
    ///
    /// The level that comes back is the one that was granted, which is at best
    /// the first entry of `levels` and may be any of them. Check it before
    /// assuming a feature: a device is still a device at `10_0`.
    pub fn createDevice(self: D3d11, options: DeviceOptions) Error!Device {
        var device: ?*ID3D11Device = null;
        var context: ?*ID3D11DeviceContext = null;
        var granted: FeatureLevel = undefined;

        const result = self.entries.D3D11CreateDevice(
            options.driver.adapterPointer(),
            options.driver.driverType(),
            null,
            options.flags,
            options.levels.ptr,
            @intCast(options.levels.len),
            sdk_version,
            &device,
            &granted,
            &context,
        );
        try result.check();

        return .{
            .device = device orelse return error.NullPointer,
            .context = context orelse return error.NullPointer,
            .level = granted,
        };
    }

    /// The highest feature level this driver would give, without making a
    /// device to find out.
    ///
    /// `D3D11CreateDevice` with no output pointers negotiates and stops, which
    /// costs a fraction of a real create and leaves nothing to release. Null
    /// means this driver cannot make a device at all.
    ///
    /// Unlike `createDevice`, this walks down the list on `E_INVALIDARG`, since
    /// that is the only way a runtime says it has never heard of a level.
    pub fn highestLevel(self: D3d11, driver: Driver) ?FeatureLevel {
        var levels: []const FeatureLevel = &FeatureLevel.all;
        while (levels.len > 0) : (levels = levels[1..]) {
            var granted: FeatureLevel = undefined;
            const result = self.entries.D3D11CreateDevice(
                driver.adapterPointer(),
                driver.driverType(),
                null,
                .{},
                levels.ptr,
                @intCast(levels.len),
                sdk_version,
                null,
                &granted,
                null,
            );
            if (result == .e_invalidarg) continue;
            if (result.failed()) return null;
            return granted;
        }
        return null;
    }
};

/// Which implementation of Direct3D 11 to run on.
///
/// A union rather than a pair of arguments, because the underlying call
/// accepts combinations that mean nothing: an adapter with a driver type is
/// `E_INVALIDARG`, and a driver type of `UNKNOWN` with no adapter is too.
pub const Driver = union(enum) {
    /// Whatever DXGI calls the default adapter, in hardware.
    hardware,
    /// WARP, the rasteriser Windows implements in software. Slow, correct, and
    /// present on every machine - which makes it the one to fall back to and
    /// the one to test on.
    warp,
    /// The reference rasteriser: slower than WARP by orders of magnitude, and
    /// only present when the SDK layers are installed. For deciding whether
    /// the driver or the program is wrong.
    reference,
    /// A particular adapter, from `dxgi`. The driver type is `UNKNOWN` in this
    /// case, which is what the runtime requires and what this union arranges.
    adapter: *dxgi.IDXGIAdapter,

    fn driverType(self: Driver) DriverType {
        return switch (self) {
            .hardware => .hardware,
            .warp => .warp,
            .reference => .reference,
            .adapter => .unknown,
        };
    }

    fn adapterPointer(self: Driver) ?*dxgi.IDXGIAdapter {
        return switch (self) {
            .adapter => |pointer| pointer,
            else => null,
        };
    }
};

/// `D3D_DRIVER_TYPE`. `Driver` is what to use; this is the wire form.
pub const DriverType = enum(u32) {
    unknown = 0,
    hardware = 1,
    reference = 2,
    null_device = 3,
    software = 4,
    warp = 5,
};

/// `D3D11_CREATE_DEVICE_FLAG`. The gaps are values Microsoft has not used.
pub const CreateFlags = packed struct(u32) {
    /// Promise never to call into the device from two threads at once, and
    /// take the locking out. A promise that is easy to break by accident.
    singlethreaded: bool = false,
    /// The debug layer: every call checked, and its complaints sent to the
    /// debugger. Needs the optional SDK layers - see the module comment.
    debug: bool = false,
    switch_to_ref: bool = false,
    prevent_internal_threading_optimizations: bool = false,
    _reserved4: u1 = 0,
    /// Surfaces the desktop compositor and Direct2D can share.
    bgra_support: bool = false,
    /// Keep shader source and disassembly around for a graphics debugger.
    debuggable: bool = false,
    prevent_altering_layer_settings_from_registry: bool = false,
    /// Do not let Windows reset the device when a draw takes too long. For
    /// long compute work, and a good way to hang a machine.
    disable_gpu_timeout: bool = false,
    _reserved9: u2 = 0,
    video_support: bool = false,
    _reserved12: u20 = 0,
};

/// A device, the context that issues work to it, and the level they agreed on.
pub const Device = struct {
    device: *ID3D11Device,
    /// The immediate context: work put here goes to the driver as it is
    /// recorded. There is exactly one per device.
    context: *ID3D11DeviceContext,
    /// What the hardware actually granted, which is at best the first entry of
    /// the list that was asked for.
    level: FeatureLevel,

    /// Release both, context first. Everything made from the device must
    /// already be gone.
    pub fn release(self: *Device) void {
        _ = com.release(self.context);
        _ = com.release(self.device);
        self.* = undefined;
    }

    /// Why the device stopped working, or `s_ok` while it still does.
    ///
    /// A device can be lost at any time - a driver update, a hang the driver
    /// recovered from, a card physically removed - and every call afterwards
    /// fails. This is the one call that says which of those happened.
    pub fn removedReason(self: Device) Hresult {
        return self.device.vtable.GetDeviceRemovedReason(self.device);
    }
};

// -------------------------------------------------------------------------
// The interfaces
//
// As in `dxgi`: each vtable holds its base as its first field, and the slots
// this library does not call keep their names and are typed as opaque
// pointers so the ones that follow stay at the right index.
// -------------------------------------------------------------------------

/// `ID3D11Device`.
pub const ID3D11Device = extern struct {
    vtable: *const VTable,

    pub const iid = Guid.parseComptime("{DB6F6DDB-AC77-4E88-8253-819DF9BBF140}");

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        CreateBuffer: *const anyopaque,
        CreateTexture1D: *const anyopaque,
        CreateTexture2D: *const anyopaque,
        CreateTexture3D: *const anyopaque,
        CreateShaderResourceView: *const anyopaque,
        CreateUnorderedAccessView: *const anyopaque,
        CreateRenderTargetView: *const anyopaque,
        CreateDepthStencilView: *const anyopaque,
        CreateInputLayout: *const anyopaque,
        CreateVertexShader: *const anyopaque,
        CreateGeometryShader: *const anyopaque,
        CreateGeometryShaderWithStreamOutput: *const anyopaque,
        CreatePixelShader: *const anyopaque,
        CreateHullShader: *const anyopaque,
        CreateDomainShader: *const anyopaque,
        CreateComputeShader: *const anyopaque,
        CreateClassLinkage: *const anyopaque,
        CreateBlendState: *const anyopaque,
        CreateDepthStencilState: *const anyopaque,
        CreateRasterizerState: *const anyopaque,
        CreateSamplerState: *const anyopaque,
        CreateQuery: *const anyopaque,
        CreatePredicate: *const anyopaque,
        CreateCounter: *const anyopaque,
        CreateDeferredContext: *const anyopaque,
        OpenSharedResource: *const anyopaque,
        /// What can be done with a format on this device: sampled, rendered
        /// to, blended, used as a display format. A `FormatSupport` out.
        CheckFormatSupport: *const fn (
            *ID3D11Device,
            u32,
            *FormatSupport,
        ) callconv(.winapi) Hresult,
        CheckMultisampleQualityLevels: *const anyopaque,
        CheckCounterInfo: *const anyopaque,
        CheckCounter: *const anyopaque,
        CheckFeatureSupport: *const anyopaque,
        GetPrivateData: *const anyopaque,
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        /// The level this device was granted. The same number `createDevice`
        /// reports, asked of the device itself.
        GetFeatureLevel: *const fn (*ID3D11Device) callconv(.winapi) FeatureLevel,
        GetCreationFlags: *const fn (*ID3D11Device) callconv(.winapi) CreateFlags,
        GetDeviceRemovedReason: *const fn (*ID3D11Device) callconv(.winapi) Hresult,
        GetImmediateContext: *const fn (
            *ID3D11Device,
            *?*ID3D11DeviceContext,
        ) callconv(.winapi) void,
        SetExceptionMode: *const anyopaque,
        GetExceptionMode: *const anyopaque,
    };
};

/// `ID3D11DeviceChild`: everything a device makes.
pub const ID3D11DeviceChild = extern struct {
    vtable: *const VTable,

    pub const iid = Guid.parseComptime("{1841E5C8-16B0-489B-BCC8-44CFB0D5DEAE}");

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        GetDevice: *const fn (*ID3D11DeviceChild, *?*ID3D11Device) callconv(.winapi) void,
        GetPrivateData: *const anyopaque,
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
    };
};

/// `ID3D11DeviceContext`.
///
/// The vtable stops after the four slots it inherits, and the hundred or so
/// that follow - every draw, bind, map and clear in Direct3D 11 - are not
/// declared. A slot that is not declared cannot be called through this
/// binding, and the ones that are declared are at their true indices, so the
/// truncation is safe rather than merely convenient. Drawing is not what a
/// loader is for; a program that wants to draw declares the slots it needs
/// with this vtable as its base.
pub const ID3D11DeviceContext = extern struct {
    vtable: *const VTable,

    pub const iid = Guid.parseComptime("{C0BFA96C-E089-44FB-8EAF-26F8796190DA}");

    pub const VTable = extern struct {
        base: ID3D11DeviceChild.VTable,
    };
};

/// `D3D11_FORMAT_SUPPORT`, as far as the bits that fit in the first word.
pub const FormatSupport = packed struct(u32) {
    buffer: bool = false,
    input_assembler_vertex_buffer: bool = false,
    input_assembler_index_buffer: bool = false,
    so_buffer: bool = false,
    texture1d: bool = false,
    texture2d: bool = false,
    texture3d: bool = false,
    texturecube: bool = false,
    shader_load: bool = false,
    shader_sample: bool = false,
    shader_sample_comparison: bool = false,
    shader_sample_mono_text: bool = false,
    mip: bool = false,
    mip_autogen: bool = false,
    render_target: bool = false,
    blendable: bool = false,
    depth_stencil: bool = false,
    cpu_lockable: bool = false,
    multisample_resolve: bool = false,
    display: bool = false,
    cast_within_bit_layout: bool = false,
    multisample_render_target: bool = false,
    multisample_load: bool = false,
    shader_gather: bool = false,
    back_buffer_cast: bool = false,
    typed_unordered_access_view: bool = false,
    shader_gather_comparison: bool = false,
    decoder_output: bool = false,
    video_processor_output: bool = false,
    video_processor_input: bool = false,
    video_encoder: bool = false,
    _reserved31: u1 = 0,
};

/// `DXGI_FORMAT_R8G8B8A8_UNORM`: the format every swap chain can present and
/// the one worth checking a device against.
pub const format_r8g8b8a8_unorm: u32 = 28;

// -------------------------------------------------------------------------
// Tests
//
// These make real devices. They use WARP wherever they can, because WARP is
// part of Windows and needs no graphics card, so a build server gets the same
// coverage as a workstation. The hardware paths are exercised where there is
// hardware and skipped where there is not.
// -------------------------------------------------------------------------

fn loadOrSkip() !D3d11 {
    return D3d11.load() catch |err| switch (err) {
        error.LibraryNotFound => error.SkipZigTest,
        else => err,
    };
}

test "loading the library" {
    var d3d11 = try loadOrSkip();
    defer d3d11.unload();
    try testing.expect(d3d11.entries.D3D11CreateDeviceAndSwapChain != null);
}

test "a device on the software rasteriser" {
    var d3d11 = try loadOrSkip();
    defer d3d11.unload();

    var device = try d3d11.createDevice(.{ .driver = .warp });
    defer device.release();

    // WARP implements the whole of Direct3D 11, so it grants the top of
    // whatever list it was given.
    try testing.expect(device.level.atLeast(.@"11_0"));
    // And the device agrees with what the create call reported.
    try testing.expectEqual(device.level, device.device.vtable.GetFeatureLevel(device.device));
    // Nothing has gone wrong with it yet.
    try testing.expectEqual(Hresult.s_ok, device.removedReason());
}

test "the flags come back as they went in" {
    var d3d11 = try loadOrSkip();
    defer d3d11.unload();

    var device = try d3d11.createDevice(.{
        .driver = .warp,
        .flags = .{ .bgra_support = true },
    });
    defer device.release();

    // Which is the check that the packed struct really is the bit field the
    // runtime reads: a misplaced field would come back as a different flag.
    const flags = device.device.vtable.GetCreationFlags(device.device);
    try testing.expect(flags.bgra_support);
    try testing.expect(!flags.debug);
    try testing.expect(!flags.singlethreaded);
}

test "the immediate context is the one the device handed out" {
    var d3d11 = try loadOrSkip();
    defer d3d11.unload();

    var device = try d3d11.createDevice(.{ .driver = .warp });
    defer device.release();

    var again: ?*ID3D11DeviceContext = null;
    device.device.vtable.GetImmediateContext(device.device, &again);
    try testing.expect(again != null);
    // There is exactly one per device, so this is the same object - and the
    // call took a reference for it, which has to go back.
    try testing.expectEqual(device.context, again.?);
    _ = com.release(again.?);

    // The context knows which device it belongs to, which is the inherited
    // slot from ID3D11DeviceChild being at the right index.
    const child: *ID3D11DeviceChild = @ptrCast(device.context);
    var owner: ?*ID3D11Device = null;
    child.vtable.GetDevice(child, &owner);
    try testing.expectEqual(device.device, owner.?);
    _ = com.release(owner.?);
}

test "a device on a named adapter" {
    var d3d11 = try loadOrSkip();
    defer d3d11.unload();

    var dxgi_lib = dxgi.Dxgi.load() catch return error.SkipZigTest;
    defer dxgi_lib.unload();

    const factory = try dxgi_lib.createFactory(dxgi.IDXGIFactory1, .{});
    defer _ = com.release(factory);

    // The software adapter, so this works with no card in the machine. Taking
    // this path at all is what checks that naming an adapter sends UNKNOWN as
    // the driver type: anything else here is E_INVALIDARG.
    const warp = dxgi.warpAdapter(factory) catch return error.SkipZigTest;
    defer _ = com.release(warp);

    var device = try d3d11.createDevice(.{ .driver = .{ .adapter = @ptrCast(warp) } });
    defer device.release();
    try testing.expect(device.level.atLeast(.@"11_0"));
}

test "asking what a driver can do without making anything" {
    var d3d11 = try loadOrSkip();
    defer d3d11.unload();

    // WARP is part of Windows, so this one always answers.
    const warp = d3d11.highestLevel(.warp).?;
    try testing.expect(warp.atLeast(.@"11_0"));

    // Hardware may or may not be there, and null is a real answer rather than
    // a failure - a machine with no display adapter reaches this.
    if (d3d11.highestLevel(.hardware)) |hardware| {
        try testing.expect(hardware.atLeast(.@"9_1"));

        // And what the query promised is what a real device is granted.
        var device = try d3d11.createDevice(.{ .levels = FeatureLevel.atOrAbove(.@"9_1") });
        defer device.release();
        try testing.expectEqual(hardware, device.level);
    }
}

test "a level list the hardware cannot meet" {
    var d3d11 = try loadOrSkip();
    defer d3d11.unload();

    // A level no runtime has heard of, in a list of one, so there is nothing
    // to fall back to. The answer is E_INVALIDARG - the whole call refused -
    // rather than a device at some level nobody asked for, which is exactly
    // the behaviour `highestLevel` has to work around and `createDevice`
    // deliberately does not hide.
    const impossible: FeatureLevel = @enumFromInt(0xF000);
    try testing.expectError(error.InvalidArgument, d3d11.createDevice(.{
        .driver = .warp,
        .levels = &.{impossible},
    }));

    // And the same level in a longer list does not poison it for `highestLevel`,
    // which drops entries from the front until the call is accepted.
    try testing.expect(d3d11.highestLevel(.warp).?.atLeast(.@"11_0"));
}

test "what a format is good for" {
    var d3d11 = try loadOrSkip();
    defer d3d11.unload();

    var device = try d3d11.createDevice(.{ .driver = .warp });
    defer device.release();

    var support: FormatSupport = .{};
    try device.device.vtable.CheckFormatSupport(
        device.device,
        format_r8g8b8a8_unorm,
        &support,
    ).check();

    // Eight-bit RGBA is the format everything can present, sample and render
    // to; a device that said otherwise would not be a Direct3D 11 device.
    try testing.expect(support.texture2d);
    try testing.expect(support.render_target);
    try testing.expect(support.shader_sample);
    try testing.expect(support.display);
}

test "the create flags are laid out as the runtime reads them" {
    try testing.expectEqual(@as(u32, 0x1), @as(u32, @bitCast(CreateFlags{ .singlethreaded = true })));
    try testing.expectEqual(@as(u32, 0x2), @as(u32, @bitCast(CreateFlags{ .debug = true })));
    try testing.expectEqual(@as(u32, 0x20), @as(u32, @bitCast(CreateFlags{ .bgra_support = true })));
    try testing.expectEqual(@as(u32, 0x40), @as(u32, @bitCast(CreateFlags{ .debuggable = true })));
    try testing.expectEqual(@as(u32, 0x100), @as(u32, @bitCast(CreateFlags{ .disable_gpu_timeout = true })));
    try testing.expectEqual(@as(u32, 0x800), @as(u32, @bitCast(CreateFlags{ .video_support = true })));
}

test "the format support bits are where the runtime puts them" {
    // Thirty-one bools in a row is easy to get wrong by one, and being wrong
    // by one is silent. These are the ends and the two either side of the gap
    // that CPU_LOCKABLE sits in.
    try testing.expectEqual(@as(u32, 0x1), @as(u32, @bitCast(FormatSupport{ .buffer = true })));
    try testing.expectEqual(@as(u32, 0x20), @as(u32, @bitCast(FormatSupport{ .texture2d = true })));
    try testing.expectEqual(@as(u32, 0x200), @as(u32, @bitCast(FormatSupport{ .shader_sample = true })));
    try testing.expectEqual(@as(u32, 0x4000), @as(u32, @bitCast(FormatSupport{ .render_target = true })));
    try testing.expectEqual(@as(u32, 0x20000), @as(u32, @bitCast(FormatSupport{ .cpu_lockable = true })));
    try testing.expectEqual(@as(u32, 0x80000), @as(u32, @bitCast(FormatSupport{ .display = true })));
    try testing.expectEqual(@as(u32, 0x40000000), @as(u32, @bitCast(FormatSupport{ .video_encoder = true })));
}
