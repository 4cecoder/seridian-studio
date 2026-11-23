// Translated to Zig from soundcraft/crates/automation/src/mcp.rs, soundcraft/docs/mcp.md (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Model Context Protocol server: JSON-RPC 2.0 over newline-delimited stdio, on top of the `Backend`
//! vtable (backend.zig). The tool table is comptime data. Replies are `std.json.Value` trees built in
//! a per-request arena, so this is control-thread code: it parses and allocates JSON.
//!
//! Changes from the Rust, all deliberate:
//! - The `parity` tool is dropped, with everything that reported against the incumbent's menu catalog.
//! - The product name is Seridian in the server name, the instructions, the tool descriptions and the
//!   resource URIs (`seridian://...`). The Rust binary names in the APP_ONLY hint are renamed the same
//!   way; the real Seridian binary names are not settled, see the report.
//! - The session extension named in the descriptions is `.seridian`; the repository does not define
//!   a project extension yet (flagged in the report).
//! - The Rust `serde_json` parse-error text is not reproduced; the reply carries the Zig error name.
//! - `serve` reads with a caller-sized `std.Io.Reader`; its buffer bounds the line length, and a longer
//!   line gets an error reply and is skipped.

const std = @import("std");
const build_options = @import("build_options");
const io = @import("io");
const backend_mod = @import("backend.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Backend = backend_mod.Backend;
const Result = backend_mod.Result;

pub const protocol_version = "2025-06-18";
const supported_versions = [_][]const u8{ "2025-06-18", "2025-03-26", "2024-11-05" };

/// The most calls one `batch` may carry. Larger batches are refused before any command runs.
pub const max_batch_calls: usize = 1000;
/// The longest request line `serve` accepts; a longer one gets an error reply.
pub const max_line_bytes: usize = 16 * 1024 * 1024;

const server_name = "seridian";
const session_uri = "seridian://session";
const commands_uri = "seridian://commands";

const instructions_text =
    "Seridian is a digital audio workstation. Everything a user can do is a " ++
    "command: call `list_commands` to discover ids and their params, then `execute` (or `batch`). Positions are samples " ++
    "(integers), `{\"seconds\": x}`, or time strings like \"bars_beats:5|1|000\" / \"0:12.500\". Tracks are referenced by id " ++
    "or name. Verify your work with `inspect_session` (tracks, clips, mixer, automation, markers, selection). Programmatic " ++
    "calls never open dialogs. Tools marked APP_ONLY need the desktop app (`seridian --control 0` + `seridian-cli mcp --connect PORT`).";

const batch_limit_text = std.fmt.comptimePrint("{d}", .{max_batch_calls});

/// The extensions `bounce_mix` may write, from the io library's writable list.
const writable_extensions = io.audiofile_types.FileFormat.writableExtensions();

// --- the tool table (comptime) ---

/// One tool as `tools/list` reports it. `input_schema` is the JSON Schema text.
pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
};

/// The dispatchable tools. Each name is a `tool_defs` entry; a test checks the two agree.
pub const ToolName = enum {
    list_commands,
    execute,
    batch,
    inspect_session,
    new_session,
    open_session,
    save_session,
    import_audio,
    bounce_mix,
    screenshot,
    ui_inspect,
    ui_set,
    menu_invoke,
    click,
    drag,
    key,
};

/// A JSON Schema object with the given `properties` and `required` members (JSON text, no braces).
fn schema(comptime props: []const u8, comptime required: []const u8) []const u8 {
    return "{\"type\":\"object\",\"properties\":{" ++ props ++ "},\"required\":[" ++ required ++ "]}";
}

/// A JSON array of string literals, for enums.
fn jsonStringList(comptime items: []const []const u8) []const u8 {
    comptime var out: []const u8 = "[";
    inline for (items, 0..) |item, i| {
        out = out ++ (if (i > 0) "," else "") ++ "\"" ++ item ++ "\"";
    }
    return out ++ "]";
}

pub const tool_defs = [_]ToolDef{
    .{
        .name = "list_commands",
        .description = "List Seridian commands (id, label, menu path, shortcut, params doc, enabled).",
        .input_schema = schema("\"filter\":{\"type\":\"string\",\"description\":\"substring of id or label\"}", ""),
    },
    .{
        .name = "execute",
        .description = "Run one command by id with JSON params. Returns the command's result.",
        .input_schema = schema("\"command\":{\"type\":\"string\"},\"params\":{\"type\":\"object\"}", "\"command\""),
    },
    .{
        .name = "batch",
        .description = "Run up to " ++ batch_limit_text ++ " commands in order; stops at the first error unless keep_going. Larger batches are rejected before any command runs.",
        .input_schema = schema(
            "\"calls\":{\"type\":\"array\",\"maxItems\":" ++ batch_limit_text ++ ",\"items\":{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"},\"params\":{\"type\":\"object\"}}}},\"keep_going\":{\"type\":\"boolean\"}",
            "\"calls\"",
        ),
    },
    .{
        .name = "inspect_session",
        .description = "The whole session as JSON: tracks (clips, inserts, sends, automation), busses, markers, groups, selection, transport.",
        .input_schema = schema("\"detail\":{\"type\":\"string\",\"enum\":[\"summary\",\"full\"]}", ""),
    },
    .{
        .name = "new_session",
        .description = "Start a new session (optionally the built-in demo).",
        .input_schema = schema(
            "\"name\":{\"type\":\"string\"},\"sample_rate\":{\"type\":\"integer\"},\"template\":{\"type\":\"string\",\"enum\":[\"blank\",\"demo\"]}",
            "",
        ),
    },
    .{
        .name = "open_session",
        .description = "Open a .seridian session file.",
        .input_schema = schema("\"path\":{\"type\":\"string\"}", "\"path\""),
    },
    .{
        .name = "save_session",
        .description = "Save the session (path required the first time; replace: true to save over another existing file).",
        .input_schema = schema("\"path\":{\"type\":\"string\"},\"replace\":{\"type\":\"boolean\"}", ""),
    },
    .{
        .name = "import_audio",
        .description = "Import an audio file (WAV, AIFF, FLAC, MP3, OGG, AAC/M4A, ALAC, CAF) onto a new or existing track.",
        .input_schema = schema("\"path\":{\"type\":\"string\"},\"track\":{\"type\":[\"string\",\"integer\"]},\"at\":{}", "\"path\""),
    },
    .{
        .name = "bounce_mix",
        .description = "Render the mix to an audio file. Returns peak dBFS and integrated LUFS.",
        .input_schema = schema(
            "\"path\":{\"type\":\"string\"},\"format\":{\"type\":\"string\",\"enum\":" ++ jsonStringList(writable_extensions) ++
                "},\"bit_depth\":{\"type\":\"string\"},\"start\":{},\"end\":{},\"normalize\":{\"type\":\"boolean\"}",
            "\"path\"",
        ),
    },
    .{
        .name = "screenshot",
        .description = "APP_ONLY. Screenshot the app window (PNG).",
        .input_schema = schema("\"path\":{\"type\":\"string\"}", ""),
    },
    .{
        .name = "ui_inspect",
        .description = "APP_ONLY. UI state: front window, panels, layout rectangles of tracks, dialogs.",
        .input_schema = schema("", ""),
    },
    .{
        .name = "ui_set",
        .description = "APP_ONLY. Set UI state fields, e.g. {\"window\": \"Mix\"}.",
        .input_schema = schema("\"state\":{\"type\":\"object\"}", "\"state\""),
    },
    .{
        .name = "menu_invoke",
        .description = "APP_ONLY. Invoke a menu item like a click (may open its dialog), e.g. \"Track > New...\".",
        .input_schema = schema("\"path\":{\"type\":\"string\"}", "\"path\""),
    },
    .{
        .name = "click",
        .description = "APP_ONLY. Click at window coordinates (points).",
        .input_schema = schema(
            "\"x\":{\"type\":\"number\"},\"y\":{\"type\":\"number\"},\"button\":{\"type\":\"string\"},\"count\":{\"type\":\"integer\"}",
            "\"x\",\"y\"",
        ),
    },
    .{
        .name = "drag",
        .description = "APP_ONLY. Drag with the primary button.",
        .input_schema = schema(
            "\"x\":{\"type\":\"number\"},\"y\":{\"type\":\"number\"},\"to_x\":{\"type\":\"number\"},\"to_y\":{\"type\":\"number\"}",
            "\"x\",\"y\",\"to_x\",\"to_y\"",
        ),
    },
    .{
        .name = "key",
        .description = "APP_ONLY. Press a key with modifiers.",
        .input_schema = schema(
            "\"key\":{\"type\":\"string\"},\"cmd\":{\"type\":\"boolean\"},\"shift\":{\"type\":\"boolean\"},\"alt\":{\"type\":\"boolean\"},\"ctrl\":{\"type\":\"boolean\"}",
            "\"key\"",
        ),
    },
};

// --- JSON helpers ---

const Pair = struct { []const u8, Value };

fn object(arena: Allocator, pairs: []const Pair) Allocator.Error!Value {
    var map: ObjectMap = .empty;
    for (pairs) |pair| try map.put(arena, pair[0], pair[1]);
    return .{ .object = map };
}

fn array(arena: Allocator, items: []const Value) Allocator.Error!Value {
    var list: std.json.Array = .empty;
    try list.appendSlice(arena, items);
    return .{ .array = list };
}

fn str(text: []const u8) Value {
    return .{ .string = text };
}

fn emptyObject() Value {
    return .{ .object = .empty };
}

fn field(v: Value, key: []const u8) ?Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn stringField(v: Value, key: []const u8) ?[]const u8 {
    const f = field(v, key) orelse return null;
    return switch (f) {
        .string => |s| s,
        else => null,
    };
}

fn boolField(v: Value, key: []const u8) ?bool {
    const f = field(v, key) orelse return null;
    return switch (f) {
        .bool => |b| b,
        else => null,
    };
}

/// A nullable JSON value, `null` when absent (Rust `args.get(k).cloned()` inside `json!`).
fn orNull(v: ?Value) Value {
    return v orelse .null;
}

// --- replies ---

const RpcError = struct { code: i64, message: []const u8 };

/// What a method produced: a `result` or an error object.
const Outcome = union(enum) {
    result: Value,
    failure: RpcError,
};

fn failure(code: i64, message: []const u8) Outcome {
    return .{ .failure = .{ .code = code, .message = message } };
}

/// The JSON-RPC reply for `id`.
fn reply(arena: Allocator, id: Value, outcome: Outcome) Allocator.Error!Value {
    return switch (outcome) {
        .result => |result| object(arena, &.{ .{ "jsonrpc", str("2.0") }, .{ "id", id }, .{ "result", result } }),
        .failure => |f| object(arena, &.{
            .{ "jsonrpc", str("2.0") },
            .{ "id", id },
            .{ "error", try object(arena, &.{ .{ "code", .{ .integer = f.code } }, .{ "message", str(f.message) } }) },
        }),
    };
}

/// An MCP tool result with one text content item.
fn textResult(arena: Allocator, text: []const u8, is_error: bool) Allocator.Error!Value {
    const item = try object(arena, &.{ .{ "type", str("text") }, .{ "text", str(text) } });
    return object(arena, &.{ .{ "content", try array(arena, &.{item}) }, .{ "isError", .{ .bool = is_error } } });
}

/// Pretty JSON for a successful call (Rust `text_result`), or the error text (Rust `error_result`).
fn toolResult(arena: Allocator, r: Result) Allocator.Error!Value {
    return switch (r) {
        .ok => |v| textResult(arena, try std.json.Stringify.valueAlloc(arena, v, .{ .whitespace = .indent_2 }), false),
        .err => |e| textResult(arena, e, true),
    };
}

fn imageResult(arena: Allocator, png_base64: []const u8) Allocator.Error!Value {
    const item = try object(arena, &.{
        .{ "type", str("image") },
        .{ "data", str(png_base64) },
        .{ "mimeType", str("image/png") },
    });
    return object(arena, &.{ .{ "content", try array(arena, &.{item}) }, .{ "isError", .{ .bool = false } } });
}

fn isSupported(version: []const u8) bool {
    for (supported_versions) |v| {
        if (std.mem.eql(u8, v, version)) return true;
    }
    return false;
}

/// `tools/list`: the comptime table, each input schema parsed into a value.
fn toolsValue(arena: Allocator) Allocator.Error!Value {
    var list: std.json.Array = .empty;
    for (tool_defs) |def| {
        const input_schema = std.json.parseFromSliceLeaky(Value, arena, def.input_schema, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // The schemas are comptime literals; a test parses every one.
            else => unreachable,
        };
        try list.append(arena, try object(arena, &.{
            .{ "name", str(def.name) },
            .{ "description", str(def.description) },
            .{ "inputSchema", input_schema },
        }));
    }
    return .{ .array = list };
}

fn resourceList(arena: Allocator) Allocator.Error!Value {
    return array(arena, &.{
        try object(arena, &.{
            .{ "uri", str(session_uri) },
            .{ "name", str("Session") },
            .{ "mimeType", str("application/json") },
            .{ "description", str("The open session as JSON") },
        }),
        try object(arena, &.{
            .{ "uri", str(commands_uri) },
            .{ "name", str("Commands") },
            .{ "mimeType", str("application/json") },
            .{ "description", str("All commands") },
        }),
    });
}

const Method = enum {
    initialize,
    ping,
    @"tools/list",
    @"tools/call",
    @"resources/list",
    @"resources/templates/list",
    @"resources/read",
};

pub const Server = struct {
    backend: Backend,

    pub fn init(backend: Backend) Server {
        return .{ .backend = backend };
    }

    /// Runs a command through the backend's `engine.execute` method (Rust `exec`).
    fn exec(self: *Server, arena: Allocator, command: []const u8, params: Value) Allocator.Error!Result {
        return self.backend.call(arena, "engine.execute", try object(arena, &.{
            .{ "command", str(command) },
            .{ "params", params },
        }));
    }

    /// The backend result of one tool call (Rust `call_tool`, before the MCP wrapping).
    fn dispatch(self: *Server, arena: Allocator, name: []const u8, args: Value) Allocator.Error!Result {
        const tool = std.meta.stringToEnum(ToolName, name) orelse
            return .{ .err = try std.fmt.allocPrint(arena, "unknown tool `{s}`", .{name}) };
        switch (tool) {
            .list_commands => return self.backend.call(arena, "engine.commands", try object(arena, &.{
                .{ "filter", orNull(field(args, "filter")) },
            })),
            .execute => {
                const command = stringField(args, "command") orelse return .{ .err = "`command` required" };
                return self.exec(arena, command, field(args, "params") orelse emptyObject());
            },
            .batch => return self.batch(arena, args),
            .inspect_session => return self.backend.call(arena, "session.inspect", try object(arena, &.{
                .{ "detail", orNull(field(args, "detail")) },
            })),
            .new_session => return self.exec(arena, "session.new", args),
            .open_session => return self.exec(arena, "session.open", args),
            .save_session => return self.exec(arena, "session.save", args),
            .import_audio => return self.exec(arena, "file.import_audio", args),
            .bounce_mix => return self.exec(arena, "file.bounce_mix", args),
            .screenshot => return self.backend.call(arena, "ui.screenshot", args),
            .ui_inspect => return self.backend.call(arena, "ui.inspect", emptyObject()),
            .ui_set => return self.backend.call(arena, "ui.set", field(args, "state") orelse emptyObject()),
            .menu_invoke => return self.backend.call(arena, "ui.menu.invoke", args),
            .click => return self.backend.call(arena, "ui.click", args),
            .drag => return self.backend.call(arena, "ui.drag", args),
            .key => return self.backend.call(arena, "ui.key", args),
        }
    }

    /// The `batch` tool: runs the calls in order, stops at the first failure unless `keep_going`.
    /// A batch over the limit is refused before the first call runs. Any failed call makes the
    /// whole result an error, whose text lists every call's outcome.
    fn batch(self: *Server, arena: Allocator, args: Value) Allocator.Error!Result {
        const keep_going = boolField(args, "keep_going") orelse false;
        const calls = switch (field(args, "calls") orelse .null) {
            .array => |list| list.items,
            else => return .{ .err = "`calls` must be an array" },
        };
        if (calls.len > max_batch_calls) {
            return .{ .err = try std.fmt.allocPrint(arena, "`calls` must contain at most {d} commands; no commands were executed", .{max_batch_calls}) };
        }
        var out: std.json.Array = .empty;
        var failed = false;
        for (calls) |call| {
            const command = std.mem.trim(u8, stringField(call, "command") orelse "", &std.ascii.whitespace);
            if (command.len == 0) {
                try out.append(arena, try object(arena, &.{
                    .{ "command", str("") },
                    .{ "ok", .{ .bool = false } },
                    .{ "error", str("`command` required") },
                }));
                failed = true;
                if (!keep_going) break;
                continue;
            }
            const params = field(call, "params") orelse emptyObject();
            switch (try self.exec(arena, command, params)) {
                .ok => |v| try out.append(arena, try object(arena, &.{
                    .{ "command", str(command) },
                    .{ "ok", .{ .bool = true } },
                    .{ "result", v },
                })),
                .err => |e| {
                    try out.append(arena, try object(arena, &.{
                        .{ "command", str(command) },
                        .{ "ok", .{ .bool = false } },
                        .{ "error", str(e) },
                    }));
                    failed = true;
                    if (!keep_going) break;
                },
            }
        }
        if (failed) {
            return .{ .err = try std.json.Stringify.valueAlloc(arena, Value{ .array = out }, .{}) };
        }
        return .{ .ok = .{ .array = out } };
    }

    /// Calls a tool and wraps the outcome as MCP content. `isError` is set on any failure, including
    /// a partial batch. A PNG from `screenshot` becomes image content.
    pub fn callTool(self: *Server, arena: Allocator, name: []const u8, args: Value) Allocator.Error!Value {
        const r = try self.dispatch(arena, name, args);
        switch (r) {
            .ok => |v| {
                if (std.mem.eql(u8, name, "screenshot")) {
                    if (stringField(v, "png_base64")) |data| return imageResult(arena, data);
                }
            },
            .err => {},
        }
        return toolResult(arena, r);
    }

    fn initialize(self: *Server, arena: Allocator, params: Value) Allocator.Error!Outcome {
        const wanted = stringField(params, "protocolVersion") orelse protocol_version;
        const version = if (isSupported(wanted)) wanted else protocol_version;
        const description = try self.backend.describe(arena);
        const text = try std.fmt.allocPrint(arena, "{s}\nBackend: {s}.", .{ instructions_text, description });
        return .{ .result = try object(arena, &.{
            .{ "protocolVersion", str(version) },
            .{ "capabilities", try object(arena, &.{ .{ "tools", emptyObject() }, .{ "resources", emptyObject() } }) },
            .{ "serverInfo", try object(arena, &.{
                .{ "name", str(server_name) },
                .{ "version", str(build_options.version) },
            }) },
            .{ "instructions", str(text) },
        }) };
    }

    fn readResource(self: *Server, arena: Allocator, uri: []const u8) Allocator.Error!Outcome {
        const r: Result = if (std.mem.eql(u8, uri, session_uri))
            self.backend.call(arena, "session.inspect", try object(arena, &.{.{ "detail", str("full") }}))
        else if (std.mem.eql(u8, uri, commands_uri))
            self.backend.call(arena, "engine.commands", emptyObject())
        else
            .{ .err = try std.fmt.allocPrint(arena, "unknown resource {s}", .{uri}) };
        switch (r) {
            .ok => |v| {
                const text = try std.json.Stringify.valueAlloc(arena, v, .{});
                const content = try object(arena, &.{
                    .{ "uri", str(uri) },
                    .{ "mimeType", str("application/json") },
                    .{ "text", str(text) },
                });
                return .{ .result = try object(arena, &.{.{ "contents", try array(arena, &.{content}) }}) };
            },
            .err => |e| return failure(-32002, e),
        }
    }

    /// Routes one request by method name (the body of Rust `handle` after the id check).
    fn route(self: *Server, arena: Allocator, name: []const u8, params: Value) Allocator.Error!Outcome {
        if (name.len == 0) return failure(-32600, "invalid request");
        const method = std.meta.stringToEnum(Method, name) orelse
            return failure(-32601, try std.fmt.allocPrint(arena, "method not found: {s}", .{name}));
        switch (method) {
            .initialize => return self.initialize(arena, params),
            .ping => return .{ .result = emptyObject() },
            .@"tools/list" => return .{ .result = try object(arena, &.{.{ "tools", try toolsValue(arena) }}) },
            .@"tools/call" => {
                const tool_name = stringField(params, "name") orelse "";
                const args = field(params, "arguments") orelse emptyObject();
                return .{ .result = try self.callTool(arena, tool_name, args) };
            },
            .@"resources/list" => return .{ .result = try object(arena, &.{.{ "resources", try resourceList(arena) }}) },
            .@"resources/templates/list" => return .{ .result = try object(arena, &.{.{ "resourceTemplates", try array(arena, &.{}) }}) },
            .@"resources/read" => return self.readResource(arena, stringField(params, "uri") orelse ""),
        }
    }

    /// Handles one JSON-RPC message. Returns the reply, or `null` for a notification (a message with
    /// no `id`). A non-object message gets an invalid-request reply with a null id.
    pub fn handle(self: *Server, arena: Allocator, msg: Value) Allocator.Error!?Value {
        if (msg != .object) return try reply(arena, .null, failure(-32600, "invalid request"));
        const id = field(msg, "id") orelse return null;
        const method_name = stringField(msg, "method") orelse "";
        const params = field(msg, "params") orelse emptyObject();
        return try reply(arena, id, try self.route(arena, method_name, params));
    }

    /// Replies to one non-blank line: a message, a batch array, or unparseable text.
    fn replyToLine(self: *Server, arena: Allocator, line: []const u8) Allocator.Error!?Value {
        const msg = std.json.parseFromSliceLeaky(Value, arena, line, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return try reply(arena, .null, failure(-32700, try std.fmt.allocPrint(arena, "parse error: {s}", .{@errorName(err)}))),
        };
        switch (msg) {
            .array => |items| {
                if (items.items.len == 0) {
                    return try reply(arena, .null, failure(-32600, "invalid request: empty batch"));
                }
                var replies: std.json.Array = .empty;
                for (items.items) |item| {
                    if (try self.handle(arena, item)) |r| try replies.append(arena, r);
                }
                if (replies.items.len == 0) return null;
                return .{ .array = replies };
            },
            else => return self.handle(arena, msg),
        }
    }

    /// Serves requests until end of input: one message (or batch array) per line, one reply line per
    /// message that gets one. The reader's buffer bounds the line length: a longer line gets an
    /// error reply, and its remainder is skipped. Each request is parsed and answered in its own arena.
    pub fn serve(self: *Server, gpa: Allocator, reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
        while (true) {
            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            const maybe_line = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    try writeReply(writer, try reply(arena, .null, failure(-32600, "request line too long")));
                    _ = reader.discardDelimiterInclusive('\n') catch |e| switch (e) {
                        error.EndOfStream => return,
                        else => |other| return other,
                    };
                    continue;
                },
                error.ReadFailed => return error.ReadFailed,
            };
            const line = maybe_line orelse return;
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0) continue;

            const maybe_reply: ?Value = if (trimmed.len > max_line_bytes)
                try reply(arena, .null, failure(-32600, "request line too long"))
            else
                try self.replyToLine(arena, trimmed);
            if (maybe_reply) |value| try writeReply(writer, value);
        }
    }
};

fn writeReply(writer: *std.Io.Writer, value: Value) !void {
    try std.json.Stringify.value(value, .{}, writer);
    try writer.writeByte('\n');
    try writer.flush();
}
