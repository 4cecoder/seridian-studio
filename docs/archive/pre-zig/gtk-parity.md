# GTK parity (src/uikit)

Status of the GTK gap items. Test status is the output of `zig test src/uikit/<file>.zig`
(counts include the shared theme.zig tests). Screenshot status is what was seen in
`/tmp/claude-1001/uikit-final.png`, captured from `uikit-demo` under `DISPLAY=:0`.

| GTK gap item | uikit widget | Test status | Screenshot status |
| --- | --- | --- | --- |
| Drag and drop | `drag_drop.zig` | All 22 tests passed | Visible: "DRAG AND DROP" glass card with a source surface and a target surface. Bottom edge clipped by the window. No live drag shown. |
| List view | `list_view.zig` | All 24 tests passed | Not in demo (rejected this sprint) |
| Tree view | `tree_view.zig` | All 28 tests passed | Not in demo (rejected this sprint) |
| Context menu | `context_menu.zig` | All 19 tests passed | Not in demo (rejected this sprint) |
| Modal dialog | `modal_dialog.zig` | All 24 tests passed | Not in demo (rejected this sprint) |
| Colour picker | `color_picker.zig` | All 22 tests passed | Not in demo (rejected this sprint) |
| Curve plot | `curve_plot.zig` | All 15 tests passed | Not in demo (rejected this sprint) |
| Splash | `splash.zig` | All 17 tests passed | Not in demo (rejected this sprint) |

## Notes

- The demo window came up at 454x492 on this display (xdotool windowsize did not change it),
  so the demo's lower part was clipped and the status line was not visible.
- The demo does not start a drag: Rdrag_begin needs a pointer-event hook that is not wired.
  Drop-callback behaviour is only covered by the pure-logic unit tests.
- Existing layout overlaps in the top-left of the demo (Flat/Disabled buttons vs the VALUES
  slider) are visible in the screenshot at this small size.
