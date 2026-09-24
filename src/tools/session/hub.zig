const std = @import("std");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const io_mod = @import("../../core/shared/io.zig");

const Allocator = std.mem.Allocator;

const max_mailbox_bytes: usize = 4 << 20;
const max_message_bytes: usize = 256 << 10;
const max_name_bytes: usize = 128;

pub const Input = struct {
    op: []u8 = "",
    to: ?[]u8 = null,
    message: ?[]u8 = null,
    from: ?[]u8 = null,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.op);
        if (self.to) |t| alloc.free(t);
        if (self.message) |m| alloc.free(m);
        if (self.from) |f| alloc.free(f);
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
        else => return .{ .failure = try ctx.allocator.dupe(u8, "hub arguments must be valid JSON") },
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "hub arguments must be an object") };
    }
    const args = parsed.value.object;
    const op = if (args.get("op")) |v| (if (v == .string) v.string else "") else "";
    if (op.len == 0) {
        return .{ .failure = try ctx.allocator.dupe(u8, "hub requires op: send|inbox|list") };
    }
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .op = try ctx.allocator.dupe(u8, op) };
    if (args.get("to")) |v| {
        if (v == .string) input.to = try ctx.allocator.dupe(u8, v.string);
    }
    if (args.get("message")) |v| {
        if (v == .string) input.message = try ctx.allocator.dupe(u8, v.string);
    }
    if (args.get("from")) |v| {
        if (v == .string) input.from = try ctx.allocator.dupe(u8, v.string);
    }
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

pub fn validate(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

fn hubRoot(alloc: Allocator) ?[]u8 {
    const home = io_mod.getenv("HOME") orelse return null;
    return std.fs.path.join(alloc, &.{ home, ".fx", "hub" }) catch null;
}

fn safeName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes) return false;
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return true;
}

fn selfName(ctx: tool_dispatch.DispatchContext, input: *const Input) []const u8 {
    if (input.from) |f| {
        if (f.len > 0) return f;
    }
    if (ctx.terminal_owner_session_id) |id| {
        if (id.len > 0) return id;
    }
    return "main";
}

fn readMailbox(alloc: Allocator, path: []const u8) ![]u8 {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch {
        return alloc.alloc(u8, 0);
    };
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, max_mailbox_bytes) catch {
        return alloc.alloc(u8, 0);
    };
}

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    defer input.deinit(ctx.allocator);
    if (ctx.cancel_flag) |flag| {
        if (flag.load(.seq_cst)) return error.Cancelled;
    }

    const alloc = ctx.allocator;
    const root = hubRoot(alloc) orelse {
        return .{ .failure = try alloc.dupe(u8, "hub is unavailable: HOME is not set.") };
    };
    defer alloc.free(root);
    io_mod.makeDirRecursive(root) catch {
        return .{ .failure = try alloc.dupe(u8, "hub failed: could not create ~/.fx/hub") };
    };

    if (std.mem.eql(u8, input.op, "list")) {
        var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), root, .{ .iterate = true }) catch {
            return .{ .success = try alloc.dupe(u8, "(no peers)") };
        };
        defer dir.close(io_mod.getIo());
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        var iter = dir.iterate();
        var count: usize = 0;
        while (iter.next(io_mod.getIo()) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
            const peer = entry.name[0 .. entry.name.len - ".jsonl".len];
            out.writer.print("{s}\n", .{peer}) catch return error.OutOfMemory;
            count += 1;
        }
        if (count == 0) return .{ .success = try alloc.dupe(u8, "(no peers)") };
        return .{ .success = try alloc.dupe(u8, out.written()) };
    }

    if (std.mem.eql(u8, input.op, "send")) {
        const to = input.to orelse {
            return .{ .failure = try alloc.dupe(u8, "hub send requires to") };
        };
        if (!safeName(to)) {
            return .{ .failure = try alloc.dupe(u8, "hub send: unsafe recipient name") };
        }
        const message = input.message orelse {
            return .{ .failure = try alloc.dupe(u8, "hub send requires message") };
        };
        if (message.len == 0 or message.len > max_message_bytes) {
            return .{ .failure = try alloc.dupe(u8, "hub send: message empty or exceeds 256 KiB") };
        }
        const from = selfName(ctx, input);
        const mbox_name = try std.fmt.allocPrint(alloc, "{s}.jsonl", .{to});
        defer alloc.free(mbox_name);
        const path = try std.fs.path.join(alloc, &.{ root, mbox_name });
        defer alloc.free(path);

        var line: std.Io.Writer.Allocating = .init(alloc);
        defer line.deinit();
        line.writer.writeAll("{\"from\":") catch return error.OutOfMemory;
        std.json.Stringify.value(from, .{}, &line.writer) catch return error.OutOfMemory;
        line.writer.writeAll(",\"to\":") catch return error.OutOfMemory;
        std.json.Stringify.value(to, .{}, &line.writer) catch return error.OutOfMemory;
        line.writer.writeAll(",\"ts\":") catch return error.OutOfMemory;
        line.writer.print("{d}", .{io_mod.milliTimestamp()}) catch return error.OutOfMemory;
        line.writer.writeAll(",\"message\":") catch return error.OutOfMemory;
        std.json.Stringify.value(message, .{}, &line.writer) catch return error.OutOfMemory;
        line.writer.writeAll("}\n") catch return error.OutOfMemory;

        const existing = try readMailbox(alloc, path);
        defer alloc.free(existing);
        var merged: std.Io.Writer.Allocating = .init(alloc);
        defer merged.deinit();
        merged.writer.writeAll(existing) catch return error.OutOfMemory;
        merged.writer.writeAll(line.written()) catch return error.OutOfMemory;
        io_mod.writeFileAtomic(alloc, path, merged.written()) catch {
            return .{ .failure = try std.fmt.allocPrint(alloc, "hub send failed for {s}", .{to}) };
        };
        return .{ .success = try std.fmt.allocPrint(alloc, "delivered to {s} ({d} bytes).", .{ to, message.len }) };
    }

    if (std.mem.eql(u8, input.op, "inbox")) {
        const name = selfName(ctx, input);
        if (!safeName(name)) {
            return .{ .failure = try alloc.dupe(u8, "hub inbox: unsafe name") };
        }
        const inbox_name = try std.fmt.allocPrint(alloc, "{s}.jsonl", .{name});
        defer alloc.free(inbox_name);
        const path = try std.fs.path.join(alloc, &.{ root, inbox_name });
        defer alloc.free(path);
        const existing = try readMailbox(alloc, path);
        defer alloc.free(existing);
        if (existing.len == 0) {
            return .{ .success = try alloc.dupe(u8, "(inbox empty)") };
        }
        io_mod.writeFileAtomic(alloc, path, "") catch {};
        return .{ .success = try alloc.dupe(u8, existing) };
    }

    return .{ .failure = try alloc.dupe(u8, "hub: unknown op: use send|inbox|list") };
}

pub fn readsOnly(input: tool_dispatch.ToolInput) bool {
    const in = input.as(Input);
    return std.mem.eql(u8, in.op, "list");
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}
