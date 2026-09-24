const std = @import("std");
const managed_execution = @import("managed_execution.zig");
const managed_contract = @import("managed_execution_contract.zig");

const Allocator = std.mem.Allocator;

pub const max_watched: usize = managed_contract.max_live_entries;

/// Tracks live background executions and detects completion. Modelled on omp's
/// async job auto-delivery: when a backgrounded command finishes while the agent
/// is idle, the agent is woken once with a notice so it can read the result via
/// shell.interact. Completion is inferred from a running id leaving the live
/// list, so no output is consumed here and the model's own observation stays
/// intact.
pub const Watcher = struct {
    watched: [max_watched][]u8 = [_][]u8{""} ** max_watched,
    watched_len: usize = 0,

    pub fn deinit(self: *Watcher, alloc: Allocator) void {
        self.clear(alloc);
    }

    pub fn clear(self: *Watcher, alloc: Allocator) void {
        for (self.watched[0..self.watched_len]) |id| alloc.free(id);
        for (self.watched[0..max_watched]) |*slot| slot.* = "";
        self.watched_len = 0;
    }

    /// Refreshes the watch set from the runtime and reports whether at least one
    /// previously-running execution left the running set (finished, stopped or
    /// lost) since the previous observation.
    pub fn observe(self: *Watcher, alloc: Allocator, runtime: *managed_execution.Runtime) bool {
        const items = runtime.list(alloc) catch return false;
        defer {
            for (items) |*item| item.deinit(alloc);
            alloc.free(items);
        }

        var finished = false;
        var i: usize = 0;
        while (i < self.watched_len) {
            const id = self.watched[i];
            var still_running = false;
            for (items) |item| {
                if (!std.mem.eql(u8, item.execution_id, id)) continue;
                still_running = std.meta.activeTag(item.state) == .running;
                break;
            }
            if (still_running) {
                i += 1;
                continue;
            }
            alloc.free(id);
            self.watched[i] = self.watched[self.watched_len - 1];
            self.watched[self.watched_len - 1] = "";
            self.watched_len -= 1;
            finished = true;
        }

        for (items) |item| {
            if (std.meta.activeTag(item.state) != .running) continue;
            var known = false;
            for (self.watched[0..self.watched_len]) |id| {
                if (std.mem.eql(u8, id, item.execution_id)) {
                    known = true;
                    break;
                }
            }
            if (known) continue;
            if (self.watched_len >= max_watched) continue;
            const owned = alloc.dupe(u8, item.execution_id) catch continue;
            self.watched[self.watched_len] = owned;
            self.watched_len += 1;
        }

        return finished;
    }

    pub fn hasWatched(self: *const Watcher) bool {
        return self.watched_len > 0;
    }
};
