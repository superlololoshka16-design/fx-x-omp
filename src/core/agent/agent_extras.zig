const std = @import("std");

const Allocator = std.mem.Allocator;

pub const max_loop_prompt_bytes: usize = 64 * 1024;
pub const max_loop_iterations: usize = 10_000;
/// omp fires the next iteration 800ms after the agent fully settles.
pub const loop_settle_delay_ms: i64 = 800;

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

/// omp loop-mode state machine:
/// - active=false: off.
/// - active=true, prompt=null: armed, waiting for the next user prompt to
///   become the repeating prompt ("Loop: on (waiting for next prompt)").
/// - active=true, prompt!=null: repeating ("Loop: on (repeating prompt)").
/// The armed prompt is captured by the submit path; the fire happens on the
/// main thread once the agent settles (idle) and the settle delay elapses.
pub const LoopState = struct {
    active: bool = false,
    prompt: ?[]u8 = null,
    condition: LoopCondition = .none,
    limit: LoopLimit = .infinite,
    iterations_run: usize = 0,
    started_ms: i64 = 0,
    /// set by the turn-end hook; consumed by the main-thread tick
    pending_fire: bool = false,
    last_turn_end_ms: i64 = 0,

    pub fn deinit(self: *LoopState, alloc: Allocator) void {
        if (self.prompt) |p| alloc.free(p);
        self.condition.deinit(alloc);
        self.* = .{};
    }

    pub fn clear(self: *LoopState, alloc: Allocator) void {
        if (self.prompt) |p| alloc.free(p);
        self.condition.deinit(alloc);
        self.* = .{};
    }

    /// Status-line label, omp-compatible wording.
    pub fn statusLabel(self: LoopState) ?[]const u8 {
        if (!self.active) return null;
        if (self.limit != .infinite or self.condition != .none) return "Loop: on (limited)";
        if (self.prompt != null) return "Loop: on (repeating prompt)";
        return "Loop: on (waiting for next prompt)";
    }

    pub fn armWithPrompt(self: *LoopState, alloc: Allocator, text: []const u8) !void {
        if (!self.active or self.prompt != null) return;
        self.prompt = try alloc.dupe(u8, text);
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

fn dupeQuoted(alloc: Allocator, rest: []const u8) !struct { cmd: []u8, remainder: []const u8 } {
    const trimmed = std.mem.trimStart(u8, rest, " \t");
    if (trimmed.len == 0) return error.MissingLoopCondition;
    const q = trimmed[0];
    if (q == '\'' or q == '"') {
        const end = std.mem.indexOfScalarPos(u8, trimmed, 1, q) orelse return error.MissingLoopCondition;
        const cmd = try alloc.dupe(u8, trimmed[1..end]);
        return .{ .cmd = cmd, .remainder = trimmed[end + 1 ..] };
    }
    const end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    const cmd = try alloc.dupe(u8, trimmed[0..end]);
    return .{ .cmd = cmd, .remainder = trimmed[end..] };
}

/// Parses `/loop` argument text: [count|duration] [--while|--until '<cmd>'] [prompt].
/// A non-empty parse always returns an active state; prompt may stay null (armed).
pub fn parseLoopArgs(alloc: Allocator, args: []const u8) !LoopState {
    var rest = std.mem.trim(u8, args, " \t");
    var state = LoopState{ .active = true };
    errdefer state.deinit(alloc);

    // leading count or duration
    const first_tok_end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
    const first_tok = rest[0..first_tok_end];
    if (first_tok.len > 0 and !std.mem.startsWith(u8, first_tok, "--")) {
        if (parseDurationMs(first_tok)) |ms| {
            const last = first_tok[first_tok.len - 1];
            const bare_int = last >= '0' and last <= '9';
            if (bare_int) {
                const count = std.fmt.parseInt(usize, first_tok, 10) catch 0;
                if (count > 0) state.limit = .{ .count = @min(count, max_loop_iterations) };
            } else {
                state.limit = .{ .duration_ms = ms };
            }
            rest = std.mem.trimStart(u8, rest[first_tok_end..], " \t");
        }
    }

    while (true) {
        if (std.mem.startsWith(u8, rest, "--while")) {
            const parsed = try dupeQuoted(alloc, rest["--while".len..]);
            state.condition = .{ .while_ok = parsed.cmd };
            rest = std.mem.trimStart(u8, parsed.remainder, " \t");
        } else if (std.mem.startsWith(u8, rest, "--until")) {
            const parsed = try dupeQuoted(alloc, rest["--until".len..]);
            state.condition = .{ .until_ok = parsed.cmd };
            rest = std.mem.trimStart(u8, parsed.remainder, " \t");
        } else break;
    }

    const prompt = std.mem.trim(u8, rest, " \t");
    if (prompt.len > max_loop_prompt_bytes) return error.LoopPromptTooLarge;
    if (prompt.len > 0) state.prompt = try alloc.dupe(u8, prompt);
    return state;
}

pub const LoopDecision = enum { run, wait, stop_limit, stop_condition };

/// Decides the next iteration given the last condition exit code
/// (null = no condition configured or not yet run).
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
            if (condition_exit == null or condition_exit.? != 0) return .stop_condition;
        },
        .until_ok => {
            if (condition_exit != null and condition_exit.? == 0) return .stop_condition;
        },
    }
    return .run;
}
