const std = @import("std");
const c = @import("cimports").c;
const sos = @import("cimports").sos;

// Sentinel value for invalid/unallocated slots
pub const INVALID_SLOT: u32 = 0;

// Page size from seL4 configuration
const PAGE_SIZE: usize = @as(usize, 1) << 12; // 4 KiB

// Initial capacity, 256 slots (1 MiB)
const INITIAL_SLOT_COUNT: u32 = 256;

// Maximum capacity, 8192 slots (32 MiB)
const MAX_SLOT_COUNT: u32 = 8192;

// NFS file mode flags
const O_RDWR: c_int = 0x0002;
const O_CREAT: c_int = 0x0100;

// Import NFS operations from nfs_handler.zig.
// NOTE: For some reason, @import does not work for this.
extern fn nfs_open_sync_c(path: [*:0]const u8, flags: c_int) ?*anyopaque;
extern fn nfs_close_sync_c(fh: ?*anyopaque) c_int;

/// Frame reference to proof that a frame index is valid (non-zero).
const FrameRef = struct {
    value: usize,

    const NULL: usize = 0;

    /// Returns null if frame is NULL_FRAME, proving non-null invariant.
    fn from(value: usize) ?FrameRef {
        if (value == NULL) return null;
        return .{ .value = value };
    }

    fn toUsize(self: FrameRef) usize {
        return self.value;
    }
};

/// Slot metadata to encode slot lifecycle.
const SlotState = union(enum) {
    free: void,
    allocated: AllocatedSlot,

    const AllocatedSlot = struct {
        frame: FrameRef,
        pid: u32,
        vaddr: usize,
    };

    fn isFree(self: SlotState) bool {
        return switch (self) {
            .free => true,
            .allocated => false,
        };
    }

    fn isAllocated(self: SlotState) bool {
        return !self.isFree();
    }
};

/// Allocation bitmap
const Bitmap = struct {
    words: []u64,

    /// Initialise bitmap with all slots free
    fn init(allocator: std.mem.Allocator, num_slots: u32) !Bitmap {
        const num_words = (num_slots + 63) / 64;
        const words = try allocator.alloc(u64, num_words);
        @memset(words, 0);
        return .{ .words = words };
    }

    fn deinit(self: Bitmap, allocator: std.mem.Allocator) void {
        allocator.free(self.words);
    }

    /// Test if slot is allocated (bit set)
    fn isSet(self: Bitmap, slot: u32) bool {
        std.debug.assert(slot > 0); // Slot 0 is reserved
        const word_idx = slot / 64;
        const bit_idx: u6 = @intCast(slot % 64);
        if (word_idx >= self.words.len) return false;
        return (self.words[word_idx] & (@as(u64, 1) << bit_idx)) != 0;
    }

    /// Mark slot as allocated
    fn set(self: *Bitmap, slot: u32) void {
        std.debug.assert(slot > 0);
        const word_idx = slot / 64;
        const bit_idx: u6 = @intCast(slot % 64);
        std.debug.assert(word_idx < self.words.len);
        self.words[word_idx] |= @as(u64, 1) << bit_idx;
    }

    /// Mark slot as free
    fn clear(self: *Bitmap, slot: u32) void {
        std.debug.assert(slot > 0);
        const word_idx = slot / 64;
        const bit_idx: u6 = @intCast(slot % 64);
        std.debug.assert(word_idx < self.words.len);
        self.words[word_idx] &= ~(@as(u64, 1) << bit_idx);
    }
};

/// Global pagefile state
const PagefileState = struct {
    nfs_handle: *anyopaque,
    slot_table: []SlotState,
    bitmap: Bitmap,
    next_search_hint: u32,
    slots_used: usize,
    slots_peak: usize,
    total_allocs: usize,
    total_frees: usize,
    allocator: std.mem.Allocator,

    /// Initialise pagefile with given capacity
    fn init(allocator: std.mem.Allocator, nfs_handle: *anyopaque, num_slots: u32) !PagefileState {
        const slot_table = try allocator.alloc(SlotState, num_slots);
        errdefer allocator.free(slot_table);

        const bitmap = try Bitmap.init(allocator, num_slots);
        errdefer bitmap.deinit(allocator);

        // Initialise all slots as free
        for (slot_table) |*slot| {
            slot.* = .free;
        }

        return .{
            .nfs_handle = nfs_handle,
            .slot_table = slot_table,
            .bitmap = bitmap,
            .next_search_hint = 1, // Skip slot 0
            .slots_used = 0,
            .slots_peak = 0,
            .total_allocs = 0,
            .total_frees = 0,
            .allocator = allocator,
        };
    }

    fn deinit(self: *PagefileState) void {
        self.allocator.free(self.slot_table);
        self.bitmap.deinit(self.allocator);
    }

    fn numSlots(self: *const PagefileState) u32 {
        return @intCast(self.slot_table.len);
    }

    /// Allocate slot using first-fit with wraparound search.
    /// Returns null if pagefile is full.
    fn allocSlot(
        self: *PagefileState,
        frame_value: usize,
        pid: u32,
        vaddr: usize,
    ) ?u32 {
        // Validate frame reference at runtime
        const frame = FrameRef.from(frame_value) orelse {
            _ = c.printf("[pagefile] ERROR: Cannot allocate slot for NULL_FRAME\n");
            return null;
        };

        // Linear search from hint with wraparound
        const search_start = self.next_search_hint;
        var slot = search_start;

        while (true) {
            // Slot 0 is reserved as invalid marker
            if (slot == 0) {
                slot = 1;
                if (slot >= self.numSlots()) {
                    slot = 0;
                }
                continue;
            }

            // Check if slot is free
            if (!self.bitmap.isSet(slot)) {
                // Allocate: transition free → allocated
                self.transitionToAllocated(slot, frame, pid, vaddr);
                return slot;
            }

            // Advance to next slot with wraparound
            slot += 1;
            if (slot >= self.numSlots()) {
                slot = 0;
            }

            // Full traversal without finding free slot
            if (slot == search_start) {
                _ = c.printf("[pagefile] WARNING: Pagefile exhausted: %zu/%u slots used\n", @as(c_ulong, self.slots_used), @as(c_uint, self.numSlots()));
                return null;
            }
        }
    }

    /// Transition slot from free to allocated state.
    fn transitionToAllocated(
        self: *PagefileState,
        slot: u32,
        frame: FrameRef,
        pid: u32,
        vaddr: usize,
    ) void {
        std.debug.assert(slot > 0 and slot < self.numSlots());
        std.debug.assert(!self.bitmap.isSet(slot));
        std.debug.assert(self.slot_table[slot].isFree());

        // Atomic state transition maintaining invariants
        self.bitmap.set(slot);
        self.slot_table[slot] = .{
            .allocated = .{
                .frame = frame,
                .pid = pid,
                .vaddr = vaddr,
            },
        };

        self.slots_used += 1;
        self.total_allocs += 1;

        if (self.slots_used > self.slots_peak) {
            self.slots_peak = self.slots_used;
        }

        self.next_search_hint = (slot + 1) % self.numSlots();

        _ = c.printf("[pagefile] Allocated slot %u for frame %zu (pid=%u, vaddr=0x%lx)\n", @as(c_uint, slot), @as(c_ulong, frame.toUsize()), @as(c_uint, pid), @as(c_ulong, vaddr));
    }

    /// Free previously allocated slot.
    fn freeSlot(self: *PagefileState, slot: u32) void {
        std.debug.assert(slot > 0 and slot < self.numSlots());
        std.debug.assert(self.bitmap.isSet(slot));
        std.debug.assert(self.slot_table[slot].isAllocated());

        // Atomic state transition maintaining invariants
        self.bitmap.clear(slot);
        self.slot_table[slot] = .free;

        self.slots_used -= 1;
        self.total_frees += 1;

        // Update search hint for allocation efficiency
        if (slot < self.next_search_hint) {
            self.next_search_hint = slot;
        }

        _ = c.printf("[pagefile] Freed slot %u (%zu/%u used)\n", @as(c_uint, slot), @as(c_ulong, self.slots_used), @as(c_uint, self.numSlots()));
    }

    /// Validate slot index and check allocation state.
    /// Returns true iff slot is in valid range and currently allocated.
    fn isValidSlot(self: *const PagefileState, slot: u32) bool {
        if (slot == INVALID_SLOT or slot >= self.numSlots()) {
            return false;
        }

        // Bitmap and slot_table must agree
        const bitmap_says_allocated = self.bitmap.isSet(slot);
        const table_says_allocated = self.slot_table[slot].isAllocated();
        std.debug.assert(bitmap_says_allocated == table_says_allocated);

        return bitmap_says_allocated;
    }
};

var global_state: ?PagefileState = null;

/// Get mutable reference to initialised state.
/// Returns null if pagefile not initialised.
fn getState() ?*PagefileState {
    if (global_state) |*state| {
        return state;
    }
    return null;
}

/// Get const reference to initialised state.
fn getStateConst() ?*const PagefileState {
    if (global_state) |*state| {
        return state;
    }
    return null;
}

/// Custom allocator that uses SOS's malloc/free for freestanding environment
const SosAllocator = struct {
    fn alloc(
        _: *anyopaque,
        len: usize,
        ptr_align: std.mem.Alignment,
        _: usize,
    ) ?[*]u8 {
        _ = ptr_align; // TODO: handle alignment if needed
        const ptr = sos.malloc(len);
        return @ptrCast(ptr);
    }

    fn resize(
        _: *anyopaque,
        _: []u8,
        _: std.mem.Alignment,
        _: usize,
        _: usize,
    ) bool {
        return false; // Don't support resize
    }

    fn free(
        _: *anyopaque,
        buf: []u8,
        _: std.mem.Alignment,
        _: usize,
    ) void {
        sos.free(buf.ptr);
    }

    fn remap(
        _: *anyopaque,
        _: []u8,
        _: std.mem.Alignment,
        _: usize,
        _: usize,
    ) ?[*]u8 {
        return null; // Don't support remap
    }
};

const sos_allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &.{
        .alloc = SosAllocator.alloc,
        .resize = SosAllocator.resize,
        .free = SosAllocator.free,
        .remap = SosAllocator.remap,
    },
};

/// Initialize pagefile subsystem.
///
/// Creates /pagefile file via NFS, allocates initial capacity (256 slots = 1 MiB).
/// Must be called after NFS initialisation but before user processes start.
///
/// Returns: 0 on success, -1 on failure (system continues without eviction)
pub export fn pagefile_init() callconv(.c) c_int {
    if (global_state != null) {
        _ = c.printf("[pagefile] WARNING: Pagefile already initialised\n");
        return 0;
    }

    _ = c.printf("[pagefile] Initializing pagefile subsystem (capacity: %u slots = %zu KiB)\n", @as(c_uint, INITIAL_SLOT_COUNT), @as(c_ulong, (INITIAL_SLOT_COUNT * PAGE_SIZE) / 1024));

    // Open or create swapfile via NFS
    const nfs_handle = nfs_open_sync_c("/pagefile", O_RDWR | O_CREAT) orelse {
        _ = c.printf("[pagefile] WARNING: Failed to create pagefile /pagefile via NFS\n");
        _ = c.printf("[pagefile] WARNING: Eviction disabled: system will operate without demand paging\n");
        return -1;
    };

    _ = c.printf("[pagefile] Pagefile /pagefile opened successfully\n");

    // Allocate pagefile state using SOS allocator
    global_state = PagefileState.init(sos_allocator, nfs_handle, INITIAL_SLOT_COUNT) catch {
        _ = c.printf("[pagefile] ERROR: Failed to allocate pagefile structures\n");
        _ = nfs_close_sync_c(nfs_handle);
        return -1;
    };

    const state = getStateConst().?;
    _ = c.printf("[pagefile] Pagefile initialised: %u slots, %zu bytes bitmap\n", @as(c_uint, state.numSlots()), @as(c_ulong, state.bitmap.words.len * @sizeOf(u64)));

    return 0;
}

/// Shutdown pagefile subsystem.
/// Closes NFS handle and releases resources.
pub export fn pagefile_shutdown() callconv(.c) void {
    const state = getState() orelse return;

    _ = c.printf("[pagefile] Shutting down pagefile subsystem\n");

    // Close NFS handle
    _ = nfs_close_sync_c(state.nfs_handle);

    // Free resources
    state.deinit();
    global_state = null;

    _ = c.printf("[pagefile] Pagefile shutdown complete\n");
}

/// Allocate pagefile slot for a frame.
/// Searches allocation bitmap for first free slot, marks as allocated.
pub export fn pagefile_alloc_slot(
    frame: usize,
    pid: u32,
    vaddr: usize,
) callconv(.c) u32 {
    const state = getState() orelse {
        _ = c.printf("[pagefile] ERROR: Pagefile not initialised\n");
        return INVALID_SLOT;
    };

    return state.allocSlot(frame, pid, vaddr) orelse INVALID_SLOT;
}

/// Free previously allocated pagefile slot.
/// Marks slot as free, clears metadata, decrements used count.
pub export fn pagefile_free_slot(slot: u32) callconv(.c) void {
    const state = getState() orelse {
        _ = c.printf("[pagefile] ERROR: Pagefile not initialised\n");
        return;
    };

    if (slot == INVALID_SLOT or slot >= state.numSlots()) {
        _ = c.printf("[pagefile] ERROR: Invalid slot index: %u (num_slots=%u)\n", @as(c_uint, slot), @as(c_uint, state.numSlots()));
        return;
    }

    if (!state.bitmap.isSet(slot)) {
        _ = c.printf("[pagefile] ERROR: Attempt to free already-free slot %u\n", @as(c_uint, slot));
        return;
    }

    state.freeSlot(slot);
}

/// Validate slot index and check allocation state.
/// Returns true if slot is valid [1, num_slots) and allocated, false otherwise
pub export fn pagefile_is_valid_slot(slot: u32) callconv(.c) bool {
    const state = getStateConst() orelse return false;
    return state.isValidSlot(slot);
}

/// Statistics snapshot for debugging and monitoring
pub const Stats = extern struct {
    slots_total: usize,
    slots_used: usize,
    slots_peak: usize,
    total_allocs: usize,
    total_frees: usize,
};

/// Retrieve pagefile statistics snapshot.
/// Populates stats structure with current allocation state and counters.
pub export fn pagefile_get_stats(out: *Stats) callconv(.c) void {
    const state = getStateConst() orelse {
        // Return zeroed stats if not initialised
        out.* = .{
            .slots_total = 0,
            .slots_used = 0,
            .slots_peak = 0,
            .total_allocs = 0,
            .total_frees = 0,
        };
        return;
    };

    out.* = .{
        .slots_total = state.numSlots(),
        .slots_used = state.slots_used,
        .slots_peak = state.slots_peak,
        .total_allocs = state.total_allocs,
        .total_frees = state.total_frees,
    };
}
