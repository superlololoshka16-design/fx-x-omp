const std = @import("std");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const io_mod = @import("../../core/shared/io.zig");

const Allocator = std.mem.Allocator;

const max_tasks: usize = 256;

pub const Input = struct {
    op: []u8 = "",
    task: ?[]u8 = null,
    items: std.ArrayListUnmanaged([]u8) = .empty,
    reason: ?[]u8 = null,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        alloc.free(self.op);
        if (self.task) |t| alloc.free(t);
        if (self.reason) |r| alloc.free(r);
        for (self.items.items) |item| alloc.free(item);
        self.items.deinit(alloc);
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
        else => return .{ .failure = try ctx.allocator.dupe(u8, "todo arguments must be valid JSON") },
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .failure = try ctx.allocator.dupe(u8, "todo arguments must be an object") };
    }
    const args = parsed.value.object;

    const op = if (args.get("op")) |v| (if (v == .string) v.string else "") else "";
    if (op.len == 0) {
        return .{ .failure = try ctx.allocator.dupe(u8, "todo requires op: add|start|done|drop|rm|view") };
    }

    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .op = try ctx.allocator.dupe(u8, op) };
    errdefer ctx.allocator.free(input.op);
    if (args.get("task")) |v| if (v == .string) {
        input.task = try ctx.allocator.dupe(u8, v.string);
    };
    errdefer if (input.task) |t| ctx.allocator.free(t);
    if (args.get("reason")) |v| if (v == .string) {
        input.reason = try ctx.allocator.dupe(u8, v.string);
    };
    errdefer if (input.reason) |r| ctx.allocator.free(r);
    if (args.get("items")) |v| if (v == .array) {
        for (v.array.items) |item| {
            if (item != .string) continue;
            try input.items.append(ctx.allocator, try ctx.allocator.dupe(u8, item.string));
        }
    };

    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

pub fn validate(_: tool_dispatch.DispatchContext, _: tool_dispatch.ToolInput) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

fn todoPath(alloc: Allocator, ctx: tool_dispatch.DispatchContext) ?[]u8 {
    if (ctx.tool_result_dir) |dir| {
        return std.fs.path.join(alloc, &.{ dir, "todo.json" }) catch null;
    }
    const home = io_mod.getenv("HOME") orelse return null;
    const scope = if (ctx.workspace_root.len > 0) ctx.workspace_root else "default";
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(scope, &hash, .{});
    const hex_digits = "0123456789abcdef";
    var file_buf: [21]u8 = undefined;
    for (hash[0..8], 0..) |b, i| {
        file_buf[i * 2] = hex_digits[b >> 4];
        file_buf[i * 2 + 1] = hex_digits[b & 0xf];
    }
    @memcpy(file_buf[16..21], ".json");
    const dir = std.fs.path.join(alloc, &.{ home, ".fx", "todos" }) catch return null;
    defer alloc.free(dir);
    io_mod.makeDirRecursive(dir) catch return null;
    return std.fs.path.join(alloc, &.{ dir, &file_buf }) catch null;
}

const TaskStatus = enum { pending, in_progress, completed, abandoned, blocked };

const TodoTask = struct {
    text: []u8,
    status: TaskStatus = .pending,
    reason: ?[]u8 = null,
};

const TodoState = struct {
    tasks: std.ArrayListUnmanaged(TodoTask) = .empty,

    fn deinit(self: *TodoState, alloc: Allocator) void {
        for (self.tasks.items) |t| {
            alloc.free(t.text);
            if (t.reason) |r| alloc.free(r);
        }
        self.tasks.deinit(alloc);
        self.* = .{};
    }

    fn serialize(self: *const TodoState, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"tasks\":[");
        for (self.tasks.items, 0..) |t, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"text\":");
            try std.json.Stringify.value(t.text, .{}, w);
            const status_str = switch (t.status) {
                .pending => "pending",
                .in_progress => "in_progress",
                .completed => "completed",
                .abandoned => "abandoned",
                .blocked => "blocked",
            };
            try w.writeAll(",\"status\":");
            try std.json.Stringify.value(status_str, .{}, w);
            if (t.reason) |r| {
                try w.writeAll(",\"reason\":");
                try std.json.Stringify.value(r, .{}, w);
            }
            try w.writeAll("}");
        }
        try w.writeAll("]}");
        return alloc.dupe(u8, out.written());
    }

    fn load(alloc: Allocator, path: []const u8) TodoState {
        var state = TodoState{};
        var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch return state;
        defer file.close(io_mod.getIo());
        const raw = io_mod.readFileToEnd(alloc, &file, 1 << 20) catch return state;
        defer alloc.free(raw);
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch return state;
        defer parsed.deinit();
        if (parsed.value != .object) return state;
        const tasks = parsed.value.object.get("tasks") orelse return state;
        if (tasks != .array) return state;
        for (tasks.array.items) |item| {
            if (item != .object) continue;
            const text_v = item.object.get("text") orelse continue;
            if (text_v != .string) continue;
            const status_v = item.object.get("status");
            const status: TaskStatus = if (status_v != null and status_v.? == .string) st: {
                const s = status_v.?.string;
                if (std.mem.eql(u8, s, "in_progress")) break :st .in_progress;
                if (std.mem.eql(u8, s, "completed")) break :st .completed;
                if (std.mem.eql(u8, s, "abandoned")) break :st .abandoned;
                if (std.mem.eql(u8, s, "blocked")) break :st .blocked;
                break :st .pending;
            } else .pending;
            const reason: ?[]u8 = if (item.object.get("reason")) |rv| (if (rv == .string) alloc.dupe(u8, rv.string) catch null else null) else null;
            state.tasks.append(alloc, .{
                .text = alloc.dupe(u8, text_v.string) catch continue,
                .status = status,
                .reason = reason,
            }) catch continue;
        }
        return state;
    }

    fn findByContent(self: *TodoState, text: []const u8) ?*TodoTask {
        for (self.tasks.items) |*t| {
            if (std.mem.eql(u8, t.text, text)) return t;
        }
        return null;
    }

    fn render(self: *const TodoState, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        const w = &out.writer;
        if (self.tasks.items.len == 0) {
            try w.writeAll("Todo list is empty.");
            return alloc.dupe(u8, out.written());
        }
        {
            var done_count: usize = 0;
            var active_count: usize = 0;
            for (self.tasks.items) |t| switch (t.status) {
                .completed => done_count += 1,
                .in_progress => active_count += 1,
                else => {},
            };
            try w.print("todo . {d}/{d} done", .{ done_count, self.tasks.items.len });
            if (active_count > 0) try w.print(" . {d} in progress", .{active_count});
            try w.writeAll("\n");
        }
        for (self.tasks.items, 0..) |t, i| {
            const marker = switch (t.status) {
                .pending => "[ ]",
                .in_progress => "[>]",
                .completed => "[x]",
                .abandoned => "[-]",
                .blocked => "[!]",
            };
            try w.print("{d: >3} {s} {s}\n", .{ i + 1, marker, t.text });
            if (t.reason) |r| try w.print("     reason: {s}\n", .{r});
        }
        return alloc.dupe(u8, out.written());
    }
};

pub fn call(ctx: tool_dispatch.DispatchContext, erased: tool_dispatch.ToolInput) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    defer input.deinit(ctx.allocator);
    if (ctx.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;

    const alloc = ctx.allocator;
    const path = todoPath(alloc, ctx) orelse {
        return .{ .failure = try alloc.dupe(u8, "todo is unavailable: this session has no backing store.") };
    };
    defer alloc.free(path);

    var state = TodoState.load(alloc, path);
    defer state.deinit(alloc);

    var err_msg: ?[]const u8 = null;

    if (std.mem.eql(u8, input.op, "add")) {
        if (input.items.items.len == 0 and input.task == null) {
            err_msg = "todo add requires task or items";
        } else {
            if (input.task) |t| {
                if (state.findByContent(t) != null) {
                    err_msg = "task already exists";
                } else if (state.tasks.items.len >= max_tasks) {
                    err_msg = "todo list is full";
                } else {
                    state.tasks.append(alloc, .{ .text = alloc.dupe(u8, t) catch return error.OutOfMemory }) catch return error.OutOfMemory;
                }
            }
            if (err_msg == null) {
                for (input.items.items) |item| {
                    if (state.findByContent(item) != null) continue;
                    if (state.tasks.items.len >= max_tasks) break;
                    state.tasks.append(alloc, .{ .text = alloc.dupe(u8, item) catch return error.OutOfMemory }) catch return error.OutOfMemory;
                }
            }
        }
    } else if (std.mem.eql(u8, input.op, "start")) {
        if (input.task) |t| {
            if (state.findByContent(t)) |found| {
                for (state.tasks.items) |*other| {
                    if (other.status == .in_progress) other.status = .pending;
                }
                found.status = .in_progress;
            } else {
                err_msg = "task not found";
            }
        } else {
            err_msg = "todo start requires task";
        }
    } else if (std.mem.eql(u8, input.op, "done") or std.mem.eql(u8, input.op, "drop")) {
        const target_status: TaskStatus = if (std.mem.eql(u8, input.op, "done")) .completed else .abandoned;
        if (input.task) |t| {
            if (std.mem.eql(u8, t, "all")) {
                for (state.tasks.items) |*task| task.status = target_status;
            } else if (state.findByContent(t)) |found| {
                found.status = target_status;
            } else {
                err_msg = "task not found";
            }
        } else {
            err_msg = "todo done/drop requires task (use task=all to target every task)";
        }
    } else if (std.mem.eql(u8, input.op, "rm")) {
        if (input.task) |t| {
            if (std.mem.eql(u8, t, "all")) {
                for (state.tasks.items) |task| {
                    alloc.free(task.text);
                    if (task.reason) |r| alloc.free(r);
                }
                state.tasks.clearRetainingCapacity();
            } else {
                var found_index: ?usize = null;
                for (state.tasks.items, 0..) |*task, i| {
                    if (std.mem.eql(u8, task.text, t)) {
                        found_index = i;
                        break;
                    }
                }
                if (found_index) |i| {
                    const removed = state.tasks.orderedRemove(i);
                    alloc.free(removed.text);
                    if (removed.reason) |r| alloc.free(r);
                } else {
                    err_msg = "task not found";
                }
            }
        } else {
            err_msg = "todo rm requires task (use task=\"all\" to clear the whole list)";
        }
    } else if (std.mem.eql(u8, input.op, "view")) {
        // read-only
    } else {
        err_msg = "unknown op: use add|start|done|drop|rm|view";
    }

    if (err_msg) |m| {
        const body = state.render(alloc) catch return error.OutOfMemory;
        defer alloc.free(body);
        return .{ .failure = try std.fmt.allocPrint(alloc, "todo error: {s}\n{s}", .{ m, body }) };
    }

    if (!std.mem.eql(u8, input.op, "view")) {
        const json = state.serialize(alloc) catch return error.OutOfMemory;
        defer alloc.free(json);
        io_mod.writeFileAtomic(alloc, path, json) catch {
            return .{ .failure = try alloc.dupe(u8, "todo failed: could not persist todo.json") };
        };
    }

    const body = state.render(alloc) catch return error.OutOfMemory;
    return .{ .success = body };
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}
