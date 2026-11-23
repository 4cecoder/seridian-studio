# Raven dependency

This directory vendors [Raven](https://github.com/oscar-soirey/Raven), an Apache-2.0 C GUI library.

- Upstream commit: `c4410662723bf0eec633a36a7c2e4d69490325cf`
- Included `LICENSE` and `NOTICE` are preserved from upstream.
- Seridian Studio uses Raven's C API and the X11/Vulkan backend on Linux.

## Seridian modifications

- `zig/` is a strangler-style translation of Raven's C sources to Zig (see `zig/PORTING.md`). `zig/ported.txt`
  lists the C sources that are replaced by their Zig translation; `cmake/RavenZig.cmake` (included from
  `CMakeLists.txt`) builds them into `libraven.a`. With an empty `zig/ported.txt` (or `-DRAVEN_ZIG=OFF`) the
  library is the unmodified C build. Translated files carry the header
  "Translated to Zig from vendor/raven/src/<path> (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation."
- API addition (not upstream): `Rset_window_class` / `Rget_window_class` (`include/raven/raven_window.h`,
  `zig/src/widget/window.zig`) name the X11 WM_CLASS of the windows created afterwards (default "raven");
  `rvn_pwindow_desc_t` gained `wm_name` / `wm_class`. Tested by `zig/tests/window_class_test.zig` (check.sh step 5b).
- `tools/ravenc` is a Zig program (`ravenc.zig`, built with `zig build-exe` by `tools/ravenc/CMakeLists.txt`); the C
  original is `deprecated-c/tools/ravenc/ravenc.c`, which the test `ravenc_matches_c` (`tools/ravenc/compare.cmake`)
  builds and compares with, byte for byte, on every Raven .xml / .xmlc* file and `tools/ravenc/tests/`.
- Raven Web (`web/src/*.c`) is translated like the library: `zig/src/web/*.zig`, listed in `zig/ported.txt` as
  `web/src/<name>.c` (C originals in `deprecated-c/web/`). `web/tests/test_web.zig` is the translated test.
  `zig/check.sh --web` builds the library with RAVEN_BUILD_WEB=ON and checks it against `baseline/*-web.<OS>.txt`.
- Layout checks (`zig/layout`): the C compiler stays the oracle only where a C ABI is still on the other side:
  `layout.c` (public headers, step 3) and `system_layout.c` (the libc types taken from std.c, step 3b). The checks of
  the private headers were removed, since no C code compiles them any more.
