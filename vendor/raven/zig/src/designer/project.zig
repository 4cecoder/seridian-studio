// Translated to Zig from vendor/raven/tools/designer/project.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven Designer - project.c
// A project is a folder built with the tools of its language: CMake (C, C++),
// Cargo (Rust), go (Go), dotnet (C#), zig build (Zig), or nothing to build
// (Python, Lua). The content drawer (Ctrl+Space) shows its files; each opens where it belongs.
// New project writes one that builds as it is, of one of two kinds: with a
// Raven interface (its interface with its code in main.xmlc, main.xmlrs...,
// what its tools need, and strings.csv), or native (what the tools of its
// language need and a classic Hello world, nothing of Raven).
// The settings of the IDE for a project are in its file .raven-ide.

const std = @import("std");
const raven = @import("raven");
const ide = @import("ide_h.zig");
const libc = @import("../sys/libc.zig");
// RAVEN_IDE_INCLUDE_DIR ("" when the build does not define it)
const designer_config = @import("designer_config");

// <string.h> functions that libc.zig does not declare
extern "c" fn strcat(dest: [*c]u8, src: [*c]const u8) [*c]u8;

// <ctype.h>, "C" locale
inline fn isspace(ch: u8) bool {
    return std.ascii.isWhitespace(ch);
}
inline fn isalnum(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch);
}
inline fn isalpha(ch: u8) bool {
    return std.ascii.isAlphabetic(ch);
}

export var g_project_dir: [*c]u8 = null;
export var g_settings: ide.ide_settings_t = std.mem.zeroes(ide.ide_settings_t);

// ---------------------------------------------------------------------------
//  Settings
// -------------------------------------------------------------------------

// The package Raven itself comes in, when the IDE runs from one (bin/raven_designer).
fn guess_raven_prefix(out: [*c]u8, size: usize) void {
    const prefix: [*c]u8 = ide.ide_join(ide.ide_exe_dir(), "..");
    const config: [*c]u8 = ide.ide_join(prefix, "lib/cmake/raven/ravenConfig.cmake");
    out[0] = 0;
    if (ide.ide_file_exists(config) != 0) _ = libc.snprintf(out, size, "%s", prefix);
    libc.free(config);
    libc.free(prefix);
}

fn load_settings() void {
    var size: usize = 0;
    {
        // (the package already chosen stays, unless the project says another one)
        var kept: [@sizeOf(@TypeOf(g_settings.raven_prefix))]u8 = undefined;
        _ = libc.snprintf(&kept, @sizeOf(@TypeOf(kept)), "%s", @as([*c]const u8, &g_settings.raven_prefix));
        g_settings = std.mem.zeroes(ide.ide_settings_t);
        _ = libc.snprintf(&g_settings.raven_prefix, @sizeOf(@TypeOf(g_settings.raven_prefix)), "%s", @as([*c]const u8, &kept));
    }
    _ = libc.snprintf(&g_settings.build_type, @sizeOf(@TypeOf(g_settings.build_type)), "Debug");
    if (g_settings.raven_prefix[0] == 0) guess_raven_prefix(&g_settings.raven_prefix, @sizeOf(@TypeOf(g_settings.raven_prefix)));
    // the package chosen once (the start page, Build settings) serves every project
    if (g_settings.raven_prefix[0] == 0) _ = libc.snprintf(&g_settings.raven_prefix, @sizeOf(@TypeOf(g_settings.raven_prefix)), "%s", ide.prefs_get("raven_prefix"));
    if (g_project_dir == null) return;
    const path: [*c]u8 = ide.ide_join(g_project_dir, ".raven-ide");
    const text: [*c]u8 = raven.Rfile_read(path, &size);
    libc.free(path);
    if (text == null) return;
    {
        var line: [*c]u8 = text;
        while (line != null and line.* != 0) {
            const end: [*c]u8 = libc.strchr(line, '\n');
            if (end != null) end.* = 0;
            if (end != null and end > line and (end - 1).* == '\r') (end - 1).* = 0;
            const equal: [*c]u8 = libc.strchr(line, '=');
            if (equal != null) {
                equal.* = 0;
                // #define READ(field, key) if (!strcmp(line, key)) snprintf(g_settings.field, sizeof(g_settings.field), "%s", equal + 1)
                // READ(build_type, "build_type");
                if (libc.strcmp(line, "build_type") == 0) _ = libc.snprintf(&g_settings.build_type, @sizeOf(@TypeOf(g_settings.build_type)), "%s", equal + 1);
                // READ(raven_prefix, "raven_prefix");
                if (libc.strcmp(line, "raven_prefix") == 0) _ = libc.snprintf(&g_settings.raven_prefix, @sizeOf(@TypeOf(g_settings.raven_prefix)), "%s", equal + 1);
                // READ(generator, "generator");
                if (libc.strcmp(line, "generator") == 0) _ = libc.snprintf(&g_settings.generator, @sizeOf(@TypeOf(g_settings.generator)), "%s", equal + 1);
                // READ(run_arguments, "run_arguments");
                if (libc.strcmp(line, "run_arguments") == 0) _ = libc.snprintf(&g_settings.run_arguments, @sizeOf(@TypeOf(g_settings.run_arguments)), "%s", equal + 1);
                // #undef READ
            }
            line = if (end != null) end + 1 else null;
        }
    }
    raven.Rmemory_free(text);
}

export fn project_save_settings() void {
    var out: ide.ide_buffer_t = std.mem.zeroes(ide.ide_buffer_t);
    if (g_project_dir == null) return;
    ide.ide_buffer_printf(&out, "build_type=%s\nraven_prefix=%s\ngenerator=%s\nrun_arguments=%s\n", @as([*c]const u8, &g_settings.build_type), @as([*c]const u8, &g_settings.raven_prefix), @as([*c]const u8, &g_settings.generator), @as([*c]const u8, &g_settings.run_arguments));
    const path: [*c]u8 = ide.ide_join(g_project_dir, ".raven-ide");
    _ = raven.Rfile_write(path, out.data, out.size);
    libc.free(path);
    ide.ide_buffer_free(&out);
}

// ---------------------------------------------------------------------------
//  The files of the project: the content drawer (drawer.c, Ctrl+Space)
// -------------------------------------------------------------------------

export fn project_refresh_explorer() void {
    // (the drawer reads the folders each time it opens: an open one is read again)
    if (ide.drawer_is_open() != 0) ide.drawer_open();
}

// ---------------------------------------------------------------------------
//  Opening files
// -------------------------------------------------------------------------

// The visual editor holds changes: ask before it shows another interface.
fn interface_can_change() c_int {
    if (ide.designer_is_modified() == 0) return raven.R_TRUE;
    const answer: raven.RMessageResult = raven.Rmessage_box(ide.g_ide_window, "Unsaved changes", "The interface has changes that were not saved. Save them?", raven.R_MESSAGE_YES_NO_CANCEL);
    if (answer == raven.R_MESSAGE_RESULT_CANCEL) return raven.R_FALSE;
    if (answer == raven.R_MESSAGE_RESULT_YES) return ide.designer_save();
    return raven.R_TRUE;
}

// void designer_open_file(const char* path);   (ide.designer_open_file)

// The visual editor shows this file now.
fn in_visual_editor(path: [*c]const u8) c_int {
    return @intFromBool(ide.designer_has_document() != 0 and ide.designer_get_path() != null and ide.ide_same_path(ide.designer_get_path(), path) != 0);
}

fn is_interface_file(path: [*c]const u8) c_int {
    return @intFromBool(ide.ide_interface_language(path) != null or ide.ide_iequal(ide.ide_extension(path), "xml") != 0);
}

export fn ide_open_file(path: [*c]const u8, line: c_int) void {
    const ext: [*c]const u8 = ide.ide_extension(path);
    if (ide.ide_file_exists(path) == 0) {
        ide.ide_status("%s does not exist.", path);
        return;
    }
    ide.welcome_hide();
    if (is_interface_file(path) != 0 and in_visual_editor(path) != 0) {
        // it is in the preview: there it is edited (an .xmlc is whole in its XML panel, a line of the file is a line of the panel)
        raven.Rdock_area_open_panel(ide.g_ide_dock, ide.g_ide_center);
        if (line > 0) ide.designer_go_to_line(line);
    } else if (is_interface_file(path) != 0) {
        // an interface opens as text, like any code: its preview is the island, or the visual editor when asked (ide_preview_file)
        _ = ide.editors_open(path, line);
        ide.island_show_preview();
    } else if (ide.ide_iequal(ext, "csv") != 0 and line <= 0) {
        ide.strings_open(path);
    } else {
        _ = ide.editors_open(path, line);
    }
}

export fn ide_preview_file(path: [*c]const u8) void {
    var text: [*c]u8 = null;
    var modified: c_int = raven.R_FALSE;
    var ok: c_int = undefined;
    if (is_interface_file(path) == 0) {
        ide_open_file(path, 0);
        return;
    }
    if (ide.ide_file_exists(path) == 0) {
        ide.ide_status("%s does not exist.", path);
        return;
    }
    ide.welcome_hide();
    if (in_visual_editor(path) == 0) {
        if (interface_can_change() == 0) return;
        // the file leaves its code editor for the visual editor, its unsaved changes with it
        const editor: raven.Rid = ide.editors_find(path);
        if (editor != raven.R_INVALID_ID) {
            text = ide.ide_strdup(raven.Rtext_editor_get_text(editor));
            modified = ide.editors_is_modified(editor);
            ide.editors_close_file(path);
        }
        if (ide.ide_interface_language(path) != null) {
            ok = ide.xmlc_open_text(path, text);
        } else {
            if (ide.xmlc_is_open() != 0) ide.xmlc_close();
            if (text != null) ide.designer_load_interface(text, path, raven.R_FALSE) else ide.designer_open_file(path);
            ok = ide.designer_has_document();
        }
        libc.free(text);
        if (ok == 0) return;
        if (modified != 0) ide.designer_set_modified(raven.R_TRUE);
    }
    raven.Rdock_area_open_panel(ide.g_ide_dock, ide.g_ide_center);
    ide.ide_status("Preview of %s. Close the preview (View > Close the preview) to go back to its code.", ide.ide_basename(path));
}

// ---------------------------------------------------------------------------
//  Templates of a new project, one per language
//
//  {{NAME}} is the name of the project, {{BINDINGS}} the folder of the
//  bindings of Raven (share/raven/bindings in a package).
// -------------------------------------------------------------------------

const TEMPLATE_STRINGS =
    "key,en,fr\n" ++
    "hello.title,Hello!,Bonjour !\n" ++
    "hello.none,You have not clicked yet.,Vous n'avez pas encore cliqué.\n" ++
    "hello.button,Click me,Cliquez-moi\n" ++
    "clicks.one,{n} click,{n} clic\n" ++
    "clicks.other,{n} clicks,{n} clics\n";

// the interface, the same in every language: {{CALLBACK}} is the name of the function
const TEMPLATE_WINDOW_XML =
    "<Window Title=\"{{NAME}}\" Width=\"480\" Height=\"320\">\n" ++
    "\t<VBox Spacing=\"12\" Slot.Padding=\"24\">\n" ++
    "\t\t<Label Text=\"@hello.title\" TextSize=\"24\"/>\n" ++
    "\t\t<Label Name=\"status\" Text=\"@hello.none\" Opacity=\"0.7\"/>\n" ++
    "\t\t<Button Text=\"@hello.button\" Style=\"Primary\" OnClicked=\"{{{CALLBACK}}}\" Slot.HAlign=\"Left\"/>\n" ++
    "\t</VBox>\n" ++
    "</Window>\n";

const TEMPLATE_CMAKE =
    "cmake_minimum_required(VERSION 3.16)\n" ++
    "project({{NAME}} {{CMAKE_LANGUAGE}})\n" ++
    "\n" ++
    "# Raven: the package (bin/, include/, lib/). The IDE gives its folder in CMAKE_PREFIX_PATH.\n" ++
    "find_package(raven REQUIRED)\n" ++
    "\n" ++
    "# {{MAIN}} holds the interface and its code: ravenc turns it into {{LANGUAGE}} (raven_target_xmlc)\n" ++
    "add_executable({{NAME}} {{MAIN}} strings.csv)\n" ++
    "target_link_libraries({{NAME}} PRIVATE raven::raven)\n" ++
    "raven_target_xmlc({{NAME}})\n" ++
    "if(MSVC)\n" ++
    "\ttarget_compile_definitions({{NAME}} PRIVATE _CRT_SECURE_NO_WARNINGS)\n" ++
    "endif()\n";

const SCRIPT_C =
    "<!-- {{NAME}}: the interface and its C code, in one file. F5 builds and runs it. -->\n" ++
    "<script>\n" ++
    "#include <stdio.h>\n" ++
    "\n" ++
    "static int g_clicks = 0;\n" ++
    "\n" ++
    "/* OnClicked=\"{on_hello}\" below calls this function: the compiler checks it */\n" ++
    "static void on_hello(Rid sender, const char* action, void* user_data) {\n" ++
    "\t(void)sender;\n" ++
    "\t(void)action;\n" ++
    "\t(void)user_data;\n" ++
    "\tg_clicks++;\n" ++
    "\t/* ui.status: the widget with Name=\"status\" */\n" ++
    "\tRlabel_set_text(ui.status, Rtr_plural(\"clicks\", g_clicks));\n" ++
    "}\n" ++
    "\n" ++
    "int main(void) {\n" ++
    "\tif (!Rinit(R_BACKEND_VULKAN)) return 1;\n" ++
    "\tRlocale_load_csv(\"strings.csv\");\n" ++
    "\tRlocale_set_language(Rlocale_get_system_language());\n" ++
    "\tmain_create();\n" ++
    "\twhile (Rdraw_frame()) {}\n" ++
    "\tRshutdown();\n" ++
    "\treturn 0;\n" ++
    "}\n" ++
    "</script>\n" ++
    "\n";

const SCRIPT_CPP =
    "<!-- {{NAME}}: the interface and its C++ code, in one file. F5 builds and runs it. -->\n" ++
    "<script>\n" ++
    "#include <string>\n" ++
    "\n" ++
    "static int g_clicks = 0;\n" ++
    "\n" ++
    "// OnClicked=\"{on_hello}\" below calls this function: the compiler checks it\n" ++
    "static void on_hello(Rid sender, const char* action) {\n" ++
    "\t(void)sender;\n" ++
    "\t(void)action;\n" ++
    "\tg_clicks++;\n" ++
    "\t// ui.status: the widget with Name=\"status\"\n" ++
    "\tRlabel_set_text(ui.status, Rtr_plural(\"clicks\", g_clicks));\n" ++
    "}\n" ++
    "\n" ++
    "int main() {\n" ++
    "\tif (!Rinit(R_BACKEND_VULKAN)) return 1;\n" ++
    "\tRlocale_load_csv(\"strings.csv\");\n" ++
    "\tRlocale_set_language(Rlocale_get_system_language());\n" ++
    "\tmain_create();\n" ++
    "\twhile (Rdraw_frame()) {}\n" ++
    "\tRshutdown();\n" ++
    "\treturn 0;\n" ++
    "}\n" ++
    "</script>\n" ++
    "\n";

const CARGO_TOML =
    "[package]\n" ++
    "name = \"{{NAME}}\"\n" ++
    "version = \"0.1.0\"\n" ++
    "edition = \"2021\"\n" ++
    "\n" ++
    "[dependencies]\n" ++
    "raven = { package = \"raven-gui\", path = \"{{BINDINGS}}/rust\" }\n" ++
    "\n" ++
    "[build-dependencies]\n" ++
    "raven-build = { package = \"raven-gui-build\", path = \"{{BINDINGS}}/rust-build\" }\n";

const CARGO_BUILD_RS =
    "// ravenc turns src/main.xmlrs into Rust ($OUT_DIR/main.xmlrs.rs)\n" ++
    "fn main() {\n" ++
    "    raven_build::compile(\"src/main.xmlrs\");\n" ++
    "}\n";

const CARGO_MAIN_RS =
    "// The program is src/main.xmlrs: the interface and its Rust code.\n" ++
    "include!(concat!(env!(\"OUT_DIR\"), \"/main.xmlrs.rs\"));\n";

const SCRIPT_RUST =
    "<!-- {{NAME}}: the interface and its Rust code, in one file. F5 builds and runs it. -->\n" ++
    "<script>\n" ++
    "use raven::*;\n" ++
    "use std::sync::atomic::{AtomicI32, Ordering};\n" ++
    "\n" ++
    "static CLICKS: AtomicI32 = AtomicI32::new(0);\n" ++
    "\n" ++
    "/// OnClicked=\"{on_hello}\" below calls this function: the compiler checks it\n" ++
    "fn on_hello(_sender: Rid, _action: &str) {\n" ++
    "    let clicks = CLICKS.fetch_add(1, Ordering::SeqCst) + 1;\n" ++
    "    // ui().status: the widget with Name=\"status\"\n" ++
    "    unsafe { Rlabel_set_text(ui().status, Rtr_plural(cstr(\"clicks\").as_ptr(), clicks)) };\n" ++
    "}\n" ++
    "\n" ++
    "fn main() {\n" ++
    "    unsafe {\n" ++
    "        if Rinit(R_BACKEND_VULKAN) == 0 {\n" ++
    "            return;\n" ++
    "        }\n" ++
    "        Rlocale_load_csv(cstr(\"strings.csv\").as_ptr());\n" ++
    "        Rlocale_set_language(Rlocale_get_system_language());\n" ++
    "    }\n" ++
    "    main_create();\n" ++
    "    unsafe {\n" ++
    "        while Rdraw_frame() != 0 {}\n" ++
    "        Rshutdown();\n" ++
    "    }\n" ++
    "}\n" ++
    "</script>\n" ++
    "\n";

const SCRIPT_PYTHON =
    "<!-- {{NAME}}: the interface and its Python code, in one file. F5 runs it. -->\n" ++
    "<script>\n" ++
    "import sys\n" ++
    "import raven as r\n" ++
    "\n" ++
    "clicks = 0\n" ++
    "\n" ++
    "\n" ++
    "# OnClicked=\"{on_hello}\" below calls this function\n" ++
    "def on_hello(sender, action):\n" ++
    "    global clicks\n" ++
    "    clicks += 1\n" ++
    "    # ui.status: the widget with Name=\"status\"\n" ++
    "    r.Rlabel_set_text(ui.status, r.Rtr_plural(\"clicks\", clicks))\n" ++
    "\n" ++
    "\n" ++
    "if __name__ == \"__main__\":\n" ++
    "    if not r.Rinit(r.R_BACKEND_VULKAN):\n" ++
    "        sys.exit(1)\n" ++
    "    r.Rlocale_load_csv(\"strings.csv\")\n" ++
    "    r.Rlocale_set_language(r.Rlocale_get_system_language())\n" ++
    "    main_create()\n" ++
    "    while r.Rdraw_frame():\n" ++
    "        pass\n" ++
    "    r.Rshutdown()\n" ++
    "</script>\n" ++
    "\n";

const GO_MOD =
    "module {{NAME}}\n" ++
    "\n" ++
    "go 1.18\n" ++
    "\n" ++
    "require raven v0.0.0\n" ++
    "\n" ++
    "replace raven => {{BINDINGS}}/go\n";

const GO_GENERATE =
    "package main\n" ++
    "\n" ++
    "// ravenc turns main.xmlgo into Go (main.xmlgo.go): go generate, then go build\n" ++
    "//go:generate ravenc main.xmlgo -o main.xmlgo.go\n";

const SCRIPT_GO =
    "<!-- {{NAME}}: the interface and its Go code, in one file. F5 builds and runs it. -->\n" ++
    "<script>\n" ++
    "package main\n" ++
    "\n" ++
    "import \"raven/raven\"\n" ++
    "\n" ++
    "var clicks = 0\n" ++
    "\n" ++
    "// OnClicked=\"{on_hello}\" below calls this function: the compiler checks it\n" ++
    "func on_hello(sender raven.ID, action string) {\n" ++
    "\tclicks++\n" ++
    "\t// ui.status: the widget with Name=\"status\"\n" ++
    "\traven.LabelSetText(ui.status, raven.TrPlural(\"clicks\", clicks))\n" ++
    "}\n" ++
    "\n" ++
    "func main() {\n" ++
    "\tif raven.Init(raven.R_BACKEND_VULKAN) == 0 {\n" ++
    "\t\treturn\n" ++
    "\t}\n" ++
    "\traven.LocaleLoadCsv(\"strings.csv\")\n" ++
    "\traven.LocaleSetLanguage(raven.LocaleGetSystemLanguage())\n" ++
    "\tmain_create()\n" ++
    "\tfor raven.DrawFrame() != 0 {\n" ++
    "\t}\n" ++
    "\traven.Shutdown()\n" ++
    "}\n" ++
    "</script>\n" ++
    "\n";

const CSPROJ =
    "<Project Sdk=\"Microsoft.NET.Sdk\">\n" ++
    "  <PropertyGroup>\n" ++
    "    <OutputType>Exe</OutputType>\n" ++
    "    <TargetFramework>net8.0</TargetFramework>\n" ++
    "    <Nullable>disable</Nullable>\n" ++
    "    <ImplicitUsings>disable</ImplicitUsings>\n" ++
    "  </PropertyGroup>\n" ++
    "  <ItemGroup>\n" ++
    "    <Compile Include=\"{{BINDINGS}}/csharp/Raven.cs\" Link=\"Raven.cs\" />\n" ++
    "    <None Update=\"strings.csv\" CopyToOutputDirectory=\"PreserveNewest\" />\n" ++
    "  </ItemGroup>\n" ++
    "  <!-- ravenc turns every .xmlcs of the project into C# before the compiler runs -->\n" ++
    "  <Import Project=\"{{BINDINGS}}/csharp/Raven.XmlCs.targets\" />\n" ++
    "</Project>\n";

const SCRIPT_CSHARP =
    "<!-- {{NAME}}: the interface and its C# code, in one file. F5 builds and runs it. -->\n" ++
    "<script>\n" ++
    "using Raven;\n" ++
    "\n" ++
    "public static partial class MainUi\n" ++
    "{\n" ++
    "    static int clicks;\n" ++
    "\n" ++
    "    // OnClicked=\"{OnHello}\" below calls this method: the compiler checks it\n" ++
    "    static void OnHello(uint sender, string action)\n" ++
    "    {\n" ++
    "        clicks++;\n" ++
    "        // status: the widget with Name=\"status\"\n" ++
    "        R.Rlabel_set_text(status, R.Rtr_plural(\"clicks\", clicks));\n" ++
    "    }\n" ++
    "}\n" ++
    "\n" ++
    "public static class Program\n" ++
    "{\n" ++
    "    public static int Main()\n" ++
    "    {\n" ++
    "        if (R.Rinit(RBackend.R_BACKEND_VULKAN) == 0) return 1;\n" ++
    "        R.Rlocale_load_csv(\"strings.csv\");\n" ++
    "        R.Rlocale_set_language(R.Rlocale_get_system_language());\n" ++
    "        MainUi.Create();\n" ++
    "        while (R.Rdraw_frame() != 0) { }\n" ++
    "        R.Rshutdown();\n" ++
    "        return 0;\n" ++
    "    }\n" ++
    "}\n" ++
    "</script>\n" ++
    "\n";

const BUILD_ZIG =
    "const std = @import(\"std\");\n" ++
    "// (copies of bindings/zig of Raven: a build.zig only imports files of its project)\n" ++
    "const xmlzig = @import(\"raven/xmlzig.zig\");\n" ++
    "\n" ++
    "pub fn build(b: *std.Build) void {\n" ++
    "    const target = b.standardTargetOptions(.{});\n" ++
    "    const optimize = b.standardOptimizeOption(.{});\n" ++
    "    const raven = b.createModule(.{ .root_source_file = b.path(\"raven/raven.zig\"), .target = target, .optimize = optimize });\n" ++
    "    // ravenc turns main.xmlzig into Zig: it is the program\n" ++
    "    const exe = b.addExecutable(.{\n" ++
    "        .name = \"{{NAME}}\",\n" ++
    "        .root_module = b.createModule(.{ .root_source_file = xmlzig.compile(b, \"main.xmlzig\"), .target = target, .optimize = optimize }),\n" ++
    "    });\n" ++
    "    exe.root_module.addImport(\"raven\", raven);\n" ++
    "    exe.root_module.linkSystemLibrary(\"raven\", .{});\n" ++
    "    exe.root_module.link_libc = true;\n" ++
    "    if (b.graph.env_map.get(\"RAVEN_LIB_DIR\")) |dir| exe.root_module.addLibraryPath(.{ .cwd_relative = dir });\n" ++
    "    b.installArtifact(exe);\n" ++
    "    const run = b.addRunArtifact(exe);\n" ++
    "    run.setCwd(b.path(\".\"));\n" ++
    "    b.step(\"run\", \"Run the program\").dependOn(&run.step);\n" ++
    "}\n";

const SCRIPT_ZIG =
    "<!-- {{NAME}}: the interface and its Zig code, in one file. F5 builds and runs it. -->\n" ++
    "<script>\n" ++
    "const r = @import(\"raven\");\n" ++
    "\n" ++
    "var clicks: c_int = 0;\n" ++
    "\n" ++
    "// OnClicked=\"{on_hello}\" below calls this function: the compiler checks it\n" ++
    "fn on_hello(sender: r.Rid, action: ?[*:0]const u8, user_data: ?*anyopaque) callconv(.C) void {\n" ++
    "    _ = sender;\n" ++
    "    _ = action;\n" ++
    "    _ = user_data;\n" ++
    "    clicks += 1;\n" ++
    "    // ui.status: the widget with Name=\"status\"\n" ++
    "    r.Rlabel_set_text(ui.status, r.Rtr_plural(\"clicks\", clicks));\n" ++
    "}\n" ++
    "\n" ++
    "pub fn main() void {\n" ++
    "    if (r.Rinit(r.R_BACKEND_VULKAN) == 0) return;\n" ++
    "    _ = r.Rlocale_load_csv(\"strings.csv\");\n" ++
    "    _ = r.Rlocale_set_language(r.Rlocale_get_system_language());\n" ++
    "    _ = main_create();\n" ++
    "    while (r.Rdraw_frame() != 0) {}\n" ++
    "    r.Rshutdown();\n" ++
    "}\n" ++
    "</script>\n" ++
    "\n";

const SCRIPT_LUA =
    "<!-- {{NAME}}: the interface and its Lua code (LuaJIT), in one file. F5 runs it. -->\n" ++
    "<script>\n" ++
    "local r = require(\"raven\")\n" ++
    "\n" ++
    "clicks = 0\n" ++
    "\n" ++
    "-- OnClicked=\"{on_hello}\" below calls this function (a global function)\n" ++
    "function on_hello(sender, action)\n" ++
    "\tclicks = clicks + 1\n" ++
    "\t-- ui.status: the widget with Name=\"status\"\n" ++
    "\tr.Rlabel_set_text(ui.status, r.Rtr_plural(\"clicks\", clicks))\n" ++
    "end\n" ++
    "\n" ++
    "if r.Rinit(r.R_BACKEND_VULKAN) == 0 then os.exit(1) end\n" ++
    "r.Rlocale_load_csv(\"strings.csv\")\n" ++
    "r.Rlocale_set_language(r.Rlocale_get_system_language())\n" ++
    "main_create()\n" ++
    "while r.Rdraw_frame() ~= 0 do end\n" ++
    "r.Rshutdown()\n" ++
    "</script>\n" ++
    "\n";

// ---------------------------------------------------------------------------
//  Native projects: the classic Hello world of each language, built with its
//  own tools, and nothing of Raven (no interface file, no strings.csv).
// -------------------------------------------------------------------------

const NATIVE_CMAKE =
    "cmake_minimum_required(VERSION 3.16)\n" ++
    "project({{NAME}} {{CMAKE_LANGUAGE}})\n" ++
    "\n" ++
    "add_executable({{NAME}} {{MAIN}})\n" ++
    "if(MSVC)\n" ++
    "\ttarget_compile_definitions({{NAME}} PRIVATE _CRT_SECURE_NO_WARNINGS)\n" ++
    "endif()\n";

const NATIVE_C =
    "#include <stdio.h>\n" ++
    "\n" ++
    "int main(void) {\n" ++
    "\tprintf(\"Hello, world!\\n\");\n" ++
    "\treturn 0;\n" ++
    "}\n";

const NATIVE_CPP =
    "#include <iostream>\n" ++
    "\n" ++
    "int main() {\n" ++
    "\tstd::cout << \"Hello, world!\" << std::endl;\n" ++
    "\treturn 0;\n" ++
    "}\n";

const NATIVE_CARGO_TOML =
    "[package]\n" ++
    "name = \"{{NAME}}\"\n" ++
    "version = \"0.1.0\"\n" ++
    "edition = \"2021\"\n" ++
    "\n" ++
    "[dependencies]\n";

const NATIVE_RUST =
    "fn main() {\n" ++
    "    println!(\"Hello, world!\");\n" ++
    "}\n";

const NATIVE_PYTHON =
    "def main():\n" ++
    "    print(\"Hello, world!\")\n" ++
    "\n" ++
    "\n" ++
    "if __name__ == \"__main__\":\n" ++
    "    main()\n";

const NATIVE_GO_MOD =
    "module {{NAME}}\n" ++
    "\n" ++
    "go 1.18\n";

const NATIVE_GO =
    "package main\n" ++
    "\n" ++
    "import \"fmt\"\n" ++
    "\n" ++
    "func main() {\n" ++
    "\tfmt.Println(\"Hello, world!\")\n" ++
    "}\n";

const NATIVE_CSPROJ =
    "<Project Sdk=\"Microsoft.NET.Sdk\">\n" ++
    "  <PropertyGroup>\n" ++
    "    <OutputType>Exe</OutputType>\n" ++
    "    <TargetFramework>net8.0</TargetFramework>\n" ++
    "    <Nullable>enable</Nullable>\n" ++
    "    <ImplicitUsings>enable</ImplicitUsings>\n" ++
    "  </PropertyGroup>\n" ++
    "</Project>\n";

const NATIVE_CSHARP =
    "public static class Program\n" ++
    "{\n" ++
    "    public static void Main()\n" ++
    "    {\n" ++
    "        System.Console.WriteLine(\"Hello, world!\");\n" ++
    "    }\n" ++
    "}\n";

const NATIVE_BUILD_ZIG =
    "const std = @import(\"std\");\n" ++
    "\n" ++
    "pub fn build(b: *std.Build) void {\n" ++
    "    const target = b.standardTargetOptions(.{});\n" ++
    "    const optimize = b.standardOptimizeOption(.{});\n" ++
    "    const exe = b.addExecutable(.{\n" ++
    "        .name = \"{{NAME}}\",\n" ++
    "        .root_module = b.createModule(.{ .root_source_file = b.path(\"src/main.zig\"), .target = target, .optimize = optimize }),\n" ++
    "    });\n" ++
    "    b.installArtifact(exe);\n" ++
    "    const run = b.addRunArtifact(exe);\n" ++
    "    b.step(\"run\", \"Run the program\").dependOn(&run.step);\n" ++
    "}\n";

const NATIVE_ZIG =
    "const std = @import(\"std\");\n" ++
    "\n" ++
    "pub fn main() void {\n" ++
    "    std.debug.print(\"Hello, world!\\n\", .{});\n" ++
    "}\n";

const NATIVE_LUA =
    "print(\"Hello, world!\")\n";

// "{{NAME}}" and the others, replaced
fn expand(text: [*c]const u8, name: [*c]const u8, bindings: [*c]const u8, extra_key: [*c]const u8, extra_value: [*c]const u8) [*c]u8 {
    var out: ide.ide_buffer_t = std.mem.zeroes(ide.ide_buffer_t);
    var p: [*c]const u8 = text;
    while (p.* != 0) {
        const open: [*c]const u8 = libc.strstr(p, "{{");
        var value: [*c]const u8 = null;
        var skip: usize = 0;
        if (open == null) {
            ide.ide_buffer_add(&out, p, libc.strlen(p));
            break;
        }
        ide.ide_buffer_add(&out, p, @intCast(open - p));
        if (libc.strncmp(open, "{{NAME}}", 8) == 0) {
            value = name;
            skip = 8;
        } else if (libc.strncmp(open, "{{BINDINGS}}", 12) == 0) {
            value = bindings;
            skip = 12;
        } else if (extra_key != null and libc.strncmp(open, extra_key, libc.strlen(extra_key)) == 0) {
            value = extra_value;
            skip = libc.strlen(extra_key);
        }
        if (value != null) {
            ide.ide_buffer_add(&out, value, libc.strlen(value));
            p = open + skip;
        } else {
            ide.ide_buffer_add(&out, "{", 1);
            p = open + 1;
        }
    }
    return if (out.data != null) out.data else ide.ide_strdup("");
}

// Where the bindings of Raven are: the package, or the sources the IDE was built from.
fn bindings_dir() [*c]u8 {
    var candidates: [3][*c]u8 = undefined;
    var found: [*c]u8 = null;
    var i: c_int = 0;
    candidates[0] = if (g_settings.raven_prefix[0] != 0) ide.ide_join(&g_settings.raven_prefix, "share/raven/bindings") else null;
    candidates[1] = ide.ide_join(ide.ide_exe_dir(), "../share/raven/bindings");
    candidates[2] = if (designer_config.ide_include_dir[0] != 0) ide.ide_join(designer_config.ide_include_dir, "../bindings") else null;
    i = 0;
    while (i < 3) : (i += 1) {
        if (found == null and candidates[@intCast(i)] != null and ide.ide_is_dir(candidates[@intCast(i)]) != 0) found = ide.ide_normalize(candidates[@intCast(i)]);
        libc.free(candidates[@intCast(i)]);
    }
    return if (found != null) found else ide.ide_strdup("RAVEN/share/raven/bindings");
}

fn copy_file(from: [*c]const u8, to: [*c]const u8) c_int {
    var size: usize = 0;
    const data: [*c]u8 = raven.Rfile_read(from, &size);
    if (data == null) return raven.R_FALSE;
    const ok: c_int = raven.Rfile_write(to, data, size);
    raven.Rmemory_free(data);
    return ok;
}

// ---------------------------------------------------------------------------
//  Projects
// -------------------------------------------------------------------------

export fn project_target_name(out: [*c]u8, size: usize) c_int {
    var p: [*c]const u8 = undefined;
    var length: usize = 0;
    out[0] = 0;
    if (g_project_dir == null) return raven.R_FALSE;
    const path: [*c]u8 = ide.ide_join(g_project_dir, "CMakeLists.txt");
    const text: [*c]u8 = raven.Rfile_read(path, &length);
    libc.free(path);
    if (text == null) return raven.R_FALSE;
    p = text;
    while (true) : (p += 1) {
        p = libc.strstr(p, "add_executable");
        if (p == null) break;
        var q: [*c]const u8 = p + 14;
        var n: usize = 0;
        while (q.* == ' ' or q.* == '\t') q += 1;
        if (q.* != '(') continue;
        q += 1;
        while (isspace(q.*)) q += 1;
        while (q[n] != 0 and (isalnum(q[n]) or q[n] == '_' or q[n] == '-' or q[n] == '.' or q[n] == '$' or q[n] == '{' or q[n] == '}')) n += 1;
        if (n == 0) continue;
        // add_executable(${PROJECT_NAME} ...): the name of the project
        if (libc.strncmp(q, "${PROJECT_NAME}", 15) == 0) {
            var pr: [*c]const u8 = libc.strstr(text, "project(");
            if (pr != null) {
                pr += 8;
                while (isspace(pr.*)) pr += 1;
                n = 0;
                while (pr[n] != 0 and (isalnum(pr[n]) or pr[n] == '_' or pr[n] == '-')) n += 1;
                _ = libc.snprintf(out, size, "%.*s", @as(c_int, @truncate(@as(isize, @bitCast(n)))), pr);
            }
        } else {
            _ = libc.snprintf(out, size, "%.*s", @as(c_int, @truncate(@as(isize, @bitCast(n)))), q);
        }
        break;
    }
    raven.Rmemory_free(text);
    return @intFromBool(out[0] != 0);
}

// What the IDE holds goes away: the interface, the code editors, the build.
fn close_everything() void {
    ide.build_reset();
    ide.editors_close_all();
    ide.designer_close();
}

export fn project_close() c_int {
    if (ide.ide_confirm_unsaved("closing the project") == 0) return raven.R_FALSE;
    close_everything();
    libc.free(g_project_dir);
    g_project_dir = null;
    load_settings();
    project_refresh_explorer();
    ide.strings_reload();
    ide.welcome_show();
    ide.designer_update_title();
    ide.ide_status("Project closed.");
    return raven.R_TRUE;
}

export fn project_open(folder: [*c]const u8) c_int {
    if (ide.ide_is_dir(folder) == 0) {
        ide.ide_status("%s is not a folder.", folder);
        _ = raven.Rmessage_box(ide.g_ide_window, "Open a project", "This folder does not exist (any more).", raven.R_MESSAGE_OK);
        return raven.R_FALSE;
    }
    const normalized: [*c]u8 = ide.ide_normalize(folder);
    {
        var n: usize = libc.strlen(normalized);
        while (n > 1 and normalized[n - 1] == '/') {
            n -= 1;
            normalized[n] = 0;
        }
    }
    // another project: what the first one holds is saved (or not) and closed
    if (ide.ide_confirm_unsaved("opening another project") == 0) {
        libc.free(normalized);
        return raven.R_FALSE;
    }
    close_everything();
    libc.free(g_project_dir);
    g_project_dir = normalized;
    load_settings();
    project_refresh_explorer();
    ide.strings_reload();
    ide.welcome_hide();
    ide.recent_add(g_project_dir);
    // the interface of the project, when there is one: main.xml?? at the top or in src/
    {
        const folders = [_][*c]const u8{ "", "src" };
        var f: c_int = 0;
        var i: c_int = 0;
        var opened: c_int = 0;
        f = 0;
        while (f < 2 and opened == 0) : (f += 1) {
            const dir: [*c]u8 = if (f != 0) ide.ide_join(g_project_dir, folders[@intCast(f)]) else ide.ide_strdup(g_project_dir);
            i = 0;
            while (i < ide.ide_language_count() and opened == 0) : (i += 1) {
                var name: [64]u8 = undefined;
                _ = libc.snprintf(&name, @sizeOf(@TypeOf(name)), "main.%s", ide.ide_language_at(i).*.extension);
                const path: [*c]u8 = ide.ide_join(dir, &name);
                if (ide.ide_file_exists(path) != 0) {
                    ide_open_file(path, 0);
                    opened = 1;
                }
                libc.free(path);
            }
            libc.free(dir);
        }
        // a native project: its program
        {
            const natives = [_][*c]const u8{ "main.c", "main.cpp", "src/main.rs", "main.py", "main.go", "Program.cs", "src/main.zig", "main.lua" };
            i = 0;
            while (i < @as(c_int, natives.len) and opened == 0) : (i += 1) {
                const path: [*c]u8 = ide.ide_join(g_project_dir, natives[@intCast(i)]);
                if (ide.ide_file_exists(path) != 0) {
                    ide_open_file(path, 0);
                    opened = 1;
                }
                libc.free(path);
            }
        }
    }
    ide.designer_update_title();
    ide.ide_status("Project %s opened. F5 builds and runs it.", ide.ide_basename(g_project_dir));
    return raven.R_TRUE;
}

fn valid_name(name: [*c]const u8) c_int {
    var p: [*c]const u8 = undefined;
    if (name == null or name[0] == 0 or !(isalpha(name[0]) or name[0] == '_')) return raven.R_FALSE;
    p = name;
    while (p.* != 0) : (p += 1) if (!(isalnum(p.*) or p.* == '_' or p.* == '-')) return raven.R_FALSE;
    return raven.R_TRUE;
}

fn write_new(folder: [*c]const u8, file: [*c]const u8, text: [*c]const u8) c_int {
    const path: [*c]u8 = ide.ide_join(folder, file);
    var ok: c_int = raven.R_TRUE;
    if (ide.ide_file_exists(path) == 0) ok = raven.Rfile_write(path, text, libc.strlen(text));
    libc.free(path);
    return ok;
}

// The interface, after the scripts, with the callback of the language.
fn main_file(script: [*c]const u8, name: [*c]const u8, bindings: [*c]const u8, callback: [*c]const u8) [*c]u8 {
    const head: [*c]u8 = expand(script, name, bindings, null, null);
    const window: [*c]u8 = expand(TEMPLATE_WINDOW_XML, name, bindings, "{{CALLBACK}}", callback);
    const both: [*c]u8 = @ptrCast(libc.malloc(libc.strlen(head) + libc.strlen(window) + 1));
    _ = libc.strcpy(both, head);
    _ = strcat(both, window);
    libc.free(head);
    libc.free(window);
    return both;
}

fn write_expanded(folder: [*c]const u8, file: [*c]const u8, text: [*c]const u8, name: [*c]const u8, bindings: [*c]const u8) c_int {
    const content: [*c]u8 = expand(text, name, bindings, null, null);
    const ok: c_int = write_new(folder, file, content);
    libc.free(content);
    return ok;
}

// A native project: the files its tools need and a Hello world, nothing of Raven.
fn create_native(folder: [*c]const u8, name: [*c]const u8, language: [*c]const u8) c_int {
    var ok: c_int = raven.R_TRUE;
    if (ide.ide_iequal(language, "C") != 0 or ide.ide_iequal(language, "C++") != 0) {
        const cpp: c_int = ide.ide_iequal(language, "C++");
        const cmake: [*c]u8 = expand(NATIVE_CMAKE, name, "", "{{CMAKE_LANGUAGE}}", if (cpp != 0) "CXX" else "C");
        const cmake2: [*c]u8 = expand(cmake, name, "", "{{MAIN}}", if (cpp != 0) "main.cpp" else "main.c");
        ok = write_new(folder, "CMakeLists.txt", cmake2);
        libc.free(cmake);
        libc.free(cmake2);
        ok = @intFromBool(ok != 0 and write_new(folder, if (cpp != 0) "main.cpp" else "main.c", if (cpp != 0) NATIVE_CPP else NATIVE_C) != 0);
        ok = @intFromBool(ok != 0 and write_new(folder, ".gitignore", "build/\n.raven-ide\n") != 0);
    } else if (ide.ide_iequal(language, "Rust") != 0) {
        const src: [*c]u8 = ide.ide_join(folder, "src");
        ok = write_expanded(folder, "Cargo.toml", NATIVE_CARGO_TOML, name, "");
        ok = @intFromBool(ok != 0 and ide.ide_make_dirs(src) != 0);
        ok = @intFromBool(ok != 0 and write_new(src, "main.rs", NATIVE_RUST) != 0);
        libc.free(src);
        ok = @intFromBool(ok != 0 and write_new(folder, ".gitignore", "target/\n.raven-ide\n") != 0);
    } else if (ide.ide_iequal(language, "Python") != 0) {
        ok = write_new(folder, "main.py", NATIVE_PYTHON);
        ok = @intFromBool(ok != 0 and write_new(folder, ".gitignore", "__pycache__/\n.raven-ide\n") != 0);
    } else if (ide.ide_iequal(language, "Go") != 0) {
        ok = write_expanded(folder, "go.mod", NATIVE_GO_MOD, name, "");
        ok = @intFromBool(ok != 0 and write_new(folder, "main.go", NATIVE_GO) != 0);
        ok = @intFromBool(ok != 0 and write_new(folder, ".gitignore", ".raven-ide\n") != 0);
    } else if (ide.ide_iequal(language, "C#") != 0) {
        var csproj: [300]u8 = undefined;
        _ = libc.snprintf(&csproj, @sizeOf(@TypeOf(csproj)), "%s.csproj", name);
        ok = write_new(folder, &csproj, NATIVE_CSPROJ);
        ok = @intFromBool(ok != 0 and write_new(folder, "Program.cs", NATIVE_CSHARP) != 0);
        ok = @intFromBool(ok != 0 and write_new(folder, ".gitignore", "bin/\nobj/\n.raven-ide\n") != 0);
    } else if (ide.ide_iequal(language, "Zig") != 0) {
        const src: [*c]u8 = ide.ide_join(folder, "src");
        ok = write_expanded(folder, "build.zig", NATIVE_BUILD_ZIG, name, "");
        ok = @intFromBool(ok != 0 and ide.ide_make_dirs(src) != 0);
        ok = @intFromBool(ok != 0 and write_new(src, "main.zig", NATIVE_ZIG) != 0);
        libc.free(src);
        ok = @intFromBool(ok != 0 and write_new(folder, ".gitignore", "zig-out/\n.zig-cache/\n.raven-ide\n") != 0);
    } else if (ide.ide_iequal(language, "Lua") != 0) {
        ok = write_new(folder, "main.lua", NATIVE_LUA);
        ok = @intFromBool(ok != 0 and write_new(folder, ".gitignore", ".raven-ide\n") != 0);
    } else {
        ide.ide_status("Unknown language %s", language);
        ok = raven.R_FALSE;
    }
    return ok;
}

export fn project_create(parent_folder: [*c]const u8, name: [*c]const u8, language_: [*c]const u8, with_interface: c_int) c_int {
    var language: [*c]const u8 = language_;
    var text: [*c]u8 = undefined;
    var main_name: [*c]const u8 = null;
    var ok: c_int = raven.R_TRUE;
    if (valid_name(name) == 0) {
        ide.ide_status("A project name is made of letters, digits, '_' and '-', and starts with a letter.");
        return raven.R_FALSE;
    }
    const folder: [*c]u8 = ide.ide_join(parent_folder, name);
    if (ide.ide_make_dirs(folder) == 0) {
        ide.ide_status("Cannot create the folder %s", folder);
        libc.free(folder);
        return raven.R_FALSE;
    }
    if (language == null or language[0] == 0) language = "C";

    if (with_interface == 0) {
        if (create_native(folder, name, language) == 0) {
            ide.ide_status("Cannot write the files of the project in %s", folder);
            libc.free(folder);
            return raven.R_FALSE;
        }
        ok = project_open(folder);
        libc.free(folder);
        return ok;
    }

    const bindings: [*c]u8 = bindings_dir();
    if (ide.ide_iequal(language, "C") != 0 or ide.ide_iequal(language, "C++") != 0) {
        const cpp: c_int = ide.ide_iequal(language, "C++");
        const cmake: [*c]u8 = expand(TEMPLATE_CMAKE, name, bindings, "{{CMAKE_LANGUAGE}}", if (cpp != 0) "CXX" else "C");
        const cmake2: [*c]u8 = expand(cmake, name, bindings, "{{MAIN}}", if (cpp != 0) "main.xmlc++" else "main.xmlc");
        const cmake3: [*c]u8 = expand(cmake2, name, bindings, "{{LANGUAGE}}", if (cpp != 0) "C++" else "C");
        ok = write_new(folder, "CMakeLists.txt", cmake3);
        libc.free(cmake);
        libc.free(cmake2);
        libc.free(cmake3);
        main_name = if (cpp != 0) "main.xmlc++" else "main.xmlc";
        text = main_file(if (cpp != 0) SCRIPT_CPP else SCRIPT_C, name, bindings, "on_hello");
        ok = @intFromBool(ok != 0 and write_new(folder, main_name, text) != 0);
        libc.free(text);
        ok = @intFromBool(ok != 0 and write_new(folder, ".gitignore", "build/\n.raven-ide\n") != 0);
    } else if (ide.ide_iequal(language, "Rust") != 0) {
        const src: [*c]u8 = ide.ide_join(folder, "src");
        ok = write_expanded(folder, "Cargo.toml", CARGO_TOML, name, bindings);
        ok = @intFromBool(ok != 0 and write_new(folder, "build.rs", CARGO_BUILD_RS) != 0);
        ok = @intFromBool(ok != 0 and ide.ide_make_dirs(src) != 0);
        ok = @intFromBool(ok != 0 and write_new(src, "main.rs", CARGO_MAIN_RS) != 0);
        text = main_file(SCRIPT_RUST, name, bindings, "on_hello");
        ok = @intFromBool(ok != 0 and write_new(src, "main.xmlrs", text) != 0);
        libc.free(text);
        libc.free(src);
        ok = @intFromBool(ok != 0 and write_new(folder, ".gitignore", "target/\n.raven-ide\n") != 0);
        main_name = "src/main.xmlrs";
    } else if (ide.ide_iequal(language, "Python") != 0) {
        main_name = "main.xmlpy";
        text = main_file(SCRIPT_PYTHON, name, bindings, "on_hello");
        ok = write_new(folder, main_name, text);
        libc.free(text);
        ok = @intFromBool(ok != 0 and write_new(folder, ".gitignore", "__pycache__/\n.raven-ide\n") != 0);
    } else if (ide.ide_iequal(language, "Go") != 0) {
        main_name = "main.xmlgo";
        ok = write_expanded(folder, "go.mod", GO_MOD, name, bindings);
        ok = @intFromBool(ok != 0 and write_new(folder, "generate.go", GO_GENERATE) != 0);
        text = main_file(SCRIPT_GO, name, bindings, "on_hello");
        ok = @intFromBool(ok != 0 and write_new(folder, main_name, text) != 0);
        libc.free(text);
        ok = @intFromBool(ok != 0 and write_new(folder, ".gitignore", "main.xmlgo.go\n.raven-ide\n") != 0);
    } else if (ide.ide_iequal(language, "C#") != 0) {
        var csproj: [300]u8 = undefined;
        main_name = "main.xmlcs";
        _ = libc.snprintf(&csproj, @sizeOf(@TypeOf(csproj)), "%s.csproj", name);
        ok = write_expanded(folder, &csproj, CSPROJ, name, bindings);
        text = main_file(SCRIPT_CSHARP, name, bindings, "OnHello");
        ok = @intFromBool(ok != 0 and write_new(folder, main_name, text) != 0);
        libc.free(text);
        ok = @intFromBool(ok != 0 and write_new(folder, ".gitignore", "bin/\nobj/\n.raven-ide\n") != 0);
    } else if (ide.ide_iequal(language, "Zig") != 0) {
        const vendored: [*c]u8 = ide.ide_join(folder, "raven");
        var from: [*c]u8 = undefined;
        var to: [*c]u8 = undefined;
        main_name = "main.xmlzig";
        ok = write_expanded(folder, "build.zig", BUILD_ZIG, name, bindings);
        ok = @intFromBool(ok != 0 and ide.ide_make_dirs(vendored) != 0);
        // (a build.zig only imports the files of its project: the bindings are copied in it)
        from = ide.ide_join(bindings, "zig/raven.zig");
        to = ide.ide_join(vendored, "raven.zig");
        ok = @intFromBool(ok != 0 and copy_file(from, to) != 0);
        libc.free(from);
        libc.free(to);
        from = ide.ide_join(bindings, "zig/xmlzig.zig");
        to = ide.ide_join(vendored, "xmlzig.zig");
        ok = @intFromBool(ok != 0 and copy_file(from, to) != 0);
        libc.free(from);
        libc.free(to);
        libc.free(vendored);
        text = main_file(SCRIPT_ZIG, name, bindings, "on_hello");
        ok = @intFromBool(ok != 0 and write_new(folder, main_name, text) != 0);
        libc.free(text);
        ok = @intFromBool(ok != 0 and write_new(folder, ".gitignore", "zig-out/\n.zig-cache/\n.raven-ide\n") != 0);
    } else if (ide.ide_iequal(language, "Lua") != 0) {
        main_name = "main.xmllua";
        text = main_file(SCRIPT_LUA, name, bindings, "on_hello");
        ok = write_new(folder, main_name, text);
        libc.free(text);
        ok = @intFromBool(ok != 0 and write_new(folder, ".gitignore", "*.xmllua.lua\n.raven-ide\n") != 0);
    } else {
        ide.ide_status("Unknown language %s", language);
        ok = raven.R_FALSE;
    }
    ok = @intFromBool(ok != 0 and write_new(folder, "strings.csv", TEMPLATE_STRINGS) != 0);
    libc.free(bindings);
    if (ok == 0) {
        ide.ide_status("Cannot write the files of the project in %s (are the bindings of Raven there?)", folder);
        libc.free(folder);
        return raven.R_FALSE;
    }
    // (void)main_name;   (Zig: it is used above, a discard is an error)
    ok = project_open(folder);
    libc.free(folder);
    return ok;
}

// ---------------------------------------------------------------------------
//  Dialogs
// -------------------------------------------------------------------------

//
// Rdialog_run deletes its content when it closes, and setting the text of an
// input does not call its changed callback (Browse... does that): the dialogs
// read their fields when a button is clicked, before closing.
//

const NEW_PROJECT_XML =
    "<Border Padding=\"24\" Width=\"600\">" ++
    "  <VBox Spacing=\"14\">" ++
    "    <Label Text=\"New project\" TextSize=\"22\"/>" ++
    "    <Label Name=\"about\" Wrap=\"true\" Opacity=\"0.65\"/>" ++
    "    <Grid Columns=\"0,1\" Spacing=\"10\">" ++
    "      <Label Text=\"Name\" Slot.VAlign=\"Center\"/>" ++
    "      <TextInput Name=\"name\" Slot.Column=\"1\" Placeholder=\"my_app\"/>" ++
    "      <Label Text=\"Language\" Slot.Row=\"1\" Slot.VAlign=\"Center\"/>" ++
    "      <ComboBox Name=\"language\" Slot.Row=\"1\" Slot.Column=\"1\" Items=\"C (CMake)|C++ (CMake)|Rust (Cargo)|Python|Go|C# (dotnet)|Zig (zig build)|Lua (LuaJIT)\" Selected=\"0\"/>" ++
    "      <Label Text=\"Kind\" Slot.Row=\"2\" Slot.VAlign=\"Center\" Tooltip=\"With a Raven interface (.xmlc, .xmlrs, .xmlpy...), or the language alone\"/>" ++
    "      <ComboBox Name=\"kind\" Slot.Row=\"2\" Slot.Column=\"1\" Items=\"Raven interface + code (main.xmlc, main.xmlrs, main.xmlpy...)|Native: the language alone, a classic Hello world\" Selected=\"0\"/>" ++
    "      <Label Text=\"Location\" Slot.Row=\"3\" Slot.VAlign=\"Center\"/>" ++
    "      <HBox Spacing=\"8\" Slot.Row=\"3\" Slot.Column=\"1\"><TextInput Name=\"folder\" Slot.Fill=\"1\"/><Button Name=\"browse\" Text=\"Browse...\"/></HBox>" ++
    "      <Label Name=\"prefix.label\" Text=\"Raven package\" Slot.Row=\"4\" Slot.VAlign=\"Center\" Tooltip=\"The folder with bin/, include/ and lib/: what the project is built with\"/>" ++
    "      <HBox Name=\"prefix.row\" Spacing=\"8\" Slot.Row=\"4\" Slot.Column=\"1\"><TextInput Name=\"prefix\" Slot.Fill=\"1\" Placeholder=\"the folder with bin/, include/ and lib/\"/><Button Name=\"browse.prefix\" Text=\"Browse...\"/></HBox>" ++
    "    </Grid>" ++
    "    <Label Name=\"where\" Opacity=\"0.6\" Wrap=\"true\"/>" ++
    "    <Label Name=\"error\" Wrap=\"true\" Visibility=\"Collapsed\"/>" ++
    "    <HBox Spacing=\"8\" Slot.HAlign=\"Right\"><Button Name=\"cancel\" Text=\"Cancel\"/><Button Name=\"create\" Text=\"Create\" Style=\"Primary\"/></HBox>" ++
    "  </VBox>" ++
    "</Border>";

const g_languages = [_][*c]const u8{ "C", "C++", "Rust", "Python", "Go", "C#", "Zig", "Lua" };

var g_np = std.mem.zeroes(extern struct {
    content: raven.Rid,
    name: raven.Rid,
    language: raven.Rid,
    kind: raven.Rid,
    folder: raven.Rid,
    prefix: raven.Rid,
    where: raven.Rid,
    @"error": raven.Rid,
    about: raven.Rid,
    // what was read when Create was clicked
    name_text: [256]u8,
    folder_text: [1024]u8,
    prefix_text: [1024]u8,
    language_index: c_int,
    native: c_int,
});

// The kind chosen: what the project will hold, said above the fields; the Raven package only matters with an interface.
fn np_update_kind() void {
    const native: c_int = @intFromBool(raven.Rcombo_box_get_selected(g_np.kind) == 1);
    raven.Rlabel_set_text(g_np.about, if (native != 0)
        "The language alone: what its tools need and a classic Hello world. No interface file and no translations: add them later if you want."
    else
        "An interface with its code in one file (main.xmlc, main.xmlrs...), what the tools of its language need, and its translations (strings.csv). It builds as it is.");
    raven.Rwidget_set_visibility(raven.Rwidget_find(g_np.content, "prefix.label"), if (native != 0) raven.R_COLLAPSED else raven.R_VISIBLE);
    raven.Rwidget_set_visibility(raven.Rwidget_find(g_np.content, "prefix.row"), if (native != 0) raven.R_COLLAPSED else raven.R_VISIBLE);
}

fn np_kind_changed(combo: raven.Rid, index: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = combo;
    _ = index;
    _ = user_data;
    np_update_kind();
}

fn on_dialog_button(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    raven.Rdialog_close(button, @bitCast(@as(c_uint, @truncate(@intFromPtr(user_data)))));
}

fn browse_into(input: raven.Rid, title: [*c]const u8, folder: c_int) void {
    var desc: raven.RFileDialogDesc = undefined;
    desc = std.mem.zeroes(raven.RFileDialogDesc);
    desc.parent = ide.g_ide_window;
    desc.title = title;
    const chosen: [*c]const u8 = if (folder != 0) raven.Rfile_dialog_select_folder(&desc) else raven.Rfile_dialog_open(&desc);
    if (chosen != null) raven.Rtext_input_set_text(input, chosen);
}

// static void np_update_where(void);   (Zig needs no prototype)

fn on_browse_folder(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    browse_into(@truncate(@intFromPtr(user_data)), "Choose a folder", raven.R_TRUE);
    // (setting the text calls no callback: the line under the fields follows by hand)
    if (ide.g_ide_dialog != raven.R_INVALID_ID and @as(raven.Rid, @truncate(@intFromPtr(user_data))) == g_np.folder) np_update_where();
}

fn np_show_error(text: [*c]const u8) void {
    raven.Rlabel_set_text(g_np.@"error", if (text != null) text else "");
    if (text != null and text[0] != 0) {
        var r: f32 = undefined;
        var gr: f32 = undefined;
        var b: f32 = undefined;
        var a: f32 = undefined;
        raven.Rtheme_get_color(raven.R_COLOR_DANGER, &r, &gr, &b, &a);
        {
            var color: [16]u8 = undefined;
            _ = libc.snprintf(&color, @sizeOf(@TypeOf(color)), "#%02X%02X%02X", @as(c_int, @intFromFloat(r * 255.0)), @as(c_int, @intFromFloat(gr * 255.0)), @as(c_int, @intFromFloat(b * 255.0)));
            _ = raven.Rwidget_set_attribute(g_np.@"error", "Color.Text", &color);
        }
    }
    raven.Rwidget_set_visibility(g_np.@"error", if (text != null and text[0] != 0) raven.R_VISIBLE else raven.R_COLLAPSED);
}

fn folder_is_empty(path: [*c]const u8) c_int {
    var entries: [*c]ide.ide_entry_t = undefined;
    const count: c_int = ide.ide_list_dir(path, &entries);
    libc.free(entries);
    return @intFromBool(count <= 0);
}

// Where the project goes, shown under the fields as they are typed.
fn np_update_where() void {
    var text: [1400]u8 = undefined;
    var pretty: [1100]u8 = undefined;
    const name: [*c]const u8 = raven.Rtext_input_get_text(g_np.name);
    const folder: [*c]const u8 = raven.Rtext_input_get_text(g_np.folder);
    if (folder[0] == 0 or name[0] == 0) {
        raven.Rlabel_set_text(g_np.where, "");
        return;
    }
    const full: [*c]u8 = ide.ide_join(folder, name);
    ide.ide_pretty_path(full, &pretty, @sizeOf(@TypeOf(pretty)));
    _ = libc.snprintf(&text, @sizeOf(@TypeOf(text)), "Creates the folder %s", @as([*c]const u8, &pretty));
    raven.Rlabel_set_text(g_np.where, &text);
    libc.free(full);
}

fn np_changed(input: raven.Rid, text: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = input;
    _ = text;
    _ = user_data;
    np_update_where();
    np_show_error(null);
}

// static int valid_name(const char* name);   (Zig needs no prototype)

// Create: what is wrong is said in the dialog, which stays open.
fn on_create(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    _ = libc.snprintf(&g_np.name_text, @sizeOf(@TypeOf(g_np.name_text)), "%s", raven.Rtext_input_get_text(g_np.name));
    _ = libc.snprintf(&g_np.folder_text, @sizeOf(@TypeOf(g_np.folder_text)), "%s", raven.Rtext_input_get_text(g_np.folder));
    _ = libc.snprintf(&g_np.prefix_text, @sizeOf(@TypeOf(g_np.prefix_text)), "%s", raven.Rtext_input_get_text(g_np.prefix));
    const language: c_int = raven.Rcombo_box_get_selected(g_np.language);
    g_np.language_index = if (language >= 0 and language < 8) language else 0;
    g_np.native = @intFromBool(raven.Rcombo_box_get_selected(g_np.kind) == 1);
    if (valid_name(&g_np.name_text) == 0) {
        np_show_error("The name is made of letters, digits, '_' and '-', and starts with a letter.");
        return;
    }
    if (g_np.folder_text[0] == 0) {
        np_show_error("Choose where the project goes (Location).");
        return;
    }
    const full: [*c]u8 = ide.ide_join(&g_np.folder_text, &g_np.name_text);
    if (ide.ide_file_exists(full) != 0 or (ide.ide_is_dir(full) != 0 and folder_is_empty(full) == 0)) {
        libc.free(full);
        np_show_error("There is already something with that name there: choose another name or another location.");
        return;
    }
    libc.free(full);
    // the languages built by their own tools need the bindings of the package
    if (g_np.native == 0 and g_np.language_index >= 2 and g_np.language_index != 3 and g_np.language_index != 7 and g_np.prefix_text[0] != 0) {
        const bindings: [*c]u8 = ide.ide_join(&g_np.prefix_text, "share/raven/bindings");
        const found: c_int = ide.ide_is_dir(bindings);
        libc.free(bindings);
        if (found == 0) {
            np_show_error("This Raven package has no share/raven/bindings: the project could not find Raven. Choose the folder of a complete package.");
            return;
        }
    }
    raven.Rdialog_close(button, 1);
}

export fn project_new() void {
    const content: raven.Rid = raven.Rwidget_create_from_xml(NEW_PROJECT_XML, NEW_PROJECT_XML.len);
    if (content == raven.R_INVALID_ID) return;
    g_np = std.mem.zeroes(@TypeOf(g_np));
    g_np.content = content;
    g_np.name = raven.Rwidget_find(content, "name");
    g_np.language = raven.Rwidget_find(content, "language");
    g_np.kind = raven.Rwidget_find(content, "kind");
    g_np.about = raven.Rwidget_find(content, "about");
    g_np.folder = raven.Rwidget_find(content, "folder");
    g_np.prefix = raven.Rwidget_find(content, "prefix");
    g_np.where = raven.Rwidget_find(content, "where");
    g_np.@"error" = raven.Rwidget_find(content, "error");
    // a name not taken yet, in the folder of the last project created
    const location: [*c]const u8 = if (ide.prefs_get("projects_folder")[0] != 0) ide.prefs_get("projects_folder") else ide.ide_default_projects_dir();
    raven.Rtext_input_set_text(g_np.folder, location);
    {
        var name: [64]u8 = undefined;
        var i: c_int = 0;
        _ = libc.snprintf(&name, @sizeOf(@TypeOf(name)), "my_app");
        i = 2;
        while (i < 100) : (i += 1) {
            const full: [*c]u8 = ide.ide_join(location, &name);
            const taken: c_int = @intFromBool(ide.ide_file_exists(full) != 0 or ide.ide_is_dir(full) != 0);
            libc.free(full);
            if (taken == 0) break;
            _ = libc.snprintf(&name, @sizeOf(@TypeOf(name)), "my_app_%d", i);
        }
        raven.Rtext_input_set_text(g_np.name, &name);
    }
    raven.Rtext_input_set_text(g_np.prefix, &g_settings.raven_prefix);
    {
        const last: c_int = libc.atoi(ide.prefs_get("projects_language"));
        raven.Rcombo_box_set_selected(g_np.language, if (last >= 0 and last < 8) last else 0);
    }
    // (the kind of the last project created)
    raven.Rcombo_box_set_selected(g_np.kind, if (libc.strcmp(ide.prefs_get("projects_native"), "1") == 0) 1 else 0);
    raven.Rcombo_box_set_changed_callback(g_np.kind, &np_kind_changed, null);
    np_update_kind();
    raven.Rtext_input_set_changed_callback(g_np.name, &np_changed, null);
    raven.Rtext_input_set_changed_callback(g_np.folder, &np_changed, null);
    np_update_where();
    raven.Rbutton_set_clicked_callback(raven.Rwidget_find(content, "browse"), &on_browse_folder, @ptrFromInt(@as(usize, g_np.folder)));
    raven.Rbutton_set_clicked_callback(raven.Rwidget_find(content, "browse.prefix"), &on_browse_folder, @ptrFromInt(@as(usize, g_np.prefix)));
    raven.Rbutton_set_clicked_callback(raven.Rwidget_find(content, "cancel"), &on_dialog_button, null);
    raven.Rbutton_set_clicked_callback(raven.Rwidget_find(content, "create"), &on_create, null);
    raven.Rwidget_focus(g_np.name);
    ide.g_ide_dialog = content;
    if (raven.Rdialog_run(ide.g_ide_window, content) != 1) {
        ide.g_ide_dialog = raven.R_INVALID_ID;
        return;
    }
    ide.g_ide_dialog = raven.R_INVALID_ID;
    // (the fields are gone: what was read when Create was clicked)
    ide.prefs_set("projects_folder", &g_np.folder_text);
    {
        var index: [8]u8 = undefined;
        _ = libc.snprintf(&index, @sizeOf(@TypeOf(index)), "%d", g_np.language_index);
        ide.prefs_set("projects_language", &index);
    }
    ide.prefs_set("projects_native", if (g_np.native != 0) "1" else "0");
    if (g_np.native == 0 and g_np.prefix_text[0] != 0) {
        _ = libc.snprintf(&g_settings.raven_prefix, @sizeOf(@TypeOf(g_settings.raven_prefix)), "%s", @as([*c]const u8, &g_np.prefix_text));
        ide.prefs_set("raven_prefix", &g_np.prefix_text);
    }
    if (project_create(&g_np.folder_text, &g_np.name_text, g_languages[@intCast(g_np.language_index)], @intFromBool(g_np.native == 0)) == 0) {
        var text: [1400]u8 = undefined;
        _ = libc.snprintf(&text, @sizeOf(@TypeOf(text)), "The project %s could not be created in %s. The status bar says why.", @as([*c]const u8, &g_np.name_text), @as([*c]const u8, &g_np.folder_text));
        _ = raven.Rmessage_box(ide.g_ide_window, "New project", &text, raven.R_MESSAGE_OK);
    }
}

const SETTINGS_XML =
    "<Border Padding=\"24\" Width=\"640\">" ++
    "  <VBox Spacing=\"14\">" ++
    "    <Label Text=\"Build settings\" TextSize=\"22\"/>" ++
    "    <Label Name=\"for\" Opacity=\"0.65\" Wrap=\"true\"/>" ++
    "    <Grid Columns=\"0,1\" Spacing=\"10\">" ++
    "      <Label Text=\"Build type\" Slot.VAlign=\"Center\"/>" ++
    "      <ComboBox Name=\"type\" Slot.Column=\"1\" Items=\"Debug|Release|RelWithDebInfo|MinSizeRel\"/>" ++
    "      <Label Text=\"Raven package\" Slot.Row=\"1\" Slot.VAlign=\"Center\" Tooltip=\"The folder of the Raven package (bin/, include/, lib/): find_package(raven) looks there\"/>" ++
    "      <HBox Spacing=\"8\" Slot.Row=\"1\" Slot.Column=\"1\"><TextInput Name=\"prefix\" Slot.Fill=\"1\" Placeholder=\"the folder with bin/, include/ and lib/\"/><Button Name=\"browse.prefix\" Text=\"Browse...\"/></HBox>" ++
    "      <Label Text=\"Generator\" Slot.Row=\"2\" Slot.VAlign=\"Center\"/>" ++
    "      <TextInput Name=\"generator\" Slot.Row=\"2\" Slot.Column=\"1\" Placeholder=\"automatic: Ninja when it is installed (MinGW Makefiles, Unix Makefiles...)\"/>" ++
    "      <Label Text=\"Run arguments\" Slot.Row=\"3\" Slot.VAlign=\"Center\"/>" ++
    "      <TextInput Name=\"arguments\" Slot.Row=\"3\" Slot.Column=\"1\"/>" ++
    "    </Grid>" ++
    "    <HBox Spacing=\"8\" Slot.HAlign=\"Right\"><Button Name=\"cancel\" Text=\"Cancel\"/><Button Name=\"ok\" Text=\"Save\" Style=\"Primary\"/></HBox>" ++
    "  </VBox>" ++
    "</Border>";

var g_edit: ide.ide_settings_t = std.mem.zeroes(ide.ide_settings_t);
var g_settings_content: raven.Rid = 0;

fn on_settings_save(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    const content: raven.Rid = g_settings_content;
    const type_: raven.Rid = raven.Rwidget_find(content, "type");
    const index: c_int = raven.Rcombo_box_get_selected(type_);
    _ = user_data;
    if (index >= 0) _ = libc.snprintf(&g_edit.build_type, @sizeOf(@TypeOf(g_edit.build_type)), "%s", raven.Rcombo_box_get_item_text(type_, index));
    // #define READ_FIELD(name, field) snprintf(g_edit.field, sizeof(g_edit.field), "%s", Rtext_input_get_text(Rwidget_find(content, name)))
    // READ_FIELD("prefix", raven_prefix);
    _ = libc.snprintf(&g_edit.raven_prefix, @sizeOf(@TypeOf(g_edit.raven_prefix)), "%s", raven.Rtext_input_get_text(raven.Rwidget_find(content, "prefix")));
    // READ_FIELD("generator", generator);
    _ = libc.snprintf(&g_edit.generator, @sizeOf(@TypeOf(g_edit.generator)), "%s", raven.Rtext_input_get_text(raven.Rwidget_find(content, "generator")));
    // READ_FIELD("arguments", run_arguments);
    _ = libc.snprintf(&g_edit.run_arguments, @sizeOf(@TypeOf(g_edit.run_arguments)), "%s", raven.Rtext_input_get_text(raven.Rwidget_find(content, "arguments")));
    // #undef READ_FIELD
    raven.Rdialog_close(button, 1);
}

export fn project_settings_dialog() void {
    const content: raven.Rid = raven.Rwidget_create_from_xml(SETTINGS_XML, SETTINGS_XML.len);
    var i: c_int = 0;
    if (content == raven.R_INVALID_ID) return;
    g_settings_content = content;
    g_edit = g_settings;
    raven.Rlabel_set_text(raven.Rwidget_find(content, "for"), if (g_project_dir != null)
        "For this project (kept in its file .raven-ide). The Raven package is also the one new projects start with."
    else
        "No project is open: the Raven package is kept for the projects to come.");
    const type_: raven.Rid = raven.Rwidget_find(content, "type");
    i = 0;
    while (i < raven.Rcombo_box_get_item_count(type_)) : (i += 1) if (ide.ide_iequal(raven.Rcombo_box_get_item_text(type_, i), &g_settings.build_type) != 0) raven.Rcombo_box_set_selected(type_, i);
    raven.Rtext_input_set_text(raven.Rwidget_find(content, "prefix"), &g_edit.raven_prefix);
    raven.Rtext_input_set_text(raven.Rwidget_find(content, "generator"), &g_edit.generator);
    raven.Rtext_input_set_text(raven.Rwidget_find(content, "arguments"), &g_edit.run_arguments);
    raven.Rbutton_set_clicked_callback(raven.Rwidget_find(content, "browse.prefix"), &on_browse_folder, @ptrFromInt(@as(usize, raven.Rwidget_find(content, "prefix"))));
    raven.Rbutton_set_clicked_callback(raven.Rwidget_find(content, "cancel"), &on_dialog_button, null);
    raven.Rbutton_set_clicked_callback(raven.Rwidget_find(content, "ok"), &on_settings_save, null);
    ide.g_ide_dialog = content;
    if (raven.Rdialog_run(ide.g_ide_window, content) != 1) {
        ide.g_ide_dialog = raven.R_INVALID_ID;
        return;
    }
    ide.g_ide_dialog = raven.R_INVALID_ID;
    g_settings = g_edit;
    if (g_settings.raven_prefix[0] != 0) ide.prefs_set("raven_prefix", &g_settings.raven_prefix);
    project_save_settings();
    ide.ide_status(if (g_project_dir != null) "Settings saved. The next build configures the project again." else "Settings kept for the projects to come.");
}

fn action_project(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = sender;
    _ = user_data;
    if (libc.strcmp(action, "project.new") == 0) {
        project_new();
    } else if (libc.strcmp(action, "project.open") == 0) {
        var desc: raven.RFileDialogDesc = undefined;
        desc = std.mem.zeroes(raven.RFileDialogDesc);
        desc.parent = ide.g_ide_window;
        desc.title = "Open a project folder";
        const chosen: [*c]const u8 = raven.Rfile_dialog_select_folder(&desc);
        if (chosen != null) {
            const copy: [*c]u8 = ide.ide_strdup(chosen);
            _ = project_open(copy);
            libc.free(copy);
        }
    } else if (libc.strcmp(action, "project.refresh") == 0) {
        project_refresh_explorer();
    } else if (libc.strcmp(action, "project.settings") == 0) {
        project_settings_dialog();
    } else if (libc.strcmp(action, "project.close") == 0) {
        if (g_project_dir != null) _ = project_close() else ide.welcome_show();
    }
}

export fn project_init() void {
    raven.Raction_bind("project.new", &action_project, null);
    raven.Raction_bind("project.open", &action_project, null);
    raven.Raction_bind("project.refresh", &action_project, null);
    raven.Raction_bind("project.settings", &action_project, null);
    raven.Raction_bind("project.close", &action_project, null);
    load_settings();
    project_refresh_explorer();
}

export fn project_shutdown() void {
    libc.free(g_project_dir);
    g_project_dir = null;
}
