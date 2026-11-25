//! The character rules for a track name, shared by `set N name` (via src/control_limits.zig) and by
//! loading project.daw, so a name that cannot be set cannot be loaded either. std only.

/// Longest track name, in bytes.
pub const max_len: usize = 24;

/// True when `text` is 1 to `max_len` bytes of printable ASCII (space to `~`). That is also valid UTF-8,
/// and holds no control byte, so the state JSON stays valid.
pub fn isPrintable(text: []const u8) bool {
    if (text.len == 0 or text.len > max_len) return false;
    for (text) |c| if (c < 0x20 or c > 0x7e) return false;
    return true;
}
