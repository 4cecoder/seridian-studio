# DAW UI Modularity Refactor Plan

**Goal:** Create a shadcn/ui-style component architecture for the GTK4 DAW in Zig

**Inspiration:** shadcn/ui's composable, reusable component system

---

## Current Problems

1. **Single 940-line C file** - Everything in `main_window_gtk.c`
2. **No code reuse** - Duplicate drawing code for meters, faders
3. **Tight coupling** - UI, logic, and drawing mixed together
4. **Hard to test** - Can't test components in isolation
5. **Not "Ziggified"** - C-style code, not idiomatic Zig

---

## Proposed Architecture

### Directory Structure

```
src/ui/
├── components/              # Reusable UI components (Zig)
│   ├── meter.zig           # Audio level meter component
│   ├── fader.zig           # Volume fader component
│   ├── transport.zig       # Transport controls (play/stop/record)
│   ├── timeline.zig        # Timeline with tracks
│   ├── track.zig           # Single track component
│   └── button.zig          # Styled button component
│
├── drawing/                 # Reusable drawing primitives (Zig)
│   ├── cairo.zig           # Cairo drawing helpers
│   ├── colors.zig          # Tokyo Night color palette
│   ├── grid.zig            # Musical grid drawing
│   ├── waveform.zig        # Optimized waveform rendering
│   └── shapes.zig          # Common shapes (rects, lines, etc.)
│
├── gtk/                     # GTK C bridge (minimal C code)
│   ├── window.c            # Window creation/management
│   ├── widgets.c           # GTK widget wrappers
│   ├── callbacks.c         # Event callback routing
│   └── drawing_area.c      # GtkDrawingArea setup
│
├── layout/                  # Layout management (Zig)
│   ├── box.zig             # Box layout helper
│   ├── panel.zig           # Resizable panel
│   └── mixer.zig           # Mixer layout
│
├── app.zig                  # Main GTK application
├── main_window.zig          # Window composition
└── types.zig                # Shared UI types
```

---

## Component Design Pattern (Zig-idiomatic)

### Example: Meter Component

```zig
// src/ui/components/meter.zig
const std = @import("std");
const cairo = @import("../drawing/cairo.zig");
const colors = @import("../drawing/colors.zig");

pub const MeterConfig = struct {
    width: i32 = 40,
    height: i32 = -1,  // -1 = flexible
    channels: u8 = 1,  // 1=mono, 2=stereo
    orientation: Orientation = .vertical,

    pub const Orientation = enum { vertical, horizontal };
};

pub const MeterState = struct {
    level: f32 = 0.0,
    peak: f32 = 0.0,
    left: f32 = 0.0,   // For stereo
    right: f32 = 0.0,  // For stereo

    pub fn update(self: *MeterState, new_level: f32) void {
        // Smooth attack
        if (new_level > self.level) {
            self.level = new_level;
        } else {
            self.level *= 0.85; // Decay
        }

        // Peak hold
        if (self.level > self.peak) {
            self.peak = self.level;
        } else {
            self.peak *= 0.98; // Slow decay
        }
    }
};

pub const Meter = struct {
    config: MeterConfig,
    state: MeterState,
    widget: *anyopaque,  // GTK widget (opaque)

    pub fn init(allocator: std.mem.Allocator, config: MeterConfig) !*Meter {
        const meter = try allocator.create(Meter);
        meter.* = .{
            .config = config,
            .state = .{},
            .widget = create_gtk_drawing_area(config.width, config.height),
        };
        return meter;
    }

    pub fn draw(self: *const Meter, cr: *cairo.Context, width: i32, height: i32) void {
        // Background
        cr.setSourceRgb(colors.TOKYO_NIGHT_BG_DARK);
        cr.rectangle(0, 0, width, height);
        cr.fill();

        const bar_height = @as(i32, @intFromFloat(self.state.level * @as(f32, @floatFromInt(height))));

        // Green zone (0-70%)
        if (bar_height > 0) {
            const green_height = @min(bar_height, @as(i32, @intFromFloat(@as(f32, @floatFromInt(height)) * 0.7)));
            cr.setSourceRgb(colors.TOKYO_NIGHT_GREEN);
            cr.rectangle(2, height - green_height, width - 4, green_height);
            cr.fill();
        }

        // Yellow zone (70-90%)
        if (bar_height > @as(i32, @intFromFloat(@as(f32, @floatFromInt(height)) * 0.7))) {
            const yellow_start = @as(i32, @intFromFloat(@as(f32, @floatFromInt(height)) * 0.7));
            const yellow_height = @min(bar_height - yellow_start, @as(i32, @intFromFloat(@as(f32, @floatFromInt(height)) * 0.2)));
            cr.setSourceRgb(colors.TOKYO_NIGHT_YELLOW);
            cr.rectangle(2, height - yellow_start - yellow_height, width - 4, yellow_height);
            cr.fill();
        }

        // Red zone (90-100%)
        if (bar_height > @as(i32, @intFromFloat(@as(f32, @floatFromInt(height)) * 0.9))) {
            const red_start = @as(i32, @intFromFloat(@as(f32, @floatFromInt(height)) * 0.9));
            const red_height = bar_height - red_start;
            cr.setSourceRgb(colors.TOKYO_NIGHT_RED);
            cr.rectangle(2, height - red_start - red_height, width - 4, red_height);
            cr.fill();
        }

        // Peak indicator
        if (self.state.peak > 0.01) {
            const peak_y = height - @as(i32, @intFromFloat(self.state.peak * @as(f32, @floatFromInt(height))));
            cr.setSourceRgb(colors.TOKYO_NIGHT_CYAN);
            cr.setLineWidth(2.0);
            cr.moveTo(0, @floatFromInt(peak_y));
            cr.lineTo(@floatFromInt(width), @floatFromInt(peak_y));
            cr.stroke();
        }
    }

    pub fn deinit(self: *Meter, allocator: std.mem.Allocator) void {
        destroy_gtk_widget(self.widget);
        allocator.destroy(self);
    }
};

// Minimal GTK bridge
extern fn create_gtk_drawing_area(width: i32, height: i32) *anyopaque;
extern fn destroy_gtk_widget(widget: *anyopaque) void;
```

---

## Drawing Primitives

### Example: Colors Module

```zig
// src/ui/drawing/colors.zig
const std = @import("std");

pub const Color = struct {
    r: f64,
    g: f64,
    b: f64,
    a: f64 = 1.0,

    pub fn fromHex(hex: u32) Color {
        return .{
            .r = @as(f64, @floatFromInt((hex >> 16) & 0xFF)) / 255.0,
            .g = @as(f64, @floatFromInt((hex >> 8) & 0xFF)) / 255.0,
            .b = @as(f64, @floatFromInt(hex & 0xFF)) / 255.0,
        };
    }

    pub fn withAlpha(self: Color, alpha: f64) Color {
        return .{
            .r = self.r,
            .g = self.g,
            .b = self.b,
            .a = alpha,
        };
    }
};

// Tokyo Night Palette
pub const TOKYO_NIGHT_BG = Color.fromHex(0x1a1b26);
pub const TOKYO_NIGHT_BG_DARK = Color.fromHex(0x16161e);
pub const TOKYO_NIGHT_BG_HIGHLIGHT = Color.fromHex(0x292e42);
pub const TOKYO_NIGHT_FG = Color.fromHex(0xc0caf5);
pub const TOKYO_NIGHT_COMMENT = Color.fromHex(0x565f89);
pub const TOKYO_NIGHT_CYAN = Color.fromHex(0x7dcfff);
pub const TOKYO_NIGHT_GREEN = Color.fromHex(0x9ece6a);
pub const TOKYO_NIGHT_ORANGE = Color.fromHex(0xff9e64);
pub const TOKYO_NIGHT_PURPLE = Color.fromHex(0xbb9af7);
pub const TOKYO_NIGHT_RED = Color.fromHex(0xf7768e);
pub const TOKYO_NIGHT_YELLOW = Color.fromHex(0xe0af68);
pub const TOKYO_NIGHT_BLUE = Color.fromHex(0x7aa2f7);
```

---

## GTK C Bridge (Minimal)

### Example: Widget Creation

```c
// src/ui/gtk/widgets.c
#include <gtk/gtk.h>

// Opaque pointers for Zig
typedef struct DrawingAreaContext DrawingAreaContext;

DrawingAreaContext* create_gtk_drawing_area(int width, int height) {
    GtkWidget *area = gtk_drawing_area_new();
    gtk_widget_set_size_request(area, width, height);
    if (height < 0) {
        gtk_widget_set_vexpand(area, TRUE);
        gtk_widget_set_valign(area, GTK_ALIGN_FILL);
    }
    return (DrawingAreaContext*)area;
}

void destroy_gtk_widget(DrawingAreaContext *ctx) {
    // GTK handles cleanup automatically in most cases
    (void)ctx;
}

void gtk_drawing_area_set_draw_callback(
    DrawingAreaContext *ctx,
    void (*callback)(void *cr, int width, int height, void *user_data),
    void *user_data
) {
    gtk_drawing_area_set_draw_func(
        GTK_DRAWING_AREA(ctx),
        (GtkDrawingAreaDrawFunc)callback,
        user_data,
        NULL
    );
}
```

---

## Composition in Main Window

```zig
// src/ui/main_window.zig
const std = @import("std");
const Meter = @import("components/meter.zig").Meter;
const Fader = @import("components/fader.zig").Fader;
const Transport = @import("components/transport.zig").Transport;
const Timeline = @import("components/timeline.zig").Timeline;

pub const MainWindow = struct {
    allocator: std.mem.Allocator,

    // Components
    transport: *Transport,
    timeline: *Timeline,
    track_meters: [4]*Meter,
    track_faders: [4]*Fader,
    master_meter: *Meter,
    master_fader: *Fader,

    pub fn init(allocator: std.mem.Allocator) !*MainWindow {
        const win = try allocator.create(MainWindow);
        win.allocator = allocator;

        // Create components
        win.transport = try Transport.init(allocator, .{});
        win.timeline = try Timeline.init(allocator, .{ .tracks = 4 });
        win.master_meter = try Meter.init(allocator, .{ .channels = 2 });
        win.master_fader = try Fader.init(allocator, .{ .value = 0.75 });

        // Create track components
        for (&win.track_meters, 0..) |*meter, i| {
            _ = i;
            meter.* = try Meter.init(allocator, .{ .channels = 1 });
        }

        for (&win.track_faders, 0..) |*fader, i| {
            _ = i;
            fader.* = try Fader.init(allocator, .{ .value = 0.75 });
        }

        return win;
    }

    pub fn update(self: *MainWindow, dt: f32) void {
        self.transport.update(dt);
        self.timeline.update(dt);

        for (self.track_meters) |meter| {
            meter.state.update(get_track_level());
        }

        self.master_meter.state.update(get_master_level());
    }

    pub fn deinit(self: *MainWindow) void {
        self.transport.deinit(self.allocator);
        self.timeline.deinit(self.allocator);
        self.master_meter.deinit(self.allocator);
        self.master_fader.deinit(self.allocator);

        for (self.track_meters) |meter| {
            meter.deinit(self.allocator);
        }

        for (self.track_faders) |fader| {
            fader.deinit(self.allocator);
        }

        self.allocator.destroy(self);
    }
};
```

---

## Benefits of This Architecture

### 1. **Reusability**
- `Meter` component can be used for tracks, master, sends, etc.
- `Fader` component reusable across all channels
- Drawing primitives shared everywhere

### 2. **Testability**
```zig
test "meter updates correctly" {
    var state = MeterState{};
    state.update(0.8);
    try std.testing.expectApprox(0.8, state.level, 0.01);
}
```

### 3. **Type Safety (Zig)** - No void pointers, clear ownership
- Allocator-based memory management
- Compile-time checks

### 4. **Modularity**
- Each component in its own file
- Clear dependencies
- Easy to swap implementations

### 5. **Performance**
- Components can be optimized independently
- Minimal C bridge
- Zero-cost abstractions

---

## Migration Plan

### Phase 1: Extract Drawing Primitives
1. Create `colors.zig`
2. Create `cairo.zig` wrapper
3. Create `grid.zig` for timeline grid

### Phase 2: Extract Components
1. `meter.zig` - Pull meter drawing from C
2. `fader.zig` - Pull fader logic
3. `transport.zig` - Transport controls
4. `timeline.zig` - Timeline rendering

### Phase 3: Refactor GTK C Bridge
1. Minimize C code to widget creation only
2. Move all logic to Zig
3. Use extern for GTK calls

### Phase 4: Composition
1. Build `main_window.zig` from components
2. Replace current monolithic C file
3. Update `app.zig` to use new structure

---

## File Size Target

**Current:**
- `main_window_gtk.c`: 940 lines

**After Refactor:**
- Each component: ~100-200 lines
- Drawing primitives: ~50-100 lines each
- GTK bridge: ~300 lines total
- Main window composition: ~200 lines

**Result:** Better organization, more reusable, easier to maintain

---

## Timeline

1. **Week 1:** Drawing primitives + Cairo wrapper
2. **Week 2:** Meter and Fader components
3. **Week 3:** Transport and Timeline components
4. **Week 4:** Integration and testing

---

**Status:** Planning Complete
**Next Step:** Implement `colors.zig` and `cairo.zig`
