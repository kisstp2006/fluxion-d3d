# Fluxion D3D

Direct3D 11 and 12, loaded at run time rather than linked. For Zig 0.16.

| Module | What it is |
| --- | --- |
| `dll` | Opening a system DLL from `System32` and nowhere else, and binding a whole struct of entry points in one call. [Fluxion Dyn](https://github.com/kisstp2006/fluxion-dyn) under a Direct3D-facing name. |
| `guid` | The 128-bit name COM gives an interface, parsed at compile time so a typo is a compile error, with both byte layouts named. |
| `hresult` | The number every COM call returns: severity, facility and code, a Zig error for the ones worth acting on, and the SDK name for the log line. |
| `com` | Calling through a vtable, the reference counting that goes with it, and a compile-time check that an interface is shaped like one. |
| `level` | Feature levels: the ladder Direct3D 11 and 12 share, ordered, named, and the descending list a create call wants. |
| `dxgi` | `dxgi.dll`: the factory, the adapters it lists, what each one is, and whether this machine can present without tearing. |
| `d3d11` | `d3d11.dll`: device and immediate context, the feature level actually granted, and a driver argument that cannot be got wrong. |
| `d3d12` | `d3d12.dll`: device creation, what it supports asked without creating one, the command queue, and the debug layer. |
| `compiler` | `d3dcompiler_47.dll`: HLSL in, bytecode out, with the compiler's message kept alongside the result rather than thrown away. |

The four DLLs share one shape, so moving between them is a change of name and
nothing else:

| Call | What it does |
| --- | --- |
| `load` / `unload` | Open the DLL and resolve its entry points. |
| `entries` | The entry points, with the ones that are not on every Windows as optionals. |
| `library` | The module itself, for a symbol this library did not think to bind. |
| `createDevice` / `createFactory` | The thing the DLL exists to make. |
| `highestLevel` / `highestSupported` | What it would grant, asked without making anything. |

Direct3D is not a library you link against. `d3d12.dll` is missing before
Windows 10, `CreateDXGIFactory2` before 8.1, `d3dcompiler_47.dll` on a
stripped-down server install, and a program that imports those the ordinary way
does not start at all where one is short — the loader fails before `main`, with
no way to fall back. So everything here is fetched by name, and a missing entry
point is a decision rather than a crash.

Nothing here allocates, and nothing here draws: it stops at a device, a queue
and an honest answer about what the machine will do. The examples go further,
and say what that costs — see [Examples](#examples).

## Install

```bash
zig fetch --save git+https://github.com/kisstp2006/fluxion-d3d
```

Or, for a checkout next to your project, add to `build.zig.zon`:

```zig
.dependencies = .{
    .fluxion_d3d = .{ .path = "../fluxion-d3d" },
},
```

Either way, wire it up in `build.zig`:

```zig
const fluxion = b.dependency("fluxion_d3d", .{
    .target = target,
    .optimize = optimize,
});
exe_mod.addImport("fluxion_d3d", fluxion.module("fluxion_d3d"));
```

```zig
const d3d = @import("fluxion_d3d");
```

One dependency comes with it, fetched the same way and needing nothing from
you: [Fluxion Dyn](https://github.com/kisstp2006/fluxion-dyn), which is where
`dll` gets its library opening and entry point binding from.

## The short version

One call opens all three DLLs, asks each what it can do, and closes them again.
No device is created and nothing is left behind, so it is cheap enough to run
at startup and print into a log:

```zig
std.debug.print("{f}\n", .{d3d.detect()});
```

```
dxgi          yes, 3 adapters (2 hardware)
tearing       yes
direct3d 11   12_1
direct3d 12   12_1  (warp 12_1)
debug layer   installed
hlsl compiler installed
```

`zig build example` prints exactly this, then lists the adapters and makes a
device on each API.

## Tour

### dll

`openSystem` loads a DLL by name from `System32` and from nowhere else:

```zig
var library = try d3d.Library.openSystem("d3d12.dll");
defer library.close();
```

That is not fussiness. `LoadLibrary("d3d12.dll")` searches the program's own
directory first, so anyone who can write a file next to the executable can have
their `d3d12.dll` loaded with the process's privileges. The fix is one flag,
`LOAD_LIBRARY_SEARCH_SYSTEM32`, which `openSystem` always passes — and it
refuses a name with a path in it.

`bind` resolves a whole table at once. The struct is both the declaration and
the list of what to fetch, so there is no second list to fall out of step with
the first:

```zig
const Entries = struct {
    D3D12CreateDevice: *const fn (...) callconv(.winapi) d3d.Hresult,
    // Missing on any machine without the Graphics Tools feature, so bound as
    // an optional and simply null there.
    D3D12GetDebugInterface: ?*const fn (...) callconv(.winapi) d3d.Hresult = null,
};

const entries = try library.bind(Entries);
```

A required entry that is not there is `error.SymbolNotFound`, and
`library.firstMissing(Entries)` names it — because "kernel32.dll has no
`ThisWasNeverAnExport`" is worth printing and `SymbolNotFound` is not.

### guid

A GUID is four fields, not sixteen bytes, because that is what the C `GUID` is:
three integers and eight loose bytes. Storing it that way makes the struct right
on any machine, and it forces the byte order — the part everyone gets wrong — to
be asked for:

```zig
const iid = d3d.iid("{189819F1-1DB6-4B57-BE54-1821339B85F7}");

iid.toBytes(.uuid);   // 18 98 19 F1 ...  the text, read left to right
iid.toBytes(.guid);   // F1 19 98 18 ...  the first three fields turned round
```

The same identifier has both forms in the wild, and reading one as the other
parses cleanly and names a different interface. `parseComptime` — which is what
`d3d.iid` is — reads the literal at compile time, so a mistyped IID is a compile
error rather than `E_NOINTERFACE` and an afternoon.

### hresult

An `HRESULT` is not an error code with a list of values. It is three fields in
an `i32`: one bit for failure, thirteen naming the component, sixteen that mean
whatever that component wanted:

```zig
const hr = d3d.Hresult.dxgi_error_device_removed;

hr.failed();              // true
hr.parts().facility;      // .dxgi
hr.parts().code;          // 5
hr.name().?;              // "DXGI_ERROR_DEVICE_REMOVED"
try hr.check();           // error.DeviceRemoved
```

Two things the sign bit is worth stating plainly. Success is not one value:
`S_OK` is zero and `S_FALSE` is one, and a call that answers a question rather
than doing work returns the second one routinely — which is exactly how
`D3D12CreateDevice` says "yes, this adapter would work". Testing `hr == .s_ok`
turns that into a failure; test `hr.failed()`. And failure is not one value
either, so `check` maps the ones a caller can act on differently and calls the
rest `error.Unexpected`, leaving the number printable for the line that follows.

### com

A COM object is a pointer to a pointer to a table of functions, and every one of
those functions takes the object as its first argument. Inheritance is not a
language feature, it is a layout rule: a derived interface repeats every slot of
its base before adding its own. Rather than copy those slots and hope the copies
stay in step, each vtable here holds its base as its first field, which lays out
identically and says out loud where a method came from:

```zig
pub const VTable = extern struct {
    base: IDXGIFactory.VTable,   // and that one begins with IDXGIObject's
    EnumAdapters1: *const fn (...) callconv(.winapi) d3d.Hresult,
    IsCurrent: *const fn (*IDXGIFactory1) callconv(.winapi) c_int,
};
```

Every object holds a reference count, and getting one from anywhere — a create
call, `queryInterface`, an enumerator — raises it and hands the obligation over:

```zig
const factory6 = try d3d.com.queryInterface(factory, d3d.dxgi.IDXGIFactory6);
defer _ = d3d.release(factory6);
```

`error.NoInterface` from that is not a fault. It is how a program finds out which
Windows it is on.

### level

A feature level is a fixed bundle of capabilities that hardware either meets in
full or does not meet at all. Both APIs run over the same ladder, which is why
`12_0` appears in each and why `d3d11.dll` still gives a device on a card from
2010:

```zig
d3d.FeatureLevel.@"12_1".atLeast(.@"11_0");   // true
d3d.FeatureLevel.@"10_1".supportsD3d12();     // false — 11_0 is the floor
d3d.FeatureLevel.range(.@"12_1", .@"11_0");   // { 12_1, 12_0, 11_1, 11_0 }
```

`range` exists because `D3D11CreateDevice` tries a list in the order given and
does not sort it, so a list that starts at `11_0` gets `11_0` on a card that
could have done `12_1`. And because a level the installed runtime has never
heard of is `E_INVALIDARG` for the whole call rather than an entry that gets
skipped — which is why the fallback after that error is a shorter list.

### dxgi

DXGI is the part of the stack with nothing to do with drawing: which adapters
exist, which monitors hang off them, how a back buffer reaches the screen.
Finding out what a machine can do starts here.

```zig
var dxgi = try d3d.Dxgi.load();
defer dxgi.unload();

const factory = try dxgi.createFactory(d3d.dxgi.IDXGIFactory1, .{});
defer _ = d3d.release(factory);

var walk = d3d.dxgi.adapters(factory);
while (try walk.next()) |adapter| {
    defer _ = d3d.release(adapter);
    const description = try d3d.dxgi.describe(adapter);
    std.debug.print("{f}\n", .{&description});
}
```

```
Intel(R) Iris(R) Xe Graphics [intel 9A49] 128 MiB
NVIDIA T500 [nvidia 1FBB] 3946 MiB
Microsoft Basic Render Driver [microsoft 008C] (software)
```

`IDXGIFactory1` is the floor — it has been in every Windows since 7 — and
everything newer is reached by asking. `warpAdapter` needs `IDXGIFactory4`, so
Windows 10; `allowsTearing` needs `IDXGIFactory5`; and picking the discrete card
by name rather than by guessing from memory sizes needs `IDXGIFactory6`:

```zig
const discrete = try d3d.dxgi.adapterByPreference(factory, 0, .high_performance);
```

### d3d11

```zig
var d3d11 = try d3d.D3d11.load();
defer d3d11.unload();

var device = try d3d11.createDevice(.{});
defer device.release();
// device.level is what the hardware granted, which is at best the first
// entry of the list that was asked for.
```

`D3D11CreateDevice` takes both an adapter and a driver type, and the two are not
independent: naming an adapter means the driver type has to be `UNKNOWN`, and
getting that wrong is `E_INVALIDARG` with nothing to say why. `Driver` is a
union rather than an enum beside a pointer, so the combination cannot be
written down:

```zig
_ = try d3d11.createDevice(.{ .driver = .warp });
_ = try d3d11.createDevice(.{ .driver = .{ .adapter = @ptrCast(adapter) } });
```

`flags.debug` needs the D3D11 SDK layers, which are an optional Windows feature
and are not on an ordinary machine. Without them the call fails, and the usual
answer is to ask again without the flag:

```zig
var device = d3d11.createDevice(.{ .flags = .{ .debug = true } }) catch |err| switch (err) {
    error.SdkComponentMissing => try d3d11.createDevice(.{}),
    else => return err,
};
```

`highestLevel` is the same negotiation with no output pointers, so it costs a
fraction of a real create and leaves nothing to release. Null is a real answer:
this machine has no hardware Direct3D 11 device to give.

### d3d12

Direct3D 12 gives back the bookkeeping the 11 runtime did on the program's
behalf. None of that is a loader's business — but the DLL is not on every
Windows, the device may refuse an adapter that 11 was happy with, and the debug
layer lives behind an optional feature:

```zig
var d3d12 = try d3d.D3d12.load();   // error.LibraryNotFound before Windows 10
defer d3d12.unload();

// Answers the question and creates nothing.
d3d12.supports(adapter, .@"11_0");
d3d12.highestSupported(adapter);    // the ceiling, same query asked downwards

const device = try d3d12.createDevice(.{ .adapter = adapter });
defer _ = d3d.release(device);

const queue = try d3d.d3d12.createCommandQueue(device, .{});
defer _ = d3d.release(queue);
```

Several Direct3D 12 methods return a small struct by value, and how that is
passed differs between the compiler Microsoft built the runtime with and
everyone else. It is the oldest bug in third-party bindings: the call appears to
work and the returned handle is rubbish. Every such slot here is left
deliberately undeclared, with a note saying so, so reaching one means declaring
it yourself with the ABI checked rather than by accident.

### compiler

Shaders should be compiled when a program is built, and for anything shipping
they should be — compiling is slow, and a syntax error found at run time is
found by a customer. But the compiler is a DLL with the same problem as the
rest of Direct3D: present on a stock Windows 10 or 11, absent on a stripped-down
server install.

```zig
var hlsl = try d3d.Compiler.load();
defer hlsl.unload();

var output = hlsl.compile(source, .{ .target = "vs_5_0", .name = "sky.vs.hlsl" });
defer output.release();

const code = output.check() catch {
    std.debug.print("{s}\n", .{output.text()});
    return error.ShaderFailed;
};
```

```
sky.vs.hlsl(2,16-23): error X3004: undeclared identifier 'nonesuch'
```

`compile` does not fail. Everything the compiler said comes back in the
`Output` — the bytecode, the messages, and the number the call returned — and
it is `check` that turns a failure into a Zig error. A compiler that says only
"failed" is not much of a compiler: the line number and the reason are the
whole value, and they arrive on a successful compile too, as warnings.

The optimisation levels are an enum rather than a number, because their two
bits are famously not in order: level 1 is zero, level 0 is the low bit, level
3 is the high bit and level 2 is both.

## Examples

Each has a step of its own. The two with windows in them open one and keep it
until it is closed — escape or the close button — and they take
`-- --frames N` to stop after a fixed count instead, or `-- --capture out.png`
to skip the window altogether and write one frame to a file:

```bash
zig build example-cube3d                              # a window, until you close it
zig build example-cube3d -- --capture cube3d.png      # no window, one PNG
```

`--capture` is the same drawing into a texture instead of a swap chain, so it
works on a machine with no display at all.

`zig build examples` runs all six in turn and has to finish on its own, so it
runs those two in `--capture` mode: it writes `zig-out/scene2d.png` and
`zig-out/cube3d.png` rather than flashing a window for three seconds and
taking it away again.

| Example | What it shows |
| --- | --- |
| `zig build example` | The tour: load all four DLLs, list the adapters, make a device on each API. |
| `zig build example-adapters` | Every adapter, its memory and LUID, and what each runtime would grant on it — asked without creating anything. |
| `zig build example-entrypoints` | Which entry points and which DXGI interface versions this particular Windows has. |
| `zig build example-shaders` | HLSL compiled at run time, disassembled, and one that does not compile. No device and no window. |
| `zig build example-scene2d` | 2D: six coloured boxes bouncing in a window. One quad, six draws, no depth buffer and no matrix. |
| `zig build example-cube3d` | 3D: a lit cube turning, with a depth buffer, a perspective projection and a normal per face. |

The last two need more of Direct3D 11 than the library has: it stops at a
device, and drawing needs the slots it leaves opaque. `examples/render11.zig`
is those, declared once — and it is the documented way out rather than a
workaround. It has to reach for the device's vtable only for the type:

```zig
const create = slot(*const fn (...) callconv(.winapi) Hresult, device.vtable.CreateBuffer);
```

The name and the index come from the loader, which already gets them right;
what the example adds is a signature. `examples/window.zig` is the Win32 a swap
chain needs, and nothing more, and `examples/capture.zig` writes a frame out as
a PNG.

All three carry tests, and `zig build test` runs them, because a vtable slot
nothing has called is a guess: they draw a triangle into a texture and read the
pixels back. The two drawing examples do the same — the cube renders a frame
offscreen and checks that its middle is the cube, its corners are the
background, and at least three faces are visible, which is the only way to be
sure the winding, the projection and the depth test all agree.

One of those tests exists because of a bug it found. A view bound to the output
stage keeps the resource behind it alive however many times the view itself is
released, so a swap chain whose back buffer was still bound could not give its
buffers back: `ResizeBuffers` refuses, and a flip-model swap chain can sit at
process exit waiting for a compositor that will never get them. The fix is two
calls — `ClearState` then `Flush` — before letting go, and the test opens a real
window, resizes it, and draws again.

## Everything together

```zig
// The software rasteriser, so this runs on a machine with no graphics card.
const warp = try d3d.dxgi.warpAdapter(factory);
defer _ = d3d.release(warp);

// Direct3D 11 on it.
var device11 = try d3d11.createDevice(.{ .driver = .{ .adapter = @ptrCast(warp) } });
defer device11.release();

// And Direct3D 12 on the same adapter at the same time, which is allowed:
// the two runtimes are independent.
const device12 = try d3d12.createDevice(.{ .adapter = @ptrCast(warp) });
defer _ = d3d.release(device12);

const level12 = try d3d.d3d12.highestLevel(device12);
const model = try d3d.d3d12.highestShaderModel(device12);
```

## Build

```bash
zig build test        # run the test suite, examples included
zig build example     # build and run the demo tour
zig build examples    # build and run every example in turn
zig build docs        # generate API documentation into zig-out/docs
```

The tests make real devices and draw real pictures. They use WARP wherever they
can, because WARP is part of Windows and needs no graphics card, so a build
server gets the same coverage as a workstation: `dll` is exercised against
`kernel32.dll`, which is loaded in every process there has ever been; `com` is
exercised against a COM object written in Zig, with the same layout and the
same counting rules, so the vtable machinery is tested with no driver anywhere
near it; `compiler` compiles a shader and reads back the error from one that
does not compile; and `dxgi`, `d3d11` and `d3d12` load their DLLs, enumerate,
create and release for real.

A machine that is missing a DLL skips those tests rather than pretending. Every
interface identifier in the library is checked by the runtime accepting it, and
every vtable slot the examples call is checked by rendering into a texture and
looking at the pixels that come out.

## Requirements

Zig 0.16.0, and a Windows target. Cross-compiling to one from anywhere is fine —
`-Dtarget=x86_64-windows` — and the `guid`, `hresult` and `level` modules have
no Windows in them and can be imported on their own.

## License


`SPDX-License-Identifier: BSL-1.0`

[Boost Software License 1.0](LICENSE) - permissive, and short enough to read
in a minute: use it, change it, ship it, in anything. The one obligation is
that the copyright notice and the licence text travel with the *source*; a
binary built from it carries nothing, which is the difference from MIT and
BSD and the reason this is the usual choice for a library that ends up
compiled into somebody else's program.

Fluxion libraries are licensed by layer: the foundation is CC0, the engine
infrastructure this one belongs to is BSL-1.0, and what builds on top of it
is BSD.
