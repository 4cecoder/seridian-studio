# Learned Patterns from ~/learning Projects

**Quick reference guide for patterns observed in Ghostty, Changies, and zig-gobject**

---

## From Ghostty (Terminal Emulator)

### 1. Runtime Backend Selection
```zig
// Pattern: Comptime backend selection with runtime preference
pub const Backend = switch (builtin.os.tag) {
    .linux => if (pipewire_available) PipeWireBackend else PulseAudioBackend,
    else => NullBackend,
};
```
**Use when:** Multiple platform-specific implementations needed

### 2. Comptime Initialization Helpers
```zig
fn initArray(comptime T: type, comptime N: usize, val: T) [N]T {
    var arr: [N]T = undefined;
    for (&arr) |*item| item.* = val;
    return arr;
}
```
**Use when:** Repeated initialization patterns (zero runtime cost)

### 3. Inline Type Conversion Helpers
```zig
inline fn castPtr(ptr: ?*anyopaque) ?*MyType {
    return if (ptr) |p| @ptrCast(@alignCast(p)) else null;
}
```
**Use when:** Frequent pointer casts at API boundaries

### 4. Validation with Early Returns
```zig
pub fn doThing(index: usize) void {
    if (index >= MAX_COUNT) return; // Early exit
    // ... rest of function
}
```
**Use when:** Validation reduces nesting depth

---

## From Changies (Audio Toolkit)

### 1. Named Constants for Domain Values
```zig
pub const TRACK_COUNT = 4;
pub const MAX_BUFFER_SIZE = 2048;
pub const SAMPLE_RATE = 48000;
```
**Use when:** Values appear multiple times or have domain significance

### 2. Optional Effects Chain
```zig
pub const Track = struct {
    reverb: ?Reverb = null,
    delay: ?Delay = null,
    eq: ?EQ = null,

    pub fn process(self: *Track, buffer: []f32) void {
        if (self.reverb) |*r| r.process(buffer);
        if (self.delay) |*d| d.process(buffer);
        if (self.eq) |*e| e.process(buffer);
    }
};
```
**Use when:** Processing pipeline has optional stages

### 3. Temp Buffer Pattern
```zig
pub fn process(self: *Engine, output: []f32) void {
    var temp: [MAX_BUFFER_SIZE]f32 = undefined;
    const temp_slice = temp[0..output.len];

    // Use temp_slice for intermediate processing
    // Copy to output when done
}
```
**Use when:** Real-time processing needs intermediate buffers

---

## From zig-gobject (GTK Bindings)

### 1. Safe C API Wrapper Pattern
```zig
export fn my_function(ptr: ?*anyopaque) callconv(.c) c_int {
    const obj = castPtr(ptr) orelse return -1;
    obj.method() catch |err| {
        std.log.err("Error: {}", .{err});
        return -1;
    };
    return 0;
}
```
**Rules:**
- Never panic across FFI
- Return error codes
- Log errors for debugging

### 2. Const-Correct APIs
```zig
// Mutable operations
inline fn cast(ptr: ?*anyopaque) ?*Type;

// Read-only operations
inline fn castConst(ptr: ?*anyopaque) ?*const Type;
```
**Use when:** C API has const/mutable distinction

### 3. Inline Wrappers for Repetitive Casts
```zig
// Instead of repeating this everywhere:
const obj: *MyType = @ptrCast(@alignCast(ptr));

// Create once:
inline fn fromPtr(ptr: *anyopaque) *MyType {
    return @ptrCast(@alignCast(ptr));
}
```
**Benefit:** DRY principle, zero runtime cost

---

## Common Patterns Across All Three

### 1. Explicit Allocators
```zig
// ✅ Good - allocator explicit
pub fn init(allocator: std.mem.Allocator) !Self { ... }

// ❌ Bad - hidden allocation
pub fn init() !Self { ... }
```

### 2. Init/Deinit Pairs
```zig
pub fn init(allocator: std.mem.Allocator) !Self {
    var self = Self{ .allocator = allocator };
    errdefer self.deinit(); // Cleanup on error
    // ... initialization
    return self;
}

pub fn deinit(self: *Self) void {
    // Cleanup in reverse order of init
}
```

### 3. Scoped Logging
```zig
const log = std.log.scoped(.module_name);

pub fn doWork() void {
    log.info("Starting work", .{});
    log.err("Failed: {}", .{err});
}
```

### 4. Descriptive Test Names
```zig
test "audio clip returns correct position after seek" { ... }
test "track meter peaks on clipped signal" { ... }
```

### 5. Error Set Documentation
```zig
pub const Error = error{
    /// File not found in search paths
    FileNotFound,
    /// Audio format not supported
    UnsupportedFormat,
};
```

---

## Anti-Patterns to Avoid

### ❌ Don't: Hide allocations
```zig
// Bad - where does allocation happen?
pub fn process(data: []const u8) !Result
```

### ❌ Don't: Ignore errors silently
```zig
// Bad
_ = doThing() catch {};

// Good
doThing() catch |err| {
    log.warn("Thing failed: {}", .{err});
    return default_value;
};
```

### ❌ Don't: Use `any`-equivalent patterns
```zig
// Bad - loses type information
pub fn process(ptr: *anyopaque) void

// Good - use generics
pub fn process(comptime T: type, ptr: *T) void
```

### ❌ Don't: Panic in library code
```zig
// Bad
if (err) |e| @panic(@errorName(e));

// Good
if (err) |e| {
    log.err("Failed: {}", .{e});
    return Error.SomethingFailed;
}
```

### ❌ Don't: Over-abstract
```zig
// Bad - helper for single use
fn wrapInOption(val: i32) ?i32 { return val; }

// Good - just use the pattern directly
const result: ?i32 = value;
```

---

## When to Apply Each Pattern

### Use Comptime Helpers When:
- Pattern repeats 3+ times
- Zero runtime cost needed
- Type safety must be preserved

### Use Inline Helpers When:
- Boilerplate repeated frequently
- Operation is simple (1-5 lines)
- Called from performance-critical code

### Use Named Constants When:
- Value appears 2+ times
- Value has domain significance
- Value might need changing

### Use Early Returns When:
- Validation reduces nesting
- Error cases are simple
- Happy path is primary focus

---

## Pattern Priority

1. **Safety First**
   - No panics in production
   - All errors handled
   - FFI boundaries protected

2. **Clarity Second**
   - Reduce duplication
   - Name magic values
   - Simplify control flow

3. **Performance Third**
   - Comptime when possible
   - Inline for hot paths
   - Profile before optimizing

---

## Quick Checklist for Code Review

- [ ] No panics (except tests/debug)
- [ ] Allocators explicit
- [ ] Errors handled/propagated
- [ ] Constants named
- [ ] Duplication < 3 instances
- [ ] Init/deinit paired
- [ ] Tests descriptive
- [ ] FFI boundary safe

---

**Remember:** Patterns are tools, not rules. Use when they improve clarity and maintainability.
