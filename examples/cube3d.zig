// SPDX-License-Identifier: BSL-1.0

//! Three dimensions: a lit cube turning in a window.
//!
//! Run it with `zig build example-cube3d`. Passing `-- --frames 240` has it
//! close itself after a fixed number of frames. Escape quits.
//!
//! `-- --capture cube3d.png` skips the window entirely: it draws one frame
//! into a texture and writes it out, which is how this can be looked at on a
//! machine with no display. `--at SECONDS` picks the moment.
//!
//! Everything the 2D example left out is here, and it is not much: a depth
//! buffer, so a face at the back cannot paint over one at the front; a matrix
//! that turns a position in the cube's own space into one on the screen; and a
//! normal per face, so the light has something to fall on. The pipeline
//! underneath is the same.
//!
//! **Which way round a matrix goes.** HLSL packs matrices in constant buffers
//! column by column unless told otherwise, so a matrix written out row by row
//! in Zig arrives transposed - and a transposed transform still looks like a
//! transform, which is what makes it a bad afternoon. The shaders here are
//! compiled with `pack_matrix_row_major`, so what is written is what is read.
//!
//! **Which way round a triangle goes.** Direct3D throws away triangles that
//! face away from the camera, and which way that is depends on the order the
//! three corners are listed in. Get it backwards and the cube is inside out:
//! every face that should be visible is discarded and the far ones are drawn
//! instead. The test at the bottom of this file renders one frame into a
//! texture and looks at the pixels, which is the only way to be sure.

const std = @import("std");
const Io = std.Io;
const d3d = @import("fluxion_d3d");
const render = @import("render11");
const capture = @import("capture");
const Window = @import("window").Window;

const com = d3d.com;

// -------------------------------------------------------------------------
// A very small amount of linear algebra
// -------------------------------------------------------------------------

/// Row by row: `m[row][column]`, which is how the maths is written and - with
/// `pack_matrix_row_major` - how the shader reads it.
const Mat4 = [4][4]f32;
const Vec3 = [3]f32;

const identity: Mat4 = .{
    .{ 1, 0, 0, 0 },
    .{ 0, 1, 0, 0 },
    .{ 0, 0, 1, 0 },
    .{ 0, 0, 0, 1 },
};

fn multiply(a: Mat4, b: Mat4) Mat4 {
    var out: Mat4 = undefined;
    for (0..4) |row| {
        for (0..4) |column| {
            var sum: f32 = 0;
            for (0..4) |k| sum += a[row][k] * b[k][column];
            out[row][column] = sum;
        }
    }
    return out;
}

/// A right-handed perspective projection that puts the near plane at depth 0
/// and the far plane at depth 1 - which is what Direct3D wants, and what
/// OpenGL does not, and the reason a projection matrix copied from the wrong
/// book gives a picture that is nearly right.
fn perspective(fov_y: f32, aspect: f32, near: f32, far: f32) Mat4 {
    const f = 1.0 / @tan(fov_y * 0.5);
    return .{
        .{ f / aspect, 0, 0, 0 },
        .{ 0, f, 0, 0 },
        .{ 0, 0, far / (near - far), near * far / (near - far) },
        .{ 0, 0, -1, 0 },
    };
}

/// A camera at `eye` looking at `target`, right-handed, with `up` deciding
/// which way is up.
fn lookAt(eye: Vec3, target: Vec3, up: Vec3) Mat4 {
    const back = normalize(subtract(eye, target));
    const right = normalize(cross(up, back));
    const above = cross(back, right);
    return .{
        .{ right[0], right[1], right[2], -dot(right, eye) },
        .{ above[0], above[1], above[2], -dot(above, eye) },
        .{ back[0], back[1], back[2], -dot(back, eye) },
        .{ 0, 0, 0, 1 },
    };
}

fn rotationY(angle: f32) Mat4 {
    const c = @cos(angle);
    const s = @sin(angle);
    return .{
        .{ c, 0, s, 0 },
        .{ 0, 1, 0, 0 },
        .{ -s, 0, c, 0 },
        .{ 0, 0, 0, 1 },
    };
}

fn rotationX(angle: f32) Mat4 {
    const c = @cos(angle);
    const s = @sin(angle);
    return .{
        .{ 1, 0, 0, 0 },
        .{ 0, c, -s, 0 },
        .{ 0, s, c, 0 },
        .{ 0, 0, 0, 1 },
    };
}

fn subtract(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn dot(a: Vec3, b: Vec3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn normalize(v: Vec3) Vec3 {
    const length = @sqrt(dot(v, v));
    if (length == 0) return v;
    return .{ v[0] / length, v[1] / length, v[2] / length };
}

// -------------------------------------------------------------------------
// The cube
// -------------------------------------------------------------------------

const Vertex = extern struct {
    position: Vec3,
    normal: Vec3,
    colour: Vec3,
};

/// One face: its outward normal, the two directions across it, and a colour.
///
/// `right` crossed with `up` gives `normal`, which is what makes the corner
/// order below come out the same way round on all six.
const Face = struct {
    normal: Vec3,
    right: Vec3,
    up: Vec3,
    colour: Vec3,
};

const faces = [_]Face{
    .{ .normal = .{ 1, 0, 0 }, .right = .{ 0, 0, -1 }, .up = .{ 0, 1, 0 }, .colour = .{ 0.91, 0.30, 0.24 } },
    .{ .normal = .{ -1, 0, 0 }, .right = .{ 0, 0, 1 }, .up = .{ 0, 1, 0 }, .colour = .{ 0.20, 0.60, 0.86 } },
    .{ .normal = .{ 0, 1, 0 }, .right = .{ 1, 0, 0 }, .up = .{ 0, 0, -1 }, .colour = .{ 0.95, 0.77, 0.06 } },
    .{ .normal = .{ 0, -1, 0 }, .right = .{ 1, 0, 0 }, .up = .{ 0, 0, 1 }, .colour = .{ 0.61, 0.35, 0.71 } },
    .{ .normal = .{ 0, 0, 1 }, .right = .{ 1, 0, 0 }, .up = .{ 0, 1, 0 }, .colour = .{ 0.18, 0.80, 0.44 } },
    .{ .normal = .{ 0, 0, -1 }, .right = .{ -1, 0, 0 }, .up = .{ 0, 1, 0 }, .colour = .{ 0.90, 0.49, 0.13 } },
};

/// Four corners a face, twenty-four in all. A cube has eight corners, but a
/// corner shared between three faces would have to have three normals, and a
/// vertex has one - so each face gets its own four, which is what makes the
/// faces flat rather than smoothly shaded.
const cube_vertices = blk: {
    var vertices: [faces.len * 4]Vertex = undefined;
    for (faces, 0..) |face, f| {
        // Bottom left, top left, top right, bottom right, seen from outside.
        const corners = [4][2]f32{ .{ -1, -1 }, .{ -1, 1 }, .{ 1, 1 }, .{ 1, -1 } };
        for (corners, 0..) |corner, c| {
            vertices[f * 4 + c] = .{
                .position = .{
                    face.normal[0] + face.right[0] * corner[0] + face.up[0] * corner[1],
                    face.normal[1] + face.right[1] * corner[0] + face.up[1] * corner[1],
                    face.normal[2] + face.right[2] * corner[0] + face.up[2] * corner[1],
                },
                .normal = face.normal,
                .colour = face.colour,
            };
        }
    }
    break :blk vertices;
};

/// Two triangles a face. The order is the one Direct3D counts as facing the
/// camera; reversed, every face of the cube would be thrown away and the
/// inside drawn instead.
const cube_indices = blk: {
    var indices: [faces.len * 6]u16 = undefined;
    for (0..faces.len) |f| {
        const base: u16 = @intCast(f * 4);
        indices[f * 6 + 0] = base + 0;
        indices[f * 6 + 1] = base + 1;
        indices[f * 6 + 2] = base + 2;
        indices[f * 6 + 3] = base + 0;
        indices[f * 6 + 4] = base + 2;
        indices[f * 6 + 5] = base + 3;
    }
    break :blk indices;
};

/// What both shaders read. Nine constant registers: four for each matrix, one
/// for the light direction and the padding that shares its register.
const Constants = extern struct {
    view_projection: Mat4,
    model: Mat4,
    light: Vec3,
    _padding: f32 = 0,
};

const vertex_shader_source =
    \\cbuffer Constants : register(b0) {
    \\    float4x4 view_projection;
    \\    float4x4 model;
    \\    float3 light;
    \\    float padding;
    \\};
    \\
    \\struct Vertex {
    \\    float3 position : POSITION;
    \\    float3 normal : NORMAL;
    \\    float3 colour : COLOR;
    \\};
    \\
    \\struct Fragment {
    \\    float4 position : SV_POSITION;
    \\    float3 normal : NORMAL;
    \\    float3 colour : COLOR;
    \\};
    \\
    \\Fragment main(Vertex input) {
    \\    float4 world = mul(model, float4(input.position, 1.0));
    \\    Fragment output;
    \\    output.position = mul(view_projection, world);
    \\    // The normal is a direction, so it is turned by the model matrix but
    \\    // not moved by it - which is what dropping the fourth row and column
    \\    // does. This is only right because the model matrix here rotates and
    \\    // nothing else; a squashed model would need the inverse transpose.
    \\    output.normal = mul((float3x3)model, input.normal);
    \\    output.colour = input.colour;
    \\    return output;
    \\}
;

const pixel_shader_source =
    \\cbuffer Constants : register(b0) {
    \\    float4x4 view_projection;
    \\    float4x4 model;
    \\    float3 light;
    \\    float padding;
    \\};
    \\
    \\struct Fragment {
    \\    float4 position : SV_POSITION;
    \\    float3 normal : NORMAL;
    \\    float3 colour : COLOR;
    \\};
    \\
    \\float4 main(Fragment input) : SV_TARGET {
    \\    // Lambert: a face is brightest when it points straight at the light
    \\    // and dark when it points away, with a quarter of the colour left as
    \\    // ambient so the unlit faces are not black.
    \\    float3 normal = normalize(input.normal);
    \\    float lit = saturate(dot(normal, -light));
    \\    return float4(input.colour * (0.25 + 0.75 * lit), 1.0);
    \\}
;

const vertex_layout = [_]render.InputElement{
    .{ .semantic_name = "POSITION", .format = .r32g32b32_float },
    .{ .semantic_name = "NORMAL", .format = .r32g32b32_float },
    .{ .semantic_name = "COLOR", .format = .r32g32b32_float },
};

const light_direction: Vec3 = .{ -0.42, -0.76, -0.5 };

/// Everything the cube needs on the GPU, built once.
const Cube = struct {
    vertex_buffer: *render.IBuffer,
    index_buffer: *render.IBuffer,
    constants: *render.IBuffer,
    layout: *render.IInputLayout,
    vertex_shader: *render.IVertexShader,
    pixel_shader: *render.IPixelShader,
    depth_state: *render.IDepthStencilState,

    fn init(device: render.Device, hlsl: d3d.Compiler) !Cube {
        // Row major, so the matrices arrive the way they are written. See the
        // note at the top of the file.
        const flags: d3d.compiler.Flags = .{ .pack_matrix_row_major = true };

        var vs = hlsl.compile(vertex_shader_source, .{
            .name = "cube3d.vs.hlsl",
            .target = "vs_5_0",
            .flags = flags,
        });
        defer vs.release();
        const vs_code = try vs.check();

        var ps = hlsl.compile(pixel_shader_source, .{
            .name = "cube3d.ps.hlsl",
            .target = "ps_5_0",
            .flags = flags,
        });
        defer ps.release();
        const ps_code = try ps.check();

        return .{
            .vertex_buffer = try device.createBuffer(.{
                .byte_width = @sizeOf(@TypeOf(cube_vertices)),
                .usage = .immutable,
                .bind = .{ .vertex_buffer = true },
            }, std.mem.asBytes(&cube_vertices)),
            .index_buffer = try device.createBuffer(.{
                .byte_width = @sizeOf(@TypeOf(cube_indices)),
                .usage = .immutable,
                .bind = .{ .index_buffer = true },
            }, std.mem.asBytes(&cube_indices)),
            .constants = try device.createConstantBuffer(Constants),
            .layout = try device.createInputLayout(&vertex_layout, vs_code.bytes()),
            .vertex_shader = try device.createVertexShader(vs_code.bytes()),
            .pixel_shader = try device.createPixelShader(ps_code.bytes()),
            .depth_state = try device.createDepthStencilState(.{}),
        };
    }

    /// Set everything up and draw the thirty-six indices.
    fn draw(self: Cube, device: render.Device, aspect: f32, seconds: f32) void {
        const context = device.context();

        const model = multiply(rotationY(seconds * 0.7), rotationX(seconds * 0.31));
        const view = lookAt(.{ 3.0, 2.2, 3.4 }, .{ 0, 0, 0 }, .{ 0, 1, 0 });
        const projection = perspective(std.math.pi / 4.0, aspect, 0.1, 100.0);

        const constants: Constants = .{
            .view_projection = multiply(projection, view),
            .model = model,
            .light = normalize(light_direction),
        };
        context.vtable.UpdateSubresource(
            context,
            render.asResource(self.constants),
            0,
            null,
            &constants,
            0,
            0,
        );

        const buffers = [_]?*render.IBuffer{self.constants};
        context.vtable.VSSetConstantBuffers(context, 0, 1, &buffers);
        // The pixel shader reads the same buffer, for the light direction.
        context.vtable.PSSetConstantBuffers(context, 0, 1, &buffers);

        context.vtable.OMSetDepthStencilState(context, self.depth_state, 0);
        context.vtable.IASetInputLayout(context, self.layout);
        context.vtable.IASetPrimitiveTopology(context, .triangle_list);
        context.vtable.IASetVertexBuffers(
            context,
            0,
            1,
            &[_]?*render.IBuffer{self.vertex_buffer},
            &[_]u32{@sizeOf(Vertex)},
            &[_]u32{0},
        );
        context.vtable.IASetIndexBuffer(context, self.index_buffer, .r16_uint, 0);
        context.vtable.VSSetShader(context, self.vertex_shader, null, 0);
        context.vtable.PSSetShader(context, self.pixel_shader, null, 0);
        context.vtable.DrawIndexed(context, cube_indices.len, 0, 0);
    }

    fn deinit(self: *Cube) void {
        com.releaseAll(.{
            self.depth_state, self.pixel_shader, self.vertex_shader, self.layout,
            self.constants,   self.index_buffer, self.vertex_buffer,
        });
        self.* = undefined;
    }
};

const background: [4]f32 = .{ 0.06, 0.07, 0.10, 1 };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout.interface;

    const options = try Options.fromArguments(init, arena);

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

    try out.print("feature level {f}, {d} vertices, {d} indices\n", .{
        device.raw.level,
        cube_vertices.len,
        cube_indices.len,
    });
    try out.flush();

    var cube = Cube.init(device, hlsl) catch |err| {
        try out.print("could not build the cube: {t}\n", .{err});
        try out.flush();
        return err;
    };
    defer cube.deinit();

    // --- one frame to a file, and no window at all -------------------------
    // The same drawing, into a texture instead of a swap chain - depth buffer
    // and all, since without one the cube would be inside out here too.
    if (options.capture) |path| {
        var screen = try render.Offscreen.init(device, options.width, options.height, true);
        defer screen.deinit();

        screen.begin(background);
        cube.draw(device, aspectOf(options.width, options.height), options.at);

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

    try out.writeAll("opening a window - escape or close it to quit\n");
    try out.flush();

    var window = try Window.open("Fluxion D3D - 3D", options.width, options.height);
    defer window.close();

    // `depth` is the difference between this and the 2D example: without it
    // the last face drawn is the one that shows, whatever is in front of it.
    var surface = try render.Surface.init(device, factory, window.handle, .{ .depth = true });
    defer surface.deinit(device);

    const started = Io.Timestamp.now(init.io, .awake).nanoseconds;
    var frames: u64 = 0;

    while (window.pump()) {
        if (window.minimised()) continue;
        if (window.takeResize()) try surface.resize(device, window.width, window.height);

        const now = Io.Timestamp.now(init.io, .awake).nanoseconds;
        const seconds: f32 = @floatCast(@as(f64, @floatFromInt(now - started)) / std.time.ns_per_s);

        surface.begin(device.context(), background);
        cube.draw(device, aspectOf(surface.width, surface.height), seconds);
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
    /// `--at SECONDS`: how far into the turn to capture. The default is a
    /// moment with three faces showing, which is what a cube should look
    /// like.
    at: f32 = 2.1,
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

test "the projection puts the near plane at zero and the far plane at one" {
    // Direct3D wants depth in 0 to 1, not -1 to 1, and a matrix from a book
    // that assumes otherwise gives a picture that is nearly right - which is
    // the worst kind.
    const p = perspective(std.math.pi / 4.0, 1.0, 0.5, 40.0);

    // A point on the near plane, in view space: the camera looks down -z.
    const near_z = p[2][2] * -0.5 + p[2][3];
    const near_w = p[3][2] * -0.5;
    try testing.expectApproxEqAbs(@as(f32, 0), near_z / near_w, 0.0001);

    const far_z = p[2][2] * -40.0 + p[2][3];
    const far_w = p[3][2] * -40.0;
    try testing.expectApproxEqAbs(@as(f32, 1), far_z / far_w, 0.0001);
}

test "the camera looks where it is pointed" {
    const view = lookAt(.{ 0, 0, 5 }, .{ 0, 0, 0 }, .{ 0, 1, 0 });

    // The point the camera is looking at lands on the axis in front of it, at
    // the distance between them.
    const z = view[2][0] * 0 + view[2][1] * 0 + view[2][2] * 0 + view[2][3];
    try testing.expectApproxEqAbs(@as(f32, -5), z, 0.0001);

    // And the camera's own position lands at the origin of view space.
    const eye_z = view[2][0] * 0 + view[2][1] * 0 + view[2][2] * 5 + view[2][3];
    try testing.expectApproxEqAbs(@as(f32, 0), eye_z, 0.0001);
}

test "the cube is closed and its normals point outwards" {
    try testing.expectEqual(@as(usize, 24), cube_vertices.len);
    try testing.expectEqual(@as(usize, 36), cube_indices.len);

    for (cube_vertices) |vertex| {
        // Every corner is a corner of the unit cube.
        for (vertex.position) |component| {
            try testing.expectApproxEqAbs(@as(f32, 1), @abs(component), 0.0001);
        }
        // And its normal points away from the middle rather than towards it,
        // which is what makes the lighting come out the right way round.
        try testing.expect(dot(vertex.position, vertex.normal) > 0);
    }
}

test "the constants are laid out as the shaders read them" {
    try testing.expectEqual(@as(usize, 144), @sizeOf(Constants));
    try testing.expectEqual(@as(usize, 64), @offsetOf(Constants, "model"));
    try testing.expectEqual(@as(usize, 128), @offsetOf(Constants, "light"));
}

test "a frame of it, rendered and looked at" {
    // The only way to know that the winding, the projection and the depth test
    // all agree is to draw the thing and look. This renders one frame into a
    // texture on WARP - no window, no graphics card - and checks that the cube
    // is where it should be and the background is where it should be.
    var d3d11 = d3d.D3d11.load() catch return error.SkipZigTest;
    defer d3d11.unload();
    var hlsl = d3d.Compiler.load() catch return error.SkipZigTest;
    defer hlsl.unload();

    var device: render.Device = .from(try d3d11.createDevice(.{ .driver = .warp }));
    defer device.release();

    var screen = try render.Offscreen.square(device, 128, true);
    defer screen.deinit();

    var cube = try Cube.init(device, hlsl);
    defer cube.deinit();

    screen.begin(background);
    cube.draw(device, 1.0, 0.0);

    // The middle of the image is the cube, and it is not the background.
    const middle = try screen.pixel(64, 64);
    try testing.expect(middle[3] == 255);
    try testing.expect(!isBackground(middle));

    // The corners are outside it, and they are.
    for ([_][2]u32{ .{ 2, 2 }, .{ 125, 2 }, .{ 2, 125 }, .{ 125, 125 } }) |point| {
        try testing.expect(isBackground(try screen.pixel(point[0], point[1])));
    }

    // Three faces of a cube are visible at once from a corner, and a flat
    // colour each, so the picture holds at least three distinct colours
    // besides the background. Fewer would mean faces are being discarded.
    var seen: [8][4]u8 = undefined;
    var count: usize = 0;
    var y: u32 = 20;
    while (y < 110) : (y += 3) {
        var x: u32 = 20;
        while (x < 110) : (x += 3) {
            const pixel = try screen.pixel(x, y);
            if (isBackground(pixel)) continue;
            for (seen[0..count]) |already| {
                if (std.mem.eql(u8, &already, &pixel)) break;
            } else {
                if (count == seen.len) break;
                seen[count] = pixel;
                count += 1;
            }
        }
    }
    try testing.expect(count >= 3);
}

fn isBackground(pixel: [4]u8) bool {
    // The clear colour, rounded to eight bits a channel, with a byte either
    // way for the conversion.
    for (background[0..3], 0..) |channel, i| {
        const expected: i32 = @intFromFloat(@round(channel * 255));
        if (@abs(@as(i32, pixel[i]) - expected) > 1) return false;
    }
    return true;
}
