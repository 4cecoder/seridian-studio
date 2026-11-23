//! Pure parser for `pactl list short sinks|sources` output.
//! No libc, no process spawning, no audio server.

const std = @import("std");
const testing = std.testing;

/// Capacity of the inline buffer that holds a derived description.
pub const max_description_len = 128;

const monitor_suffix = ".monitor";
const alsa_prefixes = [_][]const u8{ "alsa_output.", "alsa_input." };
const usb_card_prefix = "usb-";
const profile_separator = "__";

pub const Device = struct {
    index: u32,
    /// PulseAudio/PipeWire device name. Borrowed from the parsed text.
    name: []const u8,
    /// Human-readable label. Either a slice of `name` or a slice of `desc_buf`.
    description: []const u8,
    is_default: bool,
    /// Backing storage for a derived description. Slices into this field are
    /// only valid while the containing `Device` is not moved.
    desc_buf: [max_description_len]u8 = undefined,
};

/// Parse `pactl list short sinks|sources` text into `out`.
///
/// Each line is `INDEX<TAB>NAME<TAB>DRIVER<TAB>FORMAT<TAB>STATE`. Malformed lines
/// (missing tab, non-numeric index, empty name) are skipped, and `.monitor`
/// entries are dropped because they are loopbacks, not devices. A device whose
/// name equals `default_name` is marked default; an empty `default_name` marks
/// none. Returns the count written, capped at `out.len`.
pub fn parseShortList(text: []const u8, default_name: []const u8, out: []Device) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        if (count >= out.len) break;
        const line = std.mem.trimEnd(u8, raw_line, "\r");

        var fields = std.mem.splitScalar(u8, line, '\t');
        const index_text = fields.next() orelse continue;
        const name = fields.next() orelse continue;
        const index = std.fmt.parseInt(u32, std.mem.trim(u8, index_text, " "), 10) catch continue;
        if (name.len == 0) continue;
        if (std.mem.endsWith(u8, name, monitor_suffix)) continue;

        const dev = &out[count];
        dev.index = index;
        dev.name = name;
        dev.is_default = default_name.len > 0 and std.mem.eql(u8, name, default_name);
        dev.description = deriveDescription(name, &dev.desc_buf);
        count += 1;
    }
    return count;
}

/// Trim whitespace and a trailing newline from `pactl get-default-*` output.
pub fn parseDefaultName(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
}

/// Derive a readable label from a device name, writing into `buf` when it is
/// built from parts. For USB cards, `alsa_output.usb-Focusrite_Scarlett_Solo_USB_Y7F8QY411B8DFD-00.HiFi__Line__sink`
/// becomes `Focusrite Scarlett Solo USB Line`: the card name without its serial
/// and USB index, followed by the profile's channel word. Any other name, or a
/// label that does not fit in `buf`, is returned unchanged.
fn deriveDescription(name: []const u8, buf: []u8) []const u8 {
    const rest = stripAlsaPrefix(name) orelse return name;
    const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return name;
    const card_part = rest[0..dot];
    const profile_part = rest[dot + 1 ..];
    if (!std.mem.startsWith(u8, card_part, usb_card_prefix)) return name;

    var card = card_part[usb_card_prefix.len..];
    if (std.mem.lastIndexOfScalar(u8, card, '-')) |dash| card = card[0..dash];

    var len: usize = 0;
    var ok = true;
    var card_words = std.mem.splitScalar(u8, card, '_');
    while (card_words.next()) |word| {
        if (word.len == 0 or isSerial(word)) continue;
        ok = ok and appendWord(buf, &len, word);
    }
    var profile_words = std.mem.splitSequence(u8, profile_part, profile_separator);
    while (profile_words.next()) |word| {
        if (word.len == 0 or isProfileNoise(word)) continue;
        ok = ok and appendWord(buf, &len, word);
    }
    if (!ok or len == 0) return name;
    return buf[0..len];
}

fn stripAlsaPrefix(name: []const u8) ?[]const u8 {
    for (alsa_prefixes) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return name[prefix.len..];
    }
    return null;
}

/// Serial numbers in card names: at least 8 characters, all upper-case letters
/// or digits, and at least one digit (e.g. `Y7F8QY411B8DFD`, `W20221116`).
fn isSerial(word: []const u8) bool {
    if (word.len < 8) return false;
    var has_digit = false;
    for (word) |c| {
        switch (c) {
            '0'...'9' => has_digit = true,
            'A'...'Z' => {},
            else => return false,
        }
    }
    return has_digit;
}

/// Profile tokens that name the port type rather than the channel.
fn isProfileNoise(word: []const u8) bool {
    return std.mem.eql(u8, word, "HiFi") or
        std.mem.eql(u8, word, "sink") or
        std.mem.eql(u8, word, "source");
}

/// Append `word` to `buf` at `len`, preceded by a space when not first.
/// Returns false, leaving `buf` unchanged, if it does not fit.
fn appendWord(buf: []u8, len: *usize, word: []const u8) bool {
    const sep: usize = if (len.* == 0) 0 else 1;
    if (len.* + sep + word.len > buf.len) return false;
    if (sep == 1) {
        buf[len.*] = ' ';
        len.* += 1;
    }
    @memcpy(buf[len.*..][0..word.len], word);
    len.* += word.len;
    return true;
}

const sinks_fixture =
    "64\talsa_output.pci-0000_0b_00.3.iec958-stereo\tPipeWire\ts32le 2ch 48000Hz\tSUSPENDED\n" ++
    "5330\talsa_output.usb-Focusrite_Scarlett_Solo_USB_Y7F8QY411B8DFD-00.HiFi__Line__sink\tPipeWire\ts32le 2ch 48000Hz\tRUNNING\n";

const sources_fixture =
    "64\talsa_output.pci-0000_0b_00.3.iec958-stereo.monitor\tPipeWire\ts32le 2ch 48000Hz\tSUSPENDED\n" ++
    "65\talsa_input.pci-0000_0b_00.3.analog-stereo\tPipeWire\ts32le 2ch 48000Hz\tSUSPENDED\n" ++
    "67\talsa_input.usb-SunplusIT_Inc_Nisheng_M3_W20221116-02.mono-fallback\tPipeWire\ts16le 1ch 48000Hz\tSUSPENDED\n" ++
    "5325\talsa_input.usb-Focusrite_Scarlett_Solo_USB_Y7F8QY411B8DFD-00.HiFi__Mic2__source\tPipeWire\tfloat32le 1ch 48000Hz\tSUSPENDED\n" ++
    "5328\talsa_input.usb-Focusrite_Scarlett_Solo_USB_Y7F8QY411B8DFD-00.HiFi__Mic1__source\tPipeWire\tfloat32le 1ch 48000Hz\tSUSPENDED\n" ++
    "5330\talsa_output.usb-Focusrite_Scarlett_Solo_USB_Y7F8QY411B8DFD-00.HiFi__Line__sink.monitor\tPipeWire\ts32le 2ch 48000Hz\tRUNNING\n";

const focusrite_sink = "alsa_output.usb-Focusrite_Scarlett_Solo_USB_Y7F8QY411B8DFD-00.HiFi__Line__sink";
const pci_sink = "alsa_output.pci-0000_0b_00.3.iec958-stereo";

test "real sink list: 2 sinks, default marked" {
    var out: [8]Device = undefined;
    const n = parseShortList(sinks_fixture, focusrite_sink, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u32, 64), out[0].index);
    try testing.expectEqualStrings(pci_sink, out[0].name);
    try testing.expect(!out[0].is_default);
    try testing.expectEqual(@as(u32, 5330), out[1].index);
    try testing.expectEqualStrings(focusrite_sink, out[1].name);
    try testing.expect(out[1].is_default);
}

test "real source list: inputs only, no .monitor" {
    var out: [16]Device = undefined;
    const n = parseShortList(sources_fixture, "", &out);
    try testing.expectEqual(@as(usize, 4), n);
    for (out[0..n]) |d| {
        try testing.expect(!std.mem.endsWith(u8, d.name, ".monitor"));
        try testing.expect(!d.is_default);
    }
    try testing.expectEqual(@as(u32, 65), out[0].index);
    try testing.expectEqualStrings("alsa_input.pci-0000_0b_00.3.analog-stereo", out[0].name);
    try testing.expectEqual(@as(u32, 67), out[1].index);
    try testing.expectEqual(@as(u32, 5325), out[2].index);
    try testing.expect(std.mem.indexOf(u8, out[2].name, "Mic2") != null);
    try testing.expectEqual(@as(u32, 5328), out[3].index);
    try testing.expect(std.mem.indexOf(u8, out[3].name, "Mic1") != null);
}

test "empty input yields zero devices" {
    var out: [4]Device = undefined;
    try testing.expectEqual(@as(usize, 0), parseShortList("", "x", &out));
    try testing.expectEqual(@as(usize, 0), parseShortList("\n\n", "x", &out));
}

test "malformed lines are skipped" {
    var out: [4]Device = undefined;
    const text =
        "garbage with no tabs\n" ++
        "\n" ++
        "notanumber\talsa_output.foo\tPipeWire\ts16le 2ch 48000Hz\tIDLE\n" ++
        "7\n" ++
        "9\talsa_output.good\tPipeWire\ts16le 2ch 48000Hz\tIDLE\n";
    const n = parseShortList(text, "", &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u32, 9), out[0].index);
    try testing.expectEqualStrings("alsa_output.good", out[0].name);
}

test "out buffer too small returns the cap" {
    var out: [1]Device = undefined;
    const n = parseShortList(sources_fixture, "", &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u32, 65), out[0].index);
}

test "default name with trailing newline" {
    try testing.expectEqualStrings(focusrite_sink, parseDefaultName(focusrite_sink ++ "\n"));
    try testing.expectEqualStrings(focusrite_sink, parseDefaultName("  " ++ focusrite_sink ++ " \r\n"));
    try testing.expectEqualStrings("", parseDefaultName("\n"));
}

test "name with dots and dashes is preserved" {
    var out: [2]Device = undefined;
    const n = parseShortList(sinks_fixture, pci_sink, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings(pci_sink, out[0].name);
    try testing.expect(out[0].is_default);
    try testing.expect(!out[1].is_default);
}

test "description derivation for the Focusrite name" {
    var out: [8]Device = undefined;
    const n = parseShortList(sinks_fixture, focusrite_sink, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("Focusrite Scarlett Solo USB Line", out[1].description);
}
