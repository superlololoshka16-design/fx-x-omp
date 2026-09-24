const std = @import("std");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const TurnNode = struct {
    index: usize,
    preview: []u8,

    pub fn deinit(self: *TurnNode, alloc: Allocator) void {
        alloc.free(self.preview);
    }
};

pub fn freeTurnNodes(alloc: Allocator, nodes: []TurnNode) void {
    for (nodes) |*n| n.deinit(alloc);
    alloc.free(nodes);
}

fn turnPreview(alloc: Allocator, turn: types.HistoryTurn) ![]u8 {
    const text: []const u8 = switch (turn) {
        .assistant => |t| t.user.text,
        .interrupted => |t| t.user.text,
        .compacted_summary => |t| t.summary,
    };
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const cut = @min(trimmed.len, 72);
    // collapse newlines to spaces for a single-line preview
    const owned = try alloc.dupe(u8, trimmed[0..cut]);
    for (owned) |*c| {
        if (c.* == '\n' or c.* == '\r') c.* = ' ';
    }
    return owned;
}

/// Builds a turn list from live history. Index is 1-based and maps directly to
/// the rewind window: `/tree N` restores history[0..N].
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
