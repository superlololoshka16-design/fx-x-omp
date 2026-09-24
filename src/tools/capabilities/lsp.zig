const std = @import("std");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const io_mod = @import("../../core/shared/io.zig");

const Allocator = std.mem.Allocator;

const max_file_bytes: usize = 4 << 20;
const max_response_bytes: usize = 32 << 20;

pub const Input = struct {
    op: []u8 = "",
    file: ?[]u8 = null,
    line: u32 = 0,
    character: u32 = 0,
    query: ?[]u8 = null,
    new_name: ?[]u8 = null,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.op);
        if (self.file) |f| alloc.free(f);
        if (self.query) |q| alloc.free(q);
        if (self.new_name) |n| alloc.free(n);
        self.* = .{};
    }
};

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn decode(ctx: tool_dispatch.DispatchContext, args_json: []const u8) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try ctx.allocator.dupe(u8, "lsp arguments must be valid JSON") },
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "lsp arguments must be an object") };
    }
    const args = parsed.value.object;
    const op = if (args.get("op")) |v| (if (v == .string) v.string else "") else "";
    if (op.len == 0) {
        return .{ .failure = try ctx.allocator.dupe(u8, "lsp requires op: definition|hover|references|rename|symbols|wsymbols") };
    }
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .op = try ctx.allocator.dupe(u8, op) };
    if (args.get("file")) |v| {
        if (v == .string) input.file = try ctx.allocator.dupe(u8, v.string);
    }
    if (args.get("line")) |v| {
        if (v == .integer and v.integer > 0) input.line = @intCast(v.integer);
    }
    if (args.get("character")) |v| {
        if (v == .integer and v.integer >= 0) input.character = @intCast(v.integer);
    }
    if (args.get("query")) |v| {
        if (v == .string) input.query = try ctx.allocator.dupe(u8, v.string);
    }
    if (args.get("new_name")) |v| {
        if (v == .string) input.new_name = try ctx.allocator.dupe(u8, v.string);
    }
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

pub fn validate(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

const ServerSpec = struct {
    argv: []const []const u8,
    language_id: []const u8,
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn resolveServer(ext: []const u8) ?ServerSpec {
    if (eql(ext, "rs")) return .{ .argv = &.{"rust-analyzer"}, .language_id = "rust" };
    if (eql(ext, "py")) return .{ .argv = &.{ "pyright-langserver", "--stdio" }, .language_id = "python" };
    if (eql(ext, "ts") or eql(ext, "tsx")) return .{ .argv = &.{ "typescript-language-server", "--stdio" }, .language_id = "typescript" };
    if (eql(ext, "js") or eql(ext, "jsx") or eql(ext, "mjs") or eql(ext, "cjs")) return .{ .argv = &.{ "typescript-language-server", "--stdio" }, .language_id = "javascript" };
    if (eql(ext, "go")) return .{ .argv = &.{"gopls"}, .language_id = "go" };
    if (eql(ext, "zig")) return .{ .argv = &.{"zls"}, .language_id = "zig" };
    if (eql(ext, "c") or eql(ext, "h")) return .{ .argv = &.{"clangd"}, .language_id = "c" };
    if (eql(ext, "cpp") or eql(ext, "cc") or eql(ext, "cxx") or eql(ext, "hpp") or eql(ext, "hh")) return .{ .argv = &.{"clangd"}, .language_id = "cpp" };
    if (eql(ext, "java")) return .{ .argv = &.{"jdtls"}, .language_id = "java" };
    return null;
}

// ---- JSON-RPC request building via typed structs + Stringify (no brace math) ----

const Empty = struct {};
const TextDocId = struct { uri: []const u8 };
const Position = struct { line: u32, character: u32 };
const InitParams = struct { processId: ?i32 = null, rootUri: []const u8, capabilities: Empty = .{} };
const OpenDoc = struct { uri: []const u8, languageId: []const u8, version: u32 = 1, text: []const u8 };
const OpenParams = struct { textDocument: OpenDoc };
const RefContext = struct { includeDeclaration: bool = true };
const RefParams = struct { textDocument: TextDocId, position: Position, context: RefContext = .{} };
const RenameParams = struct { textDocument: TextDocId, position: Position, newName: []const u8 };
const QueryParams = struct { query: []const u8 };

fn rpcFrame(out: *std.Io.Writer.Allocating, id: ?u32, method: []const u8, params: anytype) error{OutOfMemory}!void {
    var body: std.Io.Writer.Allocating = .init(out.allocator);
    defer body.deinit();
    body.writer.writeAll("{\"jsonrpc\":\"2.0\"") catch return error.OutOfMemory;
    if (id) |i| body.writer.print(",\"id\":{d}", .{i}) catch return error.OutOfMemory;
    body.writer.writeAll(",\"method\":") catch return error.OutOfMemory;
    std.json.Stringify.value(method, .{}, &body.writer) catch return error.OutOfMemory;
    body.writer.writeAll(",\"params\":") catch return error.OutOfMemory;
    std.json.Stringify.value(params, .{}, &body.writer) catch return error.OutOfMemory;
    body.writer.writeAll("}") catch return error.OutOfMemory;
    out.writer.print("Content-Length: {d}\r\n\r\n", .{body.written().len}) catch return error.OutOfMemory;
    out.writer.writeAll(body.written()) catch return error.OutOfMemory;
}

fn extractBodyWithId(alloc: Allocator, raw: []const u8, want_id: i64) ?[]u8 {
    var rest = raw;
    while (rest.len > 0) {
        const hdr_end = std.mem.indexOf(u8, rest, "\r\n\r\n") orelse break;
        const headers = rest[0..hdr_end];
        var content_len: ?usize = null;
        var hl = std.mem.splitSequence(u8, headers, "\r\n");
        while (hl.next()) |h| {
            if (h.len > "Content-Length:".len and std.ascii.startsWithIgnoreCase(h, "Content-Length:")) {
                content_len = std.fmt.parseInt(usize, std.mem.trim(u8, h["Content-Length:".len..], " "), 10) catch null;
            }
        }
        const cl = content_len orelse break;
        const body_start = hdr_end + 4;
        if (rest.len < body_start + cl) break;
        const body = rest[body_start .. body_start + cl];
        rest = rest[body_start + cl ..];
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const id_v = parsed.value.object.get("id") orelse continue;
        if (id_v != .integer or id_v.integer != want_id) continue;
        return alloc.dupe(u8, body) catch null;
    }
    return null;
}

fn formatLocations(alloc: Allocator, result: std.json.Value) ?[]u8 {
    if (result != .array) return null;
    var out: std.Io.Writer.Allocating = .init(alloc);
    var count: usize = 0;
    for (result.array.items) |loc| {
        if (loc != .object) continue;
        const uri_v = loc.object.get("uri") orelse continue;
        if (uri_v != .string) continue;
        const range_v = loc.object.get("range") orelse continue;
        if (range_v != .object) continue;
        const start_v = range_v.object.get("start") orelse continue;
        if (start_v != .object) continue;
        const line_v = start_v.object.get("line") orelse continue;
        const char_v = start_v.object.get("character") orelse continue;
        if (line_v != .integer or char_v != .integer) continue;
        var path = uri_v.string;
        if (std.mem.startsWith(u8, path, "file://")) path = path["file://".len..];
        out.writer.print("{s}:{d}:{d}\n", .{ path, line_v.integer + 1, char_v.integer }) catch {
            out.deinit();
            return null;
        };
        count += 1;
    }
    if (count == 0) {
        out.deinit();
        return null;
    }
    return alloc.dupe(u8, out.written()) catch null;
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    const alloc = ctx.allocator;
    const is_wsymbols = eql(input.op, "wsymbols");
    if (!is_wsymbols and input.file == null) {
        return .{ .failure = try alloc.dupe(u8, "lsp requires file (except op=wsymbols)") };
    }

    var abs_path: ?[]u8 = null;
    var ext: []const u8 = "";
    var spec: ?ServerSpec = null;
    if (input.file) |f| {
        abs_path = io_mod.realpathAlloc(alloc, f) catch {
            return .{ .failure = try std.fmt.allocPrint(alloc, "lsp: cannot resolve file path: {s}", .{f}) };
        };
        const path = abs_path.?;
        ext = std.fs.path.extension(path);
        if (ext.len > 0) ext = ext[1..];
        spec = resolveServer(ext);
    }
    defer if (abs_path) |p| alloc.free(p);

    if (spec == null and !is_wsymbols) {
        return .{ .failure = try std.fmt.allocPrint(alloc, "lsp: no server mapped for .{s} (known: rs py ts tsx js jsx go zig c h cpp java)", .{ext}) };
    }

    var text: ?[]u8 = null;
    if (abs_path) |path| {
        var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch {
            return .{ .failure = try std.fmt.allocPrint(alloc, "lsp: cannot open {s}", .{path}) };
        };
        defer file.close(io_mod.getIo());
        text = io_mod.readFileToEnd(alloc, &file, max_file_bytes) catch {
            return .{ .failure = try alloc.dupe(u8, "lsp: file read failed or exceeds 4 MiB") };
        };
    }
    defer if (text) |t| alloc.free(t);

    const server = spec orelse resolveServer("rs").?;

    const root_dir: []const u8 = if (ctx.workspace_root.len > 0) ctx.workspace_root else "/";
    const root_uri = try std.fmt.allocPrint(alloc, "file://{s}", .{root_dir});
    defer alloc.free(root_uri);
    const file_uri = if (abs_path) |path|
        try std.fmt.allocPrint(alloc, "file://{s}", .{path})
    else
        try alloc.dupe(u8, "file:///");
    defer alloc.free(file_uri);

    const line0: u32 = if (input.line > 0) input.line - 1 else 0;
    const char0: u32 = input.character;

    var stream: std.Io.Writer.Allocating = .init(alloc);
    defer stream.deinit();

    rpcFrame(&stream, 1, "initialize", InitParams{ .rootUri = root_uri }) catch return error.OutOfMemory;
    rpcFrame(&stream, null, "initialized", Empty{}) catch return error.OutOfMemory;
    if (text) |t| {
        rpcFrame(&stream, null, "textDocument/didOpen", OpenParams{ .textDocument = .{
            .uri = file_uri,
            .languageId = server.language_id,
            .text = t,
        } }) catch return error.OutOfMemory;
    }

    const doc = TextDocId{ .uri = file_uri };
    const pos = Position{ .line = line0, .character = char0 };
    if (is_wsymbols) {
        rpcFrame(&stream, 2, "workspace/symbol", QueryParams{ .query = input.query orelse "" }) catch return error.OutOfMemory;
    } else if (eql(input.op, "definition")) {
        rpcFrame(&stream, 2, "textDocument/definition", .{ .textDocument = doc, .position = pos }) catch return error.OutOfMemory;
    } else if (eql(input.op, "hover")) {
        rpcFrame(&stream, 2, "textDocument/hover", .{ .textDocument = doc, .position = pos }) catch return error.OutOfMemory;
    } else if (eql(input.op, "references")) {
        rpcFrame(&stream, 2, "textDocument/references", RefParams{ .textDocument = doc, .position = pos }) catch return error.OutOfMemory;
    } else if (eql(input.op, "rename")) {
        rpcFrame(&stream, 2, "textDocument/rename", RenameParams{ .textDocument = doc, .position = pos, .newName = input.new_name orelse "" }) catch return error.OutOfMemory;
    } else if (eql(input.op, "symbols")) {
        rpcFrame(&stream, 2, "textDocument/documentSymbol", .{ .textDocument = doc }) catch return error.OutOfMemory;
    } else {
        return .{ .failure = try alloc.dupe(u8, "lsp: unknown op: use definition|hover|references|rename|symbols|wsymbols") };
    }
    rpcFrame(&stream, 3, "shutdown", Empty{}) catch return error.OutOfMemory;
    rpcFrame(&stream, null, "exit", Empty{}) catch return error.OutOfMemory;

    var child = std.process.spawn(io_mod.getIo(), .{
        .argv = server.argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch {
        return .{ .failure = try std.fmt.allocPrint(alloc, "lsp: failed to spawn {s}; install it or check PATH", .{server.argv[0]}) };
    };
    const stdin_pipe = child.stdin orelse {
        return .{ .failure = try alloc.dupe(u8, "lsp: no stdin pipe") };
    };
    child.stdin = null;
    stdin_pipe.writeStreamingAll(io_mod.getIo(), stream.written()) catch {
        stdin_pipe.close(io_mod.getIo());
        _ = child.wait(io_mod.getIo()) catch {};
        return .{ .failure = try alloc.dupe(u8, "lsp: server closed stdin early") };
    };
    stdin_pipe.close(io_mod.getIo());

    var stdout_pipe = child.stdout orelse {
        _ = child.wait(io_mod.getIo()) catch {};
        return .{ .failure = try alloc.dupe(u8, "lsp: no stdout pipe") };
    };
    defer stdout_pipe.close(io_mod.getIo());
    const raw = io_mod.readFileToEnd(alloc, &stdout_pipe, max_response_bytes) catch {
        _ = child.wait(io_mod.getIo()) catch {};
        return .{ .failure = try alloc.dupe(u8, "lsp: response read failed") };
    };
    defer alloc.free(raw);
    _ = child.wait(io_mod.getIo()) catch {};

    const body = extractBodyWithId(alloc, raw, 2) orelse {
        return .{ .failure = try alloc.dupe(u8, "lsp: server returned no response for the request (crash or unsupported method)") };
    };
    defer alloc.free(body);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        return .{ .failure = try alloc.dupe(u8, "lsp: response is not valid JSON") };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .failure = try alloc.dupe(u8, "lsp: malformed response") };
    }
    if (parsed.value.object.get("error")) |e| {
        var err_out: std.Io.Writer.Allocating = .init(alloc);
        defer err_out.deinit();
        std.json.Stringify.value(e, .{}, &err_out.writer) catch return error.OutOfMemory;
        return .{ .failure = try std.fmt.allocPrint(alloc, "lsp error: {s}", .{err_out.written()}) };
    }
    const result_v = parsed.value.object.get("result") orelse {
        return .{ .success = try alloc.dupe(u8, "lsp: no result (null)") };
    };
    if (result_v == .null) {
        return .{ .success = try alloc.dupe(u8, "lsp: null result (no matches)") };
    }
    if (eql(input.op, "definition") or eql(input.op, "references")) {
        if (formatLocations(alloc, result_v)) |locs| {
            return .{ .success = locs };
        }
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    std.json.Stringify.value(result_v, .{}, &out.writer) catch return error.OutOfMemory;
    const written = out.written();
    const cap = ctx.max_tool_result_bytes;
    if (written.len > cap) {
        return .{ .success = try std.fmt.allocPrint(alloc, "{s}\n... [truncated {d} bytes]", .{ written[0..cap], written.len - cap }) };
    }
    return .{ .success = try alloc.dupe(u8, written) };
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}
