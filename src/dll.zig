// SPDX-License-Identifier: CC0-1.0

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
//! **Why `openSystem` and not a path.** `LoadLibrary("d3d12.dll")` searches
//! the directory the program was started from first. Anyone who can write a
//! file next to the executable - an installer, a shared folder, a download
//! that landed in the same place - can therefore put their own `d3d12.dll`
//! there and have it loaded in the process, with the process's privileges.
//! This is old, it has a name (DLL planting or DLL preloading), and the fix is
//! one flag: `LOAD_LIBRARY_SEARCH_SYSTEM32` says to look in `System32` and
//! nowhere else. `openSystem` always passes it, and refuses a name with a path
//! in it, because a path would defeat the point.
//!
//! A DLL that genuinely ships with the program - `d3dcompiler_47.dll`, or the
//! Agility SDK's `D3D12Core.dll` - is a different case, and one this module
//! deliberately does not guess at: load it however its rules require and hand
//! the handle to `fromHandle`.

const std = @import("std");
const windows = std.os.windows;
const testing = std.testing;

/// `LOAD_LIBRARY_SEARCH_SYSTEM32`: look in `%SystemRoot%\System32` and stop.
const search_system32: u32 = 0x00000800;

extern "kernel32" fn LoadLibraryExW(
    lpLibFileName: [*:0]const u16,
    hFile: ?windows.HANDLE,
    dwFlags: u32,
) callconv(.winapi) ?windows.HMODULE;

extern "kernel32" fn GetProcAddress(
    hModule: windows.HMODULE,
    lpProcName: [*:0]const u8,
) callconv(.winapi) ?windows.FARPROC;

extern "kernel32" fn FreeLibrary(hLibModule: windows.HMODULE) callconv(.winapi) c_int;

/// A loaded module, and the one reference to it this value owns.
pub const Library = struct {
    handle: windows.HMODULE,

    /// The longest name `openSystem` will take, in UTF-16 code units. A DLL
    /// name in `System32` is a dozen characters; this is generous.
    pub const max_name_len = 96;

    pub const OpenError = error{
        /// Windows would not load it. Usually it is not there - this is the
        /// answer on a machine with no `d3d12.dll` - but a DLL that fails its
        /// own initialisation arrives here too.
        LibraryNotFound,
        /// Not a bare file name: too long, empty, or with a directory in it.
        InvalidName,
    };

    /// Load a DLL from `System32` by name - `"d3d12.dll"`, `"dxgi.dll"` - and
    /// from nowhere else. See the module comment for why the search path is
    /// worth caring about.
    ///
    /// Windows keeps one module per process and counts references, so calling
    /// this twice for the same DLL is cheap and gives the same handle. It also
    /// means every `openSystem` needs its `close`.
    pub fn openSystem(name: []const u8) OpenError!Library {
        // A UTF-8 name never needs more UTF-16 code units than it has bytes,
        // so this one check is enough to keep the conversion inside `wide`.
        if (name.len == 0 or name.len > max_name_len) return error.InvalidName;
        for (name) |char| {
            // A path here would either be ignored or would reintroduce exactly
            // the search this function exists to avoid.
            if (char == '\\' or char == '/' or char == ':') return error.InvalidName;
        }

        var wide: [max_name_len + 1]u16 = undefined;
        const len = std.unicode.utf8ToUtf16Le(wide[0..max_name_len], name) catch
            return error.InvalidName;
        wide[len] = 0;

        const handle = LoadLibraryExW(wide[0..len :0].ptr, null, search_system32) orelse
            return error.LibraryNotFound;
        return .{ .handle = handle };
    }

    /// Take a module handle that came from somewhere else - `LoadLibraryEx`
    /// with flags this module does not offer, or `GetModuleHandle` for a DLL
    /// that is already in the process.
    ///
    /// `close` calls `FreeLibrary` either way, so only wrap a handle whose
    /// reference this `Library` is meant to own. A `GetModuleHandle` result is
    /// not one: it does not add a reference, so freeing it takes away
    /// somebody else's.
    pub fn fromHandle(handle: windows.HMODULE) Library {
        return .{ .handle = handle };
    }

    /// Drop this reference. Any function pointer taken out of the module dies
    /// with the last reference, so nothing may be called afterwards.
    pub fn close(self: *Library) void {
        _ = FreeLibrary(self.handle);
        self.* = undefined;
    }

    /// One exported function, by name, or null if the module does not have it.
    ///
    /// `T` must be a function pointer with the calling convention the DLL was
    /// built with, which for everything in Windows means `callconv(.winapi)`.
    /// Nothing checks that at run time: a wrong signature here is a corrupt
    /// stack later, so it is worth reading the signature twice.
    ///
    /// By name, and never by ordinal. The ordinals in the Direct3D DLLs are
    /// not a documented interface and have moved between Windows releases.
    pub fn lookup(self: Library, comptime T: type, symbol: [:0]const u8) ?T {
        comptime checkFunctionPointer(T, "lookup");
        const proc = GetProcAddress(self.handle, symbol.ptr) orelse return null;
        // `FARPROC` is an opaque pointer, so it carries no alignment, while a
        // function pointer on ARM64 wants four. The assertion holds: the
        // loader will not hand back an entry point the processor cannot jump
        // to.
        return @ptrCast(@alignCast(proc));
    }

    /// Resolve a whole table of entry points in one call. Each field of `T` is
    /// looked up under its own name, so the struct is both the declaration and
    /// the list of what to fetch, and there is no second list to fall out of
    /// step with the first.
    ///
    /// A field that is an optional function pointer may be missing, and comes
    /// back null; a field that is not is required, and its absence is
    /// `error.SymbolNotFound`. That distinction is the whole point of the
    /// table: `D3D12CreateDevice` has been in `d3d12.dll` since the DLL
    /// existed and there is no sense in running without it, while
    /// `D3D12GetDebugInterface` is missing on any machine without the Graphics
    /// Tools feature and a program should simply carry on without a debug
    /// layer.
    ///
    /// A field may also be `*const anyopaque` rather than a function pointer,
    /// which says "this export exists and this program does not describe how
    /// to call it". Whether an entry point is present is worth knowing on its
    /// own - it is how a program tells one Windows from another - and writing
    /// out a signature nobody calls is a way to get one wrong.
    ///
    /// `error.SymbolNotFound` does not say which one; `firstMissing` does,
    /// for the error message.
    pub fn bind(self: Library, comptime T: type) error{SymbolNotFound}!T {
        comptime checkTable(T);
        var table: T = undefined;
        inline for (@typeInfo(T).@"struct".fields) |field| {
            if (GetProcAddress(self.handle, field.name.ptr)) |proc| {
                @field(table, field.name) = @ptrCast(@alignCast(proc));
            } else if (comptime isOptional(field.type)) {
                @field(table, field.name) = null;
            } else {
                return error.SymbolNotFound;
            }
        }
        return table;
    }

    /// The name of the first required entry of `T` this module does not
    /// export, or null if it exports them all. For turning a `bind` failure
    /// into a message that says what is actually wrong with the machine.
    pub fn firstMissing(self: Library, comptime T: type) ?[:0]const u8 {
        comptime checkTable(T);
        inline for (@typeInfo(T).@"struct".fields) |field| {
            if (comptime !isOptional(field.type)) {
                if (GetProcAddress(self.handle, field.name.ptr) == null) return field.name;
            }
        }
        return null;
    }
};

fn isOptional(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

fn functionPointerOf(comptime T: type) type {
    return if (isOptional(T)) @typeInfo(T).optional.child else T;
}

/// Reject anything that is not a pointer to a function, with a message that
/// names the type, rather than letting `@ptrCast` fail somewhere less obvious.
fn checkFunctionPointer(comptime T: type, comptime what: []const u8) void {
    const info = @typeInfo(T);
    const ok = info == .pointer and info.pointer.size == .one and
        @typeInfo(info.pointer.child) == .@"fn";
    if (!ok) @compileError(
        "fluxion-d3d: " ++ what ++ " wants a function pointer, got " ++ @typeName(T),
    );
}

fn checkTable(comptime T: type) void {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError(
        "fluxion-d3d: an entry point table must be a struct, got " ++ @typeName(T),
    );
    for (info.@"struct".fields) |field| {
        // A function pointer to call, or an opaque one to merely notice.
        const entry = @typeInfo(functionPointerOf(field.type));
        if (entry != .pointer or entry.pointer.size != .one) @compileError(
            "fluxion-d3d: an entry point table field must be a pointer, got " ++
                @typeName(field.type),
        );
    }
}

// -------------------------------------------------------------------------
// Tests
//
// Against `kernel32.dll`, which is loaded in every process on every Windows
// there has ever been. Nothing here needs a graphics card, and nothing here
// can be skipped for want of one.
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
