# automation

Layer L3. Automation lanes, modes, MIDI learn, macros. Depends on core, analysis, io.

See `docs/design/architecture.md` for the layer rules: this library may import
only the libraries named above, as named modules (`@import("core")`), never by
relative path across library directories.

- `src/root.zig` re-exports every file of the library. Add
  `pub const <file> = @import("<file>.zig");` for each new file.
- Tests live inline in the source files (`test` blocks). Tests that exercise
  only the public API may go in `tests/`; list them in `tests/all.zig`.
- Run: `zig build test-automation`.
- Translated files start with the SoundCraft attribution header; see
  `libs/RUST_TO_ZIG.md` and `THIRD_PARTY_NOTICES.md`.
