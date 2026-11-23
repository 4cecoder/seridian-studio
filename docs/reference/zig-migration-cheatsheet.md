# Zig 0.16 Migration Cheatsheet

This guide highlights the key API and language changes between Zig 0.15 and Zig 0.16.

## Build API Changes

The Build API underwent a significant overhaul in Zig 0.15.1, which is the foundation for 0.16.

### Executable and Module Initialization

**Old (0.15):**
```zig
const exe = b.addExecutable(.{
    .name = "my-app",
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});
```

**New (0.16):**
```zig
const exe_mod = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});

const exe = b.addExecutable(.{
    .name = "my-app",
    .root_module = exe_mod,
});
```

### Adding Imports (formerly Modules)

**Old (0.15):**
```zig
exe.addModule("my_dep", my_dep_module);
```

**New (0.16):**
```zig
exe_mod.addImport("my_dep", my_dep_module);
```

### Compiler Options (formerly Build Options)

**Old (0.15):**
```zig
const options = b.addOptions();
options.addOption(bool, "enable_feature", true);
exe.addOptions("build_options", options);
```

**New (0.16):**
```zig
const options = b.addOptions();
options.addOption(bool, "enable_feature", true);
exe_mod.addImport("build_options", options.createModule());
```

## Standard Library Changes

### The "Writergate" (I/O Overhaul)

Zig 0.15.1 introduced a major change to how `std.io.Reader` and `std.io.Writer` work.

- Generic interfaces now manage internal buffers.
- `std.fs.File.writer()` returns a writer that may include implicit buffering if needed.
- Many utility functions moved or changed signature to accommodate the new I/O model.

### Removed Components

- **`std.io.BufferedWriter`**: Replaced by the new buffered I/O model.
- **`std.io.CountingWriter`**: Reworked/moved.
- **`usingnamespace`**: The keyword has been removed from the language. Use explicit imports or struct fields.
- **`async` / `await`**: These keywords are removed. Zig is moving towards a different concurrency model.

## Language Changes

### Pointer Casting

`@ptrCast` is more flexible now:
- It can cast a single-item pointer to a slice: `const slice: []u8 = @ptrCast(single_ptr);`

### Boolean Vectors

More operators are allowed on `bool` vectors, enabling easier SIMD-like boolean logic.

---

**Last Updated:** 2025-12-25
