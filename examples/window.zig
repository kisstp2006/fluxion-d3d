// SPDX-License-Identifier: BSL-1.0

//! A window to put a swap chain in.
//!
//! Nothing here is Direct3D. A swap chain needs an `HWND`, and getting one
//! means a window class, a message procedure and a loop that drains the queue
//! - which is `fluxion-platform`'s job, done properly, with DPI awareness and
//! a keyboard that works. What is left here is the shape the examples want:
//! one struct with a `pump`, a `handle` for `CreateSwapChainForHwnd`, and the
//! Escape key closing it.
//!
//! ```zig
//! var window = try Window.open("Example", 960, 540);
//! defer window.close();
//!
//! while (window.pump()) {
//!     // draw, present
//! }
//! ```
//!
//! `pump` returns false once the window has gone, which is the loop's exit.
//! It does not block: a program that draws every frame must not wait for a
//! message that may never come.
//!
//! This is not part of the library, and it is not a dependency of it either:
//! `fluxion_platform` is lazy in `build.zig.zon`, fetched for the examples
//! and for nothing else. The library stops at a device; a window is what a
//! program brings.

const std = @import("std");

const platform = @import("fluxion_platform");

pub const Window = struct {
    /// Boxed, because a `platform.Window` is an id and a pointer to its
    /// context, and a context that moved would leave every handle to it
    /// pointing at where it used to be.
    ctx: *platform.Context,
    win: platform.Window,
    /// The `HWND`, which is what DXGI wants. An integer on the platform side
    /// - not every windowing system's handle is a pointer - and a pointer
    /// here, because on Windows it is one.
    handle: *anyopaque,
    /// The client area, in pixels: the size a swap chain is made at.
    width: u32,
    height: u32,
    resized: bool = false,

    /// Everything the platform layer can fail with. Most of it means "not on
    /// this machine" rather than "something went wrong": see `isAbsent`.
    pub const Error = platform.Error;

    pub const Options = struct {
        title: []const u8 = "Fluxion D3D",
        width: u32 = 960,
        height: u32 = 540,
        /// Off means the window is never shown. The swap chain is real and
        /// presents into it; nothing appears on screen. That is how a test
        /// runs on a machine somebody is using for something else.
        visible: bool = true,
    };

    /// Open a window whose *client area* - the part a swap chain fills - is
    /// `width` by `height`, and show it.
    pub fn open(title: []const u8, width: u32, height: u32) Error!Window {
        return openWith(.{ .title = title, .width = width, .height = height });
    }

    pub fn openWith(options: Options) Error!Window {
        const gpa = std.heap.smp_allocator;

        const ctx = try gpa.create(platform.Context);
        errdefer gpa.destroy(ctx);
        ctx.* = try platform.Context.init(gpa, .{});
        errdefer ctx.deinit();

        const win = try ctx.createWindow(.{
            .title = options.title,
            .width = options.width,
            .height = options.height,
            .visible = options.visible,
            // No GL context: the swap chain is the thing that draws here.
            .gl = null,
        });
        errdefer win.destroy();

        const native = win.native();
        if (native == 0) return error.Unavailable;

        const size = win.framebufferSize();
        return .{
            .ctx = ctx,
            .win = win,
            .handle = @ptrFromInt(native),
            .width = size[0],
            .height = size[1],
        };
    }

    /// Is this error the machine's answer rather than the program's fault?
    /// A test that opens a window skips on these, and a program says so and
    /// stops.
    pub fn isAbsent(err: Error) bool {
        return switch (err) {
            error.Unsupported,
            error.NoDisplay,
            error.ConnectionFailed,
            error.WindowCreationFailed,
            error.Unavailable,
            => true,
            error.OutOfMemory => false,
        };
    }

    /// Drain everything in the queue and answer whether the window is still
    /// there. This does not wait: a program that draws every frame must not
    /// block on an event that may never arrive.
    pub fn pump(self: *Window) bool {
        self.ctx.pump() catch return false;
        while (self.ctx.poll()) |ev| switch (ev) {
            .close => self.win.setShouldClose(true),
            .key => |k| if (k.key == .escape and k.action == .press) self.win.setShouldClose(true),
            .framebuffer_resize => |r| {
                // A minimised window reports zero, which is a size no swap
                // chain will accept, so the loop has to check `minimised`.
                self.width = r.width;
                self.height = r.height;
                self.resized = true;
            },
            else => {},
        };
        return !self.win.shouldClose();
    }

    /// Whether the window changed size since this was last asked. Reading it
    /// clears it, because the answer is a thing to act on once.
    pub fn takeResize(self: *Window) bool {
        defer self.resized = false;
        return self.resized;
    }

    /// True while the window has no area to draw into, which is what being
    /// minimised looks like. A swap chain cannot be resized to nothing, so a
    /// loop skips its frame instead.
    pub fn minimised(self: Window) bool {
        return self.width == 0 or self.height == 0;
    }

    pub fn close(self: *Window) void {
        self.win.destroy();
        self.ctx.deinit();
        std.heap.smp_allocator.destroy(self.ctx);
        self.* = undefined;
    }
};

/// Open a hidden test window, or skip the test on a machine that cannot.
pub fn openForTest(width: u32, height: u32) !Window {
    return Window.openWith(.{
        .title = "fluxion-d3d test",
        .width = width,
        .height = height,
        .visible = false,
    }) catch |err| if (Window.isAbsent(err)) error.SkipZigTest else err;
}

test "a window that has just been opened is not already closing" {
    var window = try openForTest(64, 64);
    defer window.close();

    try std.testing.expect(window.pump());
    try std.testing.expect(window.pump());
    try std.testing.expect(window.width >= 64);
    try std.testing.expect(window.height >= 64);

    // The handle is the thing a swap chain is made on, so a null one would
    // be a window that cannot be drawn into.
    try std.testing.expect(@intFromPtr(window.handle) != 0);
}
