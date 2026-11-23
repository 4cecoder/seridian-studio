// Translated to Zig from vendor/raven/src/render/font_system.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - render/font_system.c
// The fonts of the system, for the characters that the fonts of the
// application do not have: other alphabets (Arabic, Hebrew, Cyrillic,
// Greek, Devanagari, Thai...), Chinese, Japanese, Korean, symbols and emoji.
//
// For a character, the candidates are the files made for its script, then
// the broad fonts. font.c opens them on first need, keeps those that load,
// and remembers which font has each character.
//
//   Windows  %WINDIR%\Fonts: Segoe UI, Segoe UI Emoji (color, COLR),
//            Segoe UI Symbol, Microsoft YaHei, Yu Gothic, Malgun Gothic,
//            Nirmala UI, Ebrima, Tahoma, Arial...
//   macOS    /System/Library/Fonts (and Supplemental): Geeza Pro, Arial
//            Hebrew, PingFang, Hiragino, Apple SD Gothic Neo, Kohinoor,
//            Thonburi, Apple Symbols, Arial Unicode...
//   Linux    every .ttf / .otf / .ttc in the font folders, chosen by name
//            (Noto Sans <Script>, Noto Color Emoji in its COLR version,
//            DejaVu Sans, FreeSans...)

const std = @import("std");
const builtin = @import("builtin");
const base = @import("../core/base_h.zig");
const font = @import("font_h.zig");
const libc = @import("../sys/libc.zig");
const ext = @import("externs.zig");

// Checks that the functions below have the types that font.h declares for them.
comptime {
    std.debug.assert(@TypeOf(&font.rvn_font_system_candidates) == @TypeOf(&rvn_font_system_candidates));
    std.debug.assert(@TypeOf(&font.rvn_font_system_shutdown) == @TypeOf(&rvn_font_system_shutdown));
}

/// typedef enum rvn_script_t { ... } rvn_script_t;
const rvn_script_t = c_int;
const RVN_SCRIPT_LATIN: rvn_script_t = 0;
const RVN_SCRIPT_GREEK: rvn_script_t = 1;
const RVN_SCRIPT_CYRILLIC: rvn_script_t = 2;
const RVN_SCRIPT_ARMENIAN: rvn_script_t = 3;
const RVN_SCRIPT_HEBREW: rvn_script_t = 4;
const RVN_SCRIPT_ARABIC: rvn_script_t = 5;
const RVN_SCRIPT_SYRIAC: rvn_script_t = 6;
const RVN_SCRIPT_THAANA: rvn_script_t = 7;
const RVN_SCRIPT_INDIC: rvn_script_t = 8;
const RVN_SCRIPT_THAI: rvn_script_t = 9;
const RVN_SCRIPT_LAO: rvn_script_t = 10;
const RVN_SCRIPT_GEORGIAN: rvn_script_t = 11;
const RVN_SCRIPT_ETHIOPIC: rvn_script_t = 12;
const RVN_SCRIPT_KHMER: rvn_script_t = 13;
const RVN_SCRIPT_MYANMAR: rvn_script_t = 14;
const RVN_SCRIPT_SINHALA: rvn_script_t = 15;
const RVN_SCRIPT_TIBETAN: rvn_script_t = 16;
const RVN_SCRIPT_HANGUL: rvn_script_t = 17;
const RVN_SCRIPT_KANA: rvn_script_t = 18;
const RVN_SCRIPT_HAN: rvn_script_t = 19;
const RVN_SCRIPT_SYMBOL: rvn_script_t = 20;
const RVN_SCRIPT_EMOJI: rvn_script_t = 21;
const RVN_SCRIPT_COUNT: rvn_script_t = 22;

fn rvn_script_of(c: u32) rvn_script_t {
    if (c < 0x0370) return RVN_SCRIPT_LATIN;
    if (c < 0x0400) return RVN_SCRIPT_GREEK;
    if (c < 0x0530) return RVN_SCRIPT_CYRILLIC;
    if (c < 0x0590) return RVN_SCRIPT_ARMENIAN;
    if (c < 0x0600) return RVN_SCRIPT_HEBREW;
    if (c < 0x0700) return RVN_SCRIPT_ARABIC;
    if (c < 0x0780) return RVN_SCRIPT_SYRIAC;
    if (c < 0x07C0) return RVN_SCRIPT_THAANA;
    if (c >= 0x0860 and c < 0x0900) return RVN_SCRIPT_ARABIC;
    if (c >= 0x0900 and c < 0x0D80) return RVN_SCRIPT_INDIC;
    if (c >= 0x0D80 and c < 0x0E00) return RVN_SCRIPT_SINHALA;
    if (c >= 0x0E00 and c < 0x0E80) return RVN_SCRIPT_THAI;
    if (c >= 0x0E80 and c < 0x0F00) return RVN_SCRIPT_LAO;
    if (c >= 0x0F00 and c < 0x1000) return RVN_SCRIPT_TIBETAN;
    if (c >= 0x1000 and c < 0x10A0) return RVN_SCRIPT_MYANMAR;
    if (c >= 0x10A0 and c < 0x1100) return RVN_SCRIPT_GEORGIAN;
    if (c >= 0x1100 and c < 0x1200) return RVN_SCRIPT_HANGUL;
    if (c >= 0x1200 and c < 0x13A0) return RVN_SCRIPT_ETHIOPIC;
    if (c >= 0x1780 and c < 0x1800) return RVN_SCRIPT_KHMER;
    if (c >= 0x1E00 and c < 0x2000) return if (c < 0x1F00) RVN_SCRIPT_LATIN else RVN_SCRIPT_GREEK;
    if (c >= 0x2000 and c < 0x2E80) return RVN_SCRIPT_SYMBOL;
    if (c >= 0x3040 and c < 0x3100) return RVN_SCRIPT_KANA;
    if (c >= 0x31F0 and c < 0x3200) return RVN_SCRIPT_KANA;
    if (c >= 0x3130 and c < 0x3190) return RVN_SCRIPT_HANGUL;
    if (c >= 0xAC00 and c < 0xD7B0) return RVN_SCRIPT_HANGUL;
    if ((c >= 0x2E80 and c < 0xA000) or (c >= 0xF900 and c < 0xFB00) or (c >= 0x20000 and c < 0x32000)) return RVN_SCRIPT_HAN;
    if (c >= 0xFB1D and c < 0xFB50) return RVN_SCRIPT_HEBREW;
    if (c >= 0xFB50 and c < 0xFE00) return RVN_SCRIPT_ARABIC;
    if (c >= 0xFE70 and c < 0xFF00) return RVN_SCRIPT_ARABIC;
    if (c >= 0xFF00 and c < 0xFFF0) return RVN_SCRIPT_HAN;
    if ((c >= 0x1F000 and c < 0x1FB00) or c == 0x2764 or (c >= 0x2600 and c < 0x27C0)) return RVN_SCRIPT_EMOJI;
    if (c >= 0x1D400 and c < 0x1D800) return RVN_SCRIPT_SYMBOL;
    return RVN_SCRIPT_LATIN;
}

/// static struct { int ready; char** lists[RVN_SCRIPT_COUNT + 1]; int counts[RVN_SCRIPT_COUNT + 1]; } g_system;
const SystemFonts = extern struct {
    ready: c_int,
    // every candidate path, per script, then the broad ones
    lists: [RVN_SCRIPT_COUNT + 1][*c][*c]u8,
    counts: [RVN_SCRIPT_COUNT + 1]c_int,
};
var g_system: SystemFonts = std.mem.zeroes(SystemFonts);

fn rvn_system_add(list: c_int, path: [*c]const u8) void {
    const l: usize = @intCast(list);
    var i: c_int = 0;
    while (i < g_system.counts[l]) : (i += 1) {
        if (libc.strcmp(g_system.lists[l][@intCast(i)], path) == 0) return;
    }
    const f = libc.fopen(path, "rb") orelse return;
    _ = libc.fclose(f);
    const n: usize = @intCast(g_system.counts[l]);
    g_system.lists[l] = @ptrCast(@alignCast(base.rvn_realloc(@ptrCast(g_system.lists[l]), (n + 1) * @sizeOf([*c]u8))));
    g_system.lists[l][n] = base.rvn_strdup(path);
    g_system.counts[l] += 1;
}

/// typedef struct rvn_system_font_t { int script; const char* file; } rvn_system_font_t;
const rvn_system_font_t = extern struct {
    script: c_int, // RVN_SCRIPT_COUNT: broad
    file: [*c]const u8,
};

fn rvn_system_add_table(folder: [*c]const u8, table: [*c]const rvn_system_font_t, count: usize) void {
    var i: usize = 0;
    var path: [1024]u8 = undefined;
    while (i < count) : (i += 1) {
        _ = libc.snprintf(&path, path.len, "%s%s", folder, table[i].file);
        rvn_system_add(table[i].script, &path);
    }
}

// The tables below are used only by the scan of their own platform (font_system.c: #if _WIN32 / __APPLE__).

const g_windows_fonts = [_]rvn_system_font_t{
    .{ .script = RVN_SCRIPT_EMOJI, .file = "seguiemj.ttf" }, .{ .script = RVN_SCRIPT_EMOJI, .file = "seguisym.ttf" },
    .{ .script = RVN_SCRIPT_SYMBOL, .file = "seguisym.ttf" }, .{ .script = RVN_SCRIPT_SYMBOL, .file = "segoeui.ttf" }, .{ .script = RVN_SCRIPT_SYMBOL, .file = "cambria.ttc" },
    .{ .script = RVN_SCRIPT_ARABIC, .file = "segoeui.ttf" }, .{ .script = RVN_SCRIPT_ARABIC, .file = "tahoma.ttf" }, .{ .script = RVN_SCRIPT_ARABIC, .file = "arial.ttf" },
    .{ .script = RVN_SCRIPT_HEBREW, .file = "segoeui.ttf" }, .{ .script = RVN_SCRIPT_HEBREW, .file = "arial.ttf" },
    .{ .script = RVN_SCRIPT_GREEK, .file = "segoeui.ttf" }, .{ .script = RVN_SCRIPT_CYRILLIC, .file = "segoeui.ttf" }, .{ .script = RVN_SCRIPT_LATIN, .file = "segoeui.ttf" },
    .{ .script = RVN_SCRIPT_ARMENIAN, .file = "segoeui.ttf" }, .{ .script = RVN_SCRIPT_ARMENIAN, .file = "sylfaen.ttf" }, .{ .script = RVN_SCRIPT_GEORGIAN, .file = "segoeui.ttf" },
    .{ .script = RVN_SCRIPT_THAI, .file = "leelawui.ttf" }, .{ .script = RVN_SCRIPT_THAI, .file = "tahoma.ttf" }, .{ .script = RVN_SCRIPT_LAO, .file = "leelawui.ttf" },
    .{ .script = RVN_SCRIPT_KHMER, .file = "leelawui.ttf" }, .{ .script = RVN_SCRIPT_MYANMAR, .file = "mmrtext.ttf" },
    .{ .script = RVN_SCRIPT_INDIC, .file = "Nirmala.ttc" }, .{ .script = RVN_SCRIPT_INDIC, .file = "Nirmala.ttf" }, .{ .script = RVN_SCRIPT_SINHALA, .file = "Nirmala.ttc" }, .{ .script = RVN_SCRIPT_SINHALA, .file = "Nirmala.ttf" },
    .{ .script = RVN_SCRIPT_ETHIOPIC, .file = "ebrima.ttf" }, .{ .script = RVN_SCRIPT_THAANA, .file = "mvboli.ttf" }, .{ .script = RVN_SCRIPT_SYRIAC, .file = "estre.ttf" }, .{ .script = RVN_SCRIPT_TIBETAN, .file = "himalaya.ttf" },
    .{ .script = RVN_SCRIPT_HANGUL, .file = "malgun.ttf" },
    .{ .script = RVN_SCRIPT_KANA, .file = "YuGothM.ttc" }, .{ .script = RVN_SCRIPT_KANA, .file = "meiryo.ttc" }, .{ .script = RVN_SCRIPT_KANA, .file = "msgothic.ttc" },
    .{ .script = RVN_SCRIPT_HAN, .file = "msyh.ttc" }, .{ .script = RVN_SCRIPT_HAN, .file = "YuGothM.ttc" }, .{ .script = RVN_SCRIPT_HAN, .file = "simsun.ttc" }, .{ .script = RVN_SCRIPT_HAN, .file = "msjh.ttc" },
    .{ .script = RVN_SCRIPT_COUNT, .file = "segoeui.ttf" }, .{ .script = RVN_SCRIPT_COUNT, .file = "arial.ttf" }, .{ .script = RVN_SCRIPT_COUNT, .file = "seguisym.ttf" }, .{ .script = RVN_SCRIPT_COUNT, .file = "msyh.ttc" },
};

const g_mac_fonts = [_]rvn_system_font_t{
    .{ .script = RVN_SCRIPT_ARABIC, .file = "GeezaPro.ttc" }, .{ .script = RVN_SCRIPT_ARABIC, .file = "Supplemental/GeezaPro.ttc" }, .{ .script = RVN_SCRIPT_ARABIC, .file = "SFArabic.ttf" },
    .{ .script = RVN_SCRIPT_HEBREW, .file = "SFHebrew.ttf" }, .{ .script = RVN_SCRIPT_HEBREW, .file = "Supplemental/Arial Hebrew.ttc" }, .{ .script = RVN_SCRIPT_HEBREW, .file = "ArialHB.ttc" },
    .{ .script = RVN_SCRIPT_GREEK, .file = "Helvetica.ttc" }, .{ .script = RVN_SCRIPT_CYRILLIC, .file = "Helvetica.ttc" }, .{ .script = RVN_SCRIPT_LATIN, .file = "Helvetica.ttc" },
    .{ .script = RVN_SCRIPT_ARMENIAN, .file = "SFArmenian.ttf" }, .{ .script = RVN_SCRIPT_GEORGIAN, .file = "SFGeorgian.ttf" },
    .{ .script = RVN_SCRIPT_THAI, .file = "Thonburi.ttc" }, .{ .script = RVN_SCRIPT_THAI, .file = "Supplemental/Thonburi.ttc" }, .{ .script = RVN_SCRIPT_LAO, .file = "Supplemental/Lao Sangam MN.ttf" },
    .{ .script = RVN_SCRIPT_INDIC, .file = "Kohinoor.ttc" }, .{ .script = RVN_SCRIPT_INDIC, .file = "Supplemental/DevanagariMT.ttc" }, .{ .script = RVN_SCRIPT_INDIC, .file = "Supplemental/Tamil Sangam MN.ttc" },
    .{ .script = RVN_SCRIPT_KHMER, .file = "Supplemental/Khmer Sangam MN.ttf" }, .{ .script = RVN_SCRIPT_MYANMAR, .file = "Supplemental/Myanmar Sangam MN.ttc" },
    .{ .script = RVN_SCRIPT_SINHALA, .file = "Supplemental/Sinhala Sangam MN.ttc" }, .{ .script = RVN_SCRIPT_ETHIOPIC, .file = "Supplemental/Kefa.ttc" },
    .{ .script = RVN_SCRIPT_TIBETAN, .file = "Supplemental/Kailasa.ttc" }, .{ .script = RVN_SCRIPT_THAANA, .file = "Supplemental/Arial Unicode.ttf" },
    .{ .script = RVN_SCRIPT_HANGUL, .file = "AppleSDGothicNeo.ttc" },
    .{ .script = RVN_SCRIPT_KANA, .file = "\xE3\x83\x92\xE3\x83\xA9\xE3\x82\xAE\xE3\x83\x8E\xE8\xA7\x92\xE3\x82\xB4\xE3\x82\xB7\xE3\x83\x83\xE3\x82\xAF W3.ttc" }, .{ .script = RVN_SCRIPT_KANA, .file = "Hiragino Sans GB.ttc" },
    .{ .script = RVN_SCRIPT_HAN, .file = "PingFang.ttc" }, .{ .script = RVN_SCRIPT_HAN, .file = "Hiragino Sans GB.ttc" }, .{ .script = RVN_SCRIPT_HAN, .file = "STHeiti Light.ttc" },
    .{ .script = RVN_SCRIPT_SYMBOL, .file = "Apple Symbols.ttf" }, .{ .script = RVN_SCRIPT_SYMBOL, .file = "Supplemental/Arial Unicode.ttf" },
    // (Apple Color Emoji is made of bitmaps: the outlines of Apple Symbols stand in)
    .{ .script = RVN_SCRIPT_EMOJI, .file = "Apple Symbols.ttf" }, .{ .script = RVN_SCRIPT_EMOJI, .file = "Supplemental/Arial Unicode.ttf" },
    .{ .script = RVN_SCRIPT_COUNT, .file = "Supplemental/Arial Unicode.ttf" }, .{ .script = RVN_SCRIPT_COUNT, .file = "Helvetica.ttc" }, .{ .script = RVN_SCRIPT_COUNT, .file = "Apple Symbols.ttf" },
};

// Names of files that cover a script, the best first (they are searched for in the file names).
const latin = [_][*c]const u8{ "NotoSans-Regular", "DejaVuSans.", "LiberationSans-Regular", "FreeSans.", null };
const arabic = [_][*c]const u8{ "NotoSansArabic-Regular", "NotoNaskhArabic-Regular", "NotoSansArabicUI-Regular", "DejaVuSans.", "FreeSerif.", null };
const hebrew = [_][*c]const u8{ "NotoSansHebrew-Regular", "DejaVuSans.", "FreeSans.", null };
const armenian = [_][*c]const u8{ "NotoSansArmenian-Regular", "DejaVuSans.", "FreeSans.", null };
const georgian = [_][*c]const u8{ "NotoSansGeorgian-Regular", "DejaVuSans.", "FreeSans.", null };
const indic = [_][*c]const u8{ "NotoSansDevanagari-Regular", "NotoSansBengali-Regular", "NotoSansTamil-Regular", "NotoSansTelugu-Regular", "NotoSansGujarati-Regular", "NotoSansKannada-Regular", "NotoSansMalayalam-Regular", "NotoSansGurmukhi-Regular", "NotoSansOriya-Regular", "Lohit", "FreeSans.", null };
const thai = [_][*c]const u8{ "NotoSansThai-Regular", "NotoSansThaiUI-Regular", "Garuda", "FreeSerif.", null };
const lao = [_][*c]const u8{ "NotoSansLao-Regular", null };
const khmer = [_][*c]const u8{ "NotoSansKhmer-Regular", null };
const myanmar = [_][*c]const u8{ "NotoSansMyanmar-Regular", null };
const sinhala = [_][*c]const u8{ "NotoSansSinhala-Regular", null };
const tibetan = [_][*c]const u8{ "NotoSerifTibetan-Regular", "NotoSansTibetan", null };
const ethiopic = [_][*c]const u8{ "NotoSansEthiopic-Regular", "Abyssinica", "FreeSerif.", null };
const syriac = [_][*c]const u8{ "NotoSansSyriac", null };
const thaana = [_][*c]const u8{ "NotoSansThaana-Regular", "FreeSerif.", null };
const cjk = [_][*c]const u8{ "NotoSansCJK-Regular", "NotoSansCJKsc-Regular", "NotoSansCJKjp-Regular", "NotoSansSC-Regular", "NotoSansJP-Regular", "NotoSansKR-Regular", "wqy-microhei", "wqy-zenhei", "DroidSansFallback", "ukai", "uming", null };
const symbol = [_][*c]const u8{ "NotoSansSymbols-Regular", "NotoSansSymbols2-Regular", "NotoSansMath-Regular", "DejaVuSans.", "FreeSerif.", "Symbola", null };
const emoji = [_][*c]const u8{ "Noto-COLRv1", "NotoColorEmoji-COLR", "Twemoji", "NotoEmoji-Regular", "NotoEmoji", "Symbola", "NotoSansSymbols2-Regular", "DejaVuSans.", null };
const broad = [_][*c]const u8{ "DejaVuSans.", "NotoSans-Regular", "FreeSans.", "FreeSerif.", "unifont", null };

fn rvn_linux_patterns(script: c_int) [*c]const [*c]const u8 {
    switch (script) {
        RVN_SCRIPT_ARABIC => return &arabic,
        RVN_SCRIPT_HEBREW => return &hebrew,
        RVN_SCRIPT_ARMENIAN => return &armenian,
        RVN_SCRIPT_GEORGIAN => return &georgian,
        RVN_SCRIPT_INDIC => return &indic,
        RVN_SCRIPT_THAI => return &thai,
        RVN_SCRIPT_LAO => return &lao,
        RVN_SCRIPT_KHMER => return &khmer,
        RVN_SCRIPT_MYANMAR => return &myanmar,
        RVN_SCRIPT_SINHALA => return &sinhala,
        RVN_SCRIPT_TIBETAN => return &tibetan,
        RVN_SCRIPT_ETHIOPIC => return &ethiopic,
        RVN_SCRIPT_SYRIAC => return &syriac,
        RVN_SCRIPT_THAANA => return &thaana,
        RVN_SCRIPT_HANGUL, RVN_SCRIPT_KANA, RVN_SCRIPT_HAN => return &cjk,
        RVN_SCRIPT_SYMBOL => return &symbol,
        RVN_SCRIPT_EMOJI => return &emoji,
        RVN_SCRIPT_COUNT => return &broad,
        else => return &latin,
    }
}

var g_linux_files: [*c][*c]u8 = null;
var g_linux_file_count: c_int = 0;

/// struct stat. On Linux this Zig has no `struct stat` in std.c (std.c.Stat is void there), so the
/// Linux walk uses the glibc statx() wrapper, which fills the same file type and mode.
const StatBuf = if (builtin.os.tag == .linux) std.os.linux.Statx else std.c.Stat;
/// glibc: int statx(int dirfd, const char *pathname, int flags, unsigned int mask, struct statx *statxbuf);
extern "c" fn statx(dirfd: c_int, pathname: [*:0]const u8, flags: c_int, mask: c_uint, statxbuf: *std.os.linux.Statx) c_int;
const AT_FDCWD: c_int = -100;
const STATX_BASIC_STATS: c_uint = 0x7ff;

fn rvn_linux_walk(folder: [*c]const u8, depth: c_int) void {
    if (depth > 5 or g_linux_file_count > 20000) return;
    const dir = libc.opendir(folder) orelse return;
    while (true) {
        const entry = libc.readdir(dir) orelse break;
        var path: [1024]u8 = undefined;
        var info: StatBuf = undefined;
        const dname: [*c]const u8 = &entry.name;
        const n = libc.strlen(dname);
        if (dname[0] == '.') continue;
        _ = libc.snprintf(&path, path.len, "%s/%s", folder, dname);
        const path_z: [*:0]const u8 = @ptrCast(&path);
        const stat_ok = if (builtin.os.tag == .linux)
            statx(AT_FDCWD, path_z, 0, STATX_BASIC_STATS, &info) == 0
        else
            libc.stat(path_z, &info) == 0;
        if (!stat_ok) continue;
        if (ext.S_ISDIR(@as(u32, info.mode))) {
            rvn_linux_walk(&path, depth + 1);
        } else if (n > 4 and (base.rvn_stricmp(dname + n - 4, ".ttf") == 0 or base.rvn_stricmp(dname + n - 4, ".otf") == 0 or
            base.rvn_stricmp(dname + n - 4, ".ttc") == 0))
        {
            const k: usize = @intCast(g_linux_file_count);
            g_linux_files = @ptrCast(@alignCast(base.rvn_realloc(@ptrCast(g_linux_files), (k + 1) * @sizeOf([*c]u8))));
            g_linux_file_count += 1;
            g_linux_files[k] = base.rvn_strdup(&path);
        }
    }
    _ = libc.closedir(dir);
}

fn rvn_system_scan() void {
    if (builtin.os.tag == .windows) {
        // C:\Windows\Fonts
        const MAX_PATH = 260;
        var windows: [MAX_PATH]u8 = undefined;
        var folder: [MAX_PATH + 16]u8 = undefined;
        const n = ext.win.GetWindowsDirectoryA(&windows, MAX_PATH);
        if (n == 0 or n >= MAX_PATH) _ = libc.strcpy(&windows, "C:\\Windows");
        _ = libc.snprintf(&folder, folder.len, "%s\\Fonts\\", @as([*c]const u8, &windows));
        rvn_system_add_table(&folder, &g_windows_fonts, g_windows_fonts.len);
    } else if (builtin.os.tag.isDarwin()) {
        rvn_system_add_table("/System/Library/Fonts/", &g_mac_fonts, g_mac_fonts.len);
        rvn_system_add_table("/Library/Fonts/", &g_mac_fonts, g_mac_fonts.len);
    } else {
        const home = libc.getenv("HOME");
        const data = libc.getenv("XDG_DATA_HOME");
        var path: [1024]u8 = undefined;
        rvn_linux_walk("/usr/share/fonts", 0);
        rvn_linux_walk("/usr/local/share/fonts", 0);
        if (data != null and data[0] != 0) {
            _ = libc.snprintf(&path, path.len, "%s/fonts", data);
            rvn_linux_walk(&path, 0);
        }
        if (home != null) {
            _ = libc.snprintf(&path, path.len, "%s/.local/share/fonts", home);
            rvn_linux_walk(&path, 0);
            _ = libc.snprintf(&path, path.len, "%s/.fonts", home);
            rvn_linux_walk(&path, 0);
        }
        const file_count: usize = @intCast(g_linux_file_count);
        var script: c_int = 0;
        while (script <= RVN_SCRIPT_COUNT) : (script += 1) {
            const patterns = rvn_linux_patterns(script);
            var p: usize = 0;
            while (patterns[p] != null) : (p += 1) {
                var i: usize = 0;
                while (i < file_count) : (i += 1) {
                    const slash = libc.strrchr(g_linux_files[i], '/');
                    const name: [*c]const u8 = if (slash != null) slash + 1 else g_linux_files[i];
                    if (libc.strncmp(name, patterns[p], libc.strlen(patterns[p])) == 0) rvn_system_add(script, g_linux_files[i]);
                }
            }
        }
        // the other Noto Sans files, for the scripts named nowhere above
        var i: usize = 0;
        while (i < file_count) : (i += 1) {
            const slash = libc.strrchr(g_linux_files[i], '/');
            const name: [*c]const u8 = if (slash != null) slash + 1 else g_linux_files[i];
            if (libc.strncmp(name, "NotoSans", 8) == 0 and libc.strstr(name, "-Regular.") != null) rvn_system_add(RVN_SCRIPT_COUNT, g_linux_files[i]);
        }
        i = 0;
        while (i < file_count) : (i += 1) base.rvn_free(g_linux_files[i]);
        base.rvn_free(@ptrCast(g_linux_files));
        g_linux_files = null;
        g_linux_file_count = 0;
    }
}

export fn rvn_font_system_candidates(codepoint: u32, paths: [*c][*c]const u8, max: c_int) c_int {
    var count: c_int = 0;
    if (g_system.ready == 0) {
        g_system.ready = 1;
        rvn_system_scan();
    }
    const script = rvn_script_of(codepoint);
    var k: c_int = 0;
    while (k < 2) : (k += 1) {
        const list: c_int = if (k == 0) script else RVN_SCRIPT_COUNT;
        const l: usize = @intCast(list);
        var i: c_int = 0;
        while (i < g_system.counts[l] and count < max) : (i += 1) {
            const ii: usize = @intCast(i);
            var seen = false;
            var j: c_int = 0;
            while (j < count) : (j += 1) {
                const jj: usize = @intCast(j);
                if (paths[jj] == g_system.lists[l][ii] or libc.strcmp(paths[jj], g_system.lists[l][ii]) == 0) seen = true;
            }
            if (!seen) {
                const ci: usize = @intCast(count);
                paths[ci] = g_system.lists[l][ii];
                count += 1;
            }
        }
    }
    return count;
}

export fn rvn_font_system_shutdown() void {
    var list: c_int = 0;
    while (list <= RVN_SCRIPT_COUNT) : (list += 1) {
        const l: usize = @intCast(list);
        var i: c_int = 0;
        while (i < g_system.counts[l]) : (i += 1) base.rvn_free(g_system.lists[l][@intCast(i)]);
        base.rvn_free(@ptrCast(g_system.lists[l]));
    }
    g_system = std.mem.zeroes(SystemFonts);
}
