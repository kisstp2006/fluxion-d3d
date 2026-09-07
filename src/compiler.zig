// SPDX-License-Identifier: CC0-1.0

//! `d3dcompiler_47.dll`: HLSL in, bytecode out.
//!
//! Shaders can be compiled when a program is built, and for anything shipping
//! they should be - compilation is slow, the compiler is another dependency,
//! and a syntax error found at run time is found by a customer. But a program
//! has to load the bytecode from somewhere either way, and the compiler is a
//! DLL with the same problem as the rest of Direct3D: it is present on a
//! stock Windows 10 or 11 and absent on a stripped-down server install, and a
//! program that imports `D3DCompile` the ordinary way does not start where it
//! is missing.
//!
//! So it loads like everything else here, and a machine without it is a
//! `error.LibraryNotFound` to plan around rather than a program that will not
//! run.
//!
//! ```zig
//! var compiler = try Compiler.load();
//! defer compiler.unload();
//!
//! var output = compiler.compile(source, .{ .target = "vs_5_0" });
//! defer output.release();
//! const code = output.check() catch {
//!     std.debug.print("{s}\n", .{output.text()});
//!     return error.ShaderFailed;
//! };
//! ```
//!
//! `Output` carries the messages alongside the result rather than throwing
//! them away, because a compiler that says only "failed" is not much of a
//! compiler: the line number and the reason are the whole value.
//!
//! This is the old compiler, which produces the DXBC that Direct3D 11 and
//! shader model 5.1 take. Shader model 6 is DXIL and comes from `dxcompiler.dll`,
//! which does not ship with Windows and is a different library's problem.

const std = @import("std");
const testing = std.testing;

const com = @import("com.zig");
const dll = @import("dll.zig");
const hresult = @import("hresult.zig");

const Hresult = hresult.Hresult;
const Error = hresult.Error;
const ID3DBlob = com.ID3DBlob;

/// `d3dcompiler_47.dll`, loaded, with its entry points resolved.
pub const Compiler = struct {
    library: dll.Library,
    entries: Entries,

    pub const Entries = struct {
        D3DCompile: *const fn (
            source: [*]const u8,
            source_len: usize,
            source_name: ?[*:0]const u8,
            defines: ?[*]const Macro,
            include: ?*anyopaque,
            entry_point: ?[*:0]const u8,
            target: [*:0]const u8,
            flags1: Flags,
            flags2: u32,
            code_out: *?*ID3DBlob,
            errors_out: *?*ID3DBlob,
        ) callconv(.winapi) Hresult,
        /// The same with a secondary data blob, for the compiler's
        /// experimental paths. Rarely wanted.
        D3DCompile2: ?*const anyopaque = null,
        /// Runs the preprocessor and stops, which is how to find out what the
        /// `#if`s actually left behind.
        D3DPreprocess: ?*const fn (
            source: [*]const u8,
            source_len: usize,
            source_name: ?[*:0]const u8,
            defines: ?[*]const Macro,
            include: ?*anyopaque,
            text_out: *?*ID3DBlob,
            errors_out: *?*ID3DBlob,
        ) callconv(.winapi) Hresult = null,
        /// Bytecode back into readable assembly.
        D3DDisassemble: ?*const fn (
            code: [*]const u8,
            code_len: usize,
            flags: u32,
            comments: ?[*:0]const u8,
            text_out: *?*ID3DBlob,
        ) callconv(.winapi) Hresult = null,
        /// An empty blob of a given size, for code that came from a file
        /// rather than from the compiler.
        D3DCreateBlob: ?*const fn (
            size: usize,
            blob_out: *?*ID3DBlob,
        ) callconv(.winapi) Hresult = null,
        /// Removes reflection data and debug information from compiled code.
        D3DStripShader: ?*const anyopaque = null,
    };

    pub const LoadError = dll.Library.OpenError || error{SymbolNotFound};

    /// `error.LibraryNotFound` where the compiler is not installed, which is a
    /// real state on a server install and in a container.
    pub fn load() LoadError!Compiler {
        var library = try dll.Library.openSystem("d3dcompiler_47.dll");
        errdefer library.close();
        return .{ .library = library, .entries = try library.bind(Entries) };
    }

    /// Give the module back. Every blob it produced must be released first.
    pub fn unload(self: *Compiler) void {
        self.library.close();
        self.* = undefined;
    }

    pub const Options = struct {
        /// The name the compiler puts in its messages. It does not have to be
        /// a file that exists, and it is worth setting to one that does.
        name: ?[:0]const u8 = null,
        /// The function to compile. Null means the target's default, which
        /// for every profile here is `main`.
        entry_point: ?[:0]const u8 = "main",
        /// The profile: `"vs_5_0"`, `"ps_5_0"`, `"cs_5_0"` and so on. The
        /// number is the shader model, and 5.0 is what Direct3D 11 at feature
        /// level `11_0` takes.
        target: [:0]const u8,
        /// A list ending in `Macro.end`, or null for none.
        defines: ?[*]const Macro = null,
        flags: Flags = .{},
    };

    /// Compile HLSL.
    ///
    /// This does not fail: everything the compiler said comes back in the
    /// `Output`, and it is `Output.check` that turns a failure into a Zig
    /// error. Warnings arrive in `messages` on a successful compile too.
    pub fn compile(self: Compiler, source: []const u8, options: Options) Output {
        var output: Output = .{ .code = null, .messages = null, .result = .s_ok };
        output.result = self.entries.D3DCompile(
            source.ptr,
            source.len,
            if (options.name) |name| name.ptr else null,
            options.defines,
            null,
            if (options.entry_point) |entry| entry.ptr else null,
            options.target.ptr,
            options.flags,
            0,
            &output.code,
            &output.messages,
        );
        return output;
    }

    /// Run the preprocessor and stop. `Output.code` holds the expanded source
    /// as text rather than bytecode.
    pub fn preprocess(self: Compiler, source: []const u8, options: Options) Error!Output {
        const run = self.entries.D3DPreprocess orelse return error.Unsupported;
        var output: Output = .{ .code = null, .messages = null, .result = .s_ok };
        output.result = run(
            source.ptr,
            source.len,
            if (options.name) |name| name.ptr else null,
            options.defines,
            null,
            &output.code,
            &output.messages,
        );
        return output;
    }

    /// Compiled bytecode back into the assembly the driver will see. For
    /// looking at what the optimiser did, and for a shader that misbehaves.
    pub fn disassemble(self: Compiler, code: []const u8) Error!*ID3DBlob {
        const run = self.entries.D3DDisassemble orelse return error.Unsupported;
        var text: ?*ID3DBlob = null;
        return com.received(ID3DBlob, run(code.ptr, code.len, 0, null, &text), text);
    }
};

/// What a compile produced: the code, the messages, and the number the call
/// returned. Any of the three may be interesting on its own.
pub const Output = struct {
    /// The bytecode, or null when the compile failed.
    code: ?*ID3DBlob,
    /// What the compiler had to say. Present on failure, and present on
    /// success when there were warnings.
    messages: ?*ID3DBlob,
    result: Hresult,

    /// Release both blobs. Safe to call whatever happened, and safe to call
    /// after `check` has handed the code out - the code is borrowed from the
    /// `Output`, not taken from it.
    pub fn release(self: *Output) void {
        if (self.code) |blob| _ = com.release(blob);
        if (self.messages) |blob| _ = com.release(blob);
        self.* = .{ .code = null, .messages = null, .result = self.result };
    }

    /// The compiler's messages as text, or empty when it had nothing to say.
    /// This is the line to print: it names the line number and the reason.
    pub fn text(self: Output) []const u8 {
        const blob = self.messages orelse return "";
        return blob.text();
    }

    /// The bytecode, or the Zig error for what went wrong. The result is
    /// borrowed from the `Output` and dies with it, so anything that outlives
    /// the compile has to keep the `Output` or take its own reference.
    pub fn check(self: Output) Error!*ID3DBlob {
        try self.result.check();
        return self.code orelse error.NullPointer;
    }

    /// Whether the compiler said anything at all - warnings on a compile that
    /// otherwise worked.
    pub fn warned(self: Output) bool {
        return self.result.succeeded() and self.text().len > 0;
    }
};

/// `D3D_SHADER_MACRO`: a `#define` handed to the compiler from outside.
///
/// The list is terminated rather than counted, which is how the C API says
/// where it stops, so the last entry must be `Macro.end`:
///
/// ```zig
/// const defines = [_]Macro{
///     .{ .name = "SAMPLE_COUNT", .definition = "4" },
///     .end,
/// };
/// ```
pub const Macro = extern struct {
    name: ?[*:0]const u8 = null,
    definition: ?[*:0]const u8 = null,

    /// The terminator every list needs.
    pub const end: Macro = .{};
};

/// `D3DCOMPILE_*`. The defaults are what `fxc` uses with no arguments.
pub const Flags = packed struct(u32) {
    /// Keep debug information in the bytecode, so a graphics debugger can show
    /// the source. Makes the blob much larger and does not slow the shader
    /// down - the optimiser still runs unless `skip_optimization` says not to.
    debug: bool = false,
    skip_validation: bool = false,
    /// For stepping through a shader in a debugger, where optimised code has
    /// nothing left to step through.
    skip_optimization: bool = false,
    /// How a matrix in a constant buffer is laid out. HLSL's default is
    /// column major, which is the opposite of what most maths code writes, and
    /// getting it wrong transposes every transform silently.
    pack_matrix_row_major: bool = false,
    pack_matrix_column_major: bool = false,
    partial_precision: bool = false,
    force_vs_software_no_opt: bool = false,
    force_ps_software_no_opt: bool = false,
    no_preshader: bool = false,
    avoid_flow_control: bool = false,
    prefer_flow_control: bool = false,
    /// Refuse the legacy syntax older shaders relied on.
    enable_strictness: bool = false,
    /// Accept it, for shaders written against Direct3D 9.
    enable_backwards_compatibility: bool = false,
    ieee_strictness: bool = false,
    optimization: OptimizationLevel = .level1,
    _reserved16: u2 = 0,
    warnings_are_errors: bool = false,
    resources_may_alias: bool = false,
    enable_unbounded_descriptor_tables: bool = false,
    all_resources_bound: bool = false,
    debug_name_for_source: bool = false,
    debug_name_for_binary: bool = false,
    _reserved24: u8 = 0,
};

/// How hard the optimiser works.
///
/// The two bits are not in order, which is why this is an enum with written-out
/// values rather than a number: level 1 is zero, level 0 is the low bit, level
/// 3 is the high bit, and level 2 is both. Level 1 being the default and level
/// 0 being an explicit flag is the historical shape of it.
pub const OptimizationLevel = enum(u2) {
    /// `D3DCOMPILE_OPTIMIZATION_LEVEL0`: least.
    level0 = 0b01,
    /// `D3DCOMPILE_OPTIMIZATION_LEVEL1`: the default.
    level1 = 0b00,
    level2 = 0b11,
    /// `D3DCOMPILE_OPTIMIZATION_LEVEL3`: most.
    level3 = 0b10,
};

/// The four bytes every compiled shader starts with. A blob that does not
/// begin with these is not bytecode, whatever else it may be.
pub const container_magic = "DXBC";

// -------------------------------------------------------------------------
// Tests
//
// The compiler needs no device and no graphics card: it is a compiler. These
// run anywhere the DLL is installed, and skip where it is not.
// -------------------------------------------------------------------------

fn loadOrSkip() !Compiler {
    return Compiler.load() catch |err| switch (err) {
        error.LibraryNotFound => error.SkipZigTest,
        else => err,
    };
}

const triangle_vs =
    \\struct Vertex { float2 position : POSITION; float4 colour : COLOR; };
    \\struct Fragment { float4 position : SV_POSITION; float4 colour : COLOR; };
    \\
    \\Fragment main(Vertex input) {
    \\    Fragment output;
    \\    output.position = float4(input.position, 0.0, 1.0);
    \\    output.colour = input.colour;
    \\    return output;
    \\}
;

test "compiling a vertex shader" {
    var compiler = try loadOrSkip();
    defer compiler.unload();

    var output = compiler.compile(triangle_vs, .{ .target = "vs_5_0" });
    defer output.release();

    const code = try output.check();
    const bytes = code.bytes();
    try testing.expect(bytes.len > 4);
    try testing.expectEqualStrings(container_magic, bytes[0..4]);
    // Nothing to complain about, so nothing was said.
    try testing.expect(!output.warned());
}

test "a shader that does not compile says why" {
    var compiler = try loadOrSkip();
    defer compiler.unload();

    var output = compiler.compile("float4 main() : SV_TARGET { return notADeclaredThing; }", .{
        .name = "broken.hlsl",
        .target = "ps_5_0",
    });
    defer output.release();

    // The compiler says `E_FAIL` for anything it could not build, whatever
    // was wrong with it, which is why the message matters more than the
    // number here.
    try testing.expect(output.result.failed());
    try testing.expectError(error.Failed, output.check());

    // Which is the point of keeping the messages: the name, the line and the
    // reason, rather than a number.
    const message = output.text();
    try testing.expect(std.mem.indexOf(u8, message, "broken.hlsl") != null);
    try testing.expect(std.mem.indexOf(u8, message, "error") != null);
}

test "a definition from outside" {
    var compiler = try loadOrSkip();
    defer compiler.unload();

    const source =
        \\float4 main() : SV_TARGET { return float4(TINT, 1.0); }
    ;

    // Without the macro the shader does not compile at all.
    var without = compiler.compile(source, .{ .target = "ps_5_0" });
    defer without.release();
    try testing.expect(without.result.failed());

    const defines = [_]Macro{
        .{ .name = "TINT", .definition = "float3(1, 0, 0)" },
        .end,
    };
    var with = compiler.compile(source, .{ .target = "ps_5_0", .defines = &defines });
    defer with.release();
    _ = try with.check();
}

test "the preprocessor on its own" {
    var compiler = try loadOrSkip();
    defer compiler.unload();

    const defines = [_]Macro{ .{ .name = "WANTED", .definition = "1" }, .end };
    var output = compiler.preprocess(
        \\#ifdef WANTED
        \\this text survives
        \\#else
        \\this text does not
        \\#endif
    , .{ .target = "ps_5_0", .defines = &defines }) catch |err| switch (err) {
        error.Unsupported => return error.SkipZigTest,
        else => return err,
    };
    defer output.release();

    const expanded = (try output.check()).text();
    try testing.expect(std.mem.indexOf(u8, expanded, "this text survives") != null);
    try testing.expect(std.mem.indexOf(u8, expanded, "this text does not") == null);
}

test "bytecode back into assembly" {
    var compiler = try loadOrSkip();
    defer compiler.unload();

    var output = compiler.compile(triangle_vs, .{ .target = "vs_5_0" });
    defer output.release();
    const code = try output.check();

    const listing = compiler.disassemble(code.bytes()) catch |err| switch (err) {
        error.Unsupported => return error.SkipZigTest,
        else => return err,
    };
    defer _ = com.release(listing);

    // The profile it was built for is in the first line of every listing.
    try testing.expect(std.mem.indexOf(u8, listing.text(), "vs_5_0") != null);
}

test "debug information makes the blob bigger and not the shader slower" {
    var compiler = try loadOrSkip();
    defer compiler.unload();

    var plain = compiler.compile(triangle_vs, .{ .target = "vs_5_0" });
    defer plain.release();
    var with_debug = compiler.compile(triangle_vs, .{
        .target = "vs_5_0",
        .flags = .{ .debug = true },
    });
    defer with_debug.release();

    try testing.expect((try with_debug.check()).bytes().len > (try plain.check()).bytes().len);
}

test "the flag bits are where the compiler reads them" {
    try testing.expectEqual(@as(u32, 1 << 0), @as(u32, @bitCast(Flags{ .debug = true })));
    try testing.expectEqual(@as(u32, 1 << 2), @as(u32, @bitCast(Flags{ .skip_optimization = true })));
    try testing.expectEqual(@as(u32, 1 << 3), @as(u32, @bitCast(Flags{ .pack_matrix_row_major = true })));
    try testing.expectEqual(@as(u32, 1 << 18), @as(u32, @bitCast(Flags{ .warnings_are_errors = true })));
    try testing.expectEqual(@as(u32, 1 << 21), @as(u32, @bitCast(Flags{ .all_resources_bound = true })));

    // The optimisation levels, whose bits are famously not in order.
    try testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(Flags{ .optimization = .level1 })));
    try testing.expectEqual(@as(u32, 1 << 14), @as(u32, @bitCast(Flags{ .optimization = .level0 })));
    try testing.expectEqual(@as(u32, 1 << 15), @as(u32, @bitCast(Flags{ .optimization = .level3 })));
    try testing.expectEqual(
        @as(u32, (1 << 14) | (1 << 15)),
        @as(u32, @bitCast(Flags{ .optimization = .level2 })),
    );
}
