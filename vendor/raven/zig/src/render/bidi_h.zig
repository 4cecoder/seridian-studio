// Translated to Zig from vendor/raven/src/render/bidi.h (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - render/bidi.h
// Right-to-left text: visual order and Arabic shapes (render/bidi.c).

/// R_TRUE when the line holds right-to-left characters (or bidi controls): it must be reordered to be drawn.
pub extern fn rvn_bidi_needed(text: [*c]const u8, length: c_int) c_int;
/// R_TRUE when the first strong character of the text is right to left.
pub extern fn rvn_bidi_paragraph_rtl(text: [*c]const u8, length: c_int) c_int;
/// The line in the order it is drawn, Arabic shaped, as new UTF-8 (rvn_free).
pub extern fn rvn_bidi_visual(text: [*c]const u8, length: c_int, out_length: [*c]c_int) [*c]u8;
