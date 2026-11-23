// Translated to Zig from vendor/raven/src/platform/x11/x11_keys.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - platform/x11/x11_keys.c
// X11 key symbols and modifier masks to Raven keys.

const raven = @import("raven");
const x11 = @import("x11_internal_h.zig");

const KeySym = x11.KeySym;

// The XK_ values are declared here instead of importing <X11/keysym.h> (the C file includes it):
// they are copied from keysymdef.h, the XK_ names are kept as in C.
const XK_space: KeySym = 0x0020;
const XK_apostrophe: KeySym = 0x0027;
const XK_comma: KeySym = 0x002c;
const XK_minus: KeySym = 0x002d;
const XK_period: KeySym = 0x002e;
const XK_slash: KeySym = 0x002f;
const XK_0: KeySym = 0x0030;
const XK_9: KeySym = 0x0039;
const XK_semicolon: KeySym = 0x003b;
const XK_equal: KeySym = 0x003d;
const XK_A: KeySym = 0x0041;
const XK_Z: KeySym = 0x005a;
const XK_bracketleft: KeySym = 0x005b;
const XK_backslash: KeySym = 0x005c;
const XK_bracketright: KeySym = 0x005d;
const XK_grave: KeySym = 0x0060;
const XK_a: KeySym = 0x0061;
const XK_z: KeySym = 0x007a;

const XK_BackSpace: KeySym = 0xff08;
const XK_Tab: KeySym = 0xff09;
const XK_Return: KeySym = 0xff0d;
const XK_Pause: KeySym = 0xff13;
const XK_Escape: KeySym = 0xff1b;
const XK_Home: KeySym = 0xff50;
const XK_Left: KeySym = 0xff51;
const XK_Up: KeySym = 0xff52;
const XK_Right: KeySym = 0xff53;
const XK_Down: KeySym = 0xff54;
const XK_Page_Up: KeySym = 0xff55;
const XK_Page_Down: KeySym = 0xff56;
const XK_End: KeySym = 0xff57;
const XK_Print: KeySym = 0xff61;
const XK_Insert: KeySym = 0xff63;
const XK_Menu: KeySym = 0xff67;
const XK_KP_Enter: KeySym = 0xff8d;
const XK_KP_Home: KeySym = 0xff95;
const XK_KP_Left: KeySym = 0xff96;
const XK_KP_Up: KeySym = 0xff97;
const XK_KP_Right: KeySym = 0xff98;
const XK_KP_Down: KeySym = 0xff99;
const XK_KP_Page_Up: KeySym = 0xff9a;
const XK_KP_Page_Down: KeySym = 0xff9b;
const XK_KP_End: KeySym = 0xff9c;
const XK_KP_Begin: KeySym = 0xff9d;
const XK_KP_Insert: KeySym = 0xff9e;
const XK_KP_Delete: KeySym = 0xff9f;
const XK_KP_Multiply: KeySym = 0xffaa;
const XK_KP_Add: KeySym = 0xffab;
const XK_KP_Subtract: KeySym = 0xffad;
const XK_KP_Decimal: KeySym = 0xffae;
const XK_KP_Divide: KeySym = 0xffaf;
const XK_KP_0: KeySym = 0xffb0;
const XK_KP_9: KeySym = 0xffb9;
const XK_F1: KeySym = 0xffbe;
const XK_F12: KeySym = 0xffc9;
const XK_Shift_L: KeySym = 0xffe1;
const XK_Shift_R: KeySym = 0xffe2;
const XK_Control_L: KeySym = 0xffe3;
const XK_Control_R: KeySym = 0xffe4;
const XK_Caps_Lock: KeySym = 0xffe5;
const XK_Meta_L: KeySym = 0xffe7;
const XK_Meta_R: KeySym = 0xffe8;
const XK_Alt_L: KeySym = 0xffe9;
const XK_Alt_R: KeySym = 0xffea;
const XK_Super_L: KeySym = 0xffeb;
const XK_Super_R: KeySym = 0xffec;
const XK_ISO_Left_Tab: KeySym = 0xfe20;
const XK_ISO_Level3_Shift: KeySym = 0xfe03;
const XK_Delete: KeySym = 0xffff;

// X.h modifier masks (ShiftMask, ControlMask, Mod1Mask, Mod4Mask)
const ShiftMask: c_uint = 1 << 0;
const ControlMask: c_uint = 1 << 2;
const Mod1Mask: c_uint = 1 << 3;
const Mod4Mask: c_uint = 1 << 6;

export fn rvn_x11_translate_keysym(symbol: KeySym) raven.RKey {
    // Latin letters and digits share their codes with ASCII
    if (symbol >= XK_a and symbol <= XK_z) return @intCast(raven.R_KEY_A + @as(c_int, @intCast(symbol - XK_a)));
    if (symbol >= XK_A and symbol <= XK_Z) return @intCast(raven.R_KEY_A + @as(c_int, @intCast(symbol - XK_A)));
    if (symbol >= XK_0 and symbol <= XK_9) return @intCast(raven.R_KEY_0 + @as(c_int, @intCast(symbol - XK_0)));
    if (symbol >= XK_F1 and symbol <= XK_F12) return @intCast(raven.R_KEY_F1 + @as(c_int, @intCast(symbol - XK_F1)));
    if (symbol >= XK_KP_0 and symbol <= XK_KP_9) return @intCast(raven.R_KEY_KP_0 + @as(c_int, @intCast(symbol - XK_KP_0)));

    switch (symbol) {
        XK_space => return @intCast(raven.R_KEY_SPACE),
        XK_apostrophe => return @intCast(raven.R_KEY_APOSTROPHE),
        XK_comma => return @intCast(raven.R_KEY_COMMA),
        XK_minus => return @intCast(raven.R_KEY_MINUS),
        XK_period => return @intCast(raven.R_KEY_PERIOD),
        XK_slash => return @intCast(raven.R_KEY_SLASH),
        XK_semicolon => return @intCast(raven.R_KEY_SEMICOLON),
        XK_equal => return @intCast(raven.R_KEY_EQUAL),
        XK_bracketleft => return @intCast(raven.R_KEY_LEFT_BRACKET),
        XK_backslash => return @intCast(raven.R_KEY_BACKSLASH),
        XK_bracketright => return @intCast(raven.R_KEY_RIGHT_BRACKET),
        XK_grave => return @intCast(raven.R_KEY_GRAVE),

        XK_Escape => return @intCast(raven.R_KEY_ESCAPE),
        XK_Return => return @intCast(raven.R_KEY_ENTER),
        XK_Tab => return @intCast(raven.R_KEY_TAB),
        XK_ISO_Left_Tab => return @intCast(raven.R_KEY_TAB),
        XK_BackSpace => return @intCast(raven.R_KEY_BACKSPACE),
        XK_Insert => return @intCast(raven.R_KEY_INSERT),
        XK_Delete => return @intCast(raven.R_KEY_DELETE),
        XK_Right => return @intCast(raven.R_KEY_RIGHT),
        XK_Left => return @intCast(raven.R_KEY_LEFT),
        XK_Down => return @intCast(raven.R_KEY_DOWN),
        XK_Up => return @intCast(raven.R_KEY_UP),
        XK_Page_Up => return @intCast(raven.R_KEY_PAGE_UP),
        XK_Page_Down => return @intCast(raven.R_KEY_PAGE_DOWN),
        XK_Home => return @intCast(raven.R_KEY_HOME),
        XK_End => return @intCast(raven.R_KEY_END),
        XK_Caps_Lock => return @intCast(raven.R_KEY_CAPS_LOCK),
        XK_Print => return @intCast(raven.R_KEY_PRINT_SCREEN),
        XK_Pause => return @intCast(raven.R_KEY_PAUSE),
        XK_Menu => return @intCast(raven.R_KEY_MENU),

        // keypad: the same keys with and without Num Lock
        XK_KP_Insert => return @intCast(raven.R_KEY_KP_0),
        XK_KP_End => return @intCast(raven.R_KEY_KP_1),
        XK_KP_Down => return @intCast(raven.R_KEY_KP_2),
        XK_KP_Page_Down => return @intCast(raven.R_KEY_KP_3),
        XK_KP_Left => return @intCast(raven.R_KEY_KP_4),
        XK_KP_Begin => return @intCast(raven.R_KEY_KP_5),
        XK_KP_Right => return @intCast(raven.R_KEY_KP_6),
        XK_KP_Home => return @intCast(raven.R_KEY_KP_7),
        XK_KP_Up => return @intCast(raven.R_KEY_KP_8),
        XK_KP_Page_Up => return @intCast(raven.R_KEY_KP_9),
        XK_KP_Decimal => return @intCast(raven.R_KEY_KP_DECIMAL),
        XK_KP_Delete => return @intCast(raven.R_KEY_KP_DECIMAL),
        XK_KP_Divide => return @intCast(raven.R_KEY_KP_DIVIDE),
        XK_KP_Multiply => return @intCast(raven.R_KEY_KP_MULTIPLY),
        XK_KP_Subtract => return @intCast(raven.R_KEY_KP_SUBTRACT),
        XK_KP_Add => return @intCast(raven.R_KEY_KP_ADD),
        XK_KP_Enter => return @intCast(raven.R_KEY_KP_ENTER),

        XK_Shift_L => return @intCast(raven.R_KEY_LEFT_SHIFT),
        XK_Control_L => return @intCast(raven.R_KEY_LEFT_CTRL),
        XK_Alt_L => return @intCast(raven.R_KEY_LEFT_ALT),
        XK_Meta_L => return @intCast(raven.R_KEY_LEFT_ALT),
        XK_Super_L => return @intCast(raven.R_KEY_LEFT_SUPER),
        XK_Shift_R => return @intCast(raven.R_KEY_RIGHT_SHIFT),
        XK_Control_R => return @intCast(raven.R_KEY_RIGHT_CTRL),
        XK_Alt_R => return @intCast(raven.R_KEY_RIGHT_ALT),
        XK_Meta_R => return @intCast(raven.R_KEY_RIGHT_ALT),
        XK_ISO_Level3_Shift => return @intCast(raven.R_KEY_RIGHT_ALT),
        XK_Super_R => return @intCast(raven.R_KEY_RIGHT_SUPER),
        else => return @intCast(raven.R_KEY_UNKNOWN),
    }
}

export fn rvn_x11_translate_modifiers(state: c_uint) u32 {
    var modifiers: u32 = 0;
    if ((state & ShiftMask) != 0) modifiers |= @as(u32, @intCast(raven.R_MOD_SHIFT));
    if ((state & ControlMask) != 0) modifiers |= @as(u32, @intCast(raven.R_MOD_CTRL));
    if ((state & Mod1Mask) != 0) modifiers |= @as(u32, @intCast(raven.R_MOD_ALT));
    if ((state & Mod4Mask) != 0) modifiers |= @as(u32, @intCast(raven.R_MOD_SUPER));
    return modifiers;
}
