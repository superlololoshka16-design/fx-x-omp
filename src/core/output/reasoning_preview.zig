const std = @import("std");

/// Single-writer (worker thread) / single-reader (main render thread) reasoning
/// preview. Seqlock: the writer bumps an odd sequence, rewrites the ring, bumps
/// to even. The reader snapshots the sequence before and after copying; a mismatch
/// or odd value means a torn read and the reader keeps its previous preview.
/// No mutexes, no allocation on either path, head/tail on separate cache lines.
pub const capacity: usize = 1024; // power of two
const mask: usize = capacity - 1;
pub const preview_len: usize = 80;

const align_line = 64;

pub const ReasoningPreview = struct {
    /// Writer state. Ring holds the most recent reasoning bytes.
    write_seq: std.atomic.Value(u64) align(@alignOf(std.atomic.Value(u64))) = .init(0),
    head: usize = 0, // next write position in the ring
    filled: usize = 0, // bytes currently valid, <= capacity
    ring: [capacity]u8 = [_]u8{0} ** capacity,
    /// Reader-side scratch: last coherent preview, rendered by the footer.
    last: [preview_len]u8 = [_]u8{0} ** preview_len,
    last_len: usize = 0,

    pub fn push(self: *ReasoningPreview, delta: []const u8) void {
        if (delta.len == 0) return;
        // publish start: odd sequence marks an in-flight rewrite
        const seq = self.write_seq.load(.monotonic);
        self.write_seq.store(seq + 1, .release);

        var i: usize = 0;
        while (i < delta.len) : (i += 1) {
            const b = delta[i];
            self.ring[self.head] = if (b < 0x20 or b == 0x7f) ' ' else b;
            self.head = (self.head + 1) & mask;
        }
        self.filled = @min(self.filled + delta.len, capacity);

        self.write_seq.store(seq + 2, .release);
    }

    pub fn reset(self: *ReasoningPreview) void {
        const seq = self.write_seq.load(.monotonic);
        self.write_seq.store(seq + 1, .release);
        self.head = 0;
        self.filled = 0;
        self.write_seq.store(seq + 2, .release);
        self.last_len = 0;
    }

    /// Reader: copy the tail of the ring into `last` when a coherent snapshot is
    /// available. Returns the preview slice (borrowed from `last`).
    pub fn read(self: *ReasoningPreview) []const u8 {
        const filled = self.filled;
        if (filled == 0) {
            self.last_len = 0;
            return self.last[0..0];
        }
        const before = self.write_seq.load(.acquire);
        if (before & 1 != 0) return self.last[0..self.last_len]; // write in flight

        const take = @min(filled, preview_len);
        // ring tail: last `take` bytes ending at head
        var out_i: usize = 0;
        var src = (self.head + capacity - take) & mask;
        while (out_i < take) : (out_i += 1) {
            self.last[out_i] = self.ring[src];
            src = (src + 1) & mask;
        }

        const after = self.write_seq.load(.acquire);
        if (after != before) return self.last[0..self.last_len]; // torn; keep previous
        self.last_len = take;
        return self.last[0..take];
    }
};
