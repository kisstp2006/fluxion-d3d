// SPDX-License-Identifier: CC0-1.0

//! What the examples need beyond the loader: the Direct3D 11 calls that draw.
//!
//! Fluxion D3D stops at a device, on purpose - the slots that make buffers and
//! shaders are in its vtables at their true indices but typed as opaque
//! pointers, and its own documentation says that reaching one means declaring
//! it yourself, once, with the signature checked. This file is that, done
//! once, for the two drawing examples. It is not part of the library and it is
//! not a Direct3D binding; it is the smallest set of declarations that gets a
//! triangle onto a screen.
//!
//! Two things it does not have to repeat. The device's vtable is the loader's,
//! so a `Create` call here is the loader's slot with a signature put on it -
//! `slot(CreateBuffer, device.vtable.CreateBuffer)` - and the index is
//! whatever the loader already got right. And every vtable that extends one
//! the loader declares holds it as its first field, so `IDeviceContext` adds
//! its hundred slots after the four it inherits rather than restating them.
//!
//! The context vtable stops after `ClearDepthStencilView`, which is the last
//! slot anything here calls. That follows the library's rule: a slot that is
//! not declared cannot be called, and the ones that are declared are at their
//! true indices - which the tests at the bottom check by drawing a triangle
//! into a texture and reading the pixels back.

const std = @import("std");
const testing = std.testing;
const d3d = @import("fluxion_d3d");

const com = d3d.com;
const d3d11 = d3d.d3d11;
const dxgi = d3d.dxgi;
const Guid = d3d.Guid;
const Hresult = d3d.Hresult;
const Error = d3d.Error;
const IUnknown = d3d.IUnknown;

/// A `BOOL`: zero is false, anything else is true.
pub const Bool = c_int;

/// Give a type to a slot the loader left opaque. The name and the index come
/// from the loader's vtable, which its own tests already check; all this adds
/// is the signature.
fn slot(comptime Fn: type, pointer: *const anyopaque) Fn {
    return @ptrCast(@alignCast(pointer));
}

// -------------------------------------------------------------------------
// The values the calls take
// -------------------------------------------------------------------------

/// `DXGI_FORMAT`, as far as the examples need it. Non-exhaustive: there are
/// about a hundred and thirty.
pub const Format = enum(u32) {
    unknown = 0,
    r32g32b32a32_float = 2,
    r32g32b32_float = 6,
    r32g32_float = 16,
    /// Eight bits a channel, the format every swap chain can present.
    r8g8b8a8_unorm = 28,
    /// The same with the sRGB curve applied on write.
    r8g8b8a8_unorm_srgb = 29,
    /// Thirty-two bit depth, and the simplest depth buffer to reason about.
    d32_float = 40,
    r32_uint = 42,
    r16_uint = 57,
    /// The channel order the desktop compositor prefers.
    b8g8r8a8_unorm = 87,
    _,
};

/// `D3D11_USAGE`: who writes to a resource and how often.
pub const Usage = enum(u32) {
    /// The GPU reads and writes it. Updated from the CPU through
    /// `UpdateSubresource`, which copies rather than maps.
    default = 0,
    /// Written once, at creation, and never again. The driver may put it
    /// somewhere it could not put a resource that changes.
    immutable = 1,
    /// Written by the CPU every frame and read by the GPU. Mapped, not copied.
    dynamic = 2,
    /// Not usable by the pipeline at all: a resource that exists to be copied
    /// into and read back. The only way to get pixels out of a GPU.
    staging = 3,
};

/// `D3D11_BIND_FLAG`: which parts of the pipeline a resource may be bound to.
/// A resource that is bound to nothing - a staging one - passes zero.
pub const BindFlags = packed struct(u32) {
    vertex_buffer: bool = false,
    index_buffer: bool = false,
    constant_buffer: bool = false,
    shader_resource: bool = false,
    stream_output: bool = false,
    render_target: bool = false,
    depth_stencil: bool = false,
    unordered_access: bool = false,
    decoder: bool = false,
    video_encoder: bool = false,
    _reserved: u22 = 0,
};

/// `D3D11_CPU_ACCESS_FLAG`. The two bits sit high in the word, not at the
/// bottom, which is why this is not three fields at the front.
pub const CpuAccess = packed struct(u32) {
    _reserved0: u16 = 0,
    write: bool = false,
    read: bool = false,
    _reserved18: u14 = 0,
};

/// `D3D11_MAP`.
pub const Map = enum(u32) {
    read = 1,
    write = 2,
    read_write = 3,
    /// Hand back fresh memory rather than waiting for the GPU to finish with
    /// the old. What a per-frame dynamic buffer wants.
    write_discard = 4,
    write_no_overwrite = 5,
};

/// `D3D11_PRIMITIVE_TOPOLOGY`: what the vertices are read as.
pub const Topology = enum(u32) {
    undefined = 0,
    point_list = 1,
    line_list = 2,
    line_strip = 3,
    triangle_list = 4,
    triangle_strip = 5,
    _,
};

/// `D3D11_INPUT_CLASSIFICATION`.
pub const InputClass = enum(u32) {
    per_vertex = 0,
    per_instance = 1,
};

/// `D3D11_COMPARISON_FUNC`.
pub const Comparison = enum(u32) {
    never = 1,
    less = 2,
    equal = 3,
    less_equal = 4,
    greater = 5,
    not_equal = 6,
    greater_equal = 7,
    always = 8,
};

/// `D3D11_DEPTH_WRITE_MASK`.
pub const DepthWriteMask = enum(u32) {
    zero = 0,
    all = 1,
};

/// `D3D11_STENCIL_OP`.
pub const StencilOp = enum(u32) {
    keep = 1,
    zero = 2,
    replace = 3,
    increment_saturate = 4,
    decrement_saturate = 5,
    invert = 6,
    increment = 7,
    decrement = 8,
};

/// `D3D11_CLEAR_FLAG`.
pub const ClearFlags = packed struct(u32) {
    depth: bool = false,
    stencil: bool = false,
    _reserved: u30 = 0,
};

/// `DXGI_SWAP_EFFECT`. The flip models hand the buffer to the compositor
/// instead of copying it, which is what a window on Windows 10 wants.
pub const SwapEffect = enum(u32) {
    discard = 0,
    sequential = 1,
    flip_sequential = 3,
    flip_discard = 4,
};

/// `DXGI_SCALING`.
pub const Scaling = enum(u32) {
    stretch = 0,
    /// The back buffer is not stretched when the window is a different size,
    /// which is what a program that resizes its own buffers wants.
    none = 1,
    aspect_ratio_stretch = 2,
};

/// `DXGI_ALPHA_MODE`.
pub const AlphaMode = enum(u32) {
    unspecified = 0,
    premultiplied = 1,
    straight = 2,
    ignore = 3,
};

/// `DXGI_USAGE_RENDER_TARGET_OUTPUT`.
pub const usage_render_target_output: u32 = 1 << 5;

/// `DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING`. Must be set at creation to present
/// without waiting, and the present call has to pass its own flag as well.
pub const swap_chain_allow_tearing: u32 = 1 << 11;

/// `DXGI_PRESENT_ALLOW_TEARING`. Only legal with a sync interval of zero, and
/// only on a swap chain created with the flag above.
pub const present_allow_tearing: u32 = 1 << 9;

pub const SampleDesc = extern struct {
    count: u32 = 1,
    quality: u32 = 0,
};

pub const SwapChainDesc1 = extern struct {
    /// Zero means "the size of the window", which is what a first swap chain
    /// usually wants.
    width: u32 = 0,
    height: u32 = 0,
    format: Format = .r8g8b8a8_unorm,
    stereo: Bool = 0,
    sample: SampleDesc = .{},
    buffer_usage: u32 = usage_render_target_output,
    /// Two for the flip models, which is the minimum they accept.
    buffer_count: u32 = 2,
    scaling: Scaling = .none,
    swap_effect: SwapEffect = .flip_discard,
    alpha_mode: AlphaMode = .unspecified,
    flags: u32 = 0,
};

pub const BufferDesc = extern struct {
    byte_width: u32,
    usage: Usage = .default,
    bind: BindFlags = .{},
    cpu_access: CpuAccess = .{},
    misc: u32 = 0,
    structure_stride: u32 = 0,
};

pub const Texture2DDesc = extern struct {
    width: u32,
    height: u32,
    mip_levels: u32 = 1,
    array_size: u32 = 1,
    format: Format,
    sample: SampleDesc = .{},
    usage: Usage = .default,
    bind: BindFlags = .{},
    cpu_access: CpuAccess = .{},
    misc: u32 = 0,
};

pub const SubresourceData = extern struct {
    memory: *const anyopaque,
    row_pitch: u32 = 0,
    slice_pitch: u32 = 0,
};

pub const MappedSubresource = extern struct {
    data: ?[*]u8 = null,
    /// Bytes from one row of a texture to the next, which is not the same as
    /// the width times the pixel size: the driver pads rows to suit itself.
    row_pitch: u32 = 0,
    depth_pitch: u32 = 0,
};

pub const Viewport = extern struct {
    left: f32 = 0,
    top: f32 = 0,
    width: f32,
    height: f32,
    min_depth: f32 = 0,
    max_depth: f32 = 1,
};

pub const InputElement = extern struct {
    /// The name in the shader's input struct, after the colon. Must outlive
    /// the `CreateInputLayout` call, which is why these are literals.
    semantic_name: [*:0]const u8,
    semantic_index: u32 = 0,
    format: Format,
    input_slot: u32 = 0,
    /// `append` puts this element straight after the previous one.
    aligned_byte_offset: u32 = append,
    input_slot_class: InputClass = .per_vertex,
    instance_step_rate: u32 = 0,

    /// `D3D11_APPEND_ALIGNED_ELEMENT`: work the offset out from the elements
    /// before this one, rather than counting bytes by hand.
    pub const append: u32 = 0xFFFFFFFF;
};

pub const StencilOpDesc = extern struct {
    fail: StencilOp = .keep,
    depth_fail: StencilOp = .keep,
    pass: StencilOp = .keep,
    function: Comparison = .always,
};

pub const DepthStencilDesc = extern struct {
    depth_enable: Bool = 1,
    depth_write_mask: DepthWriteMask = .all,
    /// `less` is the usual one: a fragment survives when it is nearer than
    /// what is already there.
    depth_function: Comparison = .less,
    stencil_enable: Bool = 0,
    stencil_read_mask: u8 = 0xFF,
    stencil_write_mask: u8 = 0xFF,
    front_face: StencilOpDesc = .{},
    back_face: StencilOpDesc = .{},
};

// -------------------------------------------------------------------------
// The interfaces
// -------------------------------------------------------------------------

/// Everything a device makes. Nothing here calls a method on one beyond
/// `Release`, so each is the inherited vtable and nothing else - the type
/// exists so the compiler can tell a buffer from a shader.
fn DeviceChild(comptime identifier: []const u8) type {
    return extern struct {
        vtable: *const d3d11.ID3D11DeviceChild.VTable,
        pub const iid = Guid.parseComptime(identifier);
    };
}

pub const IBuffer = DeviceChild("{48570B85-D1EE-4FCD-A250-EB350722B037}");
pub const ITexture2D = DeviceChild("{6F15AAF2-D208-4E89-9AB4-489535D34F9C}");
pub const IRenderTargetView = DeviceChild("{DFDBA067-0B8D-4865-875B-D7B4516CC164}");
pub const IDepthStencilView = DeviceChild("{9FDAC92A-1876-48C3-AFAD-25B94F84A9B6}");
pub const IInputLayout = DeviceChild("{E4819DDC-4CF0-4025-BD26-5DE82A3E07B7}");
pub const IVertexShader = DeviceChild("{3B301D64-D678-4289-8897-22F8928B72F3}");
pub const IPixelShader = DeviceChild("{EA82E40D-51DC-4F33-93D4-DB7C9125AE8C}");
pub const IDepthStencilState = DeviceChild("{03823EFB-8D8F-4E1C-9AA2-F64BB2CBFDF1}");

/// `ID3D11Resource`: what a copy and a map take. A texture or a buffer cast
/// to the thing they have in common.
pub const IResource = DeviceChild("{DC8E63F3-D12B-4952-B47B-5E45026A862D}");

/// `ID3D11DeviceContext`, continued.
///
/// The loader declares the four slots this inherits from `ID3D11DeviceChild`
/// and stops. Everything below is what follows them, in order, and the list
/// stops at the last one anything here calls.
pub const IDeviceContext = extern struct {
    vtable: *const VTable,

    pub const iid = d3d11.ID3D11DeviceContext.iid;

    pub const VTable = extern struct {
        base: d3d11.ID3D11DeviceContext.VTable,

        VSSetConstantBuffers: *const fn (
            *IDeviceContext,
            u32,
            u32,
            [*]const ?*IBuffer,
        ) callconv(.winapi) void,
        PSSetShaderResources: *const anyopaque,
        PSSetShader: *const fn (
            *IDeviceContext,
            ?*IPixelShader,
            ?[*]const ?*IUnknown,
            u32,
        ) callconv(.winapi) void,
        PSSetSamplers: *const anyopaque,
        VSSetShader: *const fn (
            *IDeviceContext,
            ?*IVertexShader,
            ?[*]const ?*IUnknown,
            u32,
        ) callconv(.winapi) void,
        DrawIndexed: *const fn (*IDeviceContext, u32, u32, i32) callconv(.winapi) void,
        Draw: *const fn (*IDeviceContext, u32, u32) callconv(.winapi) void,
        Map: *const fn (
            *IDeviceContext,
            *IResource,
            u32,
            Map,
            u32,
            *MappedSubresource,
        ) callconv(.winapi) Hresult,
        Unmap: *const fn (*IDeviceContext, *IResource, u32) callconv(.winapi) void,
        PSSetConstantBuffers: *const fn (
            *IDeviceContext,
            u32,
            u32,
            [*]const ?*IBuffer,
        ) callconv(.winapi) void,
        IASetInputLayout: *const fn (*IDeviceContext, ?*IInputLayout) callconv(.winapi) void,
        IASetVertexBuffers: *const fn (
            *IDeviceContext,
            u32,
            u32,
            [*]const ?*IBuffer,
            [*]const u32,
            [*]const u32,
        ) callconv(.winapi) void,
        IASetIndexBuffer: *const fn (
            *IDeviceContext,
            ?*IBuffer,
            Format,
            u32,
        ) callconv(.winapi) void,
        DrawIndexedInstanced: *const anyopaque,
        DrawInstanced: *const anyopaque,
        GSSetConstantBuffers: *const anyopaque,
        GSSetShader: *const anyopaque,
        IASetPrimitiveTopology: *const fn (*IDeviceContext, Topology) callconv(.winapi) void,
        VSSetShaderResources: *const anyopaque,
        VSSetSamplers: *const anyopaque,
        Begin: *const anyopaque,
        End: *const anyopaque,
        GetData: *const anyopaque,
        SetPredication: *const anyopaque,
        GSSetShaderResources: *const anyopaque,
        GSSetSamplers: *const anyopaque,
        OMSetRenderTargets: *const fn (
            *IDeviceContext,
            u32,
            ?[*]const ?*IRenderTargetView,
            ?*IDepthStencilView,
        ) callconv(.winapi) void,
        OMSetRenderTargetsAndUnorderedAccessViews: *const anyopaque,
        OMSetBlendState: *const anyopaque,
        OMSetDepthStencilState: *const fn (
            *IDeviceContext,
            ?*IDepthStencilState,
            u32,
        ) callconv(.winapi) void,
        SOSetTargets: *const anyopaque,
        DrawAuto: *const anyopaque,
        DrawIndexedInstancedIndirect: *const anyopaque,
        DrawInstancedIndirect: *const anyopaque,
        Dispatch: *const anyopaque,
        DispatchIndirect: *const anyopaque,
        RSSetState: *const anyopaque,
        RSSetViewports: *const fn (
            *IDeviceContext,
            u32,
            ?[*]const Viewport,
        ) callconv(.winapi) void,
        RSSetScissorRects: *const anyopaque,
        CopySubresourceRegion: *const anyopaque,
        CopyResource: *const fn (
            *IDeviceContext,
            *IResource,
            *IResource,
        ) callconv(.winapi) void,
        UpdateSubresource: *const fn (
            *IDeviceContext,
            *IResource,
            u32,
            ?*const anyopaque,
            *const anyopaque,
            u32,
            u32,
        ) callconv(.winapi) void,
        CopyStructureCount: *const anyopaque,
        ClearRenderTargetView: *const fn (
            *IDeviceContext,
            *IRenderTargetView,
            *const [4]f32,
        ) callconv(.winapi) void,
        ClearUnorderedAccessViewUint: *const anyopaque,
        ClearUnorderedAccessViewFloat: *const anyopaque,
        ClearDepthStencilView: *const fn (
            *IDeviceContext,
            *IDepthStencilView,
            ClearFlags,
            f32,
            u8,
        ) callconv(.winapi) void,
        GenerateMips: *const anyopaque,
        SetResourceMinLOD: *const anyopaque,
        GetResourceMinLOD: *const anyopaque,
        ResolveSubresource: *const anyopaque,
        ExecuteCommandList: *const anyopaque,
        HSSetShaderResources: *const anyopaque,
        HSSetShader: *const anyopaque,
        HSSetSamplers: *const anyopaque,
        HSSetConstantBuffers: *const anyopaque,
        DSSetShaderResources: *const anyopaque,
        DSSetShader: *const anyopaque,
        DSSetSamplers: *const anyopaque,
        DSSetConstantBuffers: *const anyopaque,
        CSSetShaderResources: *const anyopaque,
        CSSetUnorderedAccessViews: *const anyopaque,
        CSSetShader: *const anyopaque,
        CSSetSamplers: *const anyopaque,
        CSSetConstantBuffers: *const anyopaque,
        VSGetConstantBuffers: *const anyopaque,
        PSGetShaderResources: *const anyopaque,
        PSGetShader: *const anyopaque,
        PSGetSamplers: *const anyopaque,
        VSGetShader: *const anyopaque,
        PSGetConstantBuffers: *const anyopaque,
        IAGetInputLayout: *const anyopaque,
        IAGetVertexBuffers: *const anyopaque,
        IAGetIndexBuffer: *const anyopaque,
        GSGetConstantBuffers: *const anyopaque,
        GSGetShader: *const anyopaque,
        IAGetPrimitiveTopology: *const anyopaque,
        VSGetShaderResources: *const anyopaque,
        VSGetSamplers: *const anyopaque,
        GetPredication: *const anyopaque,
        GSGetShaderResources: *const anyopaque,
        GSGetSamplers: *const anyopaque,
        /// What is bound to the output stage now. Each view that comes back
        /// has had a reference taken for the caller, so each needs releasing -
        /// which is what makes this a `Get` worth being careful with.
        OMGetRenderTargets: *const fn (
            *IDeviceContext,
            u32,
            ?[*]?*IRenderTargetView,
            ?*?*IDepthStencilView,
        ) callconv(.winapi) void,
        OMGetRenderTargetsAndUnorderedAccessViews: *const anyopaque,
        OMGetBlendState: *const anyopaque,
        OMGetDepthStencilState: *const anyopaque,
        SOGetTargets: *const anyopaque,
        RSGetState: *const anyopaque,
        RSGetViewports: *const anyopaque,
        RSGetScissorRects: *const anyopaque,
        HSGetShaderResources: *const anyopaque,
        HSGetShader: *const anyopaque,
        HSGetSamplers: *const anyopaque,
        HSGetConstantBuffers: *const anyopaque,
        DSGetShaderResources: *const anyopaque,
        DSGetShader: *const anyopaque,
        DSGetSamplers: *const anyopaque,
        DSGetConstantBuffers: *const anyopaque,
        CSGetShaderResources: *const anyopaque,
        CSGetUnorderedAccessViews: *const anyopaque,
        CSGetShader: *const anyopaque,
        CSGetSamplers: *const anyopaque,
        CSGetConstantBuffers: *const anyopaque,
        /// Unbind everything.
        ///
        /// Not tidiness: binding a view keeps a reference to the resource
        /// behind it, so a back buffer that is still bound to the output stage
        /// is still alive however many times its view has been released. That
        /// is what makes `ResizeBuffers` fail, and what leaves a flip-model
        /// swap chain waiting at process exit for buffers the compositor
        /// cannot have back.
        ClearState: *const fn (*IDeviceContext) callconv(.winapi) void,
        /// Send everything recorded so far to the driver and do not wait for
        /// it. Paired with `ClearState` before letting go of a swap chain.
        Flush: *const fn (*IDeviceContext) callconv(.winapi) void,
    };
};

/// `IDXGISwapChain`: the queue of buffers between the program and the screen.
pub const ISwapChain = extern struct {
    vtable: *const VTable,

    pub const iid = Guid.parseComptime("{310D36A0-D2E7-4C0A-AA04-6A9D23B8886A}");

    pub const VTable = extern struct {
        base: dxgi.IDXGIObject.VTable,
        /// From `IDXGIDeviceSubObject`.
        GetDevice: *const anyopaque,
        /// Hand the current back buffer over. A sync interval of 1 waits for
        /// the vertical blank; 0 does not, and needs the tearing flags on a
        /// swap chain created to allow them.
        Present: *const fn (*ISwapChain, u32, u32) callconv(.winapi) Hresult,
        GetBuffer: *const fn (
            *ISwapChain,
            u32,
            *const Guid,
            *?*anyopaque,
        ) callconv(.winapi) Hresult,
        SetFullscreenState: *const anyopaque,
        GetFullscreenState: *const anyopaque,
        GetDesc: *const anyopaque,
        /// Every view of every buffer must be released before this is called,
        /// and they are what a resize is for: the buffers are a different size
        /// afterwards.
        ResizeBuffers: *const fn (
            *ISwapChain,
            u32,
            u32,
            u32,
            Format,
            u32,
        ) callconv(.winapi) Hresult,
        ResizeTarget: *const anyopaque,
        GetContainingOutput: *const anyopaque,
        GetFrameStatistics: *const anyopaque,
        GetLastPresentCount: *const anyopaque,
    };
};

/// `IDXGIFactory2`, with the one slot the examples call given a signature.
pub const IFactory2 = extern struct {
    vtable: *const VTable,

    pub const iid = dxgi.IDXGIFactory2.iid;

    pub const VTable = extern struct {
        base: dxgi.IDXGIFactory1.VTable,
        IsWindowedStereoEnabled: *const anyopaque,
        /// The modern way to attach a swap chain to a window: a smaller
        /// description than the old call took, and the only one that reaches
        /// the flip swap effects.
        CreateSwapChainForHwnd: *const fn (
            *IFactory2,
            *IUnknown,
            ?*anyopaque,
            *const SwapChainDesc1,
            ?*const anyopaque,
            ?*anyopaque,
            *?*ISwapChain,
        ) callconv(.winapi) Hresult,
    };
};

// -------------------------------------------------------------------------
// The device, with the slots the loader left opaque given signatures
// -------------------------------------------------------------------------

pub const Device = struct {
    raw: d3d11.Device,

    pub fn from(raw: d3d11.Device) Device {
        return .{ .raw = raw };
    }

    pub fn release(self: *Device) void {
        self.raw.release();
    }

    pub fn handle(self: Device) *d3d11.ID3D11Device {
        return self.raw.device;
    }

    /// The immediate context, with the drawing half of its vtable in view.
    pub fn context(self: Device) *IDeviceContext {
        return @ptrCast(self.raw.context);
    }

    pub fn createBuffer(self: Device, desc: BufferDesc, initial: ?[]const u8) Error!*IBuffer {
        const create = slot(*const fn (
            *d3d11.ID3D11Device,
            *const BufferDesc,
            ?*const SubresourceData,
            *?*IBuffer,
        ) callconv(.winapi) Hresult, self.handle().vtable.CreateBuffer);

        var data: SubresourceData = undefined;
        if (initial) |bytes| data = .{ .memory = bytes.ptr };

        var buffer: ?*IBuffer = null;
        const result = create(
            self.handle(),
            &desc,
            if (initial == null) null else &data,
            &buffer,
        );
        return com.received(IBuffer, result, buffer);
    }

    /// A buffer holding one value, for the constants a shader reads.
    ///
    /// The size is rounded up to sixteen bytes, because a constant buffer that
    /// is not a multiple of a float4 is `E_INVALIDARG` and the reason is never
    /// obvious from the message.
    pub fn createConstantBuffer(self: Device, comptime T: type) Error!*IBuffer {
        return self.createBuffer(.{
            .byte_width = std.mem.alignForward(u32, @sizeOf(T), 16),
            .usage = .default,
            .bind = .{ .constant_buffer = true },
        }, null);
    }

    pub fn createTexture2D(self: Device, desc: Texture2DDesc) Error!*ITexture2D {
        const create = slot(*const fn (
            *d3d11.ID3D11Device,
            *const Texture2DDesc,
            ?*const SubresourceData,
            *?*ITexture2D,
        ) callconv(.winapi) Hresult, self.handle().vtable.CreateTexture2D);

        var texture: ?*ITexture2D = null;
        return com.received(ITexture2D, create(self.handle(), &desc, null, &texture), texture);
    }

    /// A view that lets the pipeline draw into a resource. A null description
    /// means "the format the resource already has", which is what everything
    /// here wants.
    pub fn createRenderTargetView(self: Device, resource: *IResource) Error!*IRenderTargetView {
        const create = slot(*const fn (
            *d3d11.ID3D11Device,
            *IResource,
            ?*const anyopaque,
            *?*IRenderTargetView,
        ) callconv(.winapi) Hresult, self.handle().vtable.CreateRenderTargetView);

        var view: ?*IRenderTargetView = null;
        return com.received(IRenderTargetView, create(self.handle(), resource, null, &view), view);
    }

    pub fn createDepthStencilView(self: Device, resource: *IResource) Error!*IDepthStencilView {
        const create = slot(*const fn (
            *d3d11.ID3D11Device,
            *IResource,
            ?*const anyopaque,
            *?*IDepthStencilView,
        ) callconv(.winapi) Hresult, self.handle().vtable.CreateDepthStencilView);

        var view: ?*IDepthStencilView = null;
        return com.received(IDepthStencilView, create(self.handle(), resource, null, &view), view);
    }

    pub fn createDepthStencilState(self: Device, desc: DepthStencilDesc) Error!*IDepthStencilState {
        const create = slot(*const fn (
            *d3d11.ID3D11Device,
            *const DepthStencilDesc,
            *?*IDepthStencilState,
        ) callconv(.winapi) Hresult, self.handle().vtable.CreateDepthStencilState);

        var state: ?*IDepthStencilState = null;
        return com.received(IDepthStencilState, create(self.handle(), &desc, &state), state);
    }

    /// How the bytes in a vertex buffer line up with the shader's input.
    ///
    /// The vertex shader's bytecode is passed in as well, and not as a
    /// formality: the runtime checks the layout against the signature the
    /// shader was compiled with, so a mismatch is an error here rather than
    /// wrong pixels later.
    pub fn createInputLayout(
        self: Device,
        elements: []const InputElement,
        vertex_shader_code: []const u8,
    ) Error!*IInputLayout {
        const create = slot(*const fn (
            *d3d11.ID3D11Device,
            [*]const InputElement,
            u32,
            [*]const u8,
            usize,
            *?*IInputLayout,
        ) callconv(.winapi) Hresult, self.handle().vtable.CreateInputLayout);

        var layout: ?*IInputLayout = null;
        const result = create(
            self.handle(),
            elements.ptr,
            @intCast(elements.len),
            vertex_shader_code.ptr,
            vertex_shader_code.len,
            &layout,
        );
        return com.received(IInputLayout, result, layout);
    }

    pub fn createVertexShader(self: Device, code: []const u8) Error!*IVertexShader {
        const create = slot(*const fn (
            *d3d11.ID3D11Device,
            [*]const u8,
            usize,
            ?*IUnknown,
            *?*IVertexShader,
        ) callconv(.winapi) Hresult, self.handle().vtable.CreateVertexShader);

        var shader: ?*IVertexShader = null;
        const result = create(self.handle(), code.ptr, code.len, null, &shader);
        return com.received(IVertexShader, result, shader);
    }

    pub fn createPixelShader(self: Device, code: []const u8) Error!*IPixelShader {
        const create = slot(*const fn (
            *d3d11.ID3D11Device,
            [*]const u8,
            usize,
            ?*IUnknown,
            *?*IPixelShader,
        ) callconv(.winapi) Hresult, self.handle().vtable.CreatePixelShader);

        var shader: ?*IPixelShader = null;
        const result = create(self.handle(), code.ptr, code.len, null, &shader);
        return com.received(IPixelShader, result, shader);
    }
};

/// Anything a copy or a map takes, as the type they have in common.
pub fn asResource(object: anytype) *IResource {
    return @ptrCast(object);
}

// -------------------------------------------------------------------------
// A window's worth of swap chain
// -------------------------------------------------------------------------

/// A swap chain, the current back buffer's view, and the size they were made
/// at.
pub const Surface = struct {
    swap_chain: *ISwapChain,
    target: *IRenderTargetView,
    depth: ?*IDepthStencilView = null,
    depth_texture: ?*ITexture2D = null,
    width: u32,
    height: u32,

    /// Attach a swap chain to a window and make a view of its back buffer.
    ///
    /// `depth` adds a depth buffer, which a 3D scene needs and a 2D one does
    /// not: without it the last triangle drawn is the one that shows.
    pub fn init(
        device: Device,
        factory: *dxgi.IDXGIFactory1,
        window: *anyopaque,
        options: Options,
    ) Error!Surface {
        const factory2: *IFactory2 = @ptrCast(try com.queryInterface(factory, dxgi.IDXGIFactory2));
        defer _ = com.release(factory2);

        var desc: SwapChainDesc1 = .{ .format = options.format };
        if (options.tearing) desc.flags |= swap_chain_allow_tearing;

        var swap_chain: ?*ISwapChain = null;
        try factory2.vtable.CreateSwapChainForHwnd(
            factory2,
            com.unknown(device.handle()),
            window,
            &desc,
            null,
            null,
            &swap_chain,
        ).check();
        errdefer _ = com.release(swap_chain.?);

        var self: Surface = .{
            .swap_chain = swap_chain.?,
            .target = undefined,
            .width = 0,
            .height = 0,
        };
        try self.attach(device, options.depth);
        return self;
    }

    pub const Options = struct {
        format: Format = .r8g8b8a8_unorm,
        depth: bool = false,
        tearing: bool = false,
    };

    /// Take a view of the current back buffer, and a depth buffer to match.
    /// Called once at creation and again after every resize.
    fn attach(self: *Surface, device: Device, want_depth: bool) Error!void {
        var raw: ?*anyopaque = null;
        try self.swap_chain.vtable.GetBuffer(
            self.swap_chain,
            0,
            com.iidOf(ITexture2D),
            &raw,
        ).check();
        const back_buffer = try com.received(ITexture2D, .s_ok, raw);
        // The view keeps its own reference to the texture, so this one goes
        // back as soon as the view exists.
        defer _ = com.release(back_buffer);

        self.target = try device.createRenderTargetView(asResource(back_buffer));
        errdefer _ = com.release(self.target);

        const extent = try self.size();
        self.width = extent[0];
        self.height = extent[1];

        if (!want_depth) return;
        const texture = try device.createTexture2D(.{
            .width = self.width,
            .height = self.height,
            .format = .d32_float,
            .bind = .{ .depth_stencil = true },
        });
        errdefer _ = com.release(texture);
        self.depth = try device.createDepthStencilView(asResource(texture));
        self.depth_texture = texture;
    }

    /// The back buffer's size, which is the window's client area unless the
    /// swap chain was made at a fixed size.
    fn size(self: Surface) Error![2]u32 {
        // Read it back off the texture rather than trusting the window: DXGI
        // rounds, and a zero-size window is a real state while it is being
        // created.
        var raw: ?*anyopaque = null;
        try self.swap_chain.vtable.GetBuffer(
            self.swap_chain,
            0,
            com.iidOf(ITexture2D),
            &raw,
        ).check();
        const texture = try com.received(ITexture2D, .s_ok, raw);
        defer _ = com.release(texture);
        const desc = try describeTexture(texture);
        return .{ desc.width, desc.height };
    }

    /// Point the pipeline at this surface, and clear it.
    pub fn begin(self: Surface, context: *IDeviceContext, clear: [4]f32) void {
        const targets = [_]?*IRenderTargetView{self.target};
        context.vtable.OMSetRenderTargets(context, 1, &targets, self.depth);
        context.vtable.ClearRenderTargetView(context, self.target, &clear);
        if (self.depth) |view| {
            // One is the far plane, and clearing to it means every fragment
            // starts out nearer than nothing.
            context.vtable.ClearDepthStencilView(context, view, .{ .depth = true }, 1.0, 0);
        }
        const viewport: Viewport = .{
            .width = @floatFromInt(self.width),
            .height = @floatFromInt(self.height),
        };
        context.vtable.RSSetViewports(context, 1, &[_]Viewport{viewport});
    }

    /// Hand the frame over. `vsync` waits for the vertical blank, which is
    /// also what keeps a loop that draws nothing from spinning a core flat.
    pub fn present(self: Surface, vsync: bool) Error!void {
        try self.swap_chain.vtable.Present(self.swap_chain, if (vsync) 1 else 0, 0).check();
    }

    /// Make the back buffers match the window again.
    ///
    /// Nothing may still refer to the old buffers, and releasing the views is
    /// not enough on its own: a view that is bound to the pipeline is held by
    /// the pipeline too. Hence `release`, which drops every reference this
    /// value has.
    pub fn resize(self: *Surface, device: Device, width: u32, height: u32) Error!void {
        if (width == 0 or height == 0) return;
        const wanted_depth = self.depth != null;
        self.release(device);
        try self.swap_chain.vtable.ResizeBuffers(
            self.swap_chain,
            0,
            width,
            height,
            .unknown,
            0,
        ).check();
        try self.attach(device, wanted_depth);
    }

    /// Let go of the views, and of the pipeline's hold on them.
    fn release(self: *Surface, device: Device) void {
        // Unbind first. A back buffer bound to the output stage stays alive
        // however many times its view is released, which is exactly what
        // `ResizeBuffers` refuses to work around - and what leaves a
        // flip-model swap chain waiting at process exit.
        const context = device.context();
        context.vtable.ClearState(context);
        context.vtable.Flush(context);

        _ = com.release(self.target);
        if (self.depth) |view| _ = com.release(view);
        if (self.depth_texture) |texture| _ = com.release(texture);
        self.depth = null;
        self.depth_texture = null;
    }

    pub fn deinit(self: *Surface, device: Device) void {
        self.release(device);
        _ = com.release(self.swap_chain);
        self.* = undefined;
    }
};

/// A texture's description, read back through the loader's opaque slot.
fn describeTexture(texture: *ITexture2D) Error!Texture2DDesc {
    // `GetDesc` is the first of ID3D11Texture2D's own slots, after the five it
    // inherits from ID3D11Resource, which are after ID3D11DeviceChild's four.
    const VTable = extern struct {
        base: d3d11.ID3D11DeviceChild.VTable,
        GetType: *const anyopaque,
        SetEvictionPriority: *const anyopaque,
        GetEvictionPriority: *const anyopaque,
        GetDesc: *const fn (*ITexture2D, *Texture2DDesc) callconv(.winapi) void,
    };
    const full: *const VTable = @ptrCast(texture.vtable);
    var desc: Texture2DDesc = undefined;
    full.GetDesc(texture, &desc);
    return desc;
}

// -------------------------------------------------------------------------
// Tests
//
// Every slot index above is a guess until something calls it, so these draw
// into a texture and read the pixels back. They run on WARP, so a machine with
// no graphics card gets the same coverage as one with two.
// -------------------------------------------------------------------------

const flat_vs =
    \\struct Vertex { float3 position : POSITION; float4 colour : COLOR; };
    \\struct Fragment { float4 position : SV_POSITION; float4 colour : COLOR; };
    \\
    \\cbuffer Constants : register(b0) { float4 tint; };
    \\
    \\Fragment main(Vertex input) {
    \\    Fragment output;
    \\    output.position = float4(input.position, 1.0);
    \\    output.colour = input.colour * tint;
    \\    return output;
    \\}
;

const flat_ps =
    \\struct Fragment { float4 position : SV_POSITION; float4 colour : COLOR; };
    \\float4 main(Fragment input) : SV_TARGET { return input.colour; }
;

const Vertex = extern struct {
    position: [3]f32,
    colour: [4]f32,
};

const vertex_layout = [_]InputElement{
    .{ .semantic_name = "POSITION", .format = .r32g32b32_float },
    .{ .semantic_name = "COLOR", .format = .r32g32b32a32_float },
};

/// A texture to draw into and a staging copy to read back through - which is
/// the only way to see what a GPU actually produced.
///
/// This is here rather than in the tests because it is what makes a renderer
/// testable at all: a picture that can be checked pixel by pixel, with no
/// window, no display and no card. The tests below use it, and so does the
/// cube example.
pub const Offscreen = struct {
    device: Device,
    texture: *ITexture2D,
    target: *IRenderTargetView,
    staging: *ITexture2D,
    depth: ?*IDepthStencilView = null,
    depth_texture: ?*ITexture2D = null,
    width: u32,
    height: u32,

    pub fn init(device: Device, width: u32, height: u32, want_depth: bool) !Offscreen {
        const texture = try device.createTexture2D(.{
            .width = width,
            .height = height,
            .format = .r8g8b8a8_unorm,
            .bind = .{ .render_target = true },
        });
        // The pipeline cannot read a staging resource and the CPU cannot read
        // anything else, so getting pixels back means two textures and a copy
        // between them. There is no shorter way.
        const staging = try device.createTexture2D(.{
            .width = width,
            .height = height,
            .format = .r8g8b8a8_unorm,
            .usage = .staging,
            .cpu_access = .{ .read = true },
        });
        var self: Offscreen = .{
            .device = device,
            .texture = texture,
            .target = try device.createRenderTargetView(asResource(texture)),
            .staging = staging,
            .width = width,
            .height = height,
        };
        if (want_depth) {
            const depth_texture = try device.createTexture2D(.{
                .width = width,
                .height = height,
                .format = .d32_float,
                .bind = .{ .depth_stencil = true },
            });
            self.depth_texture = depth_texture;
            self.depth = try device.createDepthStencilView(asResource(depth_texture));
        }
        return self;
    }

    /// A square one, which is what a test that only wants to look at a few
    /// pixels wants.
    pub fn square(device: Device, size: u32, want_depth: bool) !Offscreen {
        return init(device, size, size, want_depth);
    }

    pub fn begin(self: Offscreen, clear: [4]f32) void {
        const context = self.device.context();
        const targets = [_]?*IRenderTargetView{self.target};
        context.vtable.OMSetRenderTargets(context, 1, &targets, self.depth);
        context.vtable.ClearRenderTargetView(context, self.target, &clear);
        if (self.depth) |view| {
            context.vtable.ClearDepthStencilView(context, view, .{ .depth = true }, 1.0, 0);
        }
        context.vtable.RSSetViewports(context, 1, &[_]Viewport{.{
            .width = @floatFromInt(self.width),
            .height = @floatFromInt(self.height),
        }});
    }

    /// The whole image, as the GPU produced it, borrowed until `end`.
    ///
    /// A pixel is at `pixels[y * row_pitch + x * 4]`, and the pitch is the
    /// driver's rather than the width's: rows are padded to suit the hardware,
    /// so the arithmetic has to come from the map and not from the size the
    /// texture was asked for.
    pub const Readback = struct {
        context: *IDeviceContext,
        staging: *IResource,
        pixels: []const u8,
        row_pitch: usize,

        pub fn at(self: Readback, x: u32, y: u32) [4]u8 {
            return self.pixels[y * self.row_pitch + x * 4 ..][0..4].*;
        }

        pub fn end(self: *Readback) void {
            self.context.vtable.Unmap(self.context, self.staging, 0);
            self.* = undefined;
        }
    };

    /// Copy the rendered texture into the staging one and map it.
    pub fn read(self: Offscreen) Error!Readback {
        const context = self.device.context();
        const staging = asResource(self.staging);
        context.vtable.CopyResource(context, staging, asResource(self.texture));

        var mapped: MappedSubresource = .{};
        try context.vtable.Map(context, staging, 0, .read, 0, &mapped).check();
        errdefer context.vtable.Unmap(context, staging, 0);

        const bytes = mapped.data orelse return error.NullPointer;
        return .{
            .context = context,
            .staging = staging,
            .pixels = bytes[0 .. mapped.row_pitch * self.height],
            .row_pitch = mapped.row_pitch,
        };
    }

    /// One pixel. A whole map and unmap for each, which is fine for a test
    /// looking at four of them and not what `read` is for.
    pub fn pixel(self: Offscreen, x: u32, y: u32) ![4]u8 {
        var readback = try self.read();
        defer readback.end();
        return readback.at(x, y);
    }

    pub fn deinit(self: *Offscreen) void {
        if (self.depth) |view| _ = com.release(view);
        if (self.depth_texture) |texture| _ = com.release(texture);
        com.releaseAll(.{ self.target, self.texture, self.staging });
        self.* = undefined;
    }
};

/// Everything the tests below share: a WARP device, the compiler, and a
/// shader pair built from the source above.
const Fixture = struct {
    d3d11_library: d3d.D3d11,
    compiler: d3d.Compiler,
    device: Device,
    vertex_shader: *IVertexShader,
    pixel_shader: *IPixelShader,
    layout: *IInputLayout,
    constants: *IBuffer,

    fn init() !Fixture {
        var d3d11_library = d3d.D3d11.load() catch return error.SkipZigTest;
        errdefer d3d11_library.unload();
        var compiler = d3d.Compiler.load() catch return error.SkipZigTest;
        errdefer compiler.unload();

        // WARP: no graphics card needed, and the same answers everywhere.
        var device: Device = .from(try d3d11_library.createDevice(.{ .driver = .warp }));
        errdefer device.release();

        var vs_output = compiler.compile(flat_vs, .{ .target = "vs_5_0", .name = "flat.vs.hlsl" });
        defer vs_output.release();
        const vs_code = vs_output.check() catch {
            std.debug.print("{s}\n", .{vs_output.text()});
            return error.ShaderFailed;
        };

        var ps_output = compiler.compile(flat_ps, .{ .target = "ps_5_0", .name = "flat.ps.hlsl" });
        defer ps_output.release();
        const ps_code = ps_output.check() catch {
            std.debug.print("{s}\n", .{ps_output.text()});
            return error.ShaderFailed;
        };

        return .{
            .d3d11_library = d3d11_library,
            .compiler = compiler,
            .device = device,
            .vertex_shader = try device.createVertexShader(vs_code.bytes()),
            .pixel_shader = try device.createPixelShader(ps_code.bytes()),
            // The layout is checked against the shader's signature, so this
            // call failing would mean the two disagree.
            .layout = try device.createInputLayout(&vertex_layout, vs_code.bytes()),
            .constants = try device.createConstantBuffer([4]f32),
        };
    }

    /// Bind everything and set the tint the vertex shader multiplies by.
    fn bind(self: Fixture, tint: [4]f32) void {
        const context = self.device.context();
        context.vtable.UpdateSubresource(
            context,
            asResource(self.constants),
            0,
            null,
            &tint,
            0,
            0,
        );
        const buffers = [_]?*IBuffer{self.constants};
        context.vtable.VSSetConstantBuffers(context, 0, 1, &buffers);
        context.vtable.IASetInputLayout(context, self.layout);
        context.vtable.IASetPrimitiveTopology(context, .triangle_list);
        context.vtable.VSSetShader(context, self.vertex_shader, null, 0);
        context.vtable.PSSetShader(context, self.pixel_shader, null, 0);
    }

    fn deinit(self: *Fixture) void {
        com.releaseAll(.{ self.constants, self.layout, self.pixel_shader, self.vertex_shader });
        self.device.release();
        self.compiler.unload();
        self.d3d11_library.unload();
        self.* = undefined;
    }
};

fn expectPixel(expected: [4]u8, actual: [4]u8) !void {
    // WARP is exact for a flat fill, but a pixel on the very edge of a
    // triangle is a coin toss, so the tests sample well inside one.
    try testing.expectEqualSlices(u8, &expected, &actual);
}

test "a triangle, drawn and read back" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var screen = try Offscreen.square(fixture.device, 64, false);
    defer screen.deinit();

    // A triangle around the middle of the image, red, on a blue field.
    const vertices = [_]Vertex{
        .{ .position = .{ -0.6, -0.6, 0 }, .colour = .{ 1, 0, 0, 1 } },
        .{ .position = .{ 0.0, 0.6, 0 }, .colour = .{ 1, 0, 0, 1 } },
        .{ .position = .{ 0.6, -0.6, 0 }, .colour = .{ 1, 0, 0, 1 } },
    };
    const buffer = try fixture.device.createBuffer(.{
        .byte_width = @sizeOf(@TypeOf(vertices)),
        .usage = .immutable,
        .bind = .{ .vertex_buffer = true },
    }, std.mem.asBytes(&vertices));
    defer _ = com.release(buffer);

    screen.begin(.{ 0, 0, 1, 1 });
    fixture.bind(.{ 1, 1, 1, 1 });

    const context = fixture.device.context();
    const buffers = [_]?*IBuffer{buffer};
    context.vtable.IASetVertexBuffers(
        context,
        0,
        1,
        &buffers,
        &[_]u32{@sizeOf(Vertex)},
        &[_]u32{0},
    );
    context.vtable.Draw(context, 3, 0);

    // The middle is inside the triangle and the corner is not, so this is a
    // real check on the whole pipeline rather than on the clear.
    try expectPixel(.{ 255, 0, 0, 255 }, try screen.pixel(32, 32));
    try expectPixel(.{ 0, 0, 255, 255 }, try screen.pixel(2, 2));
    try expectPixel(.{ 0, 0, 255, 255 }, try screen.pixel(61, 2));
}

test "the constant buffer reaches the shader" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var screen = try Offscreen.square(fixture.device, 64, false);
    defer screen.deinit();

    // White vertices, so whatever comes out is the tint and nothing else.
    const vertices = [_]Vertex{
        .{ .position = .{ -0.9, -0.9, 0 }, .colour = .{ 1, 1, 1, 1 } },
        .{ .position = .{ 0.0, 0.9, 0 }, .colour = .{ 1, 1, 1, 1 } },
        .{ .position = .{ 0.9, -0.9, 0 }, .colour = .{ 1, 1, 1, 1 } },
    };
    const buffer = try fixture.device.createBuffer(.{
        .byte_width = @sizeOf(@TypeOf(vertices)),
        .usage = .immutable,
        .bind = .{ .vertex_buffer = true },
    }, std.mem.asBytes(&vertices));
    defer _ = com.release(buffer);

    const context = fixture.device.context();
    const buffers = [_]?*IBuffer{buffer};

    for ([_][2][4]f32{
        .{ .{ 0, 1, 0, 1 }, .{ 0, 1, 0, 1 } },
        .{ .{ 1, 0, 1, 1 }, .{ 1, 0, 1, 1 } },
    }) |pair| {
        const tint = pair[0];
        screen.begin(.{ 0, 0, 0, 1 });
        fixture.bind(tint);
        context.vtable.IASetVertexBuffers(context, 0, 1, &buffers, &[_]u32{@sizeOf(Vertex)}, &[_]u32{0});
        context.vtable.Draw(context, 3, 0);

        const expected = [4]u8{
            @intFromFloat(pair[1][0] * 255),
            @intFromFloat(pair[1][1] * 255),
            @intFromFloat(pair[1][2] * 255),
            255,
        };
        try expectPixel(expected, try screen.pixel(32, 40));
    }
}

test "an index buffer draws the same triangle twice as cheaply" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var screen = try Offscreen.square(fixture.device, 64, false);
    defer screen.deinit();

    // Four corners, six indices: a quad over the middle of the image.
    const vertices = [_]Vertex{
        .{ .position = .{ -0.5, -0.5, 0 }, .colour = .{ 0, 1, 0, 1 } },
        .{ .position = .{ -0.5, 0.5, 0 }, .colour = .{ 0, 1, 0, 1 } },
        .{ .position = .{ 0.5, 0.5, 0 }, .colour = .{ 0, 1, 0, 1 } },
        .{ .position = .{ 0.5, -0.5, 0 }, .colour = .{ 0, 1, 0, 1 } },
    };
    // Clockwise as seen on screen, which is the front face by default.
    const indices = [_]u16{ 0, 1, 2, 0, 2, 3 };

    const vertex_buffer = try fixture.device.createBuffer(.{
        .byte_width = @sizeOf(@TypeOf(vertices)),
        .usage = .immutable,
        .bind = .{ .vertex_buffer = true },
    }, std.mem.asBytes(&vertices));
    defer _ = com.release(vertex_buffer);

    const index_buffer = try fixture.device.createBuffer(.{
        .byte_width = @sizeOf(@TypeOf(indices)),
        .usage = .immutable,
        .bind = .{ .index_buffer = true },
    }, std.mem.asBytes(&indices));
    defer _ = com.release(index_buffer);

    screen.begin(.{ 0, 0, 0, 1 });
    fixture.bind(.{ 1, 1, 1, 1 });

    const context = fixture.device.context();
    context.vtable.IASetVertexBuffers(
        context,
        0,
        1,
        &[_]?*IBuffer{vertex_buffer},
        &[_]u32{@sizeOf(Vertex)},
        &[_]u32{0},
    );
    context.vtable.IASetIndexBuffer(context, index_buffer, .r16_uint, 0);
    context.vtable.DrawIndexed(context, indices.len, 0, 0);

    // Both halves of the quad, and outside it.
    try expectPixel(.{ 0, 255, 0, 255 }, try screen.pixel(24, 24));
    try expectPixel(.{ 0, 255, 0, 255 }, try screen.pixel(40, 40));
    try expectPixel(.{ 0, 0, 0, 255 }, try screen.pixel(2, 2));
}

test "the depth buffer decides which triangle shows" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var screen = try Offscreen.square(fixture.device, 64, true);
    defer screen.deinit();

    const state = try fixture.device.createDepthStencilState(.{});
    defer _ = com.release(state);

    // Two overlapping triangles, the red one nearer. It is drawn first, so
    // without a depth test the green one would win - which is exactly what
    // this checks.
    const near = [_]Vertex{
        .{ .position = .{ -0.8, -0.8, 0.2 }, .colour = .{ 1, 0, 0, 1 } },
        .{ .position = .{ 0.0, 0.8, 0.2 }, .colour = .{ 1, 0, 0, 1 } },
        .{ .position = .{ 0.8, -0.8, 0.2 }, .colour = .{ 1, 0, 0, 1 } },
    };
    const far = [_]Vertex{
        .{ .position = .{ -0.8, -0.8, 0.8 }, .colour = .{ 0, 1, 0, 1 } },
        .{ .position = .{ 0.0, 0.8, 0.8 }, .colour = .{ 0, 1, 0, 1 } },
        .{ .position = .{ 0.8, -0.8, 0.8 }, .colour = .{ 0, 1, 0, 1 } },
    };

    const near_buffer = try fixture.device.createBuffer(.{
        .byte_width = @sizeOf(@TypeOf(near)),
        .usage = .immutable,
        .bind = .{ .vertex_buffer = true },
    }, std.mem.asBytes(&near));
    defer _ = com.release(near_buffer);
    const far_buffer = try fixture.device.createBuffer(.{
        .byte_width = @sizeOf(@TypeOf(far)),
        .usage = .immutable,
        .bind = .{ .vertex_buffer = true },
    }, std.mem.asBytes(&far));
    defer _ = com.release(far_buffer);

    screen.begin(.{ 0, 0, 0, 1 });
    fixture.bind(.{ 1, 1, 1, 1 });

    const context = fixture.device.context();
    context.vtable.OMSetDepthStencilState(context, state, 0);
    for ([_]*IBuffer{ near_buffer, far_buffer }) |buffer| {
        context.vtable.IASetVertexBuffers(
            context,
            0,
            1,
            &[_]?*IBuffer{buffer},
            &[_]u32{@sizeOf(Vertex)},
            &[_]u32{0},
        );
        context.vtable.Draw(context, 3, 0);
    }

    // The nearer one, drawn first, is still the one on screen.
    try expectPixel(.{ 255, 0, 0, 255 }, try screen.pixel(32, 32));
}

test "clearing the state really unbinds" {
    // `ClearState` and `Flush` are the last two slots in the context's vtable,
    // fifty-eight past the last one anything else here calls, and getting
    // either index wrong would call the wrong function silently. So this
    // checks what they did rather than that they returned: bind a target, ask
    // what is bound, clear, and ask again.
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var screen = try Offscreen.square(fixture.device, 32, false);
    defer screen.deinit();

    const context = fixture.device.context();
    screen.begin(.{ 0, 0, 0, 1 });

    var bound: [1]?*IRenderTargetView = .{null};
    context.vtable.OMGetRenderTargets(context, 1, &bound, null);
    try testing.expectEqual(screen.target, bound[0].?);
    // The call took a reference for the caller, as every `Get` does.
    _ = com.release(bound[0].?);

    context.vtable.ClearState(context);
    context.vtable.Flush(context);

    bound[0] = null;
    context.vtable.OMGetRenderTargets(context, 1, &bound, null);
    try testing.expectEqual(@as(?*IRenderTargetView, null), bound[0]);
}

test "the structs are shaped the way the runtime reads them" {
    // These cross into code this program did not compile, so their layout has
    // to match the header rather than merely look right.
    try testing.expectEqual(@as(usize, 24), @sizeOf(BufferDesc));
    try testing.expectEqual(@as(usize, 24), @sizeOf(Viewport));
    try testing.expectEqual(@as(u32, 1), @as(u32, @bitCast(BindFlags{ .vertex_buffer = true })));
    try testing.expectEqual(@as(u32, 2), @as(u32, @bitCast(BindFlags{ .index_buffer = true })));
    try testing.expectEqual(@as(u32, 4), @as(u32, @bitCast(BindFlags{ .constant_buffer = true })));
    try testing.expectEqual(@as(u32, 0x20), @as(u32, @bitCast(BindFlags{ .render_target = true })));
    try testing.expectEqual(@as(u32, 0x40), @as(u32, @bitCast(BindFlags{ .depth_stencil = true })));
    // The CPU access bits are at 0x10000 and 0x20000, not at the bottom.
    try testing.expectEqual(@as(u32, 0x10000), @as(u32, @bitCast(CpuAccess{ .write = true })));
    try testing.expectEqual(@as(u32, 0x20000), @as(u32, @bitCast(CpuAccess{ .read = true })));
    try testing.expectEqual(@as(u32, 0x800), swap_chain_allow_tearing);
    try testing.expectEqual(@as(u32, 0x200), present_allow_tearing);
}
