//! How the window identifies itself to the desktop. Pure Zig, no Raven, so src/ui_abi_test.zig can check that it
//! matches what `seridian doctor` writes (src/system/desktop.zig `app_wm_class`: Hyprland rules, StartupWMClass).

/// X11 WM_CLASS res_name and res_class (XWayland reports it as the app id).
pub const window_class: [:0]const u8 = "seridian-studio";
