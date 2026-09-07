// SPDX-License-Identifier: CC0-1.0

//! Calling through a COM vtable, and the reference counting that goes with it.
//!
//! A COM object is a pointer to a pointer to a table of functions, and every
//! one of those functions takes the object as its first argument. That is the
//! whole ABI. Written out in Zig it is an `extern struct` with one field:
//!
//! ```zig
//! pub const IExample = extern struct {
//!     vtable: *const VTable,
//!
//!     pub const iid = Guid.parseComptime("{...}");
//!
//!     pub const VTable = extern struct {
//!         // Every interface begins with these three, in this order, because
//!         // every interface derives from IUnknown.
//!         QueryInterface: *const fn (*IExample, *const Guid, *?*anyopaque) callconv(.winapi) Hresult,
//!         AddRef: *const fn (*IExample) callconv(.winapi) u32,
//!         Release: *const fn (*IExample) callconv(.winapi) u32,
//!         // Then this interface's own, in declaration order.
//!         DoSomething: *const fn (*IExample, u32) callconv(.winapi) Hresult,
//!     };
//! };
//! ```
//!
//! Inheritance is a layout rule, not a language feature: a derived interface
//! repeats every slot of its base, in order, before adding its own. So
//! `*IDXGIFactory6` is a valid `*IUnknown` and `@ptrCast` between them is
//! sound. It cuts both ways - a vtable missing a slot, or with two in the
//! wrong order, compiles fine and calls the wrong function.
//!
//! Rather than copy a base's slots into every derived vtable and hope they stay
//! in step, the interfaces here hold the base vtable as their first field,
//! which lays out identically:
//!
//! ```zig
//! pub const VTable = extern struct {
//!     base: IDXGIFactory.VTable,   // and that one begins with IDXGIObject's
//!     EnumAdapters1: *const fn (...) callconv(.winapi) Hresult,
//!     IsCurrent: *const fn (*IDXGIFactory1) callconv(.winapi) c_int,
//! };
//! ```
//!
//! An inherited method is called through `base`, so the chain says which
//! interface it came from: `factory.vtable.base.EnumAdapters(...)`.
//!
//! **Counting.** Every object holds a count. Getting one from anywhere - a
//! create call, `QueryInterface`, an enumerator - raises it and puts the
//! obligation on the caller; `release` lowers it, and the object frees itself
//! at zero. Nothing here does that for you: `defer _ = com.release(x)` right
//! after the call that produced `x` is the habit that makes it hard to forget.

const std = @import("std");
const testing = std.testing;

const Guid = @import("guid.zig").Guid;
const hresult = @import("hresult.zig");
const Hresult = hresult.Hresult;

/// Everything COM can go wrong with, re-exported so a caller needs one import.
pub const Error = hresult.Error;

/// The interface every other interface derives from.
pub const IUnknown = extern struct {
    vtable: *const VTable,

    pub const iid = Guid.parseComptime("{00000000-0000-0000-C000-000000000046}");

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IUnknown, *const Guid, *?*anyopaque) callconv(.winapi) Hresult,
        AddRef: *const fn (*IUnknown) callconv(.winapi) u32,
        Release: *const fn (*IUnknown) callconv(.winapi) u32,
    };
};

/// `ID3DBlob`: a lump of bytes the runtime allocated - compiled shader code, a
/// serialised root signature, a compiler's error message. Released like any
/// other COM object.
///
/// It lives here rather than with one runtime because all of them use it, and
/// neither should have to depend on the other for the type.
pub const ID3DBlob = extern struct {
    vtable: *const VTable,

    pub const iid = Guid.parseComptime("{8BA5FB08-5195-40E2-AC58-0D989C3A0102}");

    pub const VTable = extern struct {
        base: IUnknown.VTable,
        GetBufferPointer: *const fn (*ID3DBlob) callconv(.winapi) ?[*]u8,
        GetBufferSize: *const fn (*ID3DBlob) callconv(.winapi) usize,
    };

    /// The bytes, borrowed. They belong to the blob and die with it.
    pub fn bytes(self: *ID3DBlob) []const u8 {
        const size = self.vtable.GetBufferSize(self);
        const pointer = self.vtable.GetBufferPointer(self) orelse return &.{};
        return pointer[0..size];
    }

    /// The bytes as text, for a blob that holds a message rather than code.
    /// The trailing zero the compiler puts on is trimmed off.
    pub fn text(self: *ID3DBlob) []const u8 {
        return std.mem.sliceTo(self.bytes(), 0);
    }
};

/// Any COM pointer as `*IUnknown`.
///
/// Sound for the reason above: the first three vtable slots of every interface
/// are `IUnknown`'s, so the three that `*IUnknown` can reach are the right
/// three. The compile-time check below is what keeps a struct that merely
/// looks like an interface from getting this far.
pub fn unknown(object: anytype) *IUnknown {
    comptime checkInterfacePointer(@TypeOf(object), "unknown");
    return @ptrCast(object);
}

/// Take a reference, and answer with the new count.
///
/// Rarely what is wanted: a call that hands back an object has already taken a
/// reference on the caller's behalf. This is for keeping a second, independent
/// handle on an object somebody else still owns.
pub fn addRef(object: anytype) u32 {
    const base = unknown(object);
    return base.vtable.AddRef(base);
}

/// Give a reference back, and answer with the count that is left. At zero the
/// object is gone and the pointer must not be touched again.
///
/// The count is worth reading only when chasing a leak, and even then it is a
/// weak signal: the runtime holds its own references to a device, so a device
/// released at the end of a program routinely reports a count above zero.
pub fn release(object: anytype) u32 {
    const base = unknown(object);
    return base.vtable.Release(base);
}

/// Release several objects, in the order given. For the end of a function
/// that acquired a handful:
///
/// ```zig
/// defer com.releaseAll(.{ device, queue, factory });
/// ```
pub fn releaseAll(objects: anytype) void {
    inline for (objects) |object| _ = release(object);
}

/// Ask an object for another of its interfaces.
///
/// `T` must declare `pub const iid`. A successful call takes a reference, so
/// the result needs its own `release`; releasing the object it came from is
/// not the same thing.
///
/// `error.NoInterface` is the ordinary answer, not a fault: it is how a program
/// finds out what the machine's DXGI can do.
pub fn queryInterface(object: anytype, comptime T: type) Error!*T {
    const base = unknown(object);
    var raw: ?*anyopaque = null;
    return received(T, base.vtable.QueryInterface(base, iidOf(T), &raw), raw);
}

/// Whether an object implements an interface, without keeping the result. The
/// reference `QueryInterface` took is given straight back.
pub fn implements(object: anytype, comptime T: type) bool {
    const other = queryInterface(object, T) catch return false;
    _ = release(other);
    return true;
}

/// The address of an interface's identifier, which is what a `REFIID`
/// parameter wants.
pub fn iidOf(comptime T: type) *const Guid {
    if (!@hasDecl(T, "iid")) @compileError(
        "fluxion-d3d: " ++ @typeName(T) ++ " has no `iid`; a COM interface needs one",
    );
    return &T.iid;
}

/// The other half of every creation call: check what it returned, then turn
/// what it wrote into the `void **` slot back into a typed pointer.
///
/// ```zig
/// var raw: ?*anyopaque = null;
/// const hr = entries.D3D12CreateDevice(adapter, .@"11_0", com.iidOf(ID3D12Device), &raw);
/// const device = try com.received(ID3D12Device, hr, raw);
/// ```
///
/// The null check is not paranoia: `raw` starts null and nothing proves the
/// call wrote to it, so a success with nothing written is better as
/// `error.NullPointer` than as address zero handed to the next call.
pub fn received(comptime T: type, result: Hresult, raw: ?*anyopaque) Error!*T {
    try result.check();
    const pointer = raw orelse return error.NullPointer;
    return @ptrCast(@alignCast(pointer));
}

/// A COM pointer is a single-item pointer to an `extern struct` whose only
/// field is a pointer to a vtable that starts with `IUnknown`'s three methods.
/// Checking that here turns a mistyped interface declaration into a compile
/// error naming the type, rather than a call through the wrong slot.
fn checkInterfacePointer(comptime P: type, comptime what: []const u8) void {
    const complain = struct {
        fn no(comptime why: []const u8) noreturn {
            @compileError("fluxion-d3d: " ++ what ++ " wants a COM interface pointer; " ++
                @typeName(P) ++ " " ++ why);
        }
    };

    const pointer = @typeInfo(P);
    if (pointer != .pointer or pointer.pointer.size != .one) complain.no("is not a pointer to one value");
    if (pointer.pointer.is_const) complain.no("is const; COM calls take a mutable object");

    const interface = @typeInfo(pointer.pointer.child);
    if (interface != .@"struct" or interface.@"struct".layout != .@"extern")
        complain.no("does not point at an extern struct");
    if (interface.@"struct".fields.len != 1 or !std.mem.eql(u8, interface.@"struct".fields[0].name, "vtable"))
        complain.no("has no single `vtable` field");

    const vtable = @typeInfo(interface.@"struct".fields[0].type);
    if (vtable != .pointer or @typeInfo(vtable.pointer.child) != .@"struct")
        complain.no("has a `vtable` that does not point at a struct");

    if (!beginsWithIUnknown(vtable.pointer.child))
        complain.no("has a vtable that does not begin with IUnknown's three methods");
}

/// Do the first three function slots of this vtable belong to `IUnknown`?
///
/// A derived interface may write its base out slot by slot, or hold the base
/// vtable as its first field - the two lay out identically, and the second is
/// how the interfaces in this library are declared - so the first field is
/// followed down until it stops being a struct.
fn beginsWithIUnknown(comptime VTable: type) bool {
    const fields = @typeInfo(VTable).@"struct".fields;
    if (fields.len == 0) return false;
    if (@typeInfo(fields[0].type) == .@"struct") return beginsWithIUnknown(fields[0].type);
    if (fields.len < 3) return false;
    return std.mem.eql(u8, fields[0].name, "QueryInterface") and
        std.mem.eql(u8, fields[1].name, "AddRef") and
        std.mem.eql(u8, fields[2].name, "Release");
}

// -------------------------------------------------------------------------
// Tests
//
// Against a COM object written here in Zig. It is a real one - the same
// layout, the same calling convention, the same counting rules - so the
// machinery above is exercised for real, on any machine, with no graphics
// driver anywhere near it.
// -------------------------------------------------------------------------

const IFake = extern struct {
    vtable: *const VTable,

    pub const iid = Guid.parseComptime("{7F1E42A0-4C3B-4E10-9A62-0B1D5E77C401}");

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IFake, *const Guid, *?*anyopaque) callconv(.winapi) Hresult,
        AddRef: *const fn (*IFake) callconv(.winapi) u32,
        Release: *const fn (*IFake) callconv(.winapi) u32,
        Answer: *const fn (*IFake) callconv(.winapi) u32,
    };
};

/// An interface this object does not implement, for the other half of
/// `QueryInterface`.
const IAbsent = extern struct {
    vtable: *const IFake.VTable,
    pub const iid = Guid.parseComptime("{7F1E42A0-4C3B-4E10-9A62-0B1D5E77C402}");
};

/// One derived from `IFake` the way every interface in this library is: the
/// base vtable as the first field, its own slots after it.
const IFakeMore = extern struct {
    vtable: *const VTable,

    pub const iid = Guid.parseComptime("{7F1E42A0-4C3B-4E10-9A62-0B1D5E77C403}");

    pub const VTable = extern struct {
        base: IFake.VTable,
        Twice: *const fn (*IFakeMore) callconv(.winapi) u32,
    };
};

const Fake = struct {
    interface: IFake,
    refs: u32 = 1,
    queries: u32 = 0,

    const vtable: IFake.VTable = .{
        .QueryInterface = queryInterfaceImpl,
        .AddRef = addRefImpl,
        .Release = releaseImpl,
        .Answer = answerImpl,
    };

    fn init() Fake {
        return .{ .interface = .{ .vtable = &vtable } };
    }

    fn of(interface: *IFake) *Fake {
        return @fieldParentPtr("interface", interface);
    }

    fn addRefImpl(interface: *IFake) callconv(.winapi) u32 {
        const self = of(interface);
        self.refs += 1;
        return self.refs;
    }

    fn releaseImpl(interface: *IFake) callconv(.winapi) u32 {
        const self = of(interface);
        self.refs -= 1;
        return self.refs;
    }

    fn queryInterfaceImpl(
        interface: *IFake,
        iid: *const Guid,
        out: *?*anyopaque,
    ) callconv(.winapi) Hresult {
        const self = of(interface);
        self.queries += 1;
        if (iid.eql(IFake.iid) or iid.eql(IUnknown.iid)) {
            // A successful QueryInterface takes a reference, exactly as if the
            // caller had asked for one.
            self.refs += 1;
            out.* = interface;
            return .s_ok;
        }
        out.* = null;
        return .e_nointerface;
    }

    fn answerImpl(_: *IFake) callconv(.winapi) u32 {
        return 42;
    }
};

/// The same object one interface further down the chain.
const FakeMore = struct {
    interface: IFakeMore,
    refs: u32 = 1,

    const vtable: IFakeMore.VTable = .{
        .base = .{
            .QueryInterface = queryInterfaceImpl,
            .AddRef = addRefImpl,
            .Release = releaseImpl,
            .Answer = answerImpl,
        },
        .Twice = twiceImpl,
    };

    fn init() FakeMore {
        return .{ .interface = .{ .vtable = &vtable } };
    }

    /// The inherited slots are typed against the base interface, so they take
    /// a `*IFake` and cast back down - which is sound for the same reason
    /// `unknown` is.
    fn of(interface: *IFake) *FakeMore {
        const derived: *IFakeMore = @ptrCast(interface);
        return @fieldParentPtr("interface", derived);
    }

    fn addRefImpl(interface: *IFake) callconv(.winapi) u32 {
        const self = of(interface);
        self.refs += 1;
        return self.refs;
    }

    fn releaseImpl(interface: *IFake) callconv(.winapi) u32 {
        const self = of(interface);
        self.refs -= 1;
        return self.refs;
    }

    fn queryInterfaceImpl(
        interface: *IFake,
        iid: *const Guid,
        out: *?*anyopaque,
    ) callconv(.winapi) Hresult {
        const self = of(interface);
        if (iid.eql(IFakeMore.iid) or iid.eql(IFake.iid) or iid.eql(IUnknown.iid)) {
            self.refs += 1;
            out.* = interface;
            return .s_ok;
        }
        out.* = null;
        return .e_nointerface;
    }

    fn answerImpl(_: *IFake) callconv(.winapi) u32 {
        return 42;
    }

    fn twiceImpl(_: *IFakeMore) callconv(.winapi) u32 {
        return 84;
    }
};

test "calling through the vtable" {
    var fake = Fake.init();
    const object = &fake.interface;
    try testing.expectEqual(@as(u32, 42), object.vtable.Answer(object));
}

test "counting" {
    var fake = Fake.init();
    const object = &fake.interface;
    try testing.expectEqual(@as(u32, 1), fake.refs);

    try testing.expectEqual(@as(u32, 2), addRef(object));
    try testing.expectEqual(@as(u32, 3), addRef(object));
    try testing.expectEqual(@as(u32, 2), release(object));
    try testing.expectEqual(@as(u32, 1), release(object));
    try testing.expectEqual(@as(u32, 0), release(object));
    try testing.expectEqual(@as(u32, 0), fake.refs);
}

test "any interface is an IUnknown" {
    var fake = Fake.init();
    const object = &fake.interface;

    // The cast reaches the same three functions, so counting through it moves
    // the same number.
    const base = unknown(object);
    try testing.expectEqual(@as(u32, 2), base.vtable.AddRef(base));
    try testing.expectEqual(@as(u32, 2), fake.refs);
    _ = release(object);
}

test "asking for another interface" {
    var fake = Fake.init();
    const object = &fake.interface;

    const same = try queryInterface(object, IFake);
    try testing.expectEqual(object, same);
    // The call took a reference on the caller's behalf, which is why the
    // result needs its own release even though it is the same pointer.
    try testing.expectEqual(@as(u32, 2), fake.refs);
    try testing.expectEqual(@as(u32, 1), release(same));

    // IUnknown as well, since every object implements it.
    const base = try queryInterface(object, IUnknown);
    try testing.expectEqual(@as(u32, 1), release(base));
    try testing.expectEqual(@as(u32, 2), fake.queries);
}

test "an interface the object does not implement" {
    var fake = Fake.init();
    const object = &fake.interface;

    // Not a fault: this is how a program finds out what a version of DXGI can
    // do. Nothing was taken, so nothing has to be given back.
    try testing.expectError(error.NoInterface, queryInterface(object, IAbsent));
    try testing.expectEqual(@as(u32, 1), fake.refs);

    try testing.expect(implements(object, IFake));
    try testing.expect(!implements(object, IAbsent));
    // `implements` gives back what it took.
    try testing.expectEqual(@as(u32, 1), fake.refs);
}

test "releasing several at once" {
    var first = Fake.init();
    var second = Fake.init();
    releaseAll(.{ &first.interface, &second.interface });
    try testing.expectEqual(@as(u32, 0), first.refs);
    try testing.expectEqual(@as(u32, 0), second.refs);
}

test "what a creation call hands back" {
    var fake = Fake.init();

    const object = try received(IFake, .s_ok, &fake.interface);
    try testing.expectEqual(&fake.interface, object);

    // A failure is a failure whatever is in the slot.
    try testing.expectError(
        error.NoInterface,
        received(IFake, .e_nointerface, &fake.interface),
    );
    // And a success with nothing written is caught here rather than at the
    // next call.
    try testing.expectError(error.NullPointer, received(IFake, .s_ok, null));
    // S_FALSE is a success, so it does hand the pointer back.
    _ = try received(IFake, .s_false, &fake.interface);
}

test "a derived interface is its base" {
    var fake = FakeMore.init();
    const object = &fake.interface;

    // Its own slot, and its base's, reached through the one pointer.
    try testing.expectEqual(@as(u32, 84), object.vtable.Twice(object));
    try testing.expectEqual(@as(u32, 42), object.vtable.base.Answer(@ptrCast(object)));

    // And IUnknown's, which is three levels of nesting down and still at the
    // front of the table.
    try testing.expectEqual(@as(u32, 2), addRef(object));
    try testing.expectEqual(@as(u32, 1), release(object));

    // The base interface is a cast away, and counts on the same object.
    const base = try queryInterface(object, IFake);
    try testing.expectEqual(@as(u32, 2), fake.refs);
    try testing.expectEqual(@as(u32, 42), base.vtable.Answer(base));
    try testing.expectEqual(@as(u32, 1), release(base));

    try testing.expect(!implements(object, IAbsent));
}

test "the identifier a call is given is the interface's own" {
    try testing.expect(iidOf(IFake).eql(IFake.iid));
    try testing.expect(iidOf(IUnknown).eql(
        Guid.parseComptime("{00000000-0000-0000-C000-000000000046}"),
    ));
}
