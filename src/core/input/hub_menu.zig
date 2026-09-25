const std = @import("std");
const io_mod = @import("../shared/io.zig");
const Allocator = std.mem.Allocator;

pub const max_visible_items: u16 = 20;

pub const Peer = struct {
    name: []u8,
    messages: usize,
};

fn freePeers(alloc: Allocator, peers: []Peer) void {
    for (peers) |*p| alloc.free(p.name);
    alloc.free(peers);
}

/// Live agent-hub panel, mirroring omp `/hub`: lists peers with unread counts,
/// arrow-keys move, Enter opens a peer mailbox (read-only preview), Esc closes.
pub const HubMenu = struct {
    active: bool = false,
    selected_index: usize = 0,
    window_start: usize = 0,
    peers: []Peer = &.{},
    /// When set, the menu shows this peer's mailbox instead of the peer list.
    open_peer: ?[]u8 = null,
    open_body: []u8 = &.{},

    pub fn deinit(self: *HubMenu, alloc: Allocator) void {
        self.close(alloc);
    }

    pub fn close(self: *HubMenu, alloc: Allocator) void {
        freePeers(alloc, self.peers);
        if (self.open_peer) |p| alloc.free(p);
        alloc.free(@constCast(self.open_body));
        self.* = .{};
    }

    pub fn backToList(self: *HubMenu, alloc: Allocator) bool {
        if (self.open_peer == null) return false;
        alloc.free(self.open_peer.?);
        self.open_peer = null;
        alloc.free(@constCast(self.open_body));
        self.open_body = &.{};
        self.selected_index = 0;
        self.window_start = 0;
        return true;
    }

    pub fn count(self: *const HubMenu) usize {
        return self.peers.len;
    }

    pub fn move(self: *HubMenu, delta: i32, visible_items: u16) bool {
        const n = self.peers.len;
        if (!self.active or n == 0) return false;
        const current: i32 = @intCast(self.selected_index % n);
        var next = current + delta;
        if (next < 0) next = @as(i32, @intCast(n)) - 1;
        if (next >= @as(i32, @intCast(n))) next = 0;
        self.selected_index = @intCast(next);
        const vis = @max(@as(usize, visible_items), 1);
        if (self.selected_index < self.window_start) self.window_start = self.selected_index;
        if (self.selected_index >= self.window_start + vis) self.window_start = self.selected_index - vis + 1;
        return true;
    }

    pub fn selectedPeerName(self: *const HubMenu) ?[]const u8 {
        if (!self.active or self.peers.len == 0) return null;
        return self.peers[self.selected_index % self.peers.len].name;
    }

    /// Opens the selected peer's mailbox (does NOT drain it; the agent's own
    /// hub tool op=inbox remains the only consumer).
    pub fn openSelected(self: *HubMenu, alloc: Allocator, hub_root: []const u8) !void {
        const name = self.selectedPeerName() orelse return;
        const file_name = try std.fmt.allocPrint(alloc, "{s}.jsonl", .{name});
        defer alloc.free(file_name);
        const path = try std.fs.path.join(alloc, &.{ hub_root, file_name });
        defer alloc.free(path);
        alloc.free(@constCast(self.open_body));
        self.open_body = &.{};
        var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch return;
        defer file.close(io_mod.getIo());
        self.open_body = io_mod.readFileToEnd(alloc, &file, 4 << 20) catch &.{};
        if (self.open_peer) |p| alloc.free(p);
        self.open_peer = try alloc.dupe(u8, name);
    }
};

/// Scans ~/.fx/hub for peer mailboxes with message counts.
pub fn scanPeers(alloc: Allocator, hub_root: []const u8) ![]Peer {
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), hub_root, .{ .iterate = true }) catch {
        return alloc.alloc(Peer, 0);
    };
    defer dir.close(io_mod.getIo());
    var out: std.ArrayList(Peer) = .empty;
    errdefer freePeers(alloc, out.items);
    var iter = dir.iterate();
    while (try iter.next(io_mod.getIo())) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const peer = entry.name[0 .. entry.name.len - ".jsonl".len];
        const path = try std.fs.path.join(alloc, &.{ hub_root, entry.name });
        defer alloc.free(path);
        var msgs: usize = 0;
        if (std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{})) |*file| {
            defer file.close(io_mod.getIo());
            if (io_mod.readFileToEnd(alloc, file, 4 << 20)) |raw| {
                defer alloc.free(raw);
                var lines = std.mem.splitScalar(u8, raw, '\n');
                while (lines.next()) |line| {
                    if (std.mem.trim(u8, line, " \t\r").len > 0) msgs += 1;
                }
            } else |_| {}
        } else |_| {}
        try out.append(alloc, .{ .name = try alloc.dupe(u8, peer), .messages = msgs });
    }
    return out.toOwnedSlice(alloc);
}
