// SPDX-License-Identifier: CC0-1.0

//! A window to put a swap chain in.
//!
//! Nothing here is Direct3D. A swap chain needs an `HWND` and Windows will not
//! provide one without a window class, a message procedure and a loop that
//! drains the queue, so this is the smallest amount of Win32 that gets those
//! three things and no more.
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

const std = @import("std");

const d3d = @import("fluxion_d3d");

const Handle = *opaque {};

// -------------------------------------------------------------------------
// The Win32 the examples need
// -------------------------------------------------------------------------

const Rect = extern struct {
    left: i32 = 0,
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,
};

const Point = extern struct {
    x: i32 = 0,
    y: i32 = 0,
};

const Message = extern struct {
    window: ?Handle = null,
    message: u32 = 0,
    wparam: usize = 0,
    lparam: isize = 0,
    time: u32 = 0,
    point: Point = .{},
};

const WindowProc = *const fn (Handle, u32, usize, isize) callconv(.winapi) isize;

const ClassExW = extern struct {
    size: u32,
    style: u32,
    proc: WindowProc,
    class_extra: i32 = 0,
    window_extra: i32 = 0,
    instance: ?Handle,
    icon: ?Handle = null,
    cursor: ?Handle = null,
    background: ?Handle = null,
    menu_name: ?[*:0]const u16 = null,
    class_name: [*:0]const u16,
    small_icon: ?Handle = null,
};

extern "user32" fn RegisterClassExW(class: *const ClassExW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(
    ex_style: u32,
    class_name: [*:0]const u16,
    window_name: [*:0]const u16,
    style: u32,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    parent: ?Handle,
    menu: ?Handle,
    instance: ?Handle,
    param: ?*anyopaque,
) callconv(.winapi) ?Handle;
extern "user32" fn DefWindowProcW(Handle, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn DestroyWindow(window: Handle) callconv(.winapi) c_int;
extern "user32" fn PostQuitMessage(code: c_int) callconv(.winapi) void;
extern "user32" fn ShowWindow(window: Handle, command: c_int) callconv(.winapi) c_int;
extern "user32" fn PeekMessageW(
    message: *Message,
    window: ?Handle,
    first: u32,
    last: u32,
    remove: u32,
) callconv(.winapi) c_int;
extern "user32" fn TranslateMessage(message: *const Message) callconv(.winapi) c_int;
extern "user32" fn DispatchMessageW(message: *const Message) callconv(.winapi) isize;
extern "user32" fn GetClientRect(window: Handle, rect: *Rect) callconv(.winapi) c_int;
extern "user32" fn AdjustWindowRect(rect: *Rect, style: u32, menu: c_int) callconv(.winapi) c_int;
extern "user32" fn LoadCursorW(instance: ?Handle, name: [*:0]const u16) callconv(.winapi) ?Handle;
extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?Handle;

const cs_hredraw: u32 = 0x0002;
const cs_vredraw: u32 = 0x0001;
/// `WS_OVERLAPPEDWINDOW`: a title bar, a border that resizes, and the three
/// buttons.
const ws_overlappedwindow: u32 = 0x00CF0000;
const ws_visible: u32 = 0x10000000;
const cw_usedefault: i32 = @bitCast(@as(u32, 0x80000000));
const sw_show: c_int = 5;
const pm_remove: u32 = 1;

const wm_destroy: u32 = 0x0002;
const wm_size: u32 = 0x0005;
const wm_close: u32 = 0x0010;
const wm_quit: u32 = 0x0012;
const wm_keydown: u32 = 0x0100;
const vk_escape: usize = 0x1B;

/// `IDC_ARROW`. A cursor identifier is a small integer pretending to be a
/// string, which is what `MAKEINTRESOURCE` does.
const idc_arrow: [*:0]const u16 = @ptrFromInt(32512);

// -------------------------------------------------------------------------
// The window
// -------------------------------------------------------------------------

/// What the message procedure has to tell the loop.
///
/// It lives here rather than in the window's user data because an example
/// opens one window, and the call that attaches a pointer to a window is
/// named differently on 32-bit Windows - a wrinkle worth avoiding in a file
/// whose subject is Direct3D.
const State = struct {
    closed: bool = false,
    resized: bool = false,
    width: u32 = 0,
    height: u32 = 0,
};

var state: State = .{};

fn windowProc(window: Handle, message: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    switch (message) {
        wm_close => {
            _ = DestroyWindow(window);
            return 0;
        },
        wm_destroy => {
            state.closed = true;
            PostQuitMessage(0);
            return 0;
        },
        wm_size => {
            // The new client size is packed into the low and high halves of
            // `lparam`. A minimised window reports zero, which is a size no
            // swap chain will accept, so the loop has to check.
            const packed_size: usize = @bitCast(lparam);
            state.width = @intCast(packed_size & 0xFFFF);
            state.height = @intCast(packed_size >> 16 & 0xFFFF);
            state.resized = true;
            return 0;
        },
        wm_keydown => {
            if (wparam == vk_escape) _ = DestroyWindow(window);
            return 0;
        },
        else => return DefWindowProcW(window, message, wparam, lparam),
    }
}

pub const Window = struct {
    handle: Handle,
    width: u32,
    height: u32,

    pub const Error = error{ ClassFailed, WindowFailed };

    /// Open a window whose *client area* - the part a swap chain fills - is
    /// `width` by `height`. The frame around it is added on top, which is what
    /// `AdjustWindowRect` works out.
    pub fn open(comptime title: []const u8, width: u32, height: u32) Error!Window {
        state = .{ .width = width, .height = height };
        makeDpiAware();

        const class_name = std.unicode.utf8ToUtf16LeStringLiteral("fluxion-d3d-example");
        const instance = GetModuleHandleW(null);

        const class: ClassExW = .{
            .size = @sizeOf(ClassExW),
            // Redraw the whole window when either dimension changes, rather
            // than leaving the old pixels along the edge.
            .style = cs_hredraw | cs_vredraw,
            .proc = windowProc,
            .instance = instance,
            .cursor = LoadCursorW(null, idc_arrow),
            .class_name = class_name,
        };
        // Registering twice in one process is an error, and harmless: the
        // class from the first time is still there.
        _ = RegisterClassExW(&class);

        var frame: Rect = .{
            .right = @intCast(width),
            .bottom = @intCast(height),
        };
        _ = AdjustWindowRect(&frame, ws_overlappedwindow, 0);

        const handle = CreateWindowExW(
            0,
            class_name,
            std.unicode.utf8ToUtf16LeStringLiteral(title),
            ws_overlappedwindow | ws_visible,
            cw_usedefault,
            cw_usedefault,
            frame.right - frame.left,
            frame.bottom - frame.top,
            null,
            null,
            instance,
            null,
        ) orelse return error.WindowFailed;

        _ = ShowWindow(handle, sw_show);

        var self: Window = .{ .handle = handle, .width = width, .height = height };
        // Ask the window rather than trusting the arithmetic: the frame the
        // window manager actually gave may differ.
        var client: Rect = .{};
        if (GetClientRect(handle, &client) != 0) {
            self.width = @intCast(client.right - client.left);
            self.height = @intCast(client.bottom - client.top);
        }
        state.width = self.width;
        state.height = self.height;
        return self;
    }

    /// Drain everything in the queue and answer whether the window is still
    /// there. This does not wait: a program that draws every frame must not
    /// block on a message that may never arrive.
    pub fn pump(self: *Window) bool {
        var message: Message = .{};
        while (PeekMessageW(&message, null, 0, 0, pm_remove) != 0) {
            if (message.message == wm_quit) state.closed = true;
            _ = TranslateMessage(&message);
            _ = DispatchMessageW(&message);
        }
        self.width = state.width;
        self.height = state.height;
        return !state.closed;
    }

    /// Whether the window changed size since this was last asked. Reading it
    /// clears it, because the answer is a thing to act on once.
    pub fn takeResize(_: *Window) bool {
        defer state.resized = false;
        return state.resized;
    }

    /// True while the window has no area to draw into, which is what being
    /// minimised looks like. A swap chain cannot be resized to nothing, so a
    /// loop skips its frame instead.
    pub fn minimised(self: Window) bool {
        return self.width == 0 or self.height == 0;
    }

    pub fn close(self: *Window) void {
        if (!state.closed) _ = DestroyWindow(self.handle);
        self.* = undefined;
    }
};

/// Tell Windows this program draws at the monitor's real resolution.
///
/// Without it a window on a high-resolution display is rendered at a third of
/// the pixels and scaled up, which looks exactly like a bug in the renderer.
/// The call arrived in Windows 10 1703, so it is fetched by name and skipped
/// where it is not there - which is the whole argument of the library this
/// example belongs to, applied to something that is not Direct3D at all.
fn makeDpiAware() void {
    var user32 = d3d.Library.openSystem("user32.dll") catch return;
    defer user32.close();

    const set = user32.lookup(
        *const fn (?*anyopaque) callconv(.winapi) c_int,
        "SetProcessDpiAwarenessContext",
    ) orelse return;

    // `DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2` is the handle -4, which is
    // a sentinel and not a pointer to anything.
    _ = set(@ptrFromInt(@as(usize, @bitCast(@as(isize, -4)))));
}

test "the message struct is the size Windows writes" {
    // `PeekMessage` writes into this, so it being too small is stack
    // corruption rather than a wrong answer.
    const expected: usize = if (@sizeOf(usize) == 8) 48 else 28;
    try std.testing.expectEqual(expected, @sizeOf(Message));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Rect));
}
