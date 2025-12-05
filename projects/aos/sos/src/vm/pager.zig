const std = @import("std");
const cimports = @import("cimports");
const sos = cimports.sos;

const MAX_CLIENTS: usize = @intCast(sos.MAX_CLIENTS);
pub const MAX_PAGER_REQUESTS: usize = if (MAX_CLIENTS == 0) 1 else MAX_CLIENTS * 4;

pub const PagerRequestTable = struct {
    pub const Key = struct {
        client_id: u32,
        page_base: usize,
    };

    const Entry = struct {
        used: bool = false,
        key: Key = Key{ .client_id = 0, .page_base = 0 },
    };

    pub const ReserveResult = enum {
        /// Successfully inserted a new key.
        Inserted,
        /// Request already in flight.
        Duplicate,
        /// Table saturated, caller must back off.
        TableFull,
    };

    pub const Stats = struct {
        hits: usize,
        misses: usize,
        in_flight: usize,
        capacity: usize = MAX_PAGER_REQUESTS,
    };

    entries: [MAX_PAGER_REQUESTS]Entry = [_]Entry{.{}} ** MAX_PAGER_REQUESTS,
    hits: usize = 0,
    misses: usize = 0,
    lock: SpinLock = .{},

    /// Attempt to reserve a slot for `key`.
    pub fn reserve(self: *PagerRequestTable, key: Key) ReserveResult {
        const guard = self.lock.guard();
        defer guard.release();

        if (self.findIndex(key)) |_| {
            self.hits += 1;
            return .Duplicate;
        }

        const slot = self.findFreeSlot() orelse {
            return .TableFull;
        };

        self.entries[slot] = Entry{ .used = true, .key = key };
        self.misses += 1;
        return .Inserted;
    }

    /// Release a reservation for `key`.
    pub fn release(self: *PagerRequestTable, key: Key) bool {
        const guard = self.lock.guard();
        defer guard.release();

        if (self.findIndex(key)) |idx| {
            self.entries[idx] = .{};
            return true;
        }
        return false;
    }

    /// Returns true if `key` is currently reserved.
    pub fn contains(self: *PagerRequestTable, key: Key) bool {
        const guard = self.lock.guard();
        defer guard.release();
        return self.findIndex(key) != null;
    }

    /// Return aggregated statistics.
    pub fn stats(self: *PagerRequestTable) Stats {
        const guard = self.lock.guard();
        defer guard.release();
        return Stats{
            .hits = self.hits,
            .misses = self.misses,
            .in_flight = self.activeCount(),
        };
    }

    /// Reset the table, clearing all entries and counters.
    pub fn clear(self: *PagerRequestTable) void {
        const guard = self.lock.guard();
        defer guard.release();

        for (&self.entries) |*entry| {
            entry.* = .{};
        }
        self.hits = 0;
        self.misses = 0;
    }

    fn findIndex(self: *PagerRequestTable, key: Key) ?usize {
        for (self.entries, 0..) |entry, idx| {
            if (!entry.used) continue;
            if (entry.key.client_id == key.client_id and entry.key.page_base == key.page_base) {
                return idx;
            }
        }
        return null;
    }

    fn findFreeSlot(self: *PagerRequestTable) ?usize {
        for (self.entries, 0..) |entry, idx| {
            if (!entry.used) {
                return idx;
            }
        }
        return null;
    }

    fn activeCount(self: *PagerRequestTable) usize {
        var count: usize = 0;
        for (self.entries) |entry| {
            if (entry.used) count += 1;
        }
        return count;
    }
};

/// Global table instance shared by VM fault handling and worker completions.
pub var global_table: PagerRequestTable = .{};

pub fn global() *PagerRequestTable {
    return &global_table;
}

// TODO: See if there are better locks for this
const SpinLock = struct {
    state: u32 = 0,

    fn guard(self: *SpinLock) Guard {
        self.lock();
        return Guard{ .lock = self };
    }

    fn lock(self: *SpinLock) void {
        while (true) {
            if (@cmpxchgStrong(u32, &self.state, 0, 1, .acq_rel, .acquire) == null) {
                return;
            }
        }
    }

    fn unlock(self: *SpinLock) void {
        @atomicStore(u32, &self.state, 0, .release);
    }

    const Guard = struct {
        lock: *SpinLock,

        pub fn release(self: Guard) void {
            self.lock.unlock();
        }
    };
};
