const std = @import("std");
const types = @import("../shared/types.zig");
const session_tree = @import("../session/session_tree.zig");
const Allocator = std.mem.Allocator;

pub const max_visible_items: u16 = 20;

/// Interactive conversation-tree navigator, mirroring omp `/tree`:
/// lists every turn in the physical log, arrow-keys move the selection,
/// Enter rewinds the active branch to the selected turn, Esc closes.
/// Nodes are owned by the menu and rebuilt each time it opens.
pub const TreeMenu = struct {
    active: bool = false,
    selected_index: usize = 0,
    window_start: usize = 0,
    nodes: []session_tree.TurnNode = &.{},
    /// Current active-branch leaf (1-based turn position); 0 means whole log.
    leaf: usize = 0,

    pub fn deinit(self: *TreeMenu, alloc: Allocator) void {
        session_tree.freeTurnNodes(alloc, self.nodes);
        self.* = .{};
    }

    pub fn openWith(self: *TreeMenu, alloc: Allocator, nodes: []session_tree.TurnNode, leaf: usize) void {
        // take ownership of nodes; drop any prior set
        session_tree.freeTurnNodes(alloc, self.nodes);
        self.* = .{
            .active = true,
            .nodes = nodes,
            // start the cursor on the current leaf (or last turn) like omp
            .selected_index = if (leaf > 0 and leaf <= nodes.len) leaf - 1 else (if (nodes.len > 0) nodes.len - 1 else 0),
        };
        self.leaf = leaf;
        self.window_start = if (self.selected_index >= max_visible_items) self.selected_index - max_visible_items + 1 else 0;
    }

    pub fn close(self: *TreeMenu, alloc: Allocator) void {
        session_tree.freeTurnNodes(alloc, self.nodes);
        self.* = .{};
    }

    pub fn count(self: *const TreeMenu) usize {
        return self.nodes.len;
    }

    /// 1-based turn position of the selected node, or null when empty.
    pub fn selectedTurn(self: *const TreeMenu) ?usize {
        if (!self.active or self.nodes.len == 0) return null;
        const idx = self.selected_index % self.nodes.len;
        return self.nodes[idx].index;
    }

    pub fn move(self: *TreeMenu, delta: i32, visible_items: u16) bool {
        const n = self.nodes.len;
        if (!self.active or n == 0) return false;
        const current: i32 = @intCast(self.selected_index % n);
        var next = current + delta;
        if (next < 0) next = @as(i32, @intCast(n)) - 1;
        if (next >= @as(i32, @intCast(n))) next = 0;
        self.selected_index = @intCast(next);
        self.window_start = updateWindowStart(self.window_start, n, self.selected_index, @max(visible_items, 1));
        return true;
    }
};

fn updateWindowStart(window_start: usize, item_count: usize, selected: usize, visible: u16) usize {
    const vis = @max(@as(usize, visible), 1);
    if (selected < window_start) return selected;
    if (selected >= window_start + vis) return selected - vis + 1;
    if (window_start + vis > item_count and item_count > vis) return item_count - vis;
    return window_start;
}
