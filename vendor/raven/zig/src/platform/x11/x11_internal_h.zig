// Translated to Zig from vendor/raven/src/platform/x11/x11_internal.h (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - platform/x11/x11_internal.h
// Shared by the files of the X11 platform.
//
// <X11/Xlib.h> is not available: KeySym is `XID`, an `unsigned long`.
// The Xlib declarations x11_platform.c needs are in ../externs.zig.

const raven = @import("raven");

pub const KeySym = c_ulong;

/// Maps an X11 key symbol to a Raven key, or R_KEY_UNKNOWN (x11_keys.c).
pub extern fn rvn_x11_translate_keysym(symbol: KeySym) raven.RKey;

/// Converts the modifier bits of an X11 event state (x11_keys.c).
pub extern fn rvn_x11_translate_modifiers(state: c_uint) u32;
