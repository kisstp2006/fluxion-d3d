// SPDX-License-Identifier: BSL-1.0

//! Opening a system DLL and getting function pointers out of it.
//!
//! Direct3D is not a library you link against. `d3d11.dll` and `d3d12.dll` are
//! part of Windows, they are different on every machine, and which of them
//! exists at all depends on the version: `d3d12.dll` arrived with Windows 10,
//! `CreateDXGIFactory2` with 8.1, `D3D12GetDebugInterface` only answers when
//! an optional feature is installed. A program that imports those symbols the
//! ordinary way does not run at all on a machine that is missing one - the
//! loader fails before `main`, with a message about a missing entry point and
//! no way to fall back. So a program that wants to keep running asks for them
//! at run time, one at a time, and decides what to do when one is not there.
//!
//! That is all this module is: `openSystem` for the DLL, `lookup` for one
//! symbol, and `bind` for a whole struct of them at once.
//!
//! ```zig
//! const Entries = struct {
//!     D3D12CreateDevice: *const fn (...) callconv(.winapi) Hresult,
//!     // Optional, so a machine without the Graphics Tools feature loads
//!     // fine and this field is simply null.
//!     D3D12GetDebugInterface: ?*const fn (...) callconv(.winapi) Hresult = null,
//! };
//!
//! var lib = try Library.openSystem("d3d12.dll");
//! const entries = try lib.bind(Entries);
//! ```
//!
//! **None of that is about Direct3D.** Opening a library by name and fetching
//! its entry points is what `fluxion-dyn` does, for `libvulkan.so.1` and
//! `opengl32.dll` as much as for `d3d12.dll`, so this module is the
//! Direct3D-facing name for it. What stays here is one guarantee worth
//! restating, because it is the whole argument for loading over linking:
//!
//! **Why `openSystem` and not a path.** `LoadLibrary("d3d12.dll")` searches the
//! program's own directory first, so anyone who can write a file next to the
//! executable can have their `d3d12.dll` loaded with the process's privileges.
//! This is old, it has a name (DLL planting), and the fix is one flag:
//! `LOAD_LIBRARY_SEARCH_SYSTEM32`. `openSystem` always passes it, and refuses a
//! name with a path in it.
//!
//! A DLL that ships with the program - `d3dcompiler_47.dll`, the Agility SDK's
//! `D3D12Core.dll` - is a different case this module does not guess at: load it
//! however its rules require and hand the handle to `Library.fromHandle`.

const std = @import("std");
const testing = std.testing;

const dyn = @import("fluxion_dyn");

/// An open DLL, and the one reference to it this value owns.
///
/// `openSystem` loads one from `System32`, `lookup` takes one entry point out,
/// `bind` takes a whole struct of them, `firstMissing` names the one that was
/// not there, and `close` gives the module back.
pub const Library = dyn.Library;

/// Everything opening a DLL can fail with. `LibraryNotFound` is the ordinary
/// answer on a machine that has not got it - a Windows older than 10 has no
/// `d3d12.dll` - and the reason to fall back to `d3d11` rather than to stop.
pub const OpenError = dyn.OpenError;

/// A required entry point was not there. `Library.firstMissing` says which one,
/// which is the difference between a message worth printing and one that is not.
pub const Error = dyn.Error;

/// The longest name `openSystem` will take, in bytes. A DLL name in `System32`
/// is a dozen characters; this is generous.
pub const max_name_len = dyn.library.max_name_len;

/// Load a DLL from `System32` by name - `"d3d12.dll"`, `"dxgi.dll"` - and from
/// nowhere else. Shorthand for `Library.openSystem`.
pub fn openSystem(name: [:0]const u8) OpenError!Library {
    return Library.openSystem(name);
}

// -------------------------------------------------------------------------
// Tests
//
// Against `kernel32.dll`, which is loaded in every process on every Windows
// there has ever been. Nothing here needs a graphics card, and nothing here
// can be skipped for want of one.
//
// These are not a second copy of the tests `fluxion-dyn` already runs. They
// pin the part of its contract the four DLL modules here lean on, so that a
// change upstream that broke it fails in this file rather than inside
// `d3d12.load` on a machine nobody is watching.
// -------------------------------------------------------------------------

test "opening a system library and calling something out of it" {
    var lib = try Library.openSystem("kernel32.dll");
    defer lib.close();

    const tick_count = lib.lookup(*const fn () callconv(.winapi) u64, "GetTickCount64").?;
    try testing.expect(tick_count() > 0);
}

test "a symbol that is not there is null, not a crash" {
    var lib = try Library.openSystem("kernel32.dll");
    defer lib.close();

    const missing = lib.lookup(*const fn () callconv(.winapi) u64, "NoSuchExportExists");
    try testing.expectEqual(@as(?*const fn () callconv(.winapi) u64, null), missing);
}

test "a library that is not there" {
    try testing.expectError(
        error.LibraryNotFound,
        Library.openSystem("fluxion-d3d-no-such-library.dll"),
    );
}

test "a name with a path in it is refused" {
    // All three would either bypass the System32-only search or be ignored,
    // and quietly loading the wrong file is the failure worth preventing.
    try testing.expectError(error.InvalidName, Library.openSystem("C:\\Windows\\System32\\kernel32.dll"));
    try testing.expectError(error.InvalidName, Library.openSystem("..\\kernel32.dll"));
    try testing.expectError(error.InvalidName, Library.openSystem("sub/kernel32.dll"));
    try testing.expectError(error.InvalidName, Library.openSystem(""));
    try testing.expectError(error.InvalidName, Library.openSystem("x" ** 200));
}

test "binding a whole table, required and optional" {
    const Table = struct {
        // Both of these have been in kernel32 since Windows 2000.
        GetTickCount64: *const fn () callconv(.winapi) u64,
        GetCurrentProcessId: *const fn () callconv(.winapi) u32,
        // Not there, and allowed not to be.
        NoSuchExportExists: ?*const fn () callconv(.winapi) u64 = null,
        // There, and not described: this table only wants to know whether it
        // exists, which is a fair question to ask of an entry point.
        CreateFileW: ?*const anyopaque = null,
    };

    var lib = try Library.openSystem("kernel32.dll");
    defer lib.close();

    const table = try lib.bind(Table);
    try testing.expect(table.GetTickCount64() > 0);
    try testing.expect(table.GetCurrentProcessId() != 0);
    try testing.expectEqual(@as(?*const fn () callconv(.winapi) u64, null), table.NoSuchExportExists);
    // An entry nobody wants to call is still worth noticing, and an opaque
    // pointer says so without a signature to get wrong.
    try testing.expect(table.CreateFileW != null);

    // Every required entry resolved, so there is nothing to report.
    try testing.expectEqual(@as(?[:0]const u8, null), lib.firstMissing(Table));
}

test "a required entry that is missing, and finding out which" {
    const Table = struct {
        GetTickCount64: *const fn () callconv(.winapi) u64,
        ThisWasNeverAnExport: *const fn () callconv(.winapi) u64,
    };

    var lib = try Library.openSystem("kernel32.dll");
    defer lib.close();

    try testing.expectError(error.SymbolNotFound, lib.bind(Table));
    // Which is where the message comes from: "kernel32.dll has no
    // ThisWasNeverAnExport" is worth printing, "SymbolNotFound" is not.
    try testing.expectEqualStrings("ThisWasNeverAnExport", lib.firstMissing(Table).?);
}

test "the module is shared and counted" {
    // Two opens of one DLL are one module: Windows keeps a table per process
    // and hands back the same handle with the count raised. Which is why each
    // open needs its own close, and why closing one of them leaves the other
    // perfectly usable.
    var first = try Library.openSystem("kernel32.dll");
    defer first.close();

    var second = try Library.openSystem("kernel32.dll");
    try testing.expectEqual(first.handle, second.handle);
    second.close();

    const tick_count = first.lookup(*const fn () callconv(.winapi) u64, "GetTickCount64").?;
    try testing.expect(tick_count() > 0);
}
