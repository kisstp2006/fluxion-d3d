// SPDX-License-Identifier: BSL-1.0

//! HLSL in, bytecode out, and a look at what came back.
//!
//! Run it with `zig build example-shaders`.
//!
//! No device, no window and no graphics card: `d3dcompiler_47.dll` is a
//! compiler, and compiling is all this does. It shows the four things worth
//! knowing about it - that a compile produces a DXBC container, that a failure
//! comes with a message worth printing, that a definition from outside changes
//! the result, and that the optimiser is doing something.

const std = @import("std");
const Io = std.Io;
const d3d = @import("fluxion_d3d");

const com = d3d.com;
const compiler = d3d.compiler;

const source =
    \\cbuffer Constants : register(b0) {
    \\    float4x4 transform;
    \\    float3 light;
    \\};
    \\
    \\struct Vertex {
    \\    float3 position : POSITION;
    \\    float3 normal : NORMAL;
    \\};
    \\
    \\struct Fragment {
    \\    float4 position : SV_POSITION;
    \\    float3 normal : NORMAL;
    \\};
    \\
    \\Fragment main(Vertex input) {
    \\    Fragment output;
    \\    output.position = mul(transform, float4(input.position, 1.0));
    \\    output.normal = input.normal;
    \\#ifdef WOBBLE
    \\    output.position.xy += sin(output.position.z * WOBBLE) * 0.05;
    \\#endif
    \\    return output;
    \\}
;

/// Something with enough arithmetic in it that the optimiser has a choice to
/// make. The loop count is known, so it can be unrolled - or left alone.
const loop_source =
    \\float4 main(float4 position : SV_POSITION) : SV_TARGET {
    \\    float3 sum = 0;
    \\    for (int i = 1; i <= 8; i++) {
    \\        sum += sin(position.xyz * i) / i;
    \\    }
    \\    return float4(sum, 1.0);
    \\}
;

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [8192]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout.interface;

    var hlsl = d3d.Compiler.load() catch {
        try out.writeAll(
            \\no d3dcompiler_47.dll on this machine.
            \\
            \\That is a real state - a server install can be without it - and it
            \\is exactly why it is loaded by name rather than linked: this
            \\program still ran far enough to say so.
            \\
        );
        return out.flush();
    };
    defer hlsl.unload();

    // --- a compile that works ---------------------------------------------
    var output = hlsl.compile(source, .{ .name = "example.vs.hlsl", .target = "vs_5_0" });
    defer output.release();

    const code = output.check() catch {
        try out.print("{s}\n", .{output.text()});
        return out.flush();
    };
    const bytes = code.bytes();

    try out.print("--- vs_5_0 ---\n{d} bytes, starting {s}\n", .{ bytes.len, bytes[0..4] });
    // The first four bytes name the container format; the sixteen after them
    // are a checksum of the rest, which is how the runtime knows the bytecode
    // has not been edited.
    try out.writeAll("checksum ");
    for (bytes[4..20]) |byte| try out.print("{X:0>2}", .{byte});
    try out.writeAll("\n");

    // --- what the driver will see -----------------------------------------
    if (hlsl.disassemble(bytes)) |listing| {
        defer _ = com.release(listing);
        try out.writeAll("\n--- the first lines of it, disassembled ---\n");
        var lines = std.mem.splitScalar(u8, listing.text(), '\n');
        var shown: usize = 0;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try out.print("{s}\n", .{line});
            shown += 1;
            if (shown == 14) break;
        }
    } else |_| {}

    // --- a definition from outside ----------------------------------------
    // The `#ifdef` in the source is not compiled unless something defines it,
    // which is how one file becomes several shaders.
    const defines = [_]compiler.Macro{
        .{ .name = "WOBBLE", .definition = "3.0" },
        .end,
    };
    var wobbly = hlsl.compile(source, .{
        .name = "example.vs.hlsl",
        .target = "vs_5_0",
        .defines = &defines,
    });
    defer wobbly.release();

    try out.print("\n--- with WOBBLE defined ---\n{d} bytes, {d} more than without\n", .{
        (try wobbly.check()).bytes().len,
        (try wobbly.check()).bytes().len - bytes.len,
    });

    // --- what the flags are worth -----------------------------------------
    // On a shader with a loop in it, so there is something to fold. The four
    // optimisation levels are printed as well as the two flags that matter,
    // because what they do is worth seeing rather than assuming: for a shader
    // this small they all come out the same, and it is `skip_optimization`
    // and `debug` that change anything.
    try out.writeAll("\n--- the flags, on a shader with a loop in it ---\n");
    const settings = [_]struct { name: []const u8, flags: compiler.Flags }{
        .{ .name = "level0", .flags = .{ .optimization = .level0 } },
        .{ .name = "level1", .flags = .{ .optimization = .level1 } },
        .{ .name = "level2", .flags = .{ .optimization = .level2 } },
        .{ .name = "level3", .flags = .{ .optimization = .level3 } },
        .{ .name = "skip_optimization", .flags = .{ .skip_optimization = true } },
        .{ .name = "debug", .flags = .{ .debug = true } },
    };
    for (settings) |setting| {
        var built = hlsl.compile(loop_source, .{
            .name = "loop.ps.hlsl",
            .target = "ps_5_0",
            .flags = setting.flags,
        });
        defer built.release();
        try out.print("   {s:<20} {d} bytes\n", .{ setting.name, (try built.check()).bytes().len });
    }
    try out.writeAll(
        \\
        \\`debug` is the one that costs: it keeps the source and a map back to
        \\it in the container, which a graphics debugger needs and a shipped
        \\build does not. It does not make the shader slower - the optimiser
        \\still runs unless `skip_optimization` says otherwise.
        \\
    );

    // --- a compile that does not work -------------------------------------
    // The message is the whole value of a compiler, so it is worth keeping
    // rather than reducing to a failed HRESULT.
    try out.writeAll("\n--- and one that does not compile ---\n");
    var broken = hlsl.compile(
        \\float4 main() : SV_TARGET {
        \\    return mul(nonesuch, 2.0);
        \\}
    , .{ .name = "broken.ps.hlsl", .target = "ps_5_0" });
    defer broken.release();

    if (broken.check()) |_| {
        try out.writeAll("it compiled, which it was not supposed to\n");
    } else |err| {
        try out.print("{t}: {s}\n", .{ err, broken.text() });
    }

    try out.flush();
}
