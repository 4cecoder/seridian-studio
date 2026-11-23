# UI kit (src/uikit)

Spec and status of the liquid-glass widget set. Four family modules are built
(basic, value, input, container). Label and spin_box are specified below but not
built yet.

## Approach

Retained mode first. Every widget is a Raven widget made with `Rwidget_create`
(or an `Rxxx_create` shortcut) and placed in the tree. Colours, radii and
materials are set through Raven's style API, not painted by hand. Immediate mode
(`Rcustom_set_paint_callback` + `Rdraw_*`) is used only for something that
repaints every frame. No uikit widget needs that yet. The existing knob and fader
already do and stay as they are. If a widget adopts immediate mode, its file
header must say so and why.

## Modules

| File | Role |
| --- | --- |
| `raven.zig` | Every Raven name, enum value and extern used by uikit. Enum values are checked against `vendor/raven/include/raven/*.h`. |
| `theme.zig` | Colour, radius, font and alpha tokens. Pure, with tests. |
| `style.zig` | Applies the tokens to Raven widgets: glass theme, glass borders, labels, metrics, `setColor`. |
| `basic.zig` | Button (default, primary, flat), toggle switch, checkbox, radio group, separator. |
| `value.zig` | Slider, stepper, progress bar, segmented control. |
| `input.zig` | Text field, search field (debounced), combo box, tab bar. |
| `container.zig` | Glass card, expander, tooltip, scroll area. |
| `drag_drop.zig`, `list_view.zig`, `tree_view.zig`, `context_menu.zig`, `modal_dialog.zig`, `color_picker.zig`, `curve_plot.zig`, `splash.zig` | Larger widgets, each with its own tests. |
| `demo.zig` | Window that shows the families inside a glass card (`zig build uikit-demo`). |

## Style (src/uikit/theme.zig)

| Token | Value |
| --- | --- |
| Base | `bg_void` #05060D, `bg_deep` #0A0B1A, `bg_panel` #10122A (from `src/ui/palette.h`) |
| Accent (active state) | `accent` #00F0FF; violet and magenta as secondaries |
| Text | `text` #E6F7FF (>= 7:1 on panel), `text_muted` (>= 4.5:1). Never below 12 px |
| Glass fill alpha | 0.55 base, 0.65 raised, 0.75 overlay |
| Highlight | 1 px, white at 0.18 alpha, top edge |
| Shadow | black 0.45, blur 18, offset y 6 |
| Radius | 10 to 14 (control 10, popup 12, panel 14) |
| Blur behind panels | `Rbackground_blur` with `R_BLUR_GLASS`, `Rborder_set_material` |
| Transitions | 120 ms |

Known gap: Raven animates with springs (`R_MOTION_*`, `Rset_animation_speed`) and
has no per-widget millisecond duration. `transition_ms` is the target; we pick
the closest motion preset (`R_MOTION_SNAPPY`) and tune later.

## Widgets

Built (in the family module):

| Widget | Module | Raven calls |
| --- | --- | --- |
| button | basic | `Rbutton_create/set_style/set_clicked_callback`, `Rwidget_set_color/metric/material` |
| toggle switch | basic | `Rcheckbox_create/set_style(R_CHECKBOX_SWITCH)/set_checked/set_changed_callback` |
| checkbox | basic | `Rcheckbox_create/set_style(R_CHECKBOX_CHECK)/set_checked/set_changed_callback` |
| radio group | basic | Box of `Rcheckbox` with `R_CHECKBOX_RADIO`, `Rwidget_add_child` |
| separator | basic | `Rseparator_set_orientation`, `Rwidget_set_color(SEPARATOR)` |
| slider | value | `Rslider_set_range/value/step/orientation/changed_callback` |
| stepper | value | HBox of two flat `Rbutton` around an `Rlabel` |
| progress | value | `Rprogress_bar_set_value/get_value` on a glass Border |
| segmented | value | Border + HBox of `Rbutton`, active one `R_BUTTON_PRIMARY` |
| text field | input | Border + `Rtext_input_set_text/placeholder/max_length/changed_callback` |
| search field | input | Border + `Rtext_input`, flat clear `Rbutton`, `Rtimer_create` debounce |
| combo box | input | `Rcombo_box_add_item/set_selected/set_changed_callback` |
| tab bar | input | `Rtab_view_add_tab/set_active/set_changed_callback` |
| card | container | `Rborder_*` glass material + `Rbackground_blur` |
| expander | container | `Rexpander_set_title/set_expanded/is_expanded/set_changed_callback` |
| tooltip | container | `Rwidget_set_tooltip`, `R_COLOR_TOOLTIP`, `R_COLOR_TOOLTIP_TEXT` |
| scroll area | container | `Rscroll_box_set_orientation/set_scroll_both`, `Rpanel_set_spacing` |

Not built yet. The Raven type exists and the uikit code uses `Rlabel` directly
(value readouts, the demo status line), but there is no standalone module:

| Widget | Raven type | Spec (from the removed single-widget stubs) |
| --- | --- | --- |
| label | `Rlabel` | Roles body, title, muted. Defaults: body role, font 13, left aligned. Font below 12 is clamped to 12 (muted and title too). Muted uses `theme.text_muted`, the others `theme.text`. |
| spin box | `Rspin_box` | `Rspin_box_set_range/value/step/decimals/changed_callback`. Defaults: 0..100, step 1, decimals 0. Value clamped into range. Step <= 0 becomes 1. Decimals clamped to 0..6. |

The 1 px top highlight is not a Border feature. Plan: try `R_METRIC_GLASS_RIM`
first (it is set by `style.styleGlassBorder` and the input and value glass
surfaces). Only if that is not enough, the card gets one Custom child that draws
the line with `Rdraw_line` (the single immediate-mode exception, to be marked in
`container.zig`).

## Tests

Each family module has real tests for its public `Config` types (defaults,
clamping) and its pure helpers. Raven calls are not linked into `zig test`, so the
Raven-facing code is checked by compiling it. To type-check a module without
running its tests, use a probe file in `src/uikit/` that calls
`std.testing.refAllDecls` on the module, then run it with `zig test -fno-emit-bin -lc`.
Delete the probe afterwards.

```sh
zig test src/uikit/theme.zig
zig test src/uikit/style.zig
zig test src/uikit/basic.zig
zig test src/uikit/value.zig
zig test src/uikit/input.zig
zig test src/uikit/container.zig
```

The extern signatures in `raven.zig` are checked by reading against the headers
and by the C probe, not by linking: nothing in the unit tests calls them.

## Demo layout notes

- `Rwidget_set_metric(.spacing)` does not space vbox/hbox children; call `Rpanel_set_spacing` as well.
- The demo window may be resized by the window manager (960x860 requested, 918x492 received on a tiling setup), so the demo uses three compact columns.
