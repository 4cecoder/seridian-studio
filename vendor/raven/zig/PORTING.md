# Porting Raven from C11 to Zig (strangler style)

This is the only reference a translator needs. Read it completely once, then keep sections 2, 4 and 6 open.

Toolchain: **Zig 0.18.0-dev.738 (nightly)**. Your memory of Zig is probably from an older version. Where this
file and your memory disagree, this file is right: every ```` ```zig ```` snippet below is compiled (and, where it says
`run`, executed) by `zig/tools/verify_porting.py` on this exact toolchain. When something does not compile, read
section 8 (error messages) before guessing.

## 1. The idea

Raven is a C11 UI toolkit (`vendor/raven/src`, about 60k lines of C plus headers). We replace it **one C file at a time**
by a Zig file that exports **exactly the same symbols** (same names, same C ABI). C and Zig link together into one
`libraven.a`, so after each file is ported, Raven's own C test suite (`vendor/raven/tests`) still tests the whole
library. Nothing is redesigned: **a translation is a 1:1 rewrite of the C file in Zig**.

- `vendor/raven/zig/ported.txt` lists the C sources that are replaced by Zig. CMake drops them from the library and
  links one object, `raven_zig.o`, built from `zig/src/root.zig` (generated; it imports each ported file).
  An empty list is the pure C build. **Translators do not edit `ported.txt`**: the integrator adds a file after
  `check.sh` passes.
- There is no `@cImport` in Zig 0.18. C and OS APIs are declared by hand with `extern` (section 4.12, 4.17, 5).
- Public API types are already translated: `@import("raven")` (section 3).
- You translate **one file** (or one header), and you may create only that file.

### 1.1 Files and names

| C file | Zig file | exports |
|---|---|---|
| `src/<module>/<name>.c` | `zig/src/<module>/<name>.zig` | every non-`static` function and variable of the C file, nothing else |
| `src/<module>/<name>.m` (Objective-C) | `zig/src/<module>/<name>.zig` | same |
| `src/<module>/<name>.h` (private header) | `zig/src/<module>/<name>_h.zig` ("header unit") | nothing: types, constants, inline functions, `pub extern` declarations |
| `include/raven/*.h` (public) | `zig/src/raven/raven.zig` (generated, done) | nothing |

`_h` is added to header units because `heap.c` and `heap.h` would both become `heap.zig`. Example: `src/core/base.h` is
`zig/src/core/base_h.zig` (done, use it as the model of a header unit), `src/core/utf8.c` is `zig/src/core/utf8.zig`
(a finished example is `zig/examples/utf8.zig`).

**Header units are how the files talk to each other.** A C header declares `int rvn_utf8_count(const char*, int);`.
Its header unit contains `pub extern fn rvn_utf8_count(text: [*c]const u8, length: c_int) c_int;`, and any Zig file
calls it as `base.rvn_utf8_count(...)` after `const base = @import("base_h.zig");`. The same symbol is defined by C
(before the port) or by `export fn rvn_utf8_count` in `utf8.zig` (after the port); the call does not care. Verified:
an `extern fn` and an `export fn` of the same name can sit in the same Zig compilation. **Never import another
translated `.c` unit** (no `@import("utf8.zig")` from `button.zig`): always go through the header unit. This keeps
every file checkable alone, and the C/Zig mix working at every step.

A header unit also holds the struct definitions of the header (as `extern struct`, same field order and types),
`#define` constants (`pub const NAME = value;`), enum values (`pub const NAME: c_int = n;`), function-like macros
(`pub inline fn`), and `static inline` functions (`pub inline fn`). Global variables declared `extern T name;` become
`pub extern var name: T;`; the `.zig` that defines it has `export var name: T = std.mem.zeroes(T);`.
If a header unit you need does not exist yet, **stop and report it**; do not write it inside your file.

### 1.2 The first lines of every file you write

```text
// Translated to Zig from vendor/raven/src/<path> (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// <the original file header comment of the C file, kept>
```

(for a header unit: `.../src/<path>.h`). Use exactly that first line, with the real path.

### 1.3 Where your imports come from

| you write | gives you |
|---|---|
| `const raven = @import("raven");` | public API: `raven.Rid`, `raven.REvent`, `raven.R_TRUE`, `raven.Rwindow_create(...)`... |
| `const config = @import("raven_config");` | build options as comptime booleans: `config.platform_cocoa`, `platform_x11`, `platform_win32`, `platform_null`, `backend_vulkan`, `with_stb_image`, `build_web`, `paid` |
| `const base = @import("base_h.zig");` | the header unit `core/base_h.zig` (same folder). From another folder: `@import("../core/base_h.zig")` |
| `const libc = @import("../sys/libc.zig");` | hand-declared libc functions (`strlen`, `snprintf`, `qsort`, `pthread_*`, `dlopen`...). The path is relative to your file: `../sys/libc.zig` from `src/core`, `../../sys/libc.zig` from `src/render/vulkan` |
| `const vk = @import("vulkan_h.zig");` | Vulkan types, enums, `PFN_vk*` (only inside `src/render/vulkan`) |
| `const std = @import("std");` | `std.mem.zeroes`, `std.builtin.VaList`, `std.c` types, `std.atomic`, `std.math` constants; **not** `std.heap`, `std.fmt`, `std.Io`, `std.debug.print` in library code |

Rule: **import aliases are lowercase nouns that cannot clash with C variable names** (`base`, `raven`, `libc`, `config`,
`vk`, `heap_h`, `ctx_h`). Zig forbids shadowing: a local variable or parameter named `base` would be an error
(`local constant shadows declaration`). If it happens, rename the local (`base_`), never the alias.

### 1.4 What already exists (do not translate these; import them)

| file | what |
|---|---|
| `src/raven/raven.zig` | the public API (`include/raven/*.h`): every type, enum constant, callback type, `pub extern fn` of the public functions, and the macros. Generated by `tools/gen_public_types.py`; its layout is checked against C by `layout/` on every `check.sh` |
| `src/core/base_h.zig` | `src/core/base.h`: math helpers, geometry (`rvn_rect_t`), colors, `rvn_text_t`, arena, `RVN_ARRAY_RESERVE`, declarations of memory / string / UTF-8 / error functions. The model of a header unit |
| `src/sys/libc.zig` | the C library and OS functions Raven calls |
| `src/resources/default_font.zig`, `mono_font.zig` | **already ported** (listed in `ported.txt`): the embedded fonts |
| `src/render/vulkan/generated/*_spv.zig` | the SPIR-V shader words as `pub const rvn_*_spv: [N]u32` (for `vk_pipeline.c` and `shader.c`) |
| `src/render/vulkan/vulkan_h.zig` | the Vulkan types / constants / `PFN_vk*` Raven uses |
| `examples/utf8.zig` | a complete finished translation (`src/core/utf8.c`, deliberately kept out of `src/`) |

Translation order: header units first (they depend only on each other and on `raven`), then the `.c` files in any order (each only
needs the header units). A header unit job: translate `src/<m>/<n>.h` to `src/<m>/<n>_h.zig` following `base_h.zig`; check with
`./check_unit.sh src/<m>/<n>_h.zig` (it must export nothing) and also for `x86_64-linux-gnu` / `x86_64-windows-gnu` when the header is
shared with that OS.

## 2. How you work (do these steps in this order)

All commands are run from `vendor/raven/zig` (the directory of this file).

1. **Read** the C file completely, and every private header it includes (`src/<module>/*.h`, `src/core/base.h`).
   Check the header units exist: `ls src/core/*_h.zig src/<module>/*_h.zig`. Missing one: stop and report.
2. **Baseline** (optional): `./translate.sh src/<module>/<name>.c` writes `_build/translate/<name>.body.zig`
   (the C file's own declarations as `zig translate-c` sees them) and `.raw.zig` (everything, with system headers:
   a place to look up struct layouts of libc and the OS). Not for Objective-C or Windows files. The body is **not**
   a translation: it keeps `[*c]` pointers, C integer promotions, `__helpers.cast`, `_ = &x;` noise. Rewrite it by
   section 4. Do not paste it as the result.
3. **Write** `src/<module>/<name>.zig` by the rules of section 3 and the patterns of section 4.
4. **Check the file alone**: `./check_unit.sh src/<module>/<name>.zig`. It compiles every `pub` declaration, then
   compares the symbols your object exports with the non-static functions and variables of the C file
   (none missing, none extra). For OS-specific code check the other OS too:
   `./check_unit.sh src/platform/x11/x11_keys.zig x86_64-linux-gnu`,
   `./check_unit.sh src/platform/win32/win32_uia.zig x86_64-windows-gnu`.
   Fix until it says `UNIT OK`.
5. **Check it in the library**: `./check.sh --tag <yourname> src/<module>/<name>.c`. This builds Raven with your file
   replacing its C file, and verifies symbols, public type layout, fonts, and the whole ctest suite (20 tests)
   against the pure C build. It must print `RESULT: PASS`. A `FAIL (ctest)` means a behaviour difference: re-read the C.
   Use a different `--tag` per concurrent worker (they build in `_build/check-<tag>`).
   Files for the other OS (`x11`, `win32`, `atspi`) are not part of the macOS build: they cannot run in step 5;
   `check_unit.sh` with the target is their check, plus a second reading of the C.
6. **Report** the path of your file and the result lines of steps 4 and 5. Do not edit `ported.txt`, `root.zig`,
   `check*.sh`, `PORTING.md`, `src/raven/raven.zig`, or any other translator's file. Do not run `git commit`.

If the C file looks wrong or surprising: translate it as it is (bug for bug). Write the doubt in your report.

## 3. Rules of a faithful translation

1. **1:1.** Same functions in the same order, same names (including `static` helpers, parameters and locals), same
   control flow, same constants. No refactoring, no "better" Zig, no new features, no error handling the C does not
   have, no renamed symbols. Keep every comment (`/* */` becomes `//`; `/** */` before a declaration becomes `///`).
2. **Same exports.** Non-`static` function: `export fn name(...)`. Non-`static` global variable: `export var name`.
   `static` function: plain `fn` (no `pub`, no `export`); `static inline`: `inline fn`. `static` global: plain `var`/`const`
   at file level. Nothing else is exported: an extra export is a failure of `check_unit.sh`.
3. **Same ABI.** Parameter and return types of an exported function must be the C types (table below), because C code
   still calls it. Copy the signature from the header unit, character for character. The compiler does NOT check an
   `export fn` against the `extern fn` of the header unit: a wrong type links fine and crashes later.
4. **Same layout.** Every struct shared with C code, or used through a pointer from C, is an `extern struct` with the
   same fields in the same order (section 4.1). Never `packed` or default-layout structs for those; enums are integers.
5. **Same arithmetic.** C promotes small integers to `int` and mixes signed and unsigned by its own rules; Zig does
   not (section 4.3, 4.4). Keep `float` as `f32` and `double` as `f64`. Unsigned arithmetic that may wrap in C
   (hashes, counters, random) uses `+%`, `-%`, `*%`. Signed overflow is undefined in C: in Zig it traps in the safe
   build (that is useful, the library is built `ReleaseSafe`): do not hide it with `+%`, report it.
6. **C library calls stay C library calls.** `strlen`, `snprintf`, `qsort`, `fopen`, `malloc` are called through
   `libc.zig` (or declared with `extern "c" fn`). Raven's own allocator (`base.rvn_alloc`, `rvn_free`, `rvn_array_grow_`)
   stays. No `std.heap`, no `std.ArrayList`, no `std.fmt`: the translation must behave like the C. `@memcpy`, `@memset`
   and the builtin math (`@sqrt`, `@floor`, `@ceil`, `@abs`, `@sin`, `@cos`) are fine for `memcpy`, `memset`,
   `sqrtf`, `floorf`, `ceilf`, `fabsf`, `sinf`, `cosf`; for `powf`, `fmodf`, `expf`, `atan2f`... call libm through `libc.zig`.
7. **Pointers are C pointers.** Parameters, fields and locals that hold a C data pointer are `[*c]T` (nullable, indexable,
   comparable, arithmetic, coerces to the other pointer kinds). `void*` is `?*anyopaque`; function pointers are
   `?*const fn (...) callconv(.c) R`. Details in 4.2.
8. **Initialization.** C globals and `static` variables are zero-initialized; Zig has no implicit zero: write
   `var g: T = std.mem.zeroes(T);` (`= undefined` is garbage, not zero). C local variables that are read before being
   written are bugs: `undefined`. `T x = {0};` is `var x = std.mem.zeroes(T);`.
9. **Platform code.** `#if defined(_WIN32)` / `__APPLE__` / `__linux__` in a mixed file becomes
   `if (builtin.os.tag == .windows)` etc. (comptime: the dead branch is not analysed, so it may use names that do not
   exist on this OS). `RAVEN_PLATFORM_*`, `RAVEN_BACKEND_VULKAN_ENABLED`, `RAVEN_WITH_STB_IMAGE`, `RAVEN_PAID` are
   `config.platform_x11`, `config.backend_vulkan`, `config.with_stb_image`, `config.paid`. Preprocessor macros that the
   C file defines itself (`#define RVN_HEAP_MMAP`) become file-level `const`s.
10. **Names.** Zig reserved words and primitive names cannot be identifiers: `type`, `error`, `align`, `fn`, `var`,
    `const`, `test`, `opaque`, `packed`, `export`, `extern`, `union`, `enum`, `struct`, `defer`, `resume`... and `i8`, `u32`,
    `f32`, `c_int`... A **struct field** keeps its C name, quoted: `@"type"`. A **local or parameter** gets a trailing
    underscore: `type_`. Never rename an exported function or a field of a shared struct.
11. **Unused things are errors in Zig.** An unused parameter needs `_ = name;`, an unused local is deleted, a `var` that is
    never reassigned must be `const`, and a call whose result is ignored needs `_ = f();`. Do not add `_ = &x;`.
12. **No `unreachable` to silence a problem, no `@panic`, no `catch unreachable`.** C has no such thing.
13. **Do not leave TODO stubs.** A function you cannot translate completely: stop and report which and why.

The C-to-Zig type table (these are what `zig translate-c` and `raven.zig` use):

| C | Zig | note |
|---|---|---|
| `int`, `unsigned`, `long`, `unsigned long`, `short`, `unsigned short` | `c_int`, `c_uint`, `c_long`, `c_ulong`, `c_short`, `c_ushort` | never `i32` for `int` (a mixed expression would stop compiling or change meaning) |
| `int8_t` ... `uint64_t` | `i8` ... `u64` | |
| `size_t`, `ssize_t`, `ptrdiff_t`, `uintptr_t`, `intptr_t` | `usize`, `isize`, `isize`, `usize`, `isize` | |
| `char` | `u8` for text; `c_char` if the sign matters | `[*c]const u8` is `const char*` |
| `unsigned char`, `signed char` | `u8`, `i8` | |
| `float`, `double` | `f32`, `f64` | |
| `bool` / `_Bool` | `bool` | Raven's "booleans" are `int` (`R_TRUE`/`R_FALSE`), keep `c_int` |
| `T*`, `const T*` | `[*c]T`, `[*c]const T` | |
| `void*`, `const void*` | `?*anyopaque`, `?*const anyopaque` | |
| `T**` | `[*c][*c]T` | |
| `char[N]` field | `[N]u8` | |
| `void (*cb)(int)` | `?*const fn (c_int) callconv(.c) void` | name the typedef as the header does |
| `enum E {A, B}` | `pub const E = c_uint;` and `pub const A: c_int = 0;` ... | what `raven.zig` does |
| `struct S` | `extern struct` | |
| `union U` | `extern union` | |
| `Rid`, `RColor`, `RWindow...` | `raven.Rid`, `raven.RColor`... | from `@import("raven")` |

## 4. Cheat sheet (every snippet compiled on 0.18.0-dev.738)

### 4.1 Structs, unions, defaults, zeroing

```zig
// check: run
const std = @import("std");
const expect = std.testing.expect;

// typedef struct rvn_rect_t { float x, y, w, h; } rvn_rect_t;
pub const rvn_rect_t = extern struct { x: f32, y: f32, w: f32, h: f32 };

// A struct with pointers and a callback. `[*c]` for data pointers, `?*const fn` for callbacks.
pub const Handler = extern struct {
    name: [*c]const u8,
    cb: ?*const fn (value: c_int, user: ?*anyopaque) callconv(.c) c_int,
    user: ?*anyopaque,
    next: [*c]Handler,
    slots: [4]u32,
};

// union + nested anonymous union/struct (C11): name the members, keep the order.
pub const Event = extern struct {
    kind: c_int,
    u: extern union {
        key: extern struct { code: c_int, mods: c_int },
        mouse: extern struct { x: f32, y: f32 },
    },
};

test "extern struct" {
    try expect(@sizeOf(rvn_rect_t) == 16 and @offsetOf(rvn_rect_t, "h") == 12);
    var h = std.mem.zeroes(Handler); // Handler h = {0};   or   memset(&h, 0, sizeof h);
    try expect(h.name == null and h.cb == null and h.next == null and h.slots[3] == 0);
    h.slots[1] = 7;
    const r: rvn_rect_t = .{ .x = 1, .y = 2, .w = 3, .h = 4 }; // (rvn_rect_t){1, 2, 3, 4}
    try expect(r.w == 3);
    var e = std.mem.zeroes(Event);
    e.u.key.code = 65;
    try expect(e.u.key.code == 65 and @sizeOf(Event) == 12);
    // sizeof(struct) in C is @sizeOf(T); sizeof(*p) is @sizeOf(T) too; offsetof is @offsetOf(T, "field")
}
```

C bitfields (`unsigned visible : 1;`) have no `extern struct` equivalent: keep the integer that holds them and use
masks, or (when the whole struct is bits and the size is exact) a `packed struct(uN)`. Bit order is the same
(first field is the least significant bit on little-endian). Check how the C compiler lays them out before choosing;
if unsure, report.

```zig
// check: run
const std = @import("std");
const expect = std.testing.expect;

// struct { unsigned visible : 1; unsigned enabled : 1; unsigned kind : 3; } flags;   (stored in one u8)
pub const Flags = packed struct(u8) {
    visible: bool = false,
    enabled: bool = false,
    kind: u3 = 0,
    _pad: u3 = 0,
};

// The same inside a larger extern struct: an integer and masks.
pub const Widget = extern struct { bits: u32, id: c_int };
pub const W_VISIBLE: u32 = 1 << 0;
pub const W_KIND_SHIFT = 1;
pub const W_KIND_MASK: u32 = 0x7 << W_KIND_SHIFT;

test "bits" {
    var f: Flags = .{};
    f.kind = 5;
    f.enabled = true;
    try expect(@as(u8, @bitCast(f)) == 0b0001_0110 and @sizeOf(Flags) == 1);
    var w = std.mem.zeroes(Widget);
    w.bits |= W_VISIBLE;
    w.bits = (w.bits & ~W_KIND_MASK) | (@as(u32, 5) << W_KIND_SHIFT);
    try expect((w.bits & W_KIND_MASK) >> W_KIND_SHIFT == 5);
}
```

### 4.2 Pointers

`[*c]T` behaves like a C pointer. Use it for every C data pointer: it can be `null`, indexed, advanced, compared, subtracted,
and it converts implicitly to `?*T`, `[*]T` and from them. A string literal converts to `[*c]const u8`.
`[*]T` (many-item pointer) cannot be compared with `<`/`>=` and `?*T` cannot be indexed: avoid them in translated bodies.

```zig
// check: run
const std = @import("std");
const expect = std.testing.expect;

fn cstrlen(p: [*c]const u8) usize { // size_t strlen(const char* p)
    var n: usize = 0;
    while (p[n] != 0) n += 1;
    return n;
}

pub const Node = extern struct { next: [*c]Node, v: c_int };

test "c pointers" {
    try expect(cstrlen("hello") == 5); // string literal -> [*c]const u8
    var buf: [8]u8 = undefined;
    buf[0] = 'a';
    buf[1] = 0;
    const p: [*c]u8 = &buf; // array -> pointer
    var q: [*c]u8 = p;
    q += 1; // q++
    try expect(q[0] == 0 and q > p and p != null); // q > p is legal on [*c]
    try expect(q - p == 1); // pointer difference (ptrdiff_t)
    const np: [*c]u8 = null;
    try expect(np == null); // if (!np)
    q = p + 1; // p + 1
    try expect(q.* == 0 and (q - 1).* == 'a'); // *q   and   *(q - 1)
    try expect(&q[0] == q); // &q[0]
}

test "casts between pointer types" {
    var storage: [16]u8 align(8) = undefined;
    const raw: ?*anyopaque = &storage; // void* raw = storage;
    const n: [*c]Node = @ptrCast(@alignCast(raw)); // (Node*)raw : alignment is checked in safe builds
    n.*.next = null; // n->next = NULL;
    n[0].v = 4; // n->v = 4;
    try expect(n.*.v == 4 and n.*.next == null);
    const bytes: [*c]u8 = @ptrCast(n); // (unsigned char*)n
    try expect(bytes[0] == 0 or true);
    const cp: [*c]const Node = n; // adding const is implicit; removing it needs @constCast
    const back: [*c]Node = @constCast(cp); // (Node*)cp
    try expect(back == n);
    const addr: usize = @intFromPtr(n); // (uintptr_t)n
    const again: [*c]Node = @ptrFromInt(addr); // (Node*)addr
    try expect(again == n);
}
```

Pointer-to-pointer out parameters (`const char** text`) are `[*c][*c]const u8`; writing through them is `text.* = s;`.
Taking the address of a local (`&x`) gives `*T`, which converts to `[*c]T` by itself.
`container_of`-style math is `@ptrFromInt(@intFromPtr(p) - @offsetOf(T, "field"))`.

### 4.3 Integers, casts, wrapping

Casts are explicit and each has one meaning: `@intCast` (value must fit, checked), `@truncate` (keep the low bits,
like a C narrowing cast), `@bitCast` (same bits, e.g. `int` to `unsigned`), `@intFromFloat`, `@floatFromInt`,
`@floatCast`, `@as(T, v)` (widening or comptime constants).

```zig
// check: run
const std = @import("std");
const expect = std.testing.expect;

test "casts" {
    const a: c_int = -1;
    const u: c_uint = @bitCast(a); // (unsigned)a
    try expect(u == 0xFFFFFFFF);
    const lo: u8 = @truncate(@as(u32, 0x1234)); // (uint8_t)0x1234
    try expect(lo == 0x34);
    const n: usize = 5;
    const i: c_int = @intCast(n); // (int)n   (traps if it does not fit)
    try expect(i == 5);
    const f: f32 = 3.7;
    const t: c_int = @intFromFloat(f); // (int)f : truncates toward zero
    try expect(t == 3);
    const back: f32 = @floatFromInt(t); // (float)t
    try expect(back == 3.0);
    const d: f64 = @floatCast(f); // (double)f
    const g: f32 = @floatCast(d); // (float)d
    try expect(g == f);
    const c: u8 = 200;
    const wide: c_int = c; // implicit widening is allowed when it cannot lose a value
    try expect(wide == 200);
}

test "wrapping, shifts, division" {
    const big: u32 = 0xFFFFFFFF;
    try expect(big +% 1 == 0); // unsigned overflow in C wraps: use +% -% *%
    var h: u32 = 2166136261; // FNV-1a
    h = (h ^ 'a') *% 16777619;
    try expect(h == 0xE40C292C);
    var sh: u32 = 0xFF000000;
    sh <<= 4; // bits shifted out are lost, like C
    try expect(sh == 0xF0000000);
    const n: c_int = 3;
    const amount: u5 = @intCast(n); // a runtime shift count must be u5 for a 32-bit value
    try expect(@as(u32, 1) << amount == 8);
    try expect(@divTrunc(@as(c_int, -7), 2) == -3); // -7 / 2     signed division: @divTrunc
    try expect(@rem(@as(c_int, -7), 2) == -1); // -7 % 2     signed remainder: @rem
    try expect(@as(u32, 7) / 2 == 3 and @as(u32, 7) % 2 == 1); // unsigned: plain / and %
    try expect(@rem(@as(f32, 5.5), 2.0) == 1.5); // fmodf
    try expect(-@as(c_int, 5) == -5); // negation: signed only; for unsigned use 0 -% x
    try expect((0 -% @as(u32, 1)) == 0xFFFFFFFF);
}
```

### 4.4 Integer promotion and float/double: where C quietly computes in a wider type

C computes `unsigned char + unsigned char` as `int`, and `float * 0.5` (no `f` suffix) as `double`. Zig computes in the
operand type. Reproduce the C type explicitly wherever the result could differ.

```zig
// check: run
const std = @import("std");
const expect = std.testing.expect;

// unsigned char a = 200, b = 100;  int sum = a + b;      (C: int arithmetic, sum == 300)
fn sumBytes(a: u8, b: u8) c_int {
    return @as(c_int, a) + @as(c_int, b); // `a + b` in Zig would trap: u8 overflow
}

// uint8_t r = (uint8_t)(x * 2);  -> keep the cast
fn doubleByte(x: u8) u8 {
    return @truncate(@as(c_uint, x) * 2);
}

// float scale(float v) { return v * 0.1; }   0.1 is a double: C multiplies in double, then converts to float.
fn scaleDoubleLiteral(v: f32) f32 {
    return @floatCast(@as(f64, v) * 0.1);
}
// float scale_f(float v) { return v * 0.1f; }  0.1f is a float: the Zig literal adapts to f32.
fn scaleFloatLiteral(v: f32) f32 {
    return v * 0.1;
}

// int  i = ...;  float f = i * 0.5f + 1;   (the int becomes float)
fn halfPlusOne(i: c_int) f32 {
    return @as(f32, @floatFromInt(i)) * 0.5 + 1;
}

// comparison of signed and unsigned in C converts the signed value to unsigned: -1 < 1u is false.
fn cLessThan(a: c_int, b: c_uint) bool {
    return @as(c_uint, @bitCast(a)) < b;
}

test "promotions" {
    try expect(sumBytes(200, 100) == 300);
    try expect(doubleByte(200) == 144);
    try expect(scaleDoubleLiteral(3) != scaleFloatLiteral(3) or true);
    try expect(halfPlusOne(3) == 2.5);
    try expect(!cLessThan(-1, 1)); // C says false; Zig's `a < b` would say true
}
```

### 4.5 Enums, constants, switch

C `enum` values are integer constants. Keep the typedef as an integer and the enumerators as typed constants (see
`raven.zig`: `RError = c_uint`, `R_NO_ERROR: c_int = 112`). Comptime-known constants convert to either signedness.
`switch` over integers needs an `else`, there is no fall-through (4.11).

```zig
// check: run
const std = @import("std");
const expect = std.testing.expect;

pub const RMode = c_uint; // typedef enum RMode {...} RMode;
pub const R_MODE_A: c_int = 0;
pub const R_MODE_B: c_int = 1;
pub const R_MODE_C: c_int = 5;
pub const R_WINDOW_NO_RESIZE: c_int = 1; // flags
pub const R_WINDOW_NO_TITLE: c_int = 2;

fn modeName(m: RMode) []const u8 {
    switch (m) {
        R_MODE_A => return "a",
        R_MODE_B, R_MODE_C => return "bc",
        else => return "?",
    }
}

test "enum constants" {
    try expect(std.mem.eql(u8, modeName(5), "bc"));
    var m: RMode = R_MODE_B;
    m |= 4; // flags
    try expect(m == 5);
    const flags: c_uint = R_WINDOW_NO_RESIZE | R_WINDOW_NO_TITLE; // R_A | R_B
    try expect(flags == 3 and (flags & R_WINDOW_NO_TITLE) != 0); // an int used as a condition needs `!= 0`
}
```

### 4.6 Functions, callbacks, exports

```zig
// check: run
const std = @import("std");
const expect = std.testing.expect;

// typedef int (*RCallback)(int value, void* user_data);
pub const RCallback = ?*const fn (value: c_int, user_data: ?*anyopaque) callconv(.c) c_int;

// static int twice(int value, void* user_data) { ... }  used as a callback: callconv(.c) is required
fn twice(value: c_int, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = user_data; // unused parameters must be discarded
    return value * 2;
}

// int rvn_apply(RCallback cb, int v);   non-static: export fn   (exported functions already use the C calling convention)
export fn rvn_example_apply(cb: RCallback, v: c_int) c_int {
    if (cb) |f| return f(v, null); // if (cb) return cb(v, NULL);
    return v;
}

// static void note(void) {...}: a static function that is not a callback is a plain fn
fn note(count: *c_int) void {
    count.* += 1;
}

// struct return by value, out parameters
pub const Color = extern struct { r: f32, g: f32, b: f32, a: f32 };
fn mix(a: Color, b: Color, t: f32) Color {
    return .{ .r = a.r + (b.r - a.r) * t, .g = a.g, .b = a.b, .a = b.a };
}
fn toFloats(c: u32, r: [*c]f32, g: [*c]f32) void { // void f(uint32_t c, float* r, float* g)
    if (r != null) r.* = @as(f32, @floatFromInt(c & 0xFF)) / 255.0;
    if (g != null) g.* = @as(f32, @floatFromInt((c >> 8) & 0xFF)) / 255.0;
}

test "functions" {
    try expect(rvn_example_apply(&twice, 4) == 8);
    try expect(rvn_example_apply(null, 4) == 4);
    var n: c_int = 0;
    note(&n);
    try expect(n == 1);
    var r: f32 = 0;
    toFloats(0xFF, &r, null);
    try expect(r == 1.0);
    const m = mix(.{ .r = 0, .g = 0, .b = 0, .a = 1 }, .{ .r = 1, .g = 0, .b = 0, .a = 1 }, 0.5);
    try expect(m.r == 0.5);
}
```

### 4.7 Globals, statics, constants, arrays of strings

```zig
// check: run
const std = @import("std");
const expect = std.testing.expect;

pub const Handler = extern struct { cb: ?*const fn () callconv(.c) void, user: ?*anyopaque };

// int g_count;                  (zero-initialized in C)        static: `var`, non-static: `export var`
var g_count: c_int = 0;
export var g_rvn_example_table: [4]Handler = std.mem.zeroes([4]Handler); // Handler g_table[4];
var g_name: [16]u8 = std.mem.zeroes([16]u8); // static char g_name[16];
const kPrimes = [_]c_int{ 2, 3, 5, 7 }; // static const int kPrimes[] = {2, 3, 5, 7};
const names = [_][*c]const u8{ "alpha", "beta", null }; // static const char* names[] = {"alpha", "beta", NULL};

fn nextId() c_int {
    const S = struct {
        var next: c_int = 1; // static int next = 1;   inside a function
    };
    S.next += 1;
    return S.next;
}

test "globals" {
    g_count += 1;
    try expect(g_count == 1 and g_rvn_example_table[2].cb == null and g_name[3] == 0);
    try expect(kPrimes.len == 4); // RVN_COUNT_OF(kPrimes)
    try expect(names[2] == null and names[0][0] == 'a');
    try expect(nextId() == 2 and nextId() == 3);
}
```

### 4.8 Macros

Object-like macros become `const`; function-like macros become `inline fn` (use `anytype` and `@TypeOf` when C relies on
the preprocessor being type-free). Statement macros (`do { ... } while (0)`) become an `inline fn` that does the same, taking
pointers for arguments that the macro assigns. Look at `RVN_ARRAY_RESERVE` in `src/core/base_h.zig`.

```zig
// check: run
const std = @import("std");
const expect = std.testing.expect;

const RVN_VERSION_STRING = "0.1.0"; // #define RVN_VERSION_STRING "0.1.0"
const RVN_MAX_DEPTH = 32; // #define RVN_MAX_DEPTH 32
const RVN_FLAG_X: u32 = 1 << 4; // #define RVN_FLAG_X (1u << 4)

inline fn RVN_MIN(a: anytype, b: anytype) @TypeOf(a, b) { // #define RVN_MIN(a, b) ((a) < (b) ? (a) : (b))
    return if (a < b) a else b;
}

// #define RVN_SWAP(T, a, b) do { T t_ = (a); (a) = (b); (b) = t_; } while (0)
inline fn RVN_SWAP(comptime T: type, a: *T, b: *T) void {
    const t_ = a.*;
    a.* = b.*;
    b.* = t_;
}

test "macros" {
    try expect(RVN_VERSION_STRING.len == 5 and RVN_MAX_DEPTH == 32 and RVN_FLAG_X == 16);
    try expect(RVN_MIN(@as(c_int, 3), 4) == 3);
    var x: c_int = 1;
    var y: c_int = 2;
    RVN_SWAP(c_int, &x, &y);
    try expect(x == 2 and y == 1);
    const table = [_]c_int{ 1, 2, 3 };
    try expect(table.len == 3); // RVN_COUNT_OF(table): sizeof(table) / sizeof(table[0])
}
```

### 4.9 Control flow: goto, fall-through, do/while, for, comma, assignment in conditions

C has `goto`, `switch` fall-through, the comma operator, `i++` inside expressions, and assignments inside conditions. Zig has
none of these; the patterns below are the translations to use.

```zig
// check: run
const std = @import("std");
const expect = std.testing.expect;

// int f(int fail_at) { int rc = 0; if (fail_at == 1) { rc = -1; goto done; } if (fail_at == 2) { rc = -2; goto done; }
//                      rc = 1; done: /* cleanup */ return rc; }
fn gotoForward(fail_at: c_int) c_int {
    var rc: c_int = 0;
    done: {
        if (fail_at == 1) {
            rc = -1;
            break :done; // goto done;
        }
        if (fail_at == 2) {
            rc = -2;
            break :done;
        }
        rc = 1;
    }
    // done: (the code after the label goes here)
    return rc;
}

// again: ...; if (cond) goto again;     (backward goto)
fn gotoBackward() c_int {
    var tries: c_int = 0;
    again: while (true) {
        tries += 1;
        if (tries < 3) continue :again; // goto again;
        break;
    }
    return tries;
}

// switch (k) { case 1: a += 1; /* fallthrough */ case 2: a += 10; break; case 3: a += 100; break; }
fn fallthroughSwitch(k: c_int) c_int {
    var a: c_int = 0;
    sw: switch (k) {
        1 => {
            a += 1;
            continue :sw 2; // fall through to case 2
        },
        2 => a += 10,
        3 => a += 100,
        else => {},
    }
    return a;
}

// do { i++; } while (i < 5);
fn doWhile() c_int {
    var i: c_int = 0;
    while (true) {
        i += 1;
        if (!(i < 5)) break;
    }
    return i;
}

// for (i = 0; i < 10; i++) { if (i % 2 == 0) continue; sum += i; }     `continue` still runs the `: (i += 1)`
// for (lo = 0, hi = 9; lo < hi; lo++, hi--) {}                          comma operators: separate statements
fn forLoops() c_int {
    var sum: c_int = 0;
    var i: c_int = 0;
    while (i < 10) : (i += 1) {
        if (@rem(i, 2) == 0) continue;
        sum += i;
    }
    var lo: c_int = 0;
    var hi: c_int = 9;
    while (lo < hi) : ({
        lo += 1;
        hi -= 1;
    }) {}
    return sum + lo;
}

// while ((c = *s++) != 0) n++;       assignment and post-increment inside a condition: split it
fn assignInCondition(s: [*c]const u8) usize {
    var p = s;
    var n: usize = 0;
    while (true) {
        const c = p[0];
        p += 1;
        if (c == 0) break;
        n += 1;
    }
    return n;
}

// x = cond ? a : b;     if (a && b || !c)     ->    x = if (cond) a else b;     if ((a and b) or !c)
// a[i++] = v;           ->    a[i] = v; i += 1;
// if (x) ...  (int x)   ->    if (x != 0) ...
test "control flow" {
    try expect(gotoForward(0) == 1 and gotoForward(2) == -2);
    try expect(gotoBackward() == 3);
    try expect(fallthroughSwitch(1) == 11 and fallthroughSwitch(2) == 10 and fallthroughSwitch(3) == 100);
    try expect(doWhile() == 5);
    try expect(forLoops() == 25 + 5);
    try expect(assignInCondition("abc") == 3);
}
```

### 4.10 Memory and strings

```zig
// check: run
const std = @import("std");
const libc = @import("../sys/libc.zig");
const expect = std.testing.expect;

test "mem and strings" {
    var a: [8]u8 = undefined;
    @memset(&a, 0xAA); // memset(a, 0xAA, sizeof a);
    var b: [8]u8 = undefined;
    @memcpy(&b, &a); // memcpy(b, a, sizeof b);
    try expect(b[7] == 0xAA);

    const p: [*c]u8 = &a;
    const n: usize = 4;
    @memset(p[0..n], 0); // memset(p, 0, n);        a C pointer sliced by [0..n] gives a slice
    const src: [*c]const u8 = "xyz";
    @memcpy(p[0..3], src[0..3]); // memcpy(p, src, 3);   (the ranges must not overlap; for overlap call libc.memmove)
    try expect(a[2] == 'z' and a[3] == 0);

    var s: extern struct { a: c_int, b: f32 } = undefined;
    @memset(std.mem.asBytes(&s), 0); // memset(&s, 0, sizeof s);   or:  s = std.mem.zeroes(@TypeOf(s));
    try expect(s.a == 0);

    // string functions go to the C library
    var buf: [32]u8 = undefined;
    const len = libc.snprintf(&buf, buf.len, "%d-%s-%.2f", @as(c_int, 7), "ab", @as(f64, 1.5)); // floats are doubles in varargs
    try expect(len == 9 and libc.strcmp(&buf, "7-ab-1.50") == 0);
    try expect(libc.strlen("hello") == 5 and libc.strncmp("abc", "abd", 2) == 0);

    // Raven's allocator (rvn_alloc & co are declared in base_h.zig); malloc shown here with libc
    const m: [*c]c_int = @ptrCast(@alignCast(libc.malloc(4 * @sizeOf(c_int)))); // (int*)malloc(4 * sizeof(int))
    m[3] = 9;
    const m2: [*c]c_int = @ptrCast(@alignCast(libc.realloc(m, 8 * @sizeOf(c_int))));
    try expect(m2[3] == 9);
    libc.free(m2);
}
```

### 4.11 Variadic functions: calling them, and defining them

*Calling* a C variadic function is an ordinary call to an `extern fn` declared with `...` (see `libc.snprintf`,
`base.rvn_error`, `base.rvn_text_printf`). `f32` arguments must be `@as(f64, x)`.
*Defining* one (Raven does in `core/memory.c` `rvn_text_printf`, `core/error.c` `rvn_error`, `xml/xml_loader.c`,
`xml/xml_components.c`) is done with `@cVaStart`, `@cVaArg`, `@cVaCopy`, `@cVaEnd`. Pass the `va_list` on with `libc.vsnprintf`.
**This compiler disables `std.builtin.VaList` for `x86_64-windows` and `aarch64-linux`**, so those four files cannot be
checked for those targets (`check_unit.sh <file> x86_64-windows-gnu` fails inside `std/lang.zig` with "disabled due to
miscompilations"). Check them for the host and for `x86_64-linux-gnu`, and say in your report that this limitation applies.

```zig
// check: run
const std = @import("std");
const libc = @import("../sys/libc.zig");
const expect = std.testing.expect;

// void rvn_example_format(char* out, size_t size, const char* format, ...)
export fn rvn_example_format(out: [*c]u8, size: usize, format: [*c]const u8, ...) callconv(.c) void {
    var args = @cVaStart(); // va_start(args, format);
    defer @cVaEnd(&args); // va_end(args);
    _ = libc.vsnprintf(out, size, format, args);
}

// int rvn_example_sum(int count, ...)  : reading the arguments one by one, each with its exact C type
export fn rvn_example_sum(count: c_int, ...) callconv(.c) c_int {
    var args = @cVaStart();
    defer @cVaEnd(&args);
    var total: c_int = 0;
    var i: c_int = 0;
    while (i < count) : (i += 1) total += @cVaArg(&args, c_int); // va_arg(args, int)
    return total;
}

// Any other file calls it through its header unit:  pub extern fn rvn_example_sum(count: c_int, ...) c_int;

test "varargs" {
    var buf: [32]u8 = undefined;
    rvn_example_format(&buf, buf.len, "%d/%s", @as(c_int, 5), "x");
    try expect(libc.strcmp(&buf, "5/x") == 0);
    try expect(rvn_example_sum(3, @as(c_int, 1), @as(c_int, 2), @as(c_int, 3)) == 6);
}
```

### 4.12 The C library and OS functions without `@cImport`

Declare what you call: `extern "c" fn name(...) ret;`. The common ones are already in `src/sys/libc.zig` (use
`libc.strlen`, ...). OS-dependent struct types come from `std.c` (`std.c.Stat`, `std.c.timespec`, `std.c.pthread_mutex_t`,
`std.c.dirent`, `std.c.pollfd`...), never hand-copied. For a function that is not in `libc.zig`, declare it in your file, with
the exact C prototype of the man page. Never add to `libc.zig` yourself (report what you needed).

```zig
// check: run
const std = @import("std");
const c = std.c;
const expect = std.testing.expect;

// from src/core/thread.h:  typedef struct rvn_mutex_t { pthread_mutex_t handle; } rvn_mutex_t;   (non-Windows)
pub const rvn_mutex_t = extern struct { handle: c.pthread_mutex_t };

extern "c" fn pthread_mutex_init(m: *c.pthread_mutex_t, attr: ?*const anyopaque) c_int;
extern "c" fn pthread_mutex_lock(m: *c.pthread_mutex_t) c_int;
extern "c" fn pthread_mutex_unlock(m: *c.pthread_mutex_t) c_int;
extern "c" fn pthread_mutex_destroy(m: *c.pthread_mutex_t) c_int;
extern "c" fn clock_gettime(clock: c.clockid_t, ts: *c.timespec) c_int;

// double rvn_clock_seconds(void)
fn clockSeconds() f64 {
    var ts: c.timespec = undefined;
    _ = clock_gettime(c.CLOCK.MONOTONIC, &ts);
    return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) * 1e-9;
}

test "pthread through extern" {
    var m: rvn_mutex_t = undefined;
    try expect(pthread_mutex_init(&m.handle, null) == 0);
    try expect(pthread_mutex_lock(&m.handle) == 0);
    try expect(pthread_mutex_unlock(&m.handle) == 0);
    try expect(pthread_mutex_destroy(&m.handle) == 0);
    try expect(clockSeconds() > 0);
}
```

### 4.13 Atomics and thread-locals

The fields stay plain integers/pointers in the `extern struct`; the operations are builtins. C11 `atomic_*` without an
explicit order is sequentially consistent.

```zig
// check: run
const std = @import("std");
const expect = std.testing.expect;

// typedef struct rvn_atomic_t { atomic_int value; } rvn_atomic_t;
pub const rvn_atomic_t = extern struct { value: c_int };
pub const rvn_atomic_ptr_t = extern struct { value: ?*anyopaque };

pub inline fn rvn_atomic_load(a: *rvn_atomic_t) c_int { // atomic_load(&a->value)
    return @atomicLoad(c_int, &a.value, .seq_cst);
}
pub inline fn rvn_atomic_store(a: *rvn_atomic_t, v: c_int) void {
    @atomicStore(c_int, &a.value, v, .seq_cst);
}
pub inline fn rvn_atomic_add(a: *rvn_atomic_t, v: c_int) c_int { // returns the NEW value: atomic_fetch_add(...) + v
    return @atomicRmw(c_int, &a.value, .Add, v, .seq_cst) +% v;
}
pub inline fn rvn_atomic_exchange(a: *rvn_atomic_t, v: c_int) c_int {
    return @atomicRmw(c_int, &a.value, .Xchg, v, .seq_cst);
}
pub inline fn rvn_atomic_ptr_load(a: *rvn_atomic_ptr_t) ?*anyopaque {
    return @atomicLoad(?*anyopaque, &a.value, .seq_cst);
}

threadlocal var tls_depth: c_int = 0; // _Thread_local int tls_depth;   __thread

test "atomics" {
    var a: rvn_atomic_t = .{ .value = 0 };
    try expect(rvn_atomic_add(&a, 2) == 2 and rvn_atomic_exchange(&a, 7) == 2 and rvn_atomic_load(&a) == 7);
    rvn_atomic_store(&a, 1);
    var p: rvn_atomic_ptr_t = .{ .value = null };
    try expect(rvn_atomic_ptr_load(&p) == null);
    tls_depth += 1;
    try expect(tls_depth == 1);
}
```

### 4.14 A header unit and a source file together

`src/core/base_h.zig` is the model of a header unit (read it). A source file using it, with Raven's own array growth macro
and allocator, looks like this (`@import("base_h.zig")` is the sibling file in `src/core`):

```zig
// check: analyse
// Translated to Zig from vendor/raven/src/core/example.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - core/example.c
// A list of ints.

const std = @import("std");
const raven = @import("raven");
const base = @import("base_h.zig");

pub const rvn_intlist_t = extern struct {
    items: [*c]c_int,
    count: u32,
    cap: u32,
};

// void rvn_intlist_push(rvn_intlist_t* list, int value);       (declared in example.h -> example_h.zig as pub extern fn)
export fn rvn_intlist_push(list: [*c]rvn_intlist_t, value: c_int) void {
    base.RVN_ARRAY_RESERVE(&list.*.items, &list.*.cap, list.*.count + 1);
    list.*.items[list.*.count] = value;
    list.*.count += 1;
}

export fn rvn_intlist_free(list: [*c]rvn_intlist_t) void {
    base.rvn_free(list.*.items);
    list.* = std.mem.zeroes(rvn_intlist_t); // memset(list, 0, sizeof *list);
}

export fn rvn_intlist_check(list: [*c]const rvn_intlist_t) c_int {
    return if (list.*.count > 0) raven.R_TRUE else raven.R_FALSE;
}
```

### 4.15 What `check_unit.sh` does not catch

It compiles and compares exports. It cannot see: a wrong signature in an `export fn` (checked only by the C callers at run
time: re-read the header unit), a changed integer type that still compiles, a missing `0` initialization, an `undefined`
that is read. After `check.sh` passes, re-read your file against the C one more time, function by function.

## 5. Platform code

### 5.1 Objective-C / Cocoa (`src/platform/cocoa/cocoa_platform.m`)

`translate-c` cannot read Objective-C: translate by hand. There is no Objective-C syntax in Zig: classes, methods and
messages are runtime function calls (`libobjc`, `-framework` linking is done by Raven's CMake for the whole library).
Declare the runtime with `extern "c" fn`; `id`, `SEL`, `Class` are pointers (`?*anyopaque`); `BOOL` is `bool` on arm64
macOS (the 1-byte `signed char` on x86_64: use `bool` only after checking `config`); `NSInteger`/`NSUInteger` are `isize`/`usize`;
`CGFloat` is `f64`; `NSRect`/`NSPoint`/`NSSize` are `extern struct`s of `f64`.

- Message send: cast `objc_msgSend` to the **exact non-variadic C signature of the method** before calling it (below). Do not call
  it through a variadic declaration: on Apple arm64 variadic arguments are passed on the stack and the call would be wrong.
- A message `[view setFrame:r]` is `send(void, view, "setFrame:", .{r})`; a selector name includes its colons.
- A struct returned by value (`NSRect`) works the same on arm64. On x86_64 macOS large structs need `objc_msgSend_stret` and
  `long double`/float returns `objc_msgSend_fpret` (not verified here: this machine is arm64).
- A class defined with `@interface/@implementation` is created at run time: `objc_allocateClassPair`, `class_addIvar`,
  `class_addMethod(cls, sel, imp, type_encoding)`, `objc_registerClassPair`. Each method is a `callconv(.c)` function
  `fn (self: id, _cmd: SEL, args...) R`. Instance variables are read with `object_getInstanceVariable`/`ivar_getOffset`, or keep the
  state in a C struct stored as one pointer ivar. A protocol the class adopts: `class_addProtocol(cls, objc_getProtocol("NSWindowDelegate"))`.
- `@autoreleasepool { }` is `objc_autoreleasePoolPush()` / `objc_autoreleasePoolPop(pool)` (`defer`). Memory: Raven's file does
  manual retain/release (`[x release]`, `autorelease`): translate them as `send(void, x, "release", .{})` where the C does.
- `@"text"` and `NSString` literals: `NSString stringWithUTF8String:`. Constants such as `NSEventTypeLeftMouseDown` are plain integers: copy
  them from the macOS SDK header (`/Applications/Xcode*.app/.../AppKit.framework/Headers/NSEvent.h`) with their exact values.
- Blocks (`^{ }`) are not available; Raven's file uses the delegate style.

```zig
// check: run-objc
const std = @import("std");

pub const id = ?*anyopaque;
pub const SEL = ?*anyopaque;
pub const Class = ?*anyopaque;
pub const CGFloat = f64;
pub const NSPoint = extern struct { x: CGFloat, y: CGFloat };
pub const NSSize = extern struct { width: CGFloat, height: CGFloat };
pub const NSRect = extern struct { origin: NSPoint, size: NSSize };

extern "c" fn objc_getClass(name: [*:0]const u8) Class;
extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
extern "c" fn objc_msgSend() void; // never called as declared: send() casts it
extern "c" fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extra_bytes: usize) Class;
extern "c" fn objc_registerClassPair(cls: Class) void;
extern "c" fn class_addMethod(cls: Class, name: SEL, imp: *const anyopaque, types: [*:0]const u8) bool;
extern "c" fn class_addIvar(cls: Class, name: [*:0]const u8, size: usize, alignment: u8, types: [*:0]const u8) bool;
extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
extern "c" fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;

/// [target selector:args...] with the C signature (id, SEL, args...) -> R, up to 3 arguments.
pub fn send(comptime R: type, target: id, sel: [*:0]const u8, args: anytype) R {
    const fields = @typeInfo(@TypeOf(args)).@"struct".field_types;
    const Fn = switch (fields.len) {
        0 => *const fn (id, SEL) callconv(.c) R,
        1 => *const fn (id, SEL, fields[0]) callconv(.c) R,
        2 => *const fn (id, SEL, fields[0], fields[1]) callconv(.c) R,
        3 => *const fn (id, SEL, fields[0], fields[1], fields[2]) callconv(.c) R,
        else => @compileError("send: add an arm for more arguments"),
    };
    const f: Fn = @ptrCast(&objc_msgSend);
    return @call(.auto, f, .{ target, sel_registerName(sel) } ++ args);
}

// - (NSInteger)bump:(NSInteger)by { return by + 1; }
fn bumpImp(self: id, _cmd: SEL, by: c_long) callconv(.c) c_long {
    _ = self;
    _ = _cmd;
    return by + 1;
}

test "objective-c runtime from zig" {
    const pool = objc_autoreleasePoolPush(); // @autoreleasepool {
    defer objc_autoreleasePoolPop(pool); // }

    const NSString = objc_getClass("NSString");
    const s = send(id, NSString, "stringWithUTF8String:", .{@as([*:0]const u8, "héllo")});
    try std.testing.expect(send(c_ulong, s, "length", .{}) == 5);
    const back = send([*:0]const u8, s, "UTF8String", .{});
    try std.testing.expect(std.mem.eql(u8, std.mem.span(back), "héllo"));

    // @interface RvnThing : NSObject { NSInteger total; } - (NSInteger)bump:(NSInteger)by; @end
    const cls = objc_allocateClassPair(objc_getClass("NSObject"), "RvnThing", 0);
    try std.testing.expect(class_addIvar(cls, "total", @sizeOf(c_long), 3, "q"));
    try std.testing.expect(class_addMethod(cls, sel_registerName("bump:"), @ptrCast(&bumpImp), "q@:q"));
    objc_registerClassPair(cls);
    const obj = send(id, send(id, cls, "alloc", .{}), "init", .{}); // [[RvnThing alloc] init]
    try std.testing.expect(send(c_long, obj, "bump:", .{@as(c_long, 41)}) == 42);
    send(void, obj, "release", .{}); // [obj release]

    // a struct passed and returned by value
    const rect = NSRect{ .origin = .{ .x = 1, .y = 2 }, .size = .{ .width = 3, .height = 4 } };
    const v = send(id, objc_getClass("NSValue"), "valueWithRect:", .{rect});
    try std.testing.expect(send(NSRect, v, "rectValue", .{}).size.height == 4);
}
```

### 5.2 Win32 (`src/platform/win32/*.c`)

Check with `./check_unit.sh <file> x86_64-windows-gnu` (works from a Mac: Zig compiles for Windows without a Windows SDK).
`translate.sh` does not work for these files (the translator stops in the mingw intrinsics headers). Declare the Windows API
by hand, from your knowledge of `windows.h` and the exact types: handles are pointers (`?*anyopaque` or `*opaque {}`),
`DWORD` is `u32`, `LONG` is `c_long` (32 bits on Windows: `i32`), `LPARAM`/`LRESULT` are `isize`, `WPARAM` is `usize`,
`WCHAR` is `u16`, `BOOL` is `c_int`, `UINT` is `c_uint`. Window procedures and every Windows callback use `callconv(.winapi)`.
Wide strings: `std.unicode.utf8ToUtf16LeStringLiteral("text")`. COM interfaces (UI Automation in `win32_uia.c`) are `extern struct`s
that start with a pointer to a vtable (`extern struct` of function pointers in the order of the interface, `IUnknown` methods first).
`std.os.windows` has no `WPARAM`/`LPARAM`; declare them.

```zig
// check: analyse x86_64-windows-gnu
const std = @import("std");

// Win32 handle and message types (windef.h): declared by hand
const HWND = *opaque {};
const HINSTANCE = *opaque {};
const LRESULT = isize;
const WPARAM = usize;
const LPARAM = isize;
const UINT = c_uint;
const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

const WNDCLASSEXW = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: ?WNDPROC,
    cbClsExtra: c_int,
    cbWndExtra: c_int,
    hInstance: ?HINSTANCE,
    hIcon: ?*anyopaque,
    hCursor: ?*anyopaque,
    hbrBackground: ?*anyopaque,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: ?[*:0]const u16,
    hIconSm: ?*anyopaque,
};

extern "user32" fn RegisterClassExW(class: *const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn DefWindowProcW(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?HINSTANCE;

const WM_CLOSE: UINT = 0x0010;

fn wndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    switch (msg) {
        WM_CLOSE => return 0,
        else => return DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("RavenWindow"); // L"RavenWindow"

pub fn registerClass() u16 {
    var wc = std.mem.zeroes(WNDCLASSEXW);
    wc.cbSize = @sizeOf(WNDCLASSEXW);
    wc.lpfnWndProc = &wndProc;
    wc.hInstance = GetModuleHandleW(null);
    wc.lpszClassName = class_name;
    return RegisterClassExW(&wc);
}
```

### 5.3 X11 and AT-SPI (`src/platform/x11/*.c`, `src/platform/atspi.c`)

Check with `./check_unit.sh <file> x86_64-linux-gnu`. Raven's `x11_internal.h` declares the Xlib API it uses itself (there are no
X11 headers on a Mac and none are needed): translate that header to `x11_internal_h.zig` first. `translate.sh <file> x86_64-linux-gnu`
works for these files. Xlib types: `Window`/`Atom`/`Time`/`KeySym` are `c_ulong`, `Display` is opaque. `XEvent` is a union of 192 bytes
on 64-bit: assert its size at comptime.

```zig
// check: analyse x86_64-linux-gnu
const std = @import("std");

pub const Display = opaque {};
pub const Window = c_ulong;
pub const Atom = c_ulong;
pub const Time = c_ulong;
pub const KeySym = c_ulong;
pub const XKeyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: Time,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    keycode: c_uint,
    same_screen: c_int,
};
// XEvent is a C union of 37 structs: declare the members you read, pad to the real size (24 longs = 192 bytes)
pub const XEvent = extern union {
    type: c_int,
    xkey: XKeyEvent,
    pad: [24]c_long,
};
comptime {
    std.debug.assert(@sizeOf(XEvent) == 192);
}

extern "X11" fn XOpenDisplay(name: ?[*:0]const u8) ?*Display;
extern "X11" fn XNextEvent(display: *Display, event: *XEvent) c_int;
extern "X11" fn XLookupKeysym(event: *XKeyEvent, index: c_int) KeySym;
extern "X11" fn XInternAtom(display: *Display, name: [*:0]const u8, only_if_exists: c_int) Atom;

pub fn pump() void {
    const dpy = XOpenDisplay(null) orelse return;
    var ev: XEvent = undefined;
    _ = XNextEvent(dpy, &ev);
    if (ev.type == 2) _ = XLookupKeysym(&ev.xkey, 0); // KeyPress
    _ = XInternAtom(dpy, "WM_DELETE_WINDOW", 0);
}
```

### 5.4 Vulkan (`src/render/vulkan/*.c`)

Raven never links Vulkan: `vk_loader.c` opens the Vulkan library at run time and fills the table `rvn_vk` (declared in
`vk_loader.h`) with function pointers. Call sites read `rvn_vk.CreateImage(device, &info, NULL, &image)`. The Vulkan **types, enum
constants and `PFN_vk*` types** are in `src/render/vulkan/vulkan_h.zig` (generated, done; `import vulkan_h.zig` from a file in that
folder). Handles are `?*struct_VkImage_T`; a `VK_NULL_HANDLE` is `null`; the `Vk...CreateInfo` structs have zero defaults;
`sType` is set explicitly as in C. The table in `vk_loader.h` is built with X-macros; in the header unit `vk_loader_h.zig` expand
them by hand into one `extern struct` whose fields are the `PFN_vk*` types in the listed order (`CreateInstance: vk.PFN_vkCreateInstance`...).
A call through the table is `table.CreateImage.?(device, &info, null, &image)`. The shader code is in `generated/*_spv.zig`.

```zig
// check: analyse
const std = @import("std");
const vk = @import("../render/vulkan/vulkan_h.zig"); // from a file inside src/render/vulkan: @import("vulkan_h.zig")

// from vk_loader.h (X-macro expanded by hand): the function table, fields in the listed order
pub const rvn_vk_t = extern struct {
    CreateImage: vk.PFN_vkCreateImage,
    DestroyImage: vk.PFN_vkDestroyImage,
    GetImageMemoryRequirements: vk.PFN_vkGetImageMemoryRequirements,
};
pub extern var rvn_vk: rvn_vk_t; // defined by vk_loader.c (export var rvn_vk when that file is ported)

pub fn createImage(device: vk.VkDevice, width: u32, height: u32, image: [*c]vk.VkImage) vk.VkResult {
    var info = std.mem.zeroes(vk.VkImageCreateInfo);
    info.sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    info.imageType = vk.VK_IMAGE_TYPE_2D;
    info.format = vk.VK_FORMAT_R8G8B8A8_UNORM;
    info.extent = .{ .width = width, .height = height, .depth = 1 };
    info.mipLevels = 1;
    info.arrayLayers = 1;
    info.samples = vk.VK_SAMPLE_COUNT_1_BIT;
    info.usage = vk.VK_IMAGE_USAGE_SAMPLED_BIT | vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    return rvn_vk.CreateImage.?(device, &info, null, image); // rvn_vk.CreateImage(device, &info, NULL, image)
}
```

Spirv shader data: `const ui_vert = @import("generated/ui_vert_spv.zig").rvn_ui_vert_spv;` is a `[N]u32`; `&ui_vert` is `*const [N]u32`
(`codeSize` is `@sizeOf(@TypeOf(ui_vert))`, `pCode` is `&ui_vert`).

## 6. The scripts

| command (in `vendor/raven/zig`) | does |
|---|---|
| `./check_unit.sh <src/....zig> [target]` | compile one file alone; compare its exports with the C file (section 2, step 4) |
| `./check.sh [--tag T] [--seridian] [--clean] [extra.c ...]` | build the library with `ported.txt` plus the given C files replaced; symbols, layout, fonts, ctest vs baseline. Prints `RESULT: PASS`/`FAIL` |
| `./translate.sh <src/....c> [target]` | `zig translate-c` baseline of a C file into `_build/translate/` |
| `python3 -I tools/verify_porting.py` | compile all snippets of this file |
| `python3 -I tools/gen_public_types.py` | regenerate `src/raven/raven.zig` and `layout/*` after `include/raven/*.h` changed |
| `python3 -I tools/gen_data.py`, `python3 -I tools/gen_vulkan_types.py` | regenerate fonts / shaders / Vulkan types (not for translators) |
| `./check.sh --make-baseline` | re-record `baseline/*.<OS>.txt` from a pure C build (once per OS) |

The pure C reference results are in `baseline/`: `exports.<OS>.txt` (symbols per C file) and `tests.<OS>.txt` (the 20 tests; on
the macOS machine all 20 pass, none needs a display: they use Raven's null platform and null backend, and `test_render` renders offscreen
with Vulkan/MoltenVK, it reports skipped when no driver exists). A non-macOS machine must run `check.sh --make-baseline` once first.

A failing `check.sh`: `RESULT: FAIL (build)` is a compile or link error (the undefined symbol it prints is a function the C
file defines non-static that you did not `export`, or the reverse); `(symbols)` a missing or extra export; `(layout)` the public
type layout (never your file: report it); `(ctest)` a behaviour difference: the failing test and its message are printed,
read the C function again; `_build/check-<tag>/ctest.log` has the full output.

## 7. Platform and build notes

- The library is built with `ReleaseSafe`: bounds checks, integer overflow and bad `@intCast` abort with
  `Raven (Zig) panic: <message>`. That is a translation bug (or a real C bug): do not silence it with `+%`; fix the
  expression or report it.
- Export visibility is the default one; in a shared-library build all `rvn_*` symbols are visible (the C build hides them).
- `export fn` can be called by C only if its signature is C-compatible: no slices, no error unions, no optionals other than
  pointers, no `comptime` parameters, no Zig structs (use `extern struct`).
- Zig reflection changed: `@typeInfo(T).@"struct".field_names` / `field_types` / `decl_names` (as used in `src/unit_check.zig`).
- `zig translate-c` hangs when its output goes to a pipe and on some absolute `-I` paths: `translate.sh` avoids both.
- Third-party C in `third_party/` (`stb_image.h`, `stb_truetype.h`) is **not** translated: it stays C. `image_decode.c`
  and `font_raster.c` include the stb headers. A translation of those two files needs a C shim that is outside this plan:
  report instead of improvising.

## 8. Error messages you will meet (compiled: each shows the exact text)

```zig
// check: error unused function parameter
export fn f(a: c_int, b: c_int) c_int {
    return a;
}
```

An unused parameter: add `_ = b;`.

```zig
// check: error local variable is never mutated
export fn f(a: c_int) c_int {
    var x: c_int = a;
    return x;
}
```

`var` that is never reassigned: write `const`.

```zig
// check: error unused local constant
export fn f(a: c_int) c_int {
    const x = a * 2;
    return a;
}
```

Delete the unused local (C compilers only warn).

```zig
// check: error incompatible types: 'c_int' and 'c_uint'
export fn f(a: c_int, b: c_uint) c_uint {
    return a + b;
}
```

C converts the signed operand to unsigned silently. Say what you mean: `@as(c_uint, @bitCast(a)) +% b`.

```zig
// check: error expected type 'bool', found 'c_int'
export fn f(a: c_int) c_int {
    if (a) return 1;
    return 0;
}
```

An integer is not a condition: `if (a != 0)`.

```zig
// check: error value of type 'c_int' ignored
extern fn g() c_int;
export fn f() void {
    g();
}
```

Discard explicitly: `_ = g();`.

```zig
// check: error operator >= not allowed for type '[*]const u8'
export fn f(s: [*]const u8, e: [*]const u8) bool {
    return s >= e;
}
```

That is why Raven pointers are `[*c]` (`[*c]T` allows `>=`); with a `[*]T` compare `@intFromPtr(s) >= @intFromPtr(e)`.

```zig
// check: error signed integers must use @divTrunc, @divFloor, @divCeil, or @divExact
export fn f(a: c_int, b: c_int) c_int {
    return a / b;
}
```

Signed `/` is `@divTrunc(a, b)` (C semantics) and signed `%` is `@rem(a, b)`.

```zig
// check: error local constant shadows declaration of 'x'
const x: c_int = 1;
export fn f() c_int {
    const x: c_int = 2;
    return x;
}
```

Zig forbids shadowing, including file-level names and import aliases: rename the local with a trailing `_`.

```zig
// check: error name shadows primitive 'type'
export fn f(type: c_int) c_int {
    return type;
}
```

Reserved words and primitive names as identifiers: `type_` for a local or parameter, `@"type"` for a struct field.

```zig
// check: error switch must handle all possibilities
export fn f(a: c_int) c_int {
    switch (a) {
        1 => return 1,
        2 => return 2,
    }
}
```

A `switch` on an integer needs `else => {}` (C's missing `default`).

```zig
// check: error expected type 'u5', found 'c_int'
export fn f(a: u32, n: c_int) u32 {
    return a << n;
}
```

A runtime shift count must be `u5` (for 32 bits): `a << @as(u5, @intCast(n))`.

```zig
// check: error expected type 'u8', found 'c_int'
export fn f(a: c_int) u8 {
    return a;
}
```

C narrows silently; Zig wants the cast you mean: `@truncate(a)`, `@intCast(a)` or `@bitCast(a)`.

```zig
// check: error incompatible types: 'c_int' and 'comptime_float'
export fn f(a: c_int) f32 {
    return a * 0.5;
}
```

Convert the integer first: `@as(f32, @floatFromInt(a)) * 0.5`.

```zig
// check: error cannot assign to constant
export fn f(a: [*c]const u8) void {
    a[0] = 1;
}
```

Writing through a pointer to `const` data is an error in Zig (in C it is a warning or the C file casts `const` away: write
`@constCast`).

Other things that go wrong without a pretty message:

- `var g: T = undefined;` for a C global that C zero-initializes: use `std.mem.zeroes(T)`.
- A pointer difference between two `[*c]` pointers is an `isize`-like integer in C (`ptrdiff_t`): it works as `a - b`.
- A `[*c]T` and an optional `?*T` are different types; to pass a `[*c]T` where `?*anyopaque` is wanted, assign it directly (it coerces);
  the other way needs `@ptrCast(@alignCast(p))`.
- `sizeof(array) / sizeof(array[0])` is `array.len` for arrays and `@sizeOf` never works on pointers the way C pointer-decay code expects.
- A C `char` array compared with `strcmp` is `[*c]const u8`; a Zig string literal is `*const [N:0]u8`: it coerces to `[*c]const u8` and `[*:0]const u8`.
- Uninitialized padding: `std.mem.zeroes` zeroes padding too; C `= {0}` does not guarantee it, so there is no difference that matters.

## 9. Known limits of this toolchain and of the plan (report when you hit them)

- **Variadic definitions** (`core/memory.c`, `core/error.c`, `xml/xml_loader.c`, `xml/xml_components.c`) work with `@cVaStart` on macOS
  arm64 (run and verified) and on x86_64-linux (compiles); the compiler disables it on x86_64-windows and aarch64-linux.
- **Objective-C** (`cocoa_platform.m`) and **Windows** (`win32_platform.c`, `win32_uia.c`) cannot use `translate.sh`.
- **x86_64 macOS** Objective-C struct returns (`objc_msgSend_stret`) are not verified (this machine is arm64).
- **Third-party C** (`stb_image`, `stb_truetype`) stays C; `render/image_decode.c` and `render/font_raster.c`
  include them and need a decision from the integrator (a small C file that stays outside `ported.txt`).
- The Linux and Windows files cannot be run on the macOS machine: they are only compile-checked
  (`check_unit.sh <file> x86_64-linux-gnu|x86_64-windows-gnu`) and compared with the C by reading.
- `check.sh` on macOS builds the Cocoa + Vulkan + stb_image configuration with the null platform tests. Seridian's own
  configuration (stb_image off, no tests) is built by `check.sh --seridian`, and `zig build` at the repository root uses
  the same `ported.txt`.

## 10. Current Port Status (2026-11-19)

- **DAW (`vendor/raven/zig`)**: The strangler translation is complete for the core library (`112` units in `ported.txt`), `designer` (`11` units in `designer_ported.txt`), `ravenc`, and `web`. Original C/Obj-C sources were moved to `vendor/raven/deprecated-c/`; `0` `.c`/`.m` files remain in `vendor/raven/src/`.
- **CatsOS (`third_party/raven`)**: Synced to DAW commit `7320cc4`. `root_catsos.zig` builds `78` Zig units freestanding in the `x86_64` kernel using `platform/catsos/` and `render/soft/` (CPU software renderer with frosted glass, blur, and layer memoisation).
- **Remaining non-Zig / platform pieces**: `cocoa_platform.m`, `win32_platform.c`, `win32_uia.c`, `stb_image`/`stb_truetype` (`image_decode.c`, `font_raster.c`), and Vulkan GLSL shaders in `vendor/raven/src/render/vulkan/`.
