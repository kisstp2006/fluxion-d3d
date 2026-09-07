// SPDX-License-Identifier: BSL-1.0

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // fluxion-dyn: opening a shared library at run time and binding a struct
    // of entry points from it, which is the general form of what `dll` does.
    const dyn = b.dependency("fluxion_dyn", .{
        .target = target,
        .optimize = optimize,
    });

    // The importable module. Consumers do:
    //   const d3d = @import("fluxion_d3d");
    const mod = b.addModule("fluxion_d3d", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fluxion_dyn", .module = dyn.module("fluxion_dyn") },
        },
    });

    // zig build test
    const tests = b.addTest(.{
        .name = "fluxion-d3d-tests",
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the library test suite");
    test_step.dependOn(&run_tests.step);

    // zig build docs -> zig-out/docs
    const docs_lib = b.addLibrary(.{
        .name = "fluxion-d3d",
        .root_module = mod,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate API documentation into zig-out/docs");
    docs_step.dependOn(&install_docs.step);

    // -------------------------------------------------------------------
    // Examples
    // -------------------------------------------------------------------

    // The examples need a window to put a swap chain in, and that is
    // `fluxion-platform`, a lazy dependency: fetched only when the examples
    // are actually wanted, which is when this is the package being built and
    // not when it is somebody else's dependency. `-Dexamples=false` builds
    // the library's own tests alone; `-Dexamples=true` asks for them from
    // inside another package.
    const examples_wanted = b.option(
        bool,
        "examples",
        "Build the examples and their tests (pulls fluxion-platform and fluxion-image)",
    ) orelse (b.pkg_hash.len == 0);
    if (!examples_wanted) return;

    // On the first run after a clean checkout this comes back null and the
    // build runner fetches it and starts again, so returning here is not
    // giving up - it is the first half of the fetch.
    const platform_dep = b.lazyDependency("fluxion_platform", .{
        .target = target,
        .optimize = optimize,
    }) orelse return;
    const image_dep = b.lazyDependency("fluxion_image", .{
        .target = target,
        .optimize = optimize,
    }) orelse return;

    // What the examples share: the Direct3D 11 calls that draw, which the
    // library deliberately stops short of, and a window to draw into. Neither
    // is part of the library.
    const render_mod = b.createModule(.{
        .root_source_file = b.path("examples/render11.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fluxion_d3d", .module = mod }},
    });
    const window_mod = b.createModule(.{
        .root_source_file = b.path("examples/window.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fluxion_platform", .module = platform_dep.module("fluxion_platform") },
        },
    });
    // Saving a frame, so an example with a window in it can be looked at on
    // a machine that has no display, is `fluxion-image`'s job.
    const image_mod = image_dep.module("fluxion_image");

    // Both carry their own tests, and they run with the library's: a
    // vtable slot nothing has called is a guess, and the way to stop guessing
    // is to draw a triangle into a texture and look at the pixels.
    const render_tests = b.addTest(.{
        .name = "fluxion-d3d-render-tests",
        .root_module = render_mod,
    });
    test_step.dependOn(&b.addRunArtifact(render_tests).step);
    const window_tests = b.addTest(.{
        .name = "fluxion-d3d-window-tests",
        .root_module = window_mod,
    });
    test_step.dependOn(&b.addRunArtifact(window_tests).step);

    // zig build example runs the tour; zig build example-<name> runs one of
    // the others; zig build examples runs all of them, in this order.
    //
    // The two with windows in them write a frame to a file for the aggregate
    // run rather than opening anything. `zig build examples` has to finish on
    // its own, and a window that appears for three seconds and vanishes is a
    // worse way to end than a picture that stays on disk. Run on their own -
    // `zig build example-cube3d` - they open a window and keep it.
    const examples = [_]struct {
        name: []const u8,
        step: []const u8,
        about: []const u8,
        chained_args: []const []const u8 = &.{},
    }{
        .{ .name = "demo", .step = "example", .about = "Build and run the demo tour" },
        .{ .name = "adapters", .step = "example-adapters", .about = "Every adapter, and what each runtime grants" },
        .{ .name = "entrypoints", .step = "example-entrypoints", .about = "Which entry points and interfaces this Windows has" },
        .{ .name = "shaders", .step = "example-shaders", .about = "Compile HLSL at run time and disassemble it" },
        .{ .name = "scene2d", .step = "example-scene2d", .about = "2D: coloured boxes bouncing in a window", .chained_args = &.{ "--capture", "zig-out/scene2d.png" } },
        .{ .name = "cube3d", .step = "example-cube3d", .about = "3D: a lit, spinning cube with a depth buffer", .chained_args = &.{ "--capture", "zig-out/cube3d.png" } },
    };

    const all_examples = b.step("examples", "Build and run every example in turn");
    var previous: ?*std.Build.Step = null;

    for (examples) |example| {
        const example_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{example.name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "fluxion_d3d", .module = mod },
                .{ .name = "render11", .module = render_mod },
                .{ .name = "window", .module = window_mod },
                .{ .name = "fluxion_image", .module = image_mod },
            },
        });
        const exe = b.addExecutable(.{
            .name = b.fmt("fluxion-d3d-{s}", .{example.name}),
            .root_module = example_mod,
        });
        b.installArtifact(exe);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());
        // Anything after `--` goes through: `zig build example-cube3d -- --frames 60`.
        if (b.args) |args| run.addArgs(args);
        b.step(example.step, example.about).dependOn(&run.step);

        // A second run for the aggregate step, chained one after another so
        // that `zig build examples` reads as a page rather than as six
        // programs shouting at once - and so that asking for one of them does
        // not drag the rest along with it.
        const in_order = b.addRunArtifact(exe);
        in_order.step.dependOn(b.getInstallStep());
        in_order.addArgs(example.chained_args);
        if (previous) |earlier| in_order.step.dependOn(earlier);
        previous = &in_order.step;
        all_examples.dependOn(&in_order.step);

        // The examples with something to check carry tests of their own - the
        // cube renders a frame into a texture and looks at it.
        const example_tests = b.addTest(.{
            .name = b.fmt("fluxion-d3d-{s}-tests", .{example.name}),
            .root_module = example_mod,
        });
        test_step.dependOn(&b.addRunArtifact(example_tests).step);
    }
}
