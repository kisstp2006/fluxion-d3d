// SPDX-License-Identifier: CC0-1.0

//! The 32-bit number every COM call returns instead of throwing.
//!
//! An `HRESULT` is not a code to look up in a list. It is three fields packed
//! into an `i32`: one bit for failure, eleven naming the component, and sixteen
//! that mean whatever that component wanted. Which is why `0x887A0005` can be
//! recognised as "something in DXGI" without knowing what `0x0005` is.
//!
//! Two consequences worth stating plainly:
//!
//!   * Success is not one value. `S_OK` is zero and `S_FALSE` is one, and a
//!     call that answers a question rather than doing work returns the second
//!     routinely - `D3D12CreateDevice` with no output pointer says "yes, this
//!     adapter would work" that way. Test `hr.failed()`, not `hr == .s_ok`.
//!   * Failure is not one value either. There are thousands, most from
//!     components with nothing to do with Direct3D.
//!
//! `check` maps the ones worth acting on differently to Zig errors and calls
//! everything else `error.Unexpected`; `name` and `format` keep the original
//! number readable for the log line that follows.

const std = @import("std");
const testing = std.testing;

/// Turn the way `winerror.h` writes a failing HRESULT - as a `u32` literal
/// with the top bit set - into the `i32` it actually is.
fn hr(value: u32) i32 {
    return @bitCast(value);
}

/// Non-exhaustive: the values here are the ones a Direct3D loader meets, and
/// any other number is still an `Hresult`, still readable through `parts`.
pub const Hresult = enum(i32) {
    // --- success ---------------------------------------------------------
    /// It worked. Zero, so `if (hr == .s_ok)` reads like C - but see the
    /// module comment for why that test is usually the wrong one.
    s_ok = 0,
    /// It worked, and the answer is no. A query that found nothing, a device
    /// check that says "supported" without being asked to create anything.
    s_false = 1,

    // --- the general COM failures ----------------------------------------
    e_unexpected = hr(0x8000FFFF),
    e_notimpl = hr(0x80004001),
    e_nointerface = hr(0x80004002),
    e_pointer = hr(0x80004003),
    e_abort = hr(0x80004004),
    e_fail = hr(0x80004005),

    // --- Win32 errors wearing an HRESULT -------------------------------
    // `HRESULT_FROM_WIN32` is `0x80070000 | code`, which is facility 7 and the
    // plain Win32 error in the low sixteen bits. `E_INVALIDARG` is not a COM
    // invention: it is `ERROR_INVALID_PARAMETER`, 87, dressed up.
    error_file_not_found = hr(0x80070002),
    e_accessdenied = hr(0x80070005),
    e_handle = hr(0x80070006),
    e_outofmemory = hr(0x8007000E),
    e_invalidarg = hr(0x80070057),
    error_mod_not_found = hr(0x8007007E),
    error_proc_not_found = hr(0x8007007F),

    // --- DXGI, facility 0x87A --------------------------------------------
    dxgi_error_invalid_call = hr(0x887A0001),
    dxgi_error_not_found = hr(0x887A0002),
    dxgi_error_more_data = hr(0x887A0003),
    dxgi_error_unsupported = hr(0x887A0004),
    dxgi_error_device_removed = hr(0x887A0005),
    dxgi_error_device_hung = hr(0x887A0006),
    dxgi_error_device_reset = hr(0x887A0007),
    dxgi_error_was_still_drawing = hr(0x887A000A),
    dxgi_error_frame_statistics_disjoint = hr(0x887A000B),
    dxgi_error_graphics_vidpn_source_in_use = hr(0x887A000C),
    dxgi_error_driver_internal_error = hr(0x887A0020),
    dxgi_error_nonexclusive = hr(0x887A0021),
    dxgi_error_not_currently_available = hr(0x887A0022),
    dxgi_error_remote_client_disconnected = hr(0x887A0023),
    dxgi_error_remote_outofmemory = hr(0x887A0024),
    dxgi_error_access_lost = hr(0x887A0026),
    dxgi_error_wait_timeout = hr(0x887A0027),
    dxgi_error_session_disconnected = hr(0x887A0028),
    dxgi_error_restrict_to_output_stale = hr(0x887A0029),
    dxgi_error_cannot_protect_content = hr(0x887A002A),
    dxgi_error_access_denied = hr(0x887A002B),
    dxgi_error_name_already_exists = hr(0x887A002C),
    /// The debug layer was asked for and the Graphics Tools feature is not
    /// installed. The usual answer is to drop the debug flag and carry on.
    dxgi_error_sdk_component_missing = hr(0x887A002D),

    // --- Direct3D 11, facility 0x87C -------------------------------------
    d3d11_error_too_many_unique_state_objects = hr(0x887C0001),
    d3d11_error_file_not_found = hr(0x887C0002),
    d3d11_error_too_many_unique_view_objects = hr(0x887C0003),
    d3d11_error_deferred_context_map_without_initial_discard = hr(0x887C0004),

    // --- Direct3D 12, facility 0x87E -------------------------------------
    d3d12_error_adapter_not_found = hr(0x887E0001),
    d3d12_error_driver_version_mismatch = hr(0x887E0002),

    _,

    /// The bit that decides everything: set means failure. Every other bit is
    /// detail.
    pub fn failed(self: Hresult) bool {
        return @intFromEnum(self) < 0;
    }

    /// The inverse of `failed`, for the call sites where that reads better.
    /// Note that this is true for `S_FALSE` as well as `S_OK`.
    pub fn succeeded(self: Hresult) bool {
        return @intFromEnum(self) >= 0;
    }

    /// The three fields the number is made of.
    pub fn parts(self: Hresult) Parts {
        return @bitCast(@intFromEnum(self));
    }

    /// The raw bits, as `winerror.h` writes them.
    pub fn bits(self: Hresult) u32 {
        return @bitCast(@intFromEnum(self));
    }

    /// The name the SDK gives this value, or null for one that is not in the
    /// list above. Worth printing next to the number: `0x887A0005` means
    /// nothing to a reader, `DXGI_ERROR_DEVICE_REMOVED` means the GPU went
    /// away.
    pub fn name(self: Hresult) ?[]const u8 {
        return switch (self) {
            _ => null,
            inline else => |tag| comptime upperCase(@tagName(tag)),
        };
    }

    /// A Zig error for a failing HRESULT, and nothing at all for a succeeding
    /// one - including `S_FALSE`, which is a success.
    ///
    /// ```zig
    /// try factory.vtable.EnumAdapters1(factory, index, &adapter).check();
    /// ```
    ///
    /// Values without a Zig error of their own become `error.Unexpected`; keep
    /// the `Hresult` and print it when that matters. The error set says what to
    /// do, the number says what happened.
    pub fn check(self: Hresult) Error!void {
        if (self.succeeded()) return;
        return switch (self) {
            .e_notimpl => error.NotImplemented,
            .e_nointerface => error.NoInterface,
            .e_pointer => error.NullPointer,
            .e_abort => error.Aborted,
            .e_fail => error.Failed,
            .e_accessdenied, .dxgi_error_access_denied => error.AccessDenied,
            .e_handle => error.InvalidHandle,
            .e_outofmemory, .dxgi_error_remote_outofmemory => error.OutOfMemory,
            .e_invalidarg => error.InvalidArgument,
            .error_file_not_found, .d3d11_error_file_not_found => error.FileNotFound,
            .error_mod_not_found => error.ModuleNotFound,
            .error_proc_not_found => error.SymbolNotFound,
            .dxgi_error_invalid_call => error.InvalidCall,
            .dxgi_error_not_found => error.NotFound,
            .dxgi_error_more_data => error.MoreData,
            .dxgi_error_unsupported => error.Unsupported,
            .dxgi_error_device_removed => error.DeviceRemoved,
            .dxgi_error_device_hung => error.DeviceHung,
            .dxgi_error_device_reset => error.DeviceReset,
            .dxgi_error_was_still_drawing => error.WasStillDrawing,
            .dxgi_error_driver_internal_error => error.DriverInternalError,
            .dxgi_error_nonexclusive => error.NonExclusive,
            .dxgi_error_not_currently_available => error.NotCurrentlyAvailable,
            .dxgi_error_access_lost => error.AccessLost,
            .dxgi_error_wait_timeout => error.WaitTimeout,
            .dxgi_error_sdk_component_missing => error.SdkComponentMissing,
            .d3d12_error_adapter_not_found => error.AdapterNotFound,
            .d3d12_error_driver_version_mismatch => error.DriverVersionMismatch,
            else => error.Unexpected,
        };
    }

    /// `DXGI_ERROR_DEVICE_REMOVED (0x887A0005)`, or just the number and the
    /// facility for a value with no name here.
    pub fn format(self: Hresult, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.name()) |known| {
            try w.print("{s} (0x{X:0>8})", .{ known, self.bits() });
        } else {
            try w.print("0x{X:0>8} (facility {t})", .{ self.bits(), self.parts().facility });
        }
    }
};

/// Every error `check` can produce. Two of them - `OutOfMemory` and
/// `AccessDenied` - come from more than one HRESULT, because the distinction
/// is not one a caller can act on.
pub const Error = error{
    /// A failing HRESULT this library has no name for. Print the `Hresult`.
    Unexpected,
    NotImplemented,
    NoInterface,
    NullPointer,
    Aborted,
    Failed,
    AccessDenied,
    InvalidHandle,
    OutOfMemory,
    InvalidArgument,
    FileNotFound,
    ModuleNotFound,
    SymbolNotFound,
    InvalidCall,
    NotFound,
    MoreData,
    Unsupported,
    DeviceRemoved,
    DeviceHung,
    DeviceReset,
    WasStillDrawing,
    DriverInternalError,
    NonExclusive,
    NotCurrentlyAvailable,
    AccessLost,
    WaitTimeout,
    /// The debug layer was asked for, and the optional Windows feature that
    /// provides it is not installed.
    SdkComponentMissing,
    AdapterNotFound,
    DriverVersionMismatch,
};

/// The fields an HRESULT is packed from, lowest bit first - which is the
/// order a Zig packed struct lays them out in, so this maps straight onto the
/// number with no shifting.
pub const Parts = packed struct(u32) {
    /// What went wrong, as the facility defines it. Meaningless on its own.
    code: u16,
    /// Who it went wrong in.
    facility: Facility,
    /// `C`: this value was defined by somebody other than Microsoft.
    customer: bool,
    /// `R`: reserved.
    reserved: u1,
    /// `S`: the sign bit. Set means failure.
    failure: bool,

    /// The low 16 bits are an NTSTATUS code rather than something the facility
    /// defined, which is what `HRESULT_FROM_NT` produces. The bit that says so
    /// sits inside the facility field - see `Facility`.
    pub fn fromNtstatus(self: Parts) bool {
        return @intFromEnum(self.facility) & 0x1000 != 0;
    }
};

/// The component a code belongs to. Non-exhaustive - there are over a hundred
/// and most have nothing to do with graphics.
///
/// Thirteen bits, because that is what `HRESULT_FACILITY` masks off. The
/// original layout gave the facility eleven and spent the two above it on
/// flags, but Microsoft ran past 0x7FF and began handing out numbers that
/// overlap them - `dxgi` is 0x87A. Bit 12, 0x1000, is still the NTSTATUS
/// marker `Parts.fromNtstatus` reads.
pub const Facility = enum(u13) {
    null = 0,
    rpc = 1,
    dispatch = 2,
    storage = 3,
    itf = 4,
    /// Where `HRESULT_FROM_WIN32` puts a plain Win32 error.
    win32 = 7,
    windows = 8,
    control = 10,
    internet = 12,
    /// Direct3D 9 and earlier.
    d3d = 0x876,
    dxgi = 0x87A,
    dxgi_ddi = 0x87B,
    direct3d11 = 0x87C,
    direct3d11_debug = 0x87D,
    direct3d12 = 0x87E,
    direct3d12_debug = 0x87F,
    direct2d = 0x899,
    _,
};

/// `HRESULT_FROM_WIN32`: what `GetLastError` gives, as an HRESULT. Zero stays
/// zero, because success has no facility.
pub fn fromWin32(code: u32) Hresult {
    if (code == 0) return .s_ok;
    return @enumFromInt(hr(0x80070000 | (code & 0xFFFF)));
}

/// Upper-case a tag name at compile time, so `name` can hand back the SDK
/// spelling without a second table to keep in step with the enum.
fn upperCase(comptime tag_name: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(20_000);
        var buffer: [tag_name.len]u8 = undefined;
        for (tag_name, 0..) |char, i| buffer[i] = std.ascii.toUpper(char);
        const frozen = buffer;
        return &frozen;
    }
}

test "success is not one value" {
    try testing.expect(Hresult.s_ok.succeeded());
    try testing.expect(!Hresult.s_ok.failed());

    // The one that catches people out: a question answered "no" is a success.
    try testing.expect(Hresult.s_false.succeeded());
    try testing.expect(Hresult.s_false != .s_ok);
    try Hresult.s_false.check();

    try testing.expect(Hresult.e_fail.failed());
    try testing.expect(!Hresult.e_fail.succeeded());
}

test "the fields the number is made of" {
    const removed = Hresult.dxgi_error_device_removed;
    const parts = removed.parts();
    try testing.expect(parts.failure);
    try testing.expectEqual(Facility.dxgi, parts.facility);
    try testing.expectEqual(@as(u16, 5), parts.code);
    try testing.expect(!parts.customer);
    try testing.expect(!parts.fromNtstatus());

    // Which is the same thing the raw number says, read by hand.
    try testing.expectEqual(@as(u32, 0x887A0005), removed.bits());

    // And the facility is what tells a stranger's code where it came from.
    try testing.expectEqual(Facility.direct3d12, Hresult.d3d12_error_adapter_not_found.parts().facility);
    try testing.expectEqual(Facility.direct3d11, Hresult.d3d11_error_file_not_found.parts().facility);
    try testing.expectEqual(Facility.win32, Hresult.e_invalidarg.parts().facility);
}

test "E_INVALIDARG is a Win32 error in a hat" {
    // 87 is ERROR_INVALID_PARAMETER. There is nothing COM about it.
    try testing.expectEqual(Hresult.e_invalidarg, fromWin32(87));
    try testing.expectEqual(@as(u16, 87), Hresult.e_invalidarg.parts().code);

    // 126 is ERROR_MOD_NOT_FOUND, which is what a missing DLL turns into.
    try testing.expectEqual(Hresult.error_mod_not_found, fromWin32(126));

    // Success has no facility to belong to.
    try testing.expectEqual(Hresult.s_ok, fromWin32(0));
}

test "errors, named and unnamed" {
    try testing.expectError(error.DeviceRemoved, Hresult.dxgi_error_device_removed.check());
    try testing.expectError(error.InvalidArgument, Hresult.e_invalidarg.check());
    try testing.expectError(error.OutOfMemory, Hresult.e_outofmemory.check());
    try testing.expectError(error.SdkComponentMissing, Hresult.dxgi_error_sdk_component_missing.check());

    // A failure from some component this library has never heard of still has
    // to be an error, and still has to be printable.
    const stranger: Hresult = @enumFromInt(hr(0x88990001));
    try testing.expectError(error.Unexpected, stranger.check());
    try testing.expectEqual(Facility.direct2d, stranger.parts().facility);
    try testing.expectEqual(@as(?[]const u8, null), stranger.name());
}

test "names come from the tags" {
    try testing.expectEqualStrings("DXGI_ERROR_DEVICE_REMOVED", Hresult.dxgi_error_device_removed.name().?);
    try testing.expectEqualStrings("E_INVALIDARG", Hresult.e_invalidarg.name().?);
    try testing.expectEqualStrings("S_OK", Hresult.s_ok.name().?);
    try testing.expectEqualStrings(
        "D3D12_ERROR_DRIVER_VERSION_MISMATCH",
        Hresult.d3d12_error_driver_version_mismatch.name().?,
    );
}

test "formatting keeps the number" {
    var buffer: [128]u8 = undefined;

    const known = try std.fmt.bufPrint(&buffer, "{f}", .{Hresult.dxgi_error_device_removed});
    try testing.expectEqualStrings("DXGI_ERROR_DEVICE_REMOVED (0x887A0005)", known);

    const unknown = try std.fmt.bufPrint(&buffer, "{f}", .{@as(Hresult, @enumFromInt(hr(0x887A00FF)))});
    try testing.expectEqualStrings("0x887A00FF (facility dxgi)", unknown);
}

test "the packed struct really is the number" {
    // If the field order were wrong this would still compile and would be
    // wrong everywhere, so check both directions on a value with every field
    // set to something distinguishable.
    const parts: Parts = .{
        .code = 0x1234,
        .facility = .dxgi,
        .customer = true,
        .reserved = 0,
        .failure = true,
    };
    const value: u32 = @bitCast(parts);
    try testing.expectEqual(@as(u32, 0xA87A1234), value);

    const back: Hresult = @enumFromInt(@as(i32, @bitCast(value)));
    try testing.expectEqual(parts, back.parts());
    try testing.expect(back.failed());
}
