# Code Refactoring Plan

**Date:** 2025-12-23
**Focus:** Reduce code duplication without adding new features

## Summary

This document identifies code duplication in the current DAW codebase and proposes refactorings based on patterns learned from ~/learning projects (Ghostty, Changies, zig-gobject).

---

## 1. C API Wrapper Duplication

### Current Problem

**File:** `src/audio/engine_c_api.zig`
**Lines:** 6-88

Every exported C function repeats the same pattern:
```zig
export fn audio_engine_something(engine: ?*anyopaque, ...) callconv(.c) ReturnType {
    if (engine) |eng| {
        const audio_eng: *AudioEngine = @ptrCast(@alignCast(eng));
        // ... actual work
    }
    // ... default return
}
```

**Instances:** 13 functions with identical pointer casting boilerplate

### Learned Pattern

From **Ghostty** (`~/learning/ghostty/src/renderer/opengl/lib.zig`):
- Uses inline helper functions to reduce casting duplication
- Pattern: Extract common operations into small inline helpers

From **zig-gobject** (`~/learning/zig-gobject/src/c_api.zig`):
- Uses inline wrapper functions for type conversion
- Pattern: `inline fn castEngine(ptr: ?*anyopaque) ?*AudioEngine`

### Proposed Refactoring

```zig
// Add at top of file
inline fn castEngine(engine: ?*anyopaque) ?*AudioEngine {
    return if (engine) |eng|
        @ptrCast(@alignCast(eng))
    else
        null;
}

inline fn castEngineConst(engine: ?*anyopaque) ?*const AudioEngine {
    return if (engine) |eng|
        @ptrCast(@alignCast(eng))
    else
        null;
}

// Then functions become:
export fn audio_engine_stop(engine: ?*anyopaque) callconv(.c) void {
    if (castEngine(engine)) |eng| {
        eng.stop();
    }
}

export fn audio_engine_get_track_meter(engine: ?*anyopaque, track: c_int) callconv(.c) f32 {
    return if (castEngineConst(engine)) |eng|
        eng.getTrackMeter(@intCast(track))
    else
        0.0;
}
```

**Impact:** Reduces 13 × 2 lines = 26 lines of duplicated code
**Risk:** Low - inline functions have zero runtime cost
**Files Changed:** 1 (engine_c_api.zig)

---

## 2. Atomic Array Initialization Duplication

### Current Problem

**File:** `src/audio/engine.zig`
**Lines:** 25-58

Four identical patterns for initializing atomic arrays:
```zig
track_gains: [4]std.atomic.Value(f32) = blk: {
    var gains: [4]std.atomic.Value(f32) = undefined;
    for (&gains) |*gain| {
        gain.* = std.atomic.Value(f32).init(0.75);
    }
    break :blk gains;
},
```

**Instances:** 4 (track_gains, track_meters, track_muted, track_solo)

### Learned Pattern

From **Ghostty** (`~/learning/ghostty/src/audio/types.zig`):
- Uses comptime functions to generate repeated structures
- Pattern: `fn initAtomicArray(comptime T: type, comptime N: usize, init_val: T) [N]std.atomic.Value(T)`

### Proposed Refactoring

```zig
// Add helper function in engine.zig
fn initAtomicArray(comptime T: type, comptime N: usize, init_val: T) [N]std.atomic.Value(T) {
    var arr: [N]std.atomic.Value(T) = undefined;
    for (&arr) |*item| {
        item.* = std.atomic.Value(T).init(init_val);
    }
    return arr;
}

// Then in AudioEngine struct:
track_gains: [4]std.atomic.Value(f32) = initAtomicArray(f32, 4, 0.75),
track_meters: [4]std.atomic.Value(f32) = initAtomicArray(f32, 4, 0.0),
track_muted: [4]std.atomic.Value(bool) = initAtomicArray(bool, 4, false),
track_solo: [4]std.atomic.Value(bool) = initAtomicArray(bool, 4, false),
```

**Impact:** Reduces 4 × 6 lines = 24 lines of duplicated code
**Risk:** Low - comptime function, zero runtime cost
**Files Changed:** 1 (engine.zig)

---

## 3. Track Index Validation Duplication

### Current Problem

**File:** `src/audio/engine.zig`
**Lines:** 262-310

Multiple functions repeat the same track index validation:
```zig
pub fn setTrackGain(self: *AudioEngine, track: usize, gain: f32) void {
    if (track < 4) {
        // ... actual work
    }
}

pub fn getTrackGain(self: *const AudioEngine, track: usize) f32 {
    if (track < 4) {
        return self.track_gains[track].load(.monotonic);
    }
    return 0.0;
}
```

**Instances:** 8 functions with track index checking

### Learned Pattern

From **Ghostty** (`~/learning/ghostty/src/renderer/types.zig`):
- Uses early returns for validation
- Pattern: Consistent validation style

From **Changies** (`~/learning/changies/src/audio/mixer.zig`):
- Documents track count as constant
- Pattern: `const TRACK_COUNT = 4;`

### Proposed Refactoring

```zig
// Add constant at top of AudioEngine
const TRACK_COUNT = 4;

// Option A: Keep as-is but use constant
pub fn setTrackGain(self: *AudioEngine, track: usize, gain: f32) void {
    if (track >= TRACK_COUNT) return;
    const clamped = @max(0.0, @min(1.0, gain));
    self.track_gains[track].store(clamped, .monotonic);
}

// Option B: Helper for validation (if pattern repeats more)
inline fn isValidTrack(track: usize) bool {
    return track < TRACK_COUNT;
}
```

**Impact:** Better maintainability, magic number elimination
**Risk:** Very low - just using a constant
**Files Changed:** 1 (engine.zig)

---

## 4. Repeated Logging Patterns

### Current Analysis

**Pattern Found:** Consistent use of `std.log.scoped(.module_name)` across all modules

**Files:** 14 modules use this pattern

**Assessment:** This is GOOD duplication. It's a consistent pattern that should be maintained, not eliminated.

**Learned from:** All three projects (Ghostty, Changies, zig-gobject) use this exact pattern.

**Action:** NO CHANGE NEEDED - Document as best practice

---

## 5. Error Handling in C API

### Current Problem

**File:** `src/audio/engine_c_api.zig`
**Line:** 10

Still has `@panic(@errorName(err))` in audio_engine_start function.

From previous analysis (docs/NEXT_STEPS_COMPLETE.md), this was supposed to be fixed but wasn't.

### Learned Pattern

From **zig-gobject** C API wrappers:
- Never panic in C API boundary
- Return error codes
- Log errors for debugging

### Proposed Refactoring

```zig
export fn audio_engine_start(engine: ?*anyopaque) callconv(.c) c_int {
    if (castEngine(engine)) |eng| {
        eng.start() catch |err| {
            std.log.err("Failed to start audio engine: {}", .{err});
            return -1;
        };
        return 0;
    }
    return -1;
}
```

**Impact:** Removes last panic from C API
**Risk:** Very low - same pattern as other C API functions
**Files Changed:** 1 (engine_c_api.zig)

---

## Implementation Priority

### High Priority (Do First)
1. **Fix panic in C API** - Critical safety issue
2. **C API casting helpers** - High duplication, low risk

### Medium Priority
3. **Atomic array initialization** - Moderate duplication, educational value
4. **Track count constant** - Good practice, low effort

### Low Priority (Optional)
5. None currently identified

---

## Code Quality Standards Applied

Based on CLAUDE.md standards:

### Zig Standards Met:
- ✅ All errors handled explicitly (fixing last panic)
- ✅ Using comptime for zero-cost abstractions
- ✅ Inline functions for performance
- ✅ Meaningful names (castEngine, initAtomicArray)
- ✅ No hidden allocations

### Patterns from ~/learning:
- ✅ Ghostty: Comptime helpers, inline wrappers
- ✅ Changies: Constant definitions, validation patterns
- ✅ zig-gobject: C API boundary safety

---

## Testing Plan

After each refactoring:
1. Run `zig build` - Ensure compilation succeeds
2. Run `zig build test` - Ensure all tests pass
3. Run `zig build run` - Manual smoke test of UI
4. Check specific functionality:
   - C API: Test mute/solo buttons work
   - Atomics: Test mixer controls work
   - Track validation: Test out-of-bounds handling

---

## Anti-Patterns to Avoid

Based on learned patterns, DO NOT:
- ❌ Extract helpers that hide allocations
- ❌ Use `any` type equivalents (keep type safety)
- ❌ Over-abstract - keep code readable
- ❌ Create helpers for one-time use
- ❌ Add runtime overhead for style

---

## Metrics

### Current Duplication:
- C API casting: 26 lines duplicated
- Atomic init: 24 lines duplicated
- Track validation: ~16 lines with magic numbers
- **Total:** ~66 lines of duplication

### Expected Reduction:
- C API: -26 lines (replaced with 10 lines of helpers)
- Atomic init: -24 lines (replaced with 8 lines)
- Track validation: -0 lines (just constant rename)
- **Net reduction:** ~32 lines, improved maintainability

### Code Quality:
- Before: 1 panic in C boundary ❌
- After: 0 panics ✅
- Before: 4 magic numbers (track count)
- After: 1 named constant
