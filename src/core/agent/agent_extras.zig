const std = @import("std");

const Allocator = std.mem.Allocator;

pub const max_loop_prompt_bytes: usize = 64 * 1024;
pub const max_loop_iterations: usize = 10_000;

pub const LoopCondition = union(enum) {
    none,
    /// keep looping while cmd exits 0
    while_ok: []u8,
    /// keep looping until cmd exits 0
    until_ok: []u8,

    pub fn deinit(self: *LoopCondition, alloc: Allocator) void {
        switch (self.*) {
            .none => {},
            .while_ok => |c| alloc.free(c),
            .until_ok => |c| alloc.free(c),
        }
        self.* = .none;
    }
};

pub const LoopLimit = union(enum) {
    infinite,
    count: usize,
    duration_ms: u64,
};

pub const LoopState = struct {
    active: bool = false,
    prompt: []u8 = &.{},
    condition: LoopCondition = .none,
    limit: LoopLimit = .infinite,
    iterations_run: usize = 0,
    started_ms: i64 = 0,

    pub fn deinit(self: *LoopState, alloc: Allocator) void {
        alloc.free(self.prompt);
        self.condition.deinit(alloc);
        self.* = .{};
    }

    pub fn clear(self: *LoopState, alloc: Allocator) void {
        alloc.free(self.prompt);
        self.condition.deinit(alloc);
        self.prompt = &.{};
        self.condition = .none;
        self.limit = .infinite;
        self.iterations_run = 0;
        self.active = false;
        self.started_ms = 0;
    }
};

fn parseDurationMs(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    const unit = text[text.len - 1];
    const digits = switch (unit) {
        's', 'm', 'h' => text[0 .. text.len - 1],
        '0'...'9' => text,
        else => return null,
    };
    const value = std.fmt.parseInt(u64, digits, 10) catch return null;
    const mult: u64 = switch (unit) {
        's' => 1000,
        'm' => 60 * 1000,
        'h' => 60 * 60 * 1000,
        else => 1000, // bare number = seconds
    };
    return value *| mult;
}

fn dupeQuoted(alloc: Allocator, rest: []const u8, cmd_start: []const u8) !struct { cmd: []u8, remainder: []const u8 } {
    _ = cmd_start;
    const trimmed = std.mem.trimStart(u8, rest, " \t");
    if (trimmed.len == 0) return error.MissingLoopCondition;
    const q = trimmed[0];
    if (q == '\'' or q == '"') {
        const end = std.mem.indexOfScalarPos(u8, trimmed, 1, q) orelse return error.MissingLoopCondition;
        const cmd = try alloc.dupe(u8, trimmed[1..end]);
        return .{ .cmd = cmd, .remainder = trimmed[end + 1 ..] };
    }
    // unquoted: take up to next whitespace
    const end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    const cmd = try alloc.dupe(u8, trimmed[0..end]);
    return .{ .cmd = cmd, .remainder = trimmed[end..] };
}

/// Parses `/loop` argument text: [count|duration] [--while|--until '<cmd>'] [prompt].
/// Empty args -> toggle off (returns null state, cleared flag).
pub fn parseLoopArgs(alloc: Allocator, args: []const u8) !?LoopState {
    var rest = std.mem.trim(u8, args, " \t");
    if (rest.len == 0) return null; // toggle off

    var state = LoopState{};
    errdefer state.deinit(alloc);

    // leading count or duration
    const first_tok_end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
    const first_tok = rest[0..first_tok_end];
    if (!std.mem.startsWith(u8, first_tok, "--")) {
        if (parseDurationMs(first_tok)) |ms| {
            // a bare integer is a count; anything with a unit is a duration
            const is_count = std.fmt.parseInt(usize, first_tok, 10) catch 0;
            if (is_count > 0 and first_tok.len > 0 and first_tok[first_tok.len - 1] >= '0' and first_tok[first_tok.len - 1] <= '9') {
                state.limit = .{ .count = @min(is_count, max_loop_iterations) };
            } else {
                state.limit = .{ .duration_ms = ms };
            }
            rest = std.mem.trimStart(u8, rest[first_tok_end..], " \t");
        }
    }

    // flags
    while (true) {
        if (std.mem.startsWith(u8, rest, "--while")) {
            const parsed = try dupeQuoted(alloc, rest["--while".len..], "--while");
            state.condition = .{ .while_ok = parsed.cmd };
            rest = std.mem.trimStart(u8, parsed.remainder, " \t");
        } else if (std.mem.startsWith(u8, rest, "--until")) {
            const parsed = try dupeQuoted(alloc, rest["--until".len..], "--until");
            state.condition = .{ .until_ok = parsed.cmd };
            rest = std.mem.trimStart(u8, parsed.remainder, " \t");
        } else break;
    }

    // remainder is the prompt
    const prompt = std.mem.trim(u8, rest, " \t");
    if (prompt.len > max_loop_prompt_bytes) return error.LoopPromptTooLarge;
    state.prompt = try alloc.dupe(u8, prompt);
    state.active = true;
    return state;
}

pub const LoopDecision = enum { run, stop_limit, stop_condition };

/// Decides whether the next iteration should run, given the last condition
/// command exit code (null when no condition is configured).
pub fn loopShouldContinue(state: LoopState, now_ms: i64, condition_exit: ?u8) LoopDecision {
    if (!state.active) return .stop_limit;
    switch (state.limit) {
        .infinite => {},
        .count => |max| if (state.iterations_run >= max) return .stop_limit,
        .duration_ms => |dur| if (now_ms - state.started_ms >= @as(i64, @intCast(dur))) return .stop_limit,
    }
    switch (state.condition) {
        .none => {},
        .while_ok => {
            // continue only while exit == 0
            if (condition_exit == null or condition_exit.? != 0) return .stop_condition;
        },
        .until_ok => {
            // continue only until exit == 0 (stop when it succeeds)
            if (condition_exit != null and condition_exit.? == 0) return .stop_condition;
        },
    }
    return .run;
}

/// In-memory leaf rewind over a linear history. Mirrors omp navigateTree:
/// moving the leaf backward keeps abandoned turns available so the leaf can
/// move forward again. No file rewrite, no fork.
pub const TreeState = struct {
    /// Number of leading history turns considered active. null = all.
    leaf: ?usize = null,

    pub fn activeCount(self: TreeState, total: usize) usize {
        if (self.leaf) |l| return @min(l, total);
        return total;
    }

    pub fn isRewound(self: TreeState, total: usize) bool {
        return self.leaf != null and self.leaf.? < total;
    }
};
