/// Zig wrapper for Cairo drawing API
/// Provides type-safe, idiomatic Zig interface to cairo_t
const std = @import("std");
const colors = @import("colors.zig");
const Color = colors.Color;

/// Opaque cairo context type
pub const Context = opaque {
    /// Set source color from RGB values
    pub fn setSourceRgb(self: *Context, r: f64, g: f64, b: f64) void {
        cairo_set_source_rgb(@ptrCast(self), r, g, b);
    }

    /// Set source color from RGBA values
    pub fn setSourceRgba(self: *Context, r: f64, g: f64, b: f64, a: f64) void {
        cairo_set_source_rgba(@ptrCast(self), r, g, b, a);
    }

    /// Set source from Color struct
    pub fn setColor(self: *Context, color: Color) void {
        if (color.a < 1.0) {
            self.setSourceRgba(color.r, color.g, color.b, color.a);
        } else {
            self.setSourceRgb(color.r, color.g, color.b);
        }
    }

    /// Draw a filled rectangle
    pub fn fillRect(self: *Context, x: f64, y: f64, width: f64, height: f64, color: Color) void {
        self.setColor(color);
        cairo_rectangle(@ptrCast(self), x, y, width, height);
        cairo_fill(@ptrCast(self));
    }

    /// Draw a stroked rectangle
    pub fn strokeRect(self: *Context, x: f64, y: f64, width: f64, height: f64, color: Color, line_width: f64) void {
        self.setColor(color);
        self.setLineWidth(line_width);
        cairo_rectangle(@ptrCast(self), x, y, width, height);
        cairo_stroke(@ptrCast(self));
    }

    /// Draw a line
    pub fn drawLine(self: *Context, x1: f64, y1: f64, x2: f64, y2: f64, color: Color, line_width: f64) void {
        self.setColor(color);
        self.setLineWidth(line_width);
        cairo_move_to(@ptrCast(self), x1, y1);
        cairo_line_to(@ptrCast(self), x2, y2);
        cairo_stroke(@ptrCast(self));
    }

    /// Set line width
    pub fn setLineWidth(self: *Context, width: f64) void {
        cairo_set_line_width(@ptrCast(self), width);
    }

    /// Move to point (start new path)
    pub fn moveTo(self: *Context, x: f64, y: f64) void {
        cairo_move_to(@ptrCast(self), x, y);
    }

    /// Line to point
    pub fn lineTo(self: *Context, x: f64, y: f64) void {
        cairo_line_to(@ptrCast(self), x, y);
    }

    /// Rectangle path
    pub fn rectangle(self: *Context, x: f64, y: f64, width: f64, height: f64) void {
        cairo_rectangle(@ptrCast(self), x, y, width, height);
    }

    /// Fill current path
    pub fn fill(self: *Context) void {
        cairo_fill(@ptrCast(self));
    }

    /// Stroke current path
    pub fn stroke(self: *Context) void {
        cairo_stroke(@ptrCast(self));
    }

    /// Close current path
    pub fn closePath(self: *Context) void {
        cairo_close_path(@ptrCast(self));
    }

    /// Start new path
    pub fn newPath(self: *Context) void {
        cairo_new_path(@ptrCast(self));
    }

    /// Save context state
    pub fn save(self: *Context) void {
        cairo_save(@ptrCast(self));
    }

    /// Restore context state
    pub fn restore(self: *Context) void {
        cairo_restore(@ptrCast(self));
    }

    /// Set clipping region
    pub fn clip(self: *Context) void {
        cairo_clip(@ptrCast(self));
    }

    /// Reset clipping region
    pub fn resetClip(self: *Context) void {
        cairo_reset_clip(@ptrCast(self));
    }

    /// Set font size
    pub fn setFontSize(self: *Context, size: f64) void {
        cairo_set_font_size(@ptrCast(self), size);
    }

    /// Show text at current position
    pub fn showText(self: *Context, text: [*:0]const u8) void {
        cairo_show_text(@ptrCast(self), text);
    }

    /// Select font face
    pub fn selectFontFace(self: *Context, family: [*:0]const u8, slant: FontSlant, weight: FontWeight) void {
        cairo_select_font_face(@ptrCast(self), family, @backingInt(slant), @backingInt(weight));
    }

    /// Check cairo status for errors
    pub fn status(self: *Context) Status {
        return @fromBackingInt(@intCast(cairo_status(@ptrCast(self))));
    }

    /// Get status string
    pub fn statusToString(s: Status) [*:0]const u8 {
        return cairo_status_to_string(@backingInt(s));
    }
};

pub const FontSlant = enum(c_int) {
    normal = 0,
    italic = 1,
    oblique = 2,
};

pub const FontWeight = enum(c_int) {
    normal = 0,
    bold = 1,
};

pub const Status = enum(c_int) {
    success = 0,
    no_memory = 1,
    invalid_restore = 2,
    invalid_pop_group = 3,
    no_current_point = 4,
    invalid_matrix = 5,
    invalid_status = 6,
    null_pointer = 7,
    invalid_string = 8,
    invalid_path_data = 9,
    read_error = 10,
    write_error = 11,
    surface_finished = 12,
    surface_type_mismatch = 13,
    pattern_type_mismatch = 14,
    invalid_content = 15,
    invalid_format = 16,
    invalid_visual = 17,
    file_not_found = 18,
    invalid_dash = 19,
    invalid_dsc_comment = 20,
    invalid_index = 21,
    clip_not_representable = 22,
    _,
};

// Cairo C API bindings
extern fn cairo_set_source_rgb(cr: *anyopaque, r: f64, g: f64, b: f64) void;
extern fn cairo_set_source_rgba(cr: *anyopaque, r: f64, g: f64, b: f64, a: f64) void;
extern fn cairo_rectangle(cr: *anyopaque, x: f64, y: f64, width: f64, height: f64) void;
extern fn cairo_fill(cr: *anyopaque) void;
extern fn cairo_stroke(cr: *anyopaque) void;
extern fn cairo_set_line_width(cr: *anyopaque, width: f64) void;
extern fn cairo_move_to(cr: *anyopaque, x: f64, y: f64) void;
extern fn cairo_line_to(cr: *anyopaque, x: f64, y: f64) void;
extern fn cairo_close_path(cr: *anyopaque) void;
extern fn cairo_new_path(cr: *anyopaque) void;
extern fn cairo_save(cr: *anyopaque) void;
extern fn cairo_restore(cr: *anyopaque) void;
extern fn cairo_clip(cr: *anyopaque) void;
extern fn cairo_reset_clip(cr: *anyopaque) void;
extern fn cairo_set_font_size(cr: *anyopaque, size: f64) void;
extern fn cairo_show_text(cr: *anyopaque, text: [*:0]const u8) void;
extern fn cairo_select_font_face(cr: *anyopaque, family: [*:0]const u8, slant: c_int, weight: c_int) void;
extern fn cairo_status(cr: *anyopaque) c_int;
extern fn cairo_status_to_string(status: c_int) [*:0]const u8;
