const std = @import("std");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

const max_events_bytes: usize = 64 << 20;
const max_turns: usize = 1 << 20;

pub const TurnNode = struct {
    index: usize,
    preview: []u8,

    pub fn deinit(self: *TurnNode, alloc: Allocator) void {
        alloc.free(self.preview);
    }
};

pub fn freeTurnNodes(alloc: Allocator, turns: []TurnNode) void {
    for (turns) |*t| t.deinit(alloc);
    alloc.free(turns);
}

fn turnPreview(alloc: Allocator, turn: types.HistoryTurn) ![]u8 {
    const text: []const u8 = switch (turn) {
        .assistant => |t| t.user.text,
        .interrupted => |t| t.user.text,
        .compacted_summary => |t| t.summary,
    };
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const cut = @min(trimmed.len, 72);
    const owned = try alloc.dupe(u8, trimmed[0..cut]);
    for (owned) |*c| {
        if (c.* == '\n' or c.* == '\r') c.* = ' ';
    }
    return owned;
}

/// Live-history turn list for the in-session /tree menu.
pub fn scanTurns(alloc: Allocator, history: []const types.HistoryTurn) ![]TurnNode {
    var nodes: std.ArrayList(TurnNode) = .empty;
    errdefer freeTurnNodes(alloc, nodes.items);
    var count: usize = 0;
    for (history) |turn| {
        if (turn == .compacted_summary) continue;
        count += 1;
        try nodes.append(alloc, .{
            .index = count,
            .preview = try turnPreview(alloc, turn),
        });
    }
    return nodes.toOwnedSlice(alloc);
}

// ---------- persistent branch sidecar ----------
//
// The event log stays append-only: abandoned turns are never rewritten, exactly
// like omp's tree over a linear log. tree.json records the rewind leaf so a
// resume reconstructs only the active branch and the model genuinely forgets
// abandoned turns.
//
//   {"leaf":3,"physical":5}
//
// leaf: 1-based active turn position; 0 means "no rewind, whole log active".
// physical: number of log turns when the rewind happened; turns appended after
// the rewind (position > physical) are children of the leaf and stay active.
// Absent file => the whole log is active.

pub const BranchState = struct {
    leaf: usize,
    physical: usize,
};

pub fn branchPath(alloc: Allocator, session_dir: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ session_dir, "tree.json" });
}

pub fn loadBranch(alloc: Allocator, session_dir: []const u8) ?BranchState {
    const path = branchPath(alloc, session_dir) catch return null;
    defer alloc.free(path);
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch return null;
    defer file.close(io_mod.getIo());
    const raw = io_mod.readFileToEnd(alloc, &file, 1 << 20) catch return null;
    defer alloc.free(raw);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const obj = parsed.value.object;
    const leaf_v = obj.get("leaf") orelse return null;
    const phys_v = obj.get("physical") orelse return null;
    if (leaf_v != .integer or phys_v != .integer) return null;
    if (leaf_v.integer < 0 or phys_v.integer < 0) return null;
    return .{
        .leaf = @intCast(leaf_v.integer),
        .physical = @intCast(phys_v.integer),
    };
}

pub fn saveBranch(alloc: Allocator, session_dir: []const u8, state: BranchState) !void {
    const path = try branchPath(alloc, session_dir);
    defer alloc.free(path);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    out.writer.print("{{\"leaf\":{d},\"physical\":{d}}}", .{ state.leaf, state.physical }) catch
        return error.OutOfMemory;
    try io_mod.writeFileAtomic(alloc, path, out.written());
}

/// True when the turn at 1-based `position` belongs to the active branch.
pub fn turnActive(state: ?BranchState, position: usize) bool {
    const s = state orelse return true;
    if (s.leaf == 0) return true;
    return position <= s.leaf or position > s.physical;
}

/// Copies the active-branch turns out of the full log. compacted_summary turns
/// on the active prefix are retained so a checkpoint is never dropped.
pub fn filterToBranch(
    alloc: Allocator,
    history: []const types.HistoryTurn,
    state: ?BranchState,
) ![]types.HistoryTurn {
    var out: std.ArrayList(types.HistoryTurn) = .empty;
    errdefer {
        for (out.items) |t| types.freeHistoryTurn(alloc, t);
        out.deinit(alloc);
    }
    var real_index: usize = 0;
    for (history) |turn| {
        if (turn == .compacted_summary) {
            if (turnActive(state, real_index)) {
                try out.append(alloc, try types.dupeHistoryTurn(alloc, turn));
            }
            continue;
        }
        real_index += 1;
        if (!turnActive(state, real_index)) continue;
        try out.append(alloc, try types.dupeHistoryTurn(alloc, turn));
    }
    return out.toOwnedSlice(alloc);
}
