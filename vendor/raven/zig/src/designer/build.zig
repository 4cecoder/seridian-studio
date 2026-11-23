// Translated to Zig from vendor/raven/tools/designer/build.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven Designer - build.c
// Builds the project with the CMake and the compiler installed on the
// machine: configure, build, run, stop. What they write goes to the Output
// panel; the errors and warnings (GCC, Clang, MSVC, CMake, ravenc) go to the
// Build panel, and on the lines of the editors. A double click opens the
// file at the line, the .xmlc included (the compiler sees its lines).

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const ide = @import("ide_h.zig");
const libc = @import("../sys/libc.zig");

extern "c" fn sprintf(str: [*c]u8, format: [*c]const u8, ...) c_int;
extern "c" fn strtok(str: [*c]u8, delim: [*c]const u8) [*c]u8;

const MAX_STEPS = 4;
const MAX_ARGS = 24;
const MAX_ISSUES = 400;

const step_t = extern struct {
    argv: [MAX_ARGS + 1][*c]u8,
    directory: [*c]u8,
    /// the program itself: its output is not read for errors
    run: c_int,
    /// argv[0] is the program CMake makes: looked for when the step starts
    find: c_int,
};

/// How a project is built: from the files it has.
const kind_t = c_uint;
const KIND_NONE: c_int = 0;
const KIND_CMAKE: c_int = 1;
const KIND_CARGO: c_int = 2;
const KIND_GO: c_int = 3;
const KIND_DOTNET: c_int = 4;
const KIND_ZIG: c_int = 5;
const KIND_PYTHON: c_int = 6;
const KIND_LUA: c_int = 7;

const issue_t = extern struct {
    file: [*c]u8,
    line: c_int,
    column: c_int,
    @"error": c_int,
    message: [*c]u8,
};

const g_b_t = extern struct {
    output: raven.Rid,
    issues_list: raven.Rid,
    timer: raven.Rid,
    process: ?*ide.ide_process_t,
    steps: [MAX_STEPS]step_t,
    step_count: c_int,
    step_at: c_int,
    /// the end of a line not complete yet
    pending: ide.ide_buffer_t,
    issues: [MAX_ISSUES]issue_t,
    issue_count: c_int,
    error_count: c_int,
    warning_count: c_int,
    started: f64,
    configured_with: [2048]u8,
    kind: kind_t,
    /// rustc: "error[E0308]: ..." comes before the line that says where
    pending_message: [512]u8,
    pending_error: c_int,
    /// said in the Output once it is cleared, when the build starts
    note: [512]u8,
    /// CMake said it could not find the package of Raven
    package_missing: c_int,
    /// the last build that ended (the island shows it)
    has_result: c_int,
    last_ok: c_int,
    finished: f64,
};
var g_b: g_b_t = std.mem.zeroes(g_b_t);

export fn build_is_running() c_int {
    return @intFromBool(g_b.process != null or g_b.step_at < g_b.step_count);
}

export fn build_get_summary(summary: [*c]ide.build_summary_t) void {
    summary.* = std.mem.zeroes(ide.build_summary_t);
    summary.*.running = build_is_running();
    // the step under way is the program itself: it runs, it is not building
    summary.*.program = @intFromBool(g_b.process != null and g_b.step_at < g_b.step_count and g_b.steps[@intCast(g_b.step_at)].run != 0);
    summary.*.started = g_b.started;
    summary.*.has_result = g_b.has_result;
    summary.*.ok = g_b.last_ok;
    summary.*.finished = g_b.finished;
    summary.*.errors = g_b.error_count;
    summary.*.warnings = g_b.warning_count;
}

// ---------------------------------------------------------------------------
//  Output
// -------------------------------------------------------------------------

fn output_append(text: [*c]const u8, length: usize) void {
    var lines: c_int = undefined;
    var copy: [*c]u8 = undefined;
    if (length == 0) return;
    copy = @ptrCast(libc.malloc(length + 1));
    _ = libc.memcpy(copy, text, length);
    copy[length] = 0;
    raven.Rtext_editor_set_read_only(g_b.output, raven.R_FALSE);
    lines = raven.Rtext_editor_get_line_count(g_b.output);
    {
        const last = raven.Rtext_editor_get_line(g_b.output, lines - 1);
        raven.Rtext_editor_set_cursor(g_b.output, lines - 1, if (last != null) @as(c_int, @intCast(libc.strlen(last))) else 0);
    }
    raven.Rtext_editor_insert_text(g_b.output, copy);
    raven.Rtext_editor_set_read_only(g_b.output, raven.R_TRUE);
    raven.Rtext_editor_scroll_to_line(g_b.output, raven.Rtext_editor_get_line_count(g_b.output) - 1);
    libc.free(copy);
}

fn output_printf(format: [*c]const u8, ...) callconv(.c) void {
    var text: [2048]u8 = undefined;
    var args = @cVaStart();
    var n: c_int = undefined;
    n = libc.vsnprintf(&text, text.len, format, &args);
    @cVaEnd(&args);
    if (n > 0) output_append(&text, @intCast(if (n < @as(c_int, text.len)) n else @as(c_int, text.len) - 1));
}

fn output_clear() void {
    raven.Rtext_editor_set_read_only(g_b.output, raven.R_FALSE);
    raven.Rtext_editor_set_text(g_b.output, "");
    raven.Rtext_editor_set_read_only(g_b.output, raven.R_TRUE);
}

// ---------------------------------------------------------------------------
//  Problems in what the tools write
// -------------------------------------------------------------------------

fn clear_issues() void {
    var i: c_int = 0;
    while (i < g_b.issue_count) : (i += 1) {
        libc.free(g_b.issues[@intCast(i)].file);
        libc.free(g_b.issues[@intCast(i)].message);
    }
    g_b.warning_count = 0;
    g_b.error_count = g_b.warning_count;
    g_b.issue_count = g_b.error_count;
    raven.Rlist_view_clear_items(g_b.issues_list);
    ide.editors_clear_markers();
}

fn find_in(folder: [*c]const u8, name: [*c]const u8, depth: c_int) [*c]u8 {
    var entries: [*c]ide.ide_entry_t = undefined;
    const count = ide.ide_list_dir(folder, &entries);
    var i: c_int = 0;
    var found: [*c]u8 = null;
    while (i < count and found == null) : (i += 1) {
        if (entries[@intCast(i)].is_dir == 0 and libc.strcmp(&entries[@intCast(i)].name, name) == 0) found = ide.ide_join(folder, name);
    }
    i = 0;
    while (i < count and found == null and depth > 0) : (i += 1) {
        const entry = &entries[@intCast(i)];
        if (entry.is_dir != 0 and entry.name[0] != '.' and libc.strcmp(&entry.name, "build") != 0 and libc.strcmp(&entry.name, "target") != 0 and
            libc.strcmp(&entry.name, "obj") != 0 and libc.strcmp(&entry.name, "bin") != 0 and libc.strcmp(&entry.name, "zig-out") != 0 and libc.strcmp(&entry.name, "node_modules") != 0)
        {
            const sub = ide.ide_join(folder, &entry.name);
            found = find_in(sub, name, depth - 1);
            libc.free(sub);
        }
    }
    libc.free(entries);
    return found;
}

// A file ravenc made (main.xmlrs.rs, main.xmlgo.go, main.xmlcs.cs...) is the
// .xmlrs of the project: the scripts keep their lines in it.
fn source_of_generated(file: [*c]const u8) [*c]u8 {
    var name: [300]u8 = undefined;
    const base = ide.ide_basename(file);
    var dot: [*c]u8 = undefined;
    _ = libc.snprintf(&name, name.len, "%s", base);
    dot = libc.strrchr(&name, '.');
    if (dot == null or ide.g_project_dir == null) return null;
    dot.* = 0;
    if (ide.ide_interface_language(&name) == null) return null;
    return find_in(ide.g_project_dir, &name, 4);
}

/// A path the tool wrote, as a file that exists (they are often relative to the build folder).
fn resolve_file(file: [*c]const u8) [*c]u8 {
    var candidate: [*c]u8 = undefined;
    const source = source_of_generated(file);
    if (source != null) {
        const n = ide.ide_normalize(source);
        libc.free(source);
        return n;
    }
    if (ide.ide_file_exists(file) != 0) return ide.ide_normalize(file);
    if (ide.g_project_dir != null) {
        const build = ide.ide_join(ide.g_project_dir, "build");
        candidate = ide.ide_join(build, file);
        libc.free(build);
        if (ide.ide_file_exists(candidate) != 0) {
            const n = ide.ide_normalize(candidate);
            libc.free(candidate);
            return n;
        }
        libc.free(candidate);
        candidate = ide.ide_join(ide.g_project_dir, file);
        if (ide.ide_file_exists(candidate) != 0) {
            const n = ide.ide_normalize(candidate);
            libc.free(candidate);
            return n;
        }
        libc.free(candidate);
    }
    return ide.ide_normalize(file);
}

/// Reads a run of digits and advances `p` past it; -1 when there is none. Seridian fix: the C overflowed (UB) on
/// 10+ digits in compiler output; the value now saturates at maxInt(c_int) and the whole run is consumed.
fn read_number(p: [*c][*c]const u8) c_int {
    var n: c_int = 0;
    if (!std.ascii.isDigit(p.*.*)) return -1;
    while (std.ascii.isDigit(p.*.*)) {
        const digit: c_int = p.*.* - '0';
        p.* += 1;
        const shifted = std.math.mul(c_int, n, 10) catch std.math.maxInt(c_int);
        n = std.math.add(c_int, shifted, digit) catch std.math.maxInt(c_int);
    }
    return n;
}

test "read_number saturates instead of overflowing" {
    var text: [*c]const u8 = "12:rest";
    try std.testing.expectEqual(@as(c_int, 12), read_number(&text));
    try std.testing.expectEqual(@as(u8, ':'), text.*);
    var long: [*c]const u8 = "99999999999999999999x";
    try std.testing.expectEqual(@as(c_int, std.math.maxInt(c_int)), read_number(&long));
    try std.testing.expectEqual(@as(u8, 'x'), long.*);
    var none: [*c]const u8 = "abc";
    try std.testing.expectEqual(@as(c_int, -1), read_number(&none));
}

fn kind_at(p_: [*c]const u8, @"error": [*c]c_int, message: [*c][*c]const u8) c_int {
    var p = p_;
    while (p.* == ' ') p += 1;
    if (libc.strncmp(p, "fatal error", 11) == 0) {
        @"error".* = 1;
        p += 11;
    } else if (libc.strncmp(p, "error", 5) == 0) {
        @"error".* = 1;
        p += 5;
    } else if (libc.strncmp(p, "warning", 7) == 0) {
        @"error".* = 0;
        p += 7;
    } else return 0;
    // MSVC: "error C2065: ..."; GCC: "error: ..."
    while (p.* != 0 and p.* != ':') p += 1;
    if (p.* == ':') p += 1;
    while (p.* == ' ') p += 1;
    message.* = p;
    return 1;
}

fn add_issue(file: [*c]const u8, file_length: usize, line: c_int, column: c_int, @"error": c_int, message: [*c]const u8) void {
    var issue: [*c]issue_t = undefined;
    var raw: [*c]u8 = undefined;
    var row: [700]u8 = undefined;
    if (g_b.issue_count >= MAX_ISSUES or file_length == 0) return;
    raw = @ptrCast(libc.malloc(file_length + 1));
    _ = libc.memcpy(raw, file, file_length);
    raw[file_length] = 0;
    issue = &g_b.issues[@intCast(g_b.issue_count)];
    g_b.issue_count += 1;
    issue.*.file = resolve_file(raw);
    libc.free(raw);
    issue.*.line = line;
    issue.*.column = column;
    issue.*.@"error" = @"error";
    issue.*.message = ide.ide_strdup(message);
    if (@"error" != 0) g_b.error_count += 1 else g_b.warning_count += 1;
    _ = libc.snprintf(&row, row.len, "%s  %s:%d  %s", @as([*c]const u8, if (@"error" != 0) "error" else "warning"), ide.ide_basename(issue.*.file), line, message);
    _ = raven.Rlist_view_add_item(g_b.issues_list, &row);
    ide.editors_add_marker(issue.*.file, line, column, @"error", message);
}

fn parse_line(line: [*c]const u8) void {
    var p: [*c]const u8 = undefined;
    var message: [*c]const u8 = undefined;
    var @"error": c_int = undefined;
    // rustc: "error[E0425]: cannot find value", then " --> src/main.rs:12:5"
    if (g_b.kind == KIND_CARGO) {
        if (libc.strncmp(line, "error", 5) == 0 or libc.strncmp(line, "warning", 7) == 0) {
            const colon: [*c]const u8 = libc.strchr(line, ':');
            g_b.pending_error = @intFromBool(line[0] == 'e');
            _ = libc.snprintf(&g_b.pending_message, g_b.pending_message.len, "%s", if (colon != null) colon + 1 + @intFromBool(colon[1] == ' ') else line);
            // (the summary lines have no place)
            if (libc.strstr(line, "could not compile") != null or libc.strstr(line, "generated ") != null or libc.strstr(line, "aborting") != null) g_b.pending_message[0] = 0;
            return;
        }
        p = libc.strstr(line, "--> ");
        if (p != null and g_b.pending_message[0] != 0) {
            const file: [*c]const u8 = p + 4;
            var q: [*c]const u8 = file + 1;
            while (true) : (q += 1) {
                q = libc.strchr(q, ':');
                if (q == null) break;
                var r: [*c]const u8 = q + 1;
                const n = read_number(&r);
                var column: c_int = 0;
                if (n <= 0) continue;
                if (r.* == ':') {
                    r += 1;
                    column = read_number(&r);
                }
                add_issue(file, q - file, n, if (column > 0) column else 0, g_b.pending_error, &g_b.pending_message);
                break;
            }
            g_b.pending_message[0] = 0;
            return;
        }
    }
    // go: "./main.xmlgo.go:12:5: undefined: x" (no word for the kind: an error)
    if (g_b.kind == KIND_GO and line[0] != '#') {
        p = line + 1;
        while (true) : (p += 1) {
            p = libc.strchr(p, ':');
            if (p == null) break;
            var q: [*c]const u8 = p + 1;
            const n = read_number(&q);
            var column: c_int = 0;
            if (n <= 0 or q.* != ':') continue;
            q += 1;
            {
                var r: [*c]const u8 = q;
                const c = read_number(&r);
                if (c > 0 and r.* == ':') {
                    column = c;
                    q = r + 1;
                }
            }
            while (q.* == ' ') q += 1;
            if (column > 0) {
                add_issue(line, p - line, n, column, 1, q);
                return;
            }
            break;
        }
    }
    // find_package(raven) failed: the IDE says what to do about it at the end
    if (libc.strstr(line, "ravenConfig.cmake") != null or libc.strstr(line, "raven-config.cmake") != null) g_b.package_missing = raven.R_TRUE;
    // CMake Error at CMakeLists.txt:12 (add_executable):
    if (libc.strncmp(line, "CMake Error at ", 15) == 0 or libc.strncmp(line, "CMake Warning at ", 17) == 0) {
        const file: [*c]const u8 = line + @as(usize, if (line[6] == 'E') 15 else 17);
        const colon: [*c]const u8 = libc.strrchr(file, ':');
        if (colon != null) {
            var q: [*c]const u8 = colon + 1;
            const n = read_number(&q);
            if (n > 0) add_issue(file, colon - file, n, 0, @intFromBool(line[6] == 'E'), if (line[6] == 'E') "CMake error (see the Output)" else "CMake warning (see the Output)");
        }
        return;
    }
    // MSVC: file(12,5): error C2065: ... or file(12): warning C4100: ...
    p = libc.strchr(line, '(');
    while (p != null) {
        var q: [*c]const u8 = p + 1;
        const n = read_number(&q);
        var column: c_int = 0;
        if (n > 0) {
            if (q.* == ',') {
                q += 1;
                column = read_number(&q);
            }
            if (q.* == ')' and q[1] == ':' and kind_at(q + 2, &@"error", &message) != 0) {
                var start: [*c]const u8 = line;
                while (start.* == ' ') start += 1;
                add_issue(start, p - start, n, if (column > 0) column else 0, @"error", message);
                return;
            }
        }
        p = libc.strchr(p + 1, '(');
    }
    // GCC, Clang, ravenc: file:12:5: error: ... or file:12: error: ... (C:\ is a drive, not a line)
    p = line + 1;
    while (true) : (p += 1) {
        p = libc.strchr(p, ':');
        if (p == null) break;
        var q: [*c]const u8 = p + 1;
        const n = read_number(&q);
        var column: c_int = 0;
        if (n <= 0 or q.* != ':') continue;
        q += 1;
        {
            var r: [*c]const u8 = q;
            const c = read_number(&r);
            if (c > 0 and r.* == ':') {
                column = c;
                q = r + 1;
            }
        }
        if (kind_at(q, &@"error", &message) != 0) {
            var start: [*c]const u8 = line;
            while (start.* == ' ') start += 1;
            add_issue(start, p - start, n, column, @"error", message);
        }
        return;
    }
}

fn take_output(text: [*c]const u8, length: usize) void {
    var i: usize = 0;
    var start: usize = 0;
    output_append(text, length);
    ide.ide_buffer_add(&g_b.pending, text, length);
    while (i < g_b.pending.size) : (i += 1) {
        if (g_b.pending.data[i] == '\n') {
            g_b.pending.data[i] = 0;
            if (i > start and g_b.pending.data[i - 1] == '\r') g_b.pending.data[i - 1] = 0;
            if (g_b.steps[@intCast(if (g_b.step_at < g_b.step_count) g_b.step_at else 0)].run == 0) parse_line(g_b.pending.data + start);
            start = i + 1;
        }
    }
    if (start != 0) {
        _ = libc.memmove(g_b.pending.data, g_b.pending.data + start, g_b.pending.size - start);
        g_b.pending.size -= start;
        g_b.pending.data[g_b.pending.size] = 0;
    }
}

fn on_issue_activated(list: raven.Rid, index: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = list;
    _ = user_data;
    if (index < 0 or index >= g_b.issue_count) return;
    ide.ide_open_file(g_b.issues[@intCast(index)].file, g_b.issues[@intCast(index)].line);
}

// ---------------------------------------------------------------------------
//  Steps
// -------------------------------------------------------------------------

fn free_steps() void {
    var i: c_int = 0;
    while (i < g_b.step_count) : (i += 1) {
        var j: usize = 0;
        while (g_b.steps[@intCast(i)].argv[j] != null) : (j += 1) libc.free(g_b.steps[@intCast(i)].argv[j]);
        libc.free(g_b.steps[@intCast(i)].directory);
    }
    g_b.steps = std.mem.zeroes([MAX_STEPS]step_t);
    g_b.step_at = 0;
    g_b.step_count = g_b.step_at;
}

fn add_step(directory: [*c]const u8) [*c]step_t {
    var step: [*c]step_t = undefined;
    if (g_b.step_count >= MAX_STEPS) return null;
    step = &g_b.steps[@intCast(g_b.step_count)];
    g_b.step_count += 1;
    step.* = std.mem.zeroes(step_t);
    step.*.directory = ide.ide_strdup(directory);
    return step;
}

fn add_arg(step: [*c]step_t, format: [*c]const u8, ...) callconv(.c) void {
    var text: [2048]u8 = undefined;
    var i: usize = 0;
    while (i < MAX_ARGS and step.*.argv[i] != null) : (i += 1) {}
    if (i >= MAX_ARGS) return;
    var args = @cVaStart();
    _ = libc.vsnprintf(&text, text.len, format, &args);
    @cVaEnd(&args);
    step.*.argv[i] = ide.ide_strdup(&text);
}

fn finish(ok: c_int) void {
    const seconds: f64 = raven.Rget_time() - g_b.started;
    g_b.has_result = raven.R_TRUE;
    g_b.last_ok = ok;
    g_b.finished = raven.Rget_time();
    if (g_b.timer != raven.R_INVALID_ID and raven.Rtimer_is_valid(g_b.timer) != 0) raven.Rtimer_destroy(g_b.timer);
    g_b.timer = raven.R_INVALID_ID;
    free_steps();
    if (g_b.error_count != 0 or g_b.warning_count != 0) {
        var title: [64]u8 = undefined;
        _ = libc.snprintf(&title, title.len, "Build (%d)", g_b.error_count + g_b.warning_count);
        raven.Rdock_area_set_panel_title(ide.g_ide_dock, g_b.issues_list, &title);
    } else {
        raven.Rdock_area_set_panel_title(ide.g_ide_dock, g_b.issues_list, "Build");
    }
    if (g_b.error_count != 0) raven.Rdock_area_open_panel(ide.g_ide_dock, g_b.issues_list);
    if (ok == 0 and g_b.package_missing != 0) {
        output_printf("\n[CMake did not find the Raven package. Choose its folder (the one with bin/, include/ and lib/) in Project > Build settings > " ++
            "Raven package, or on the start page (File > Welcome page).]\n");
        ide.ide_status("The Raven package was not found: Project > Build settings > Raven package.");
        return;
    }
    ide.ide_status(@as([*c]const u8, if (ok != 0) "Done in %.1f s (%d warning%s)." else "Failed after %.1f s: %d error%s, see the Build panel."), seconds, if (ok != 0) g_b.warning_count else g_b.error_count, @as([*c]const u8, if ((if (ok != 0) g_b.warning_count else g_b.error_count) == 1) "" else "s"));
}

// static void start_step(void);
// static void refresh_run_step(void);

fn on_poll(timer: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    var buffer: [8192]u8 = undefined;
    var n: c_int = undefined;
    var code: c_int = 0;
    var guard: c_int = 0;
    _ = timer;
    _ = user_data;
    if (g_b.process == null) return;
    while (true) {
        n = ide.ide_process_read(g_b.process, &buffer, buffer.len);
        if (!(n > 0)) break;
        const g = guard;
        guard += 1;
        if (!(g < 64)) break;
        take_output(&buffer, @intCast(n));
    }
    if (ide.ide_process_done(g_b.process, &code) != 0) {
        while (true) {
            n = ide.ide_process_read(g_b.process, &buffer, buffer.len);
            if (!(n > 0)) break;
            take_output(&buffer, @intCast(n));
        }
        if (g_b.pending.size != 0) {
            take_output("\n", 1);
        }
        ide.ide_process_free(g_b.process);
        g_b.process = null;
        if (g_b.steps[@intCast(g_b.step_at)].run != 0) output_printf("\n[the program ended with code %d]\n", code) else if (code != 0) output_printf("\n[%s failed with code %d]\n", g_b.steps[@intCast(g_b.step_at)].argv[0], code);
        if (code != 0 and g_b.steps[@intCast(g_b.step_at)].run == 0) {
            finish(raven.R_FALSE);
            return;
        }
        g_b.step_at += 1;
        if (g_b.step_at < g_b.step_count) start_step() else finish(raven.R_TRUE);
    }
}

fn start_step() void {
    var step: [*c]step_t = undefined;
    var i: usize = 0;
    refresh_run_step();
    step = &g_b.steps[@intCast(g_b.step_at)];
    output_printf("%s>", @as([*c]const u8, if (step.*.run != 0) "\n" else ""));
    while (step.*.argv[i] != null) : (i += 1) output_printf(" %s", step.*.argv[i]);
    output_printf("\n");
    g_b.process = ide.ide_process_start(@ptrCast(&step.*.argv), step.*.directory);
    if (g_b.process == null) {
        output_printf("cannot start %s (is it installed and in the PATH?)\n", step.*.argv[0]);
        finish(raven.R_FALSE);
        return;
    }
    if (g_b.timer == raven.R_INVALID_ID) g_b.timer = raven.Rtimer_create(0.05, raven.R_TRUE, &on_poll, null);
}

fn begin() void {
    g_b.started = raven.Rget_time();
    g_b.step_at = 0;
    g_b.pending.size = 0;
    g_b.package_missing = raven.R_FALSE;
    clear_issues();
    output_clear();
    if (g_b.note[0] != 0) {
        output_printf("%s\n", &g_b.note);
        g_b.note[0] = 0;
    }
    raven.Rdock_area_open_panel(ide.g_ide_dock, g_b.output);
    start_step();
}

export fn build_reset() void {
    if (g_b.process != null) {
        ide.ide_process_kill(g_b.process);
        ide.ide_process_free(g_b.process);
        g_b.process = null;
    }
    if (g_b.timer != raven.R_INVALID_ID and raven.Rtimer_is_valid(g_b.timer) != 0) raven.Rtimer_destroy(g_b.timer);
    g_b.timer = raven.R_INVALID_ID;
    free_steps();
    clear_issues();
    output_clear();
    g_b.configured_with[0] = 0;
    g_b.note[0] = 0;
    raven.Rdock_area_set_panel_title(ide.g_ide_dock, g_b.issues_list, "Build");
}

// ---------------------------------------------------------------------------
//  What the commands do
// -------------------------------------------------------------------------

fn has_file(name: [*c]const u8) c_int {
    const path = ide.ide_join(ide.g_project_dir, name);
    const ok = ide.ide_file_exists(path);
    libc.free(path);
    return ok;
}

/// The first file of the project with that extension (its top folder), or NULL.
fn first_with_extension(extension: [*c]const u8) [*c]u8 {
    var entries: [*c]ide.ide_entry_t = undefined;
    const count = ide.ide_list_dir(ide.g_project_dir, &entries);
    var i: c_int = 0;
    var found: [*c]u8 = null;
    while (i < count and found == null) : (i += 1) {
        if (entries[@intCast(i)].is_dir == 0 and ide.ide_iequal(ide.ide_extension(&entries[@intCast(i)].name), extension) != 0) found = ide.ide_strdup(&entries[@intCast(i)].name);
    }
    libc.free(entries);
    return found;
}

fn project_kind() kind_t {
    var file: [*c]u8 = undefined;
    if (ide.g_project_dir == null) return KIND_NONE;
    if (has_file("Cargo.toml") != 0) return KIND_CARGO;
    if (has_file("go.mod") != 0) return KIND_GO;
    file = first_with_extension("csproj");
    if (file != null) {
        libc.free(file);
        return KIND_DOTNET;
    }
    if (has_file("build.zig") != 0) return KIND_ZIG;
    if (has_file("CMakeLists.txt") != 0) return KIND_CMAKE;
    file = first_with_extension("xmlpy");
    if (file != null) {
        libc.free(file);
        return KIND_PYTHON;
    }
    file = first_with_extension("xmllua");
    if (file != null) {
        libc.free(file);
        return KIND_LUA;
    }
    // native projects: a program in the language alone
    file = first_with_extension("py");
    if (file != null) {
        libc.free(file);
        return KIND_PYTHON;
    }
    file = first_with_extension("lua");
    if (file != null) {
        libc.free(file);
        return KIND_LUA;
    }
    return KIND_NONE;
}

fn have_project() c_int {
    if (ide.g_project_dir == null) {
        ide.ide_status("Open a project first (Project > Open folder, or New project).");
        return raven.R_FALSE;
    }
    g_b.kind = project_kind();
    if (g_b.kind == KIND_NONE) {
        ide.ide_status("Nothing to build: the project has no CMakeLists.txt, Cargo.toml, go.mod, .csproj, build.zig, .xmlpy, .xmllua, .py or .lua.");
        return raven.R_FALSE;
    }
    return raven.R_TRUE;
}

// What the tools of the languages need to find Raven, from the folder of the
// Raven package: ravenc in the PATH, the library for the linker and for the
// program, the bindings of Python and Lua.
fn set_environment() void {
    var bin: [*c]u8 = undefined;
    var lib: [*c]u8 = undefined;
    var bindings: [*c]u8 = undefined;
    var value: [*c]u8 = undefined;
    const prefix: [*c]const u8 = &ide.g_settings.raven_prefix;
    if (prefix[0] == 0) return;
    bin = ide.ide_join(prefix, "bin");
    lib = ide.ide_join(prefix, "lib");
    bindings = ide.ide_join(prefix, "share/raven/bindings");
    ide.ide_prepend_path(bin);
    if (builtin.os.tag == .windows) {
        value = ide.ide_join(bin, "ravenc.exe");
    } else {
        value = ide.ide_join(bin, "ravenc");
    }
    ide.ide_set_env("RAVENC", value);
    libc.free(value);
    ide.ide_set_env("RAVEN_LIB_DIR", lib);
    if (builtin.os.tag == .windows) {
        value = ide.ide_join(bin, "raven.dll");
    } else if (builtin.os.tag.isDarwin()) {
        value = ide.ide_join(lib, "libraven.dylib");
        ide.ide_set_env("DYLD_LIBRARY_PATH", lib);
    } else {
        value = ide.ide_join(lib, "libraven.so");
        {
            const old: [*c]const u8 = libc.getenv("LD_LIBRARY_PATH");
            const both: [*c]u8 = @ptrCast(libc.malloc(libc.strlen(lib) + (if (old != null) libc.strlen(old) else 0) + 2));
            _ = sprintf(both, "%s%s%s", lib, @as([*c]const u8, if (old != null and old[0] != 0) ":" else ""), @as([*c]const u8, if (old != null) old else ""));
            ide.ide_set_env("LD_LIBRARY_PATH", both);
            libc.free(both);
        }
    }
    ide.ide_set_env("RAVEN_LIBRARY", value);
    libc.free(value);
    {
        const include = ide.ide_join(prefix, "include");
        var flags: [1200]u8 = undefined;
        _ = libc.snprintf(&flags, flags.len, "-I%s", include);
        ide.ide_set_env("CGO_CFLAGS", &flags);
        _ = libc.snprintf(&flags, flags.len, "-L%s", lib);
        ide.ide_set_env("CGO_LDFLAGS", &flags);
        libc.free(include);
    }
    value = ide.ide_join(bindings, "python");
    ide.ide_set_env("PYTHONPATH", value);
    libc.free(value);
    {
        var lua: [1200]u8 = undefined;
        _ = libc.snprintf(&lua, lua.len, "%s/luajit/?.lua;./?.lua;;", bindings);
        ide.ide_set_env("LUA_PATH", &lua);
    }
    libc.free(bin);
    libc.free(lib);
    libc.free(bindings);
}

fn python_program() [*c]const u8 {
    var found: [1024]u8 = undefined;
    if (ide.ide_find_program("python3", &found, found.len) != 0) return "python3";
    return "python";
}

fn is_release() c_int {
    return @intFromBool(ide.g_settings.build_type[0] != 0 and ide.ide_iequal(&ide.g_settings.build_type, "Debug") == 0);
}

fn add_run_arguments(step: [*c]step_t) void {
    if (ide.g_settings.run_arguments[0] != 0) {
        var arguments: [512]u8 = undefined;
        var token: [*c]u8 = undefined;
        _ = libc.snprintf(&arguments, arguments.len, "%s", &ide.g_settings.run_arguments);
        token = strtok(&arguments, " ");
        while (token != null) : (token = strtok(null, " ")) add_arg(step, "%s", token);
    }
}

/// The steps of a project that is not built with CMake. R_FALSE: the command does not apply.
fn add_language_steps(action: [*c]const u8) c_int {
    const build = libc.strcmp(action, "build.build") == 0 or libc.strcmp(action, "build.rebuild") == 0;
    const run = libc.strcmp(action, "build.run") == 0;
    const clean = libc.strcmp(action, "build.clean") == 0 or libc.strcmp(action, "build.rebuild") == 0;
    var step: [*c]step_t = undefined;
    var main_file: [*c]u8 = null;
    if (libc.strcmp(action, "build.configure") == 0) {
        ide.ide_status("Only a CMake project is configured; this one builds as it is.");
        return raven.R_FALSE;
    }
    switch (g_b.kind) {
        KIND_CARGO => {
            if (clean) {
                step = add_step(ide.g_project_dir);
                add_arg(step, "cargo");
                add_arg(step, "clean");
            }
            if (build or run) {
                step = add_step(ide.g_project_dir);
                add_arg(step, "cargo");
                add_arg(step, @as([*c]const u8, if (run) "run" else "build"));
                if (is_release() != 0) add_arg(step, "--release");
                if (run and ide.g_settings.run_arguments[0] != 0) {
                    add_arg(step, "--");
                    add_run_arguments(step);
                }
            }
        },
        KIND_GO => {
            if (clean) {
                step = add_step(ide.g_project_dir);
                add_arg(step, "go");
                add_arg(step, "clean");
            }
            if (build or run) {
                // ravenc writes main.xmlgo.go (//go:generate)
                step = add_step(ide.g_project_dir);
                add_arg(step, "go");
                add_arg(step, "generate");
                add_arg(step, "./...");
                step = add_step(ide.g_project_dir);
                add_arg(step, "go");
                add_arg(step, @as([*c]const u8, if (run) "run" else "build"));
                add_arg(step, ".");
                if (run) add_run_arguments(step);
            }
        },
        KIND_DOTNET => {
            if (clean) {
                step = add_step(ide.g_project_dir);
                add_arg(step, "dotnet");
                add_arg(step, "clean");
            }
            if (build or run) {
                step = add_step(ide.g_project_dir);
                add_arg(step, "dotnet");
                add_arg(step, @as([*c]const u8, if (run) "run" else "build"));
                add_arg(step, "-c");
                add_arg(step, "%s", @as([*c]const u8, if (is_release() != 0) "Release" else "Debug"));
                if (run and ide.g_settings.run_arguments[0] != 0) {
                    add_arg(step, "--");
                    add_run_arguments(step);
                }
            }
        },
        KIND_ZIG => {
            if (build or run) {
                step = add_step(ide.g_project_dir);
                add_arg(step, "zig");
                add_arg(step, "build");
                if (run) add_arg(step, "run");
                if (is_release() != 0) add_arg(step, "-Doptimize=ReleaseFast");
                if (run and ide.g_settings.run_arguments[0] != 0) {
                    add_arg(step, "--");
                    add_run_arguments(step);
                }
            }
        },
        KIND_PYTHON => python: {
            main_file = if (has_file("main.xmlpy") != 0) ide.ide_strdup("main.xmlpy") else first_with_extension("xmlpy");
            if (main_file == null) {
                // a native project: python and its file, nothing of Raven
                main_file = if (has_file("main.py") != 0) ide.ide_strdup("main.py") else first_with_extension("py");
                step = add_step(ide.g_project_dir);
                add_arg(step, "%s", python_program());
                if (run) {
                    step.*.run = raven.R_TRUE;
                    add_arg(step, "%s", main_file);
                    add_run_arguments(step);
                } else {
                    add_arg(step, "-m");
                    add_arg(step, "py_compile");
                    add_arg(step, "%s", main_file);
                }
                libc.free(main_file);
                break :python;
            }
            // building: ravenc reads it (its mistakes are reported); running: python with raven_xmlpy
            step = add_step(ide.g_project_dir);
            if (run) {
                step.*.run = raven.R_TRUE;
                add_arg(step, "%s", python_program());
                add_arg(step, "-m");
                add_arg(step, "raven_xmlpy");
                add_arg(step, "%s", main_file);
                add_run_arguments(step);
            } else {
                add_arg(step, "%s", python_program());
                add_arg(step, "-c");
                add_arg(step, "import raven_xmlpy, py_compile, sys; py_compile.compile(raven_xmlpy.compile_file(sys.argv[1]), doraise=True)");
                add_arg(step, "%s", main_file);
            }
            libc.free(main_file);
        },
        KIND_LUA => lua_case: {
            main_file = if (has_file("main.xmllua") != 0) ide.ide_strdup("main.xmllua") else first_with_extension("xmllua");
            if (main_file == null) {
                // a native project: LuaJIT (or Lua) and its file
                var found: [1024]u8 = undefined;
                var check: [700]u8 = undefined;
                const lua: [*c]const u8 = if (ide.ide_find_program("luajit", &found, found.len) != 0 or ide.ide_find_program("lua", &found, found.len) == 0) "luajit" else "lua";
                main_file = if (has_file("main.lua") != 0) ide.ide_strdup("main.lua") else first_with_extension("lua");
                step = add_step(ide.g_project_dir);
                add_arg(step, "%s", lua);
                if (run) {
                    step.*.run = raven.R_TRUE;
                    add_arg(step, "%s", main_file);
                    add_run_arguments(step);
                } else {
                    // building: the file is read, its mistakes are reported, nothing runs
                    _ = libc.snprintf(&check, check.len, "assert(loadfile('%s'))", main_file);
                    add_arg(step, "-e");
                    add_arg(step, "%s", &check);
                }
                libc.free(main_file);
                break :lua_case;
            }
            step = add_step(ide.g_project_dir);
            if (run) {
                var script: [1200]u8 = undefined;
                step.*.run = raven.R_TRUE;
                add_arg(step, "luajit");
                _ = libc.snprintf(&script, script.len, "%s/share/raven/bindings/luajit/raven_xmllua.lua", @as([*c]const u8, if (ide.g_settings.raven_prefix[0] != 0) &ide.g_settings.raven_prefix else "."));
                add_arg(step, "%s", &script);
                add_arg(step, "%s", main_file);
                add_run_arguments(step);
            } else {
                var output: [600]u8 = undefined;
                _ = libc.snprintf(&output, output.len, "%s.lua", main_file);
                add_arg(step, "ravenc");
                add_arg(step, "%s", main_file);
                add_arg(step, "-o");
                add_arg(step, "%s", &output);
            }
            libc.free(main_file);
        },
        else => return raven.R_FALSE,
    }
    return raven.R_TRUE;
}

fn build_dir() [*c]u8 {
    return ide.ide_join(ide.g_project_dir, "build");
}

/// What the configuration depends on: when it changes, CMake is run again.
fn configuration_key(out: [*c]u8, size: usize) void {
    _ = libc.snprintf(out, size, "%s|%s|%s|%s", ide.g_project_dir, &ide.g_settings.build_type, &ide.g_settings.raven_prefix, &ide.g_settings.generator);
}

/// The generator the build folder was made with ("" when it was not configured yet).
fn cached_generator(build: [*c]const u8, out: [*c]u8, size: usize) void {
    const cache = ide.ide_join(build, "CMakeCache.txt");
    var length: usize = 0;
    const text = raven.Rfile_read(cache, &length);
    var at: [*c]const u8 = undefined;
    out[0] = 0;
    libc.free(cache);
    if (text == null) return;
    at = libc.strstr(text, "CMAKE_GENERATOR:INTERNAL=");
    if (at != null) {
        var n: usize = undefined;
        at += 25;
        n = libc.strcspn(at, "\r\n");
        _ = libc.snprintf(out, size, "%.*s", @as(c_int, @intCast(n)), at);
    }
    raven.Rmemory_free(text);
}

// The generator: the one of the settings; else the one the build folder
// already has; else Ninja when it is installed, else on Windows MinGW
// Makefiles when mingw32-make is there (the default of CMake would be Visual
// Studio, which the Raven of a MinGW package cannot link with).
fn choose_generator(build: [*c]const u8, out: [*c]u8, size: usize) void {
    var found: [1024]u8 = undefined;
    var cached: [256]u8 = undefined;
    cached_generator(build, &cached, cached.len);
    out[0] = 0;
    if (ide.g_settings.generator[0] != 0) {
        // another generator than the one the folder was made with: CMake refuses, so the cache goes
        if (cached[0] != 0 and libc.strcmp(&cached, &ide.g_settings.generator) != 0) {
            const cache = ide.ide_join(build, "CMakeCache.txt");
            _ = ide.ide_remove_file(cache);
            libc.free(cache);
            _ = libc.snprintf(&g_b.note, g_b.note.len, "[the build folder was made with %s: configured again with %s]", &cached, &ide.g_settings.generator);
        }
        _ = libc.snprintf(out, size, "%s", &ide.g_settings.generator);
        return;
    }
    if (cached[0] != 0) return;
    if (ide.ide_find_program("ninja", &found, found.len) != 0) {
        _ = libc.snprintf(out, size, "Ninja");
    } else if (builtin.os.tag == .windows) {
        if (ide.ide_find_program("mingw32-make", &found, found.len) != 0) _ = libc.snprintf(out, size, "MinGW Makefiles");
    }
}

fn add_configure() void {
    const build = build_dir();
    var generator: [256]u8 = undefined;
    const step = add_step(ide.g_project_dir);
    choose_generator(build, &generator, generator.len);
    add_arg(step, "cmake");
    add_arg(step, "-S");
    add_arg(step, "%s", ide.g_project_dir);
    add_arg(step, "-B");
    add_arg(step, "%s", build);
    if (generator[0] != 0) {
        add_arg(step, "-G");
        add_arg(step, "%s", &generator);
    }
    add_arg(step, "-DCMAKE_BUILD_TYPE=%s", @as([*c]const u8, if (ide.g_settings.build_type[0] != 0) &ide.g_settings.build_type else "Debug"));
    add_arg(step, "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON");
    if (ide.g_settings.raven_prefix[0] != 0) add_arg(step, "-DCMAKE_PREFIX_PATH=%s", &ide.g_settings.raven_prefix);
    configuration_key(&g_b.configured_with, g_b.configured_with.len);
    libc.free(build);
}

fn add_build(target: [*c]const u8) void {
    const build = build_dir();
    const step = add_step(ide.g_project_dir);
    add_arg(step, "cmake");
    add_arg(step, "--build");
    add_arg(step, "%s", build);
    add_arg(step, "--config");
    add_arg(step, "%s", @as([*c]const u8, if (ide.g_settings.build_type[0] != 0) &ide.g_settings.build_type else "Debug"));
    add_arg(step, "--parallel");
    if (target != null) {
        add_arg(step, "--target");
        add_arg(step, "%s", target);
    }
    libc.free(build);
}

fn needs_configure() c_int {
    const build = build_dir();
    const cache = ide.ide_join(build, "CMakeCache.txt");
    var key: [2048]u8 = undefined;
    var needs: c_int = @intFromBool(ide.ide_file_exists(cache) == 0);
    configuration_key(&key, key.len);
    if (libc.strcmp(&key, &g_b.configured_with) != 0) needs = raven.R_TRUE;
    libc.free(cache);
    libc.free(build);
    return needs;
}

/// The program the project makes, in the build folder (wherever the generator put it).
fn find_program_file(folder: [*c]const u8, name: [*c]const u8, depth: c_int) [*c]u8 {
    var entries: [*c]ide.ide_entry_t = undefined;
    var count: c_int = undefined;
    var i: c_int = undefined;
    var found: [*c]u8 = null;
    var exe: [300]u8 = undefined;
    if (builtin.os.tag == .windows) {
        _ = libc.snprintf(&exe, exe.len, "%s.exe", name);
    } else {
        _ = libc.snprintf(&exe, exe.len, "%s", name);
    }
    count = ide.ide_list_dir(folder, &entries);
    i = 0;
    while (i < count and found == null) : (i += 1) {
        if (entries[@intCast(i)].is_dir == 0 and ide.ide_iequal(&entries[@intCast(i)].name, &exe) != 0) found = ide.ide_join(folder, &entries[@intCast(i)].name);
    }
    i = 0;
    while (i < count and found == null and depth > 0) : (i += 1) {
        if (entries[@intCast(i)].is_dir != 0 and libc.strcmp(&entries[@intCast(i)].name, "CMakeFiles") != 0 and entries[@intCast(i)].name[0] != '.') {
            const sub = ide.ide_join(folder, &entries[@intCast(i)].name);
            found = find_program_file(sub, name, depth - 1);
            libc.free(sub);
        }
    }
    libc.free(entries);
    return found;
}

fn add_run() void {
    var name: [256]u8 = undefined;
    var build: [*c]u8 = undefined;
    var program: [*c]u8 = undefined;
    var step: [*c]step_t = undefined;
    if (ide.project_target_name(&name, name.len) == 0) {
        _ = libc.snprintf(&g_b.note, g_b.note.len, "[the CMakeLists.txt has no add_executable: it is built, there is nothing to run]");
        return;
    }
    build = build_dir();
    program = find_program_file(build, &name, 4);
    libc.free(build);
    step = add_step(ide.g_project_dir);
    step.*.run = raven.R_TRUE;
    step.*.find = raven.R_TRUE;
    // (found once it is built: looked for again when the step starts)
    add_arg(step, "%s", @as([*c]const u8, if (program != null) program else &name));
    libc.free(program);
    add_run_arguments(step);
}

fn save_everything() c_int {
    var ok: c_int = raven.R_TRUE;
    if (ide.designer_has_document() != 0 and ide.designer_is_modified() != 0 and ide.designer_get_path() != null) ok = @intFromBool(ide.designer_save() != 0 and ok != 0);
    if (ide.editors_any_modified() != 0) ok = @intFromBool(ide.editors_save_all() != 0 and ok != 0);
    if (ide.strings_any_modified() != 0) ok = @intFromBool(ide.strings_save() != 0 and ok != 0);
    return ok;
}

fn action_build(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    if (libc.strcmp(action, "build.stop") == 0) {
        if (g_b.process != null) {
            ide.ide_process_kill(g_b.process);
            output_printf("\n[stopped]\n");
        }
        return;
    }
    if (build_is_running() != 0) {
        ide.ide_status("A build or the program is still running (Build > Stop).");
        return;
    }
    // no project: Run opens the interface in a window, as the designer did
    if (ide.g_project_dir == null and libc.strcmp(action, "build.run") == 0) {
        raven.Raction_fire("view.run", sender);
        return;
    }
    if (have_project() == 0) return;
    _ = save_everything();
    free_steps();
    set_environment();
    g_b.pending_message[0] = 0;
    if (g_b.kind != KIND_CMAKE) {
        if (add_language_steps(action) == 0) return;
    } else if (libc.strcmp(action, "build.configure") == 0) {
        add_configure();
    } else if (libc.strcmp(action, "build.build") == 0) {
        if (needs_configure() != 0) add_configure();
        add_build(null);
    } else if (libc.strcmp(action, "build.run") == 0) {
        if (needs_configure() != 0) add_configure();
        add_build(null);
        add_run();
    } else if (libc.strcmp(action, "build.clean") == 0) {
        add_build("clean");
    } else if (libc.strcmp(action, "build.rebuild") == 0) {
        add_configure();
        add_build(null);
        {
            const step: [*c]step_t = &g_b.steps[@intCast(g_b.step_count - 1)];
            add_arg(step, "--clean-first");
        }
    }
    if (g_b.step_count != 0) {
        ide.ide_status("Building %s...", ide.ide_basename(ide.g_project_dir));
        begin();
    }
}

/// (the program is looked for again once it exists: the first build makes it)
fn refresh_run_step() void {
    var i: c_int = g_b.step_at;
    while (i < g_b.step_count) : (i += 1) {
        if (g_b.steps[@intCast(i)].find != 0 and ide.ide_file_exists(g_b.steps[@intCast(i)].argv[0]) == 0) {
            var name: [256]u8 = undefined;
            const build = build_dir();
            const program: [*c]u8 = if (ide.project_target_name(&name, name.len) != 0) find_program_file(build, &name, 4) else null;
            libc.free(build);
            if (program != null) {
                libc.free(g_b.steps[@intCast(i)].argv[0]);
                g_b.steps[@intCast(i)].argv[0] = program;
            }
        }
    }
}

export fn build_init() void {
    g_b.output = raven.Rwidget_find(ide.g_ide_window, "output");
    g_b.issues_list = raven.Rwidget_find(ide.g_ide_window, "build.problems");
    g_b.timer = raven.R_INVALID_ID;
    raven.Rtext_editor_set_read_only(g_b.output, raven.R_TRUE);
    raven.Rlist_view_set_activated_callback(g_b.issues_list, &on_issue_activated, null);
    raven.Raction_bind("build.configure", &action_build, null);
    raven.Raction_bind("build.build", &action_build, null);
    raven.Raction_bind("build.run", &action_build, null);
    raven.Raction_bind("build.stop", &action_build, null);
    raven.Raction_bind("build.clean", &action_build, null);
    raven.Raction_bind("build.rebuild", &action_build, null);
}

export fn build_shutdown() void {
    if (g_b.process != null) {
        ide.ide_process_kill(g_b.process);
        ide.ide_process_free(g_b.process);
        g_b.process = null;
    }
    free_steps();
    clear_issues();
    ide.ide_buffer_free(&g_b.pending);
}
