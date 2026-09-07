// SPDX-License-Identifier: BSL-1.0

//! Two dimensions: coloured boxes bouncing around a window.
//!
//! Run it with `zig build example-scene2d`. Passing `-- --frames 120` has it
//! close itself after a fixed number of frames. Escape quits.
//!
//! `-- --capture scene2d.png` skips the window entirely: it draws one frame
//! into a texture and writes it out, which is how this can be looked at on a
//! machine with no display. `--at SECONDS` picks the moment.
//!
//! There is no depth buffer, no camera and no matrix here. Every corner the
//! vertex shader is given is already in clip space - the square from -1 to 1
//! that the screen is - and all a box needs is a scale and an offset applied
//! to a unit quad. That is the whole of 2D: the pipeline is the same one the
//! cube example uses, with the parts that turn a world into a picture left
//! out.
//!
//! One quad is drawn once per box, with the constant buffer rewritten in
//! between. For six boxes that is fine and it is the clearest thing to read.
//! A program drawing thousands would put the per-box values in a vertex buffer
//! and issue one instanced draw instead - the difference is a bandwidth
//! decision, not a different kind of graphics.

const std = @import("std");
const Io = std.Io;
const d3d = @import("fluxion_d3d");
const render = @import("render11");
const capture = @import("capture");
const Window = @import("window").Window;

const com = d3d.com;

/// What the vertex shader reads for each box. The two `float2`s share one
/// constant register and the colour takes the next, which is why the struct is
/// exactly thirty-two bytes and needs no padding written out.
const Quad = extern struct {
    offset: [2]f32,
    half_size: [2]f32,
    colour: [4]f32,
};

const vertex_shader_source =
    \\cbuffer Quad : register(b0) {
    \\    float2 offset;
    \\    float2 half_size;
    \\    float4 colour;
    \\};
    \\
    \\struct Fragment {
    \\    float4 position : SV_POSITION;
    \\    float4 colour : COLOR;
    \\};
    \\
    \\Fragment main(float2 corner : POSITION) {
    \\    Fragment output;
    \\    output.position = float4(corner * half_size + offset, 0.0, 1.0);
    \\    output.colour = colour;
    \\    return output;
    \\}
;

const pixel_shader_source =
    \\struct Fragment {
    \\    float4 position : SV_POSITION;
    \\    float4 colour : COLOR;
    \\};
    \\
    \\float4 main(Fragment input) : SV_TARGET {
    \\    return input.colour;
    \\}
;

/// The unit quad every box is a scaled copy of, and the six indices that make
/// two triangles out of its four corners. Bottom left, top left, top right,
/// bottom right - which is the order Direct3D counts as facing the camera.
const corners = [_][2]f32{
    .{ -1, -1 },
    .{ -1, 1 },
    .{ 1, 1 },
    .{ 1, -1 },
};
const quad_indices = [_]u16{ 0, 1, 2, 0, 2, 3 };

const Box = struct {
    colour: [4]f32,
    size: f32,
    speed: [2]f32,
    phase: [2]f32,
};

const boxes = [_]Box{
    .{ .colour = .{ 0.91, 0.30, 0.24, 1 }, .size = 0.14, .speed = .{ 0.62, 0.41 }, .phase = .{ 0.0, 0.3 } },
    .{ .colour = .{ 0.95, 0.77, 0.06, 1 }, .size = 0.10, .speed = .{ 0.44, 0.73 }, .phase = .{ 0.7, 1.1 } },
    .{ .colour = .{ 0.18, 0.80, 0.44, 1 }, .size = 0.17, .speed = .{ 0.83, 0.29 }, .phase = .{ 1.4, 0.2 } },
    .{ .colour = .{ 0.20, 0.60, 0.86, 1 }, .size = 0.09, .speed = .{ 0.35, 0.91 }, .phase = .{ 0.2, 1.8 } },
    .{ .colour = .{ 0.61, 0.35, 0.71, 1 }, .size = 0.12, .speed = .{ 0.71, 0.55 }, .phase = .{ 1.9, 0.9 } },
    .{ .colour = .{ 0.90, 0.49, 0.13, 1 }, .size = 0.07, .speed = .{ 0.97, 0.67 }, .phase = .{ 1.1, 1.5 } },
};

const background: [4]f32 = .{ 0.07, 0.08, 0.11, 1 };

/// Everything the scene needs on the GPU, built once.
const Scene = struct {
    vertex_buffer: *render.IBuffer,
    index_buffer: *render.IBuffer,
    constants: *render.IBuffer,
    layout: *render.IInputLayout,
    vertex_shader: *render.IVertexShader,
    pixel_shader: *render.IPixelShader,

    fn init(device: render.Device, hlsl: d3d.Compiler) !Scene {
        var vs = hlsl.compile(vertex_shader_source, .{
            .name = "scene2d.vs.hlsl",
            .target = "vs_5_0",
        });
        defer vs.release();
        const vs_code = try vs.check();

        var ps = hlsl.compile(pixel_shader_source, .{
            .name = "scene2d.ps.hlsl",
            .target = "ps_5_0",
        });
        defer ps.release();
        const ps_code = try ps.check();

        return .{
            .vertex_buffer = try device.createBuffer(.{
                .byte_width = @sizeOf(@TypeOf(corners)),
                .usage = .immutable,
                .bind = .{ .vertex_buffer = true },
            }, std.mem.asBytes(&corners)),
            .index_buffer = try device.createBuffer(.{
                .byte_width = @sizeOf(@TypeOf(quad_indices)),
                .usage = .immutable,
                .bind = .{ .index_buffer = true },
            }, std.mem.asBytes(&quad_indices)),
            .constants = try device.createConstantBuffer(Quad),
            .layout = try device.createInputLayout(&.{
                .{ .semantic_name = "POSITION", .format = .r32g32_float },
            }, vs_code.bytes()),
            .vertex_shader = try device.createVertexShader(vs_code.bytes()),
            .pixel_shader = try device.createPixelShader(ps_code.bytes()),
        };
    }

    /// One frame: the same quad, six times, with a different constant buffer
    /// each time.
    fn draw(self: Scene, device: render.Device, aspect: f32, seconds: f32) void {
        const context = device.context();

        context.vtable.IASetInputLayout(context, self.layout);
        context.vtable.IASetPrimitiveTopology(context, .triangle_list);
        context.vtable.IASetVertexBuffers(
            context,
            0,
            1,
            &[_]?*render.IBuffer{self.vertex_buffer},
            &[_]u32{@sizeOf([2]f32)},
            &[_]u32{0},
        );
        context.vtable.IASetIndexBuffer(context, self.index_buffer, .r16_uint, 0);
        context.vtable.VSSetShader(context, self.vertex_shader, null, 0);
        context.vtable.PSSetShader(context, self.pixel_shader, null, 0);
        context.vtable.VSSetConstantBuffers(context, 0, 1, &[_]?*render.IBuffer{self.constants});

        for (boxes) |box| {
            const quad = quadFor(box, aspect, seconds);
            // One box, one write, one draw. The runtime keeps the old contents
            // alive for the draw that already read them, so this is not a
            // stall - and for six boxes it is the clearest thing to write.
            context.vtable.UpdateSubresource(
                context,
                render.asResource(self.constants),
                0,
                null,
                &quad,
                0,
                0,
            );
            context.vtable.DrawIndexed(context, quad_indices.len, 0, 0);
        }
    }

    fn deinit(self: *Scene) void {
        com.releaseAll(.{
            self.pixel_shader, self.vertex_shader, self.layout,
            self.constants,    self.index_buffer,  self.vertex_buffer,
        });
        self.* = undefined;
    }
};

/// Where a box is and how big, at a given moment.
///
/// A wide window would stretch a square into a rectangle, so the horizontal
/// half-size is divided by however much wider than tall the window is - and
/// the wall the box turns at moves with it.
fn quadFor(box: Box, aspect: f32, seconds: f32) Quad {
    const half_width = box.size / aspect;
    return .{
        .offset = .{
            bounce(seconds * box.speed[0] + box.phase[0], 1.0 - half_width),
            bounce(seconds * box.speed[1] + box.phase[1], 1.0 - box.size),
        },
        .half_size = .{ half_width, box.size },
        .colour = box.colour,
    };
}

/// A triangle wave: something moving in a straight line and reflecting off
/// walls at plus and minus `limit`. Written as a function of time rather than
/// as a position that gets updated, so a dropped frame does not move anything.
fn bounce(t: f32, limit: f32) f32 {
    const span = 4.0 * limit;
    const x = @mod(t, span);
    return if (x < 2.0 * limit) x - limit else 3.0 * limit - x;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout.interface;

    const options = try Options.fromArguments(init, arena);

    // --- the loader's part, which is all of three calls -------------------
    var dxgi = try d3d.Dxgi.load();
    defer dxgi.unload();
    var d3d11 = try d3d.D3d11.load();
    defer d3d11.unload();
    var hlsl = try d3d.Compiler.load();
    defer hlsl.unload();

    const factory = try dxgi.createFactory(d3d.dxgi.IDXGIFactory1, .{});
    defer _ = com.release(factory);

    var device: render.Device = .from(try d3d11.createDevice(.{}));
    defer device.release();

    try out.print("feature level {f}, {d} boxes\n", .{ device.raw.level, boxes.len });
    try out.flush();

    var scene = Scene.init(device, hlsl) catch |err| {
        try out.print("could not build the scene: {t}\n", .{err});
        try out.flush();
        return err;
    };
    defer scene.deinit();

    // --- one frame to a file, and no window at all -------------------------
    // The same drawing, into a texture instead of a swap chain. It is how an
    // example with a window in it gets looked at on a machine that has none.
    if (options.capture) |path| {
        var screen = try render.Offscreen.init(device, options.width, options.height, false);
        defer screen.deinit();

        screen.begin(background);
        scene.draw(device, aspectOf(options.width, options.height), options.at);

        var readback = try screen.read();
        defer readback.end();

        try capture.writePng(
            init.gpa,
            init.io,
            path,
            options.width,
            options.height,
            readback.pixels,
            readback.row_pitch,
        );
        try out.print("wrote {s}, {d} by {d}, at {d:.2} seconds\n", .{
            path,
            options.width,
            options.height,
            options.at,
        });
        return out.flush();
    }

    // --- a window and something to draw into -----------------------------
    try out.writeAll("opening a window - escape or close it to quit\n");
    try out.flush();

    var window = try Window.open("Fluxion D3D - 2D", options.width, options.height);
    defer window.close();

    var surface = try render.Surface.init(device, factory, window.handle, .{});
    defer surface.deinit(device);

    // --- the loop ---------------------------------------------------------
    const started = Io.Timestamp.now(init.io, .awake).nanoseconds;
    var frames: u64 = 0;

    while (window.pump()) {
        // A minimised window has no pixels, and a swap chain cannot be
        // resized to nothing, so there is nothing to do until it comes back.
        if (window.minimised()) continue;
        if (window.takeResize()) try surface.resize(device, window.width, window.height);

        const now = Io.Timestamp.now(init.io, .awake).nanoseconds;
        const seconds: f32 = @floatCast(@as(f64, @floatFromInt(now - started)) / std.time.ns_per_s);

        surface.begin(device.context(), background);
        scene.draw(device, aspectOf(surface.width, surface.height), seconds);
        try surface.present(true);

        frames += 1;
        if (options.frames) |limit| {
            if (frames >= limit) break;
        }
    }

    try out.print("{d} frames\n", .{frames});
    try out.flush();
}

fn aspectOf(width: u32, height: u32) f32 {
    if (height == 0) return 1;
    return @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
}

/// What the command line can say. All of it is about running the example
/// without a person watching: stopping after a fixed number of frames, or not
/// opening a window at all and writing one frame to a file.
const Options = struct {
    /// `--frames N`: stop after N frames.
    frames: ?u64 = null,
    /// `--capture PATH`: no window; render one frame and write it as a PNG.
    capture: ?[]const u8 = null,
    /// `--at SECONDS`: which moment of the animation to capture.
    at: f32 = 1.7,
    width: u32 = 960,
    height: u32 = 540,

    fn fromArguments(init: std.process.Init, arena: std.mem.Allocator) !Options {
        var options: Options = .{};
        const arguments = try init.minimal.args.toSlice(arena);
        var i: usize = 1;
        while (i < arguments.len) : (i += 1) {
            const argument = arguments[i];
            const value = if (i + 1 < arguments.len) arguments[i + 1] else null;
            if (std.mem.eql(u8, argument, "--frames")) {
                options.frames = try std.fmt.parseInt(u64, value orelse return error.MissingValue, 10);
                i += 1;
            } else if (std.mem.eql(u8, argument, "--capture")) {
                options.capture = value orelse return error.MissingValue;
                i += 1;
            } else if (std.mem.eql(u8, argument, "--at")) {
                options.at = try std.fmt.parseFloat(f32, value orelse return error.MissingValue);
                i += 1;
            } else {
                return error.UnknownArgument;
            }
        }
        return options;
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "the constants are laid out as the shader reads them" {
    // Two float2s share a register and the colour takes the next, so the
    // struct is exactly two registers with nothing between.
    try testing.expectEqual(@as(usize, 32), @sizeOf(Quad));
    try testing.expectEqual(@as(usize, 16), @offsetOf(Quad, "colour"));
}

test "a box turns round at the wall and never leaves it" {
    // Whatever the time, a box stays inside its limits - which is the only
    // thing the motion has to guarantee.
    var t: f32 = 0;
    while (t < 40) : (t += 0.013) {
        const x = bounce(t, 0.8);
        try testing.expect(x >= -0.8001 and x <= 0.8001);
    }
    // And it is continuous across the turn: no jump from one side to the other.
    try testing.expectApproxEqAbs(@as(f32, 0.8), bounce(1.6, 0.8), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -0.8), bounce(0.0, 0.8), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), bounce(0.8, 0.8), 0.0001);
}

test "a box stays inside the window whatever its shape" {
    // The horizontal limit moves with the aspect ratio, so a wide window does
    // not let a box walk off the side.
    for ([_]f32{ 0.5, 1.0, 1.78, 3.0 }) |aspect| {
        for (boxes) |box| {
            var t: f32 = 0;
            while (t < 30) : (t += 0.017) {
                const quad = quadFor(box, aspect, t);
                try testing.expect(@abs(quad.offset[0]) + quad.half_size[0] <= 1.0001);
                try testing.expect(@abs(quad.offset[1]) + quad.half_size[1] <= 1.0001);
            }
        }
    }
}

test "a frame of it, rendered and looked at" {
    // The same check the cube example makes: draw one frame into a texture on
    // WARP and look at the pixels. It catches a quad wound the wrong way
    // round, which would be culled and leave nothing but the background.
    var d3d11 = d3d.D3d11.load() catch return error.SkipZigTest;
    defer d3d11.unload();
    var hlsl = d3d.Compiler.load() catch return error.SkipZigTest;
    defer hlsl.unload();

    var device: render.Device = .from(try d3d11.createDevice(.{ .driver = .warp }));
    defer device.release();

    var screen = try render.Offscreen.square(device, 128, false);
    defer screen.deinit();

    var scene = try Scene.init(device, hlsl);
    defer scene.deinit();

    screen.begin(background);
    scene.draw(device, 1.0, 0.0);

    // Sample the image and collect what is on it. Two things have to hold: a
    // good part of it is not the background, and everything that is not the
    // background is one of the six colours - which it can only be if the
    // pixel shader is passing the constant through and no quad was culled.
    var found: [boxes.len]bool = @splat(false);
    var painted: usize = 0;
    var y: u32 = 1;
    while (y < 128) : (y += 2) {
        var x: u32 = 1;
        while (x < 128) : (x += 2) {
            const pixel = try screen.pixel(x, y);
            if (isBackground(pixel)) continue;
            painted += 1;
            found[
                indexOfColour(pixel) orelse {
                    std.debug.print("a pixel that is neither a box nor the background: {any}\n", .{pixel});
                    return error.UnexpectedColour;
                }
            ] = true;
        }
    }

    // Six boxes of that size cover a real fraction of the image.
    try testing.expect(painted > 100);

    // And most of them are visible at this moment. Not all six: they are free
    // to overlap, and the one drawn last wins where they do.
    var visible: usize = 0;
    for (found) |seen| visible += @intFromBool(seen);
    try testing.expect(visible >= 4);
}

test "a window, a swap chain, and a resize" {
    // The one path an offscreen test cannot reach: a real window, a real swap
    // chain, and `ResizeBuffers` - which refuses to work if anything still
    // holds a back buffer, including the pipeline the views were bound to.
    // That is the bug this exists to catch, and it only shows on a resize or
    // at process exit.
    var dxgi = d3d.Dxgi.load() catch return error.SkipZigTest;
    defer dxgi.unload();
    var d3d11 = d3d.D3d11.load() catch return error.SkipZigTest;
    defer d3d11.unload();
    var hlsl = d3d.Compiler.load() catch return error.SkipZigTest;
    defer hlsl.unload();

    const factory = try dxgi.createFactory(d3d.dxgi.IDXGIFactory1, .{});
    defer _ = com.release(factory);

    var device: render.Device = .from(try d3d11.createDevice(.{}));
    defer device.release();

    var scene = try Scene.init(device, hlsl);
    defer scene.deinit();

    // Hidden: the swap chain is real and presents into it, and nothing
    // flashes up on a machine somebody is using.
    var window = try @import("window").openForTest(320, 240);
    defer window.close();
    _ = window.pump();

    var surface = try render.Surface.init(device, factory, window.handle, .{});
    defer surface.deinit(device);

    try testing.expectEqual(@as(u32, 320), surface.width);
    try testing.expectEqual(@as(u32, 240), surface.height);

    // A frame at the size it was made.
    surface.begin(device.context(), background);
    scene.draw(device, aspectOf(surface.width, surface.height), 0.5);
    try surface.present(false);

    // And a frame at another size, which is the call that fails when a buffer
    // is still bound.
    try surface.resize(device, 400, 300);
    try testing.expectEqual(@as(u32, 400), surface.width);
    try testing.expectEqual(@as(u32, 300), surface.height);

    surface.begin(device.context(), background);
    scene.draw(device, aspectOf(surface.width, surface.height), 0.9);
    try surface.present(false);
}

fn isBackground(pixel: [4]u8) bool {
    return matches(background, pixel);
}

fn indexOfColour(pixel: [4]u8) ?usize {
    for (boxes, 0..) |box, i| {
        if (matches(box.colour, pixel)) return i;
    }
    return null;
}

/// A colour as the shader wrote it, rounded to eight bits a channel, with a
/// step either way for the conversion.
fn matches(colour: [4]f32, pixel: [4]u8) bool {
    for (colour[0..3], 0..) |channel, i| {
        const expected: i32 = @intFromFloat(@round(channel * 255));
        if (@abs(@as(i32, pixel[i]) - expected) > 1) return false;
    }
    return true;
}
