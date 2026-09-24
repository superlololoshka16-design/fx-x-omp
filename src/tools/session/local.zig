const std = @import("std");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const io_mod = @import("../../core/shared/io.zig");

const Allocator = std.mem.Allocator;

const max_content_bytes: usize = 4 << 20;
const max_name_bytes: usize = 255;

pub const Input = struct {
    op: []u8 = "",
    name: ?[]u8 = null,
    content: ?[]u8 = null,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.op);
        if (self.name) |n| alloc.free(n);
        if (self.content) |c| alloc.free(c);
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
        else => return .{ .failure = try ctx.allocator.dupe(u8, "local arguments must be valid JSON") },
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "local arguments must be an object") };
    }
    const args = parsed.value.object;
    const op = if (args.get("op")) |v| (if (v == .string) v.string else "") else "";
    if (op.len == 0) {
        return .{ .failure = try ctx.allocator.dupe(u8, "local requires op: put|get|list") };
    }
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .op = try ctx.allocator.dupe(u8, op) };
    if (args.get("name")) |v| {
        if (v == .string) input.name = try ctx.allocator.dupe(u8, v.string);
    }
    if (args.get("content")) |v| {
        if (v == .string) input.content = try ctx.allocator.dupe(u8, v.string);
    }
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

pub fn validate(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

fn localRoot(alloc: Allocator) ?[]u8 {
    const home = io_mod.getenv("HOME") orelse return null;
    return std.fs.path.join(alloc, &.{ home, ".fx", "local" }) catch null;
}

fn safeName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes) return false;
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return true;
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    defer input.deinit(ctx.allocator);
    if (ctx.cancel_flag) |flag| {
        if (flag.load(.seq_cst)) return error.Cancelled;
    }

    const alloc = ctx.allocator;
    const root = localRoot(alloc) orelse {
        return .{ .failure = try alloc.dupe(u8, "local is unavailable: HOME is not set.") };
    };
    defer alloc.free(root);
    io_mod.makeDirRecursive(root) catch {
        return .{ .failure = try alloc.dupe(u8, "local failed: could not create ~/.fx/local") };
    };

    if (std.mem.eql(u8, input.op, "list")) {
        var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), root, .{ .iterate = true }) catch {
            return .{ .success = try alloc.dupe(u8, "(empty)") };
        };
        defer dir.close(io_mod.getIo());
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        var iter = dir.iterate();
        var count: usize = 0;
        while (iter.next(io_mod.getIo()) catch null) |entry| {
            if (entry.kind != .file) continue;
            out.writer.print("{s}\n", .{entry.name}) catch return error.OutOfMemory;
            count += 1;
        }
        if (count == 0) return .{ .success = try alloc.dupe(u8, "(empty)") };
        return .{ .success = try alloc.dupe(u8, out.written()) };
    }

    const name = input.name orelse {
        return .{ .failure = try alloc.dupe(u8, "local put/get requires name") };
    };
    if (!safeName(name)) {
        return .{ .failure = try alloc.dupe(u8, "local: unsafe name (no paths, no . or ..)") };
    }
    const path = try std.fs.path.join(alloc, &.{ root, name });
    defer alloc.free(path);

    if (std.mem.eql(u8, input.op, "put")) {
        const content = input.content orelse {
            return .{ .failure = try alloc.dupe(u8, "local put requires content") };
        };
        if (content.len > max_content_bytes) {
            return .{ .failure = try alloc.dupe(u8, "local put content exceeds 4 MiB") };
        }
        io_mod.writeFileAtomic(alloc, path, content) catch {
            return .{ .failure = try std.fmt.allocPrint(alloc, "local put failed for {s}", .{name}) };
        };
        return .{ .success = try std.fmt.allocPrint(alloc, "wrote local://{s} ({d} bytes). Any agent can read it by that name.", .{ name, content.len }) };
    }

    if (std.mem.eql(u8, input.op, "get")) {
        var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch {
            return .{ .failure = try std.fmt.allocPrint(alloc, "local get failed: no such name: {s}", .{name}) };
        };
        defer file.close(io_mod.getIo());
        const raw = io_mod.readFileToEnd(alloc, &file, max_content_bytes) catch {
            return .{ .failure = try alloc.dupe(u8, "local get failed: read error or file too large") };
        };
        return .{ .success = raw };
    }

    return .{ .failure = try alloc.dupe(u8, "local: unknown op: use put|get|list") };
}

pub fn readsOnly(input: tool_dispatch.ToolInput) bool {
    const in = input.as(Input);
    return std.mem.eql(u8, in.op, "get") or std.mem.eql(u8, in.op, "list");
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}
