const std = @import("std");
const c = @import("cimports").c;
const sos = @import("cimports").sos;

const file = @import("file.zig");
const KernelFileHandle = file.KernelFileHandle;

// Sentinel value for invalid/unallocated slots
pub const INVALID_SLOT: u32 = 0;

// Page size from seL4 configuration
const PAGE_SIZE: usize = @as(usize, 1) << 12; // 4 KiB

// Initial capacity, 256 slots (1 MiB)
const INITIAL_SLOT_COUNT: u32 = 256;

// Maximum capacity, 8192 slots (32 MiB)
const MAX_SLOT_COUNT: u32 = 8192;

// File mode for pagefile creation
const DEFAULT_CREATE_MODE: c_int = 0o600; // rw-------

// Import NFS async operations
extern fn get_nfs_context() ?*anyopaque;
extern fn nfs_open2_async(
    nfs_ctx: ?*anyopaque,
    path: [*:0]const u8,
    flags: c_int,
    mode: c_int,
    cb: *const fn (c_int, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void,
    private_data: ?*anyopaque,
) c_int;
extern fn nfs_get_error(nfs_ctx: ?*anyopaque) [*:0]const u8;

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

/// Slot metadata encoding slot lifecycle.
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
    file_handle: KernelFileHandle,
    slot_table: []SlotState,
    bitmap: Bitmap,
    next_search_hint: u32,
    slots_used: usize,
    slots_peak: usize,
    total_allocs: usize,
    total_frees: usize,
    allocator: std.mem.Allocator,

    /// Initialise pagefile with given capacity
    fn init(allocator: std.mem.Allocator, file_handle: KernelFileHandle, num_slots: u32) !PagefileState {
        const slot_table = try allocator.alloc(SlotState, num_slots);
        errdefer allocator.free(slot_table);

        const bitmap = try Bitmap.init(allocator, num_slots);
        errdefer bitmap.deinit(allocator);

        // Initialise all slots as free
        for (slot_table) |*slot| {
            slot.* = .free;
        }

        return .{
            .file_handle = file_handle,
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

    /// Attempt to grow slot_table and bitmap up to MAX_SLOT_COUNT.
    /// Returns true on growth, false if already at cap. Errors on OOM.
    fn grow(self: *PagefileState) !bool {
        const current: u32 = self.numSlots();
        if (current >= MAX_SLOT_COUNT) {
            return false;
        }
        const target: u32 = blk: {
            const doubled: u32 = current * 2;
            break :blk if (doubled > MAX_SLOT_COUNT) MAX_SLOT_COUNT else doubled;
        };

        const new_slot_table = try self.allocator.alloc(SlotState, target);
        errdefer self.allocator.free(new_slot_table);
        // Copy existing slot metadata, initialise rest to free
        std.mem.copyForwards(SlotState, new_slot_table[0..current], self.slot_table[0..current]);
        for (new_slot_table[current..]) |*slot| {
            slot.* = .free;
        }

        const new_bitmap = try Bitmap.init(self.allocator, target);
        errdefer new_bitmap.deinit(self.allocator);
        const copy_words = @min(self.bitmap.words.len, new_bitmap.words.len);
        std.mem.copyForwards(u64, new_bitmap.words[0..copy_words], self.bitmap.words[0..copy_words]);

        // Swap in new structures
        self.allocator.free(self.slot_table);
        self.slot_table = new_slot_table;
        self.bitmap.deinit(self.allocator);
        self.bitmap = new_bitmap;

        // Reset search hint to first real slot to spread load.
        self.next_search_hint = 1;

        _ = c.printf("[pagefile] Grew capacity from %u to %u slots\n", @as(c_uint, current), @as(c_uint, target));
        return true;
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
        const tryFind = struct {
            fn find(pf: *PagefileState) ?u32 {
                const n: u32 = pf.numSlots();
                var slot = pf.next_search_hint;
                var visited: u32 = 0;
                while (visited < n) : (visited += 1) {
                    if (slot == 0) {
                        slot = 1;
                    }
                    if (!pf.bitmap.isSet(slot)) {
                        return slot;
                    }
                    slot = (slot + 1) % n;
                }
                return null;
            }
        }.find;

        if (tryFind(self)) |slot| {
            self.transitionToAllocated(slot, frame, pid, vaddr);
            return slot;
        }

        // Attempt to grow and retry once.
        const grew = self.grow() catch {
            _ = c.printf("[pagefile] ERROR: grow OOM at %u slots\n", @as(c_uint, self.numSlots()));
            return null;
        };
        if (grew) {
            if (tryFind(self)) |slot2| {
                self.transitionToAllocated(slot2, frame, pid, vaddr);
                return slot2;
            }
        }

        _ = c.printf("[pagefile] WARNING: Pagefile exhausted: %zu/%u slots used\n", @as(c_ulong, self.slots_used), @as(c_uint, self.numSlots()));
        return null;
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
var init_pending: bool = false;
var init_failed: bool = false;

/// Get mutable reference to initialised state.
///
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

/// Initialise pagefile subsystem asynchronously.
///
/// This callback is invoked by the NFS event loop when the async open operation
/// completes. It allocates slot structures and sets global_state on success,
/// or marks init_failed on failure.
///
/// This callback executes in the context of the IRQ handler (via nfsServicePoll
/// called from network_irq), so it must not block or perform long operations.
fn pagefileOpenCallback(
    err: c_int,
    nfs_ctx: ?*anyopaque,
    data: ?*anyopaque,
    private_data: ?*anyopaque,
) callconv(.c) void {
    _ = nfs_ctx;
    _ = private_data;

    _ = c.printf("[pagefile] Async open callback invoked: err=%d\n", err);

    // Mark init as no longer pending
    init_pending = false;

    if (err < 0) {
        // Get detailed error message from NFS library
        const nfs_ctx_local = get_nfs_context();
        if (nfs_ctx_local) |ctx| {
            const error_str = nfs_get_error(ctx);
            _ = c.printf("[pagefile] NFS error: %s (errno=%d)\n", error_str, err);
        }

        // Provide helpful message for common error (file doesn't exist)
        if (err == -2) { // ENOENT
            _ = c.printf("[pagefile] HINT: File 'pagefile' must be pre-created on NFS server\n");
            _ = c.printf("[pagefile] HINT: Run on server: touch /export/odroid-84-root/.pagefile\n");
        }

        _ = c.printf("[pagefile] WARNING: Pagefile open failed (err=%d); eviction disabled\n", err);
        init_failed = true;
        return;
    }

    if (data == null) {
        _ = c.printf("[pagefile] ERROR: Open succeeded but file handle is null\n");
        init_failed = true;
        return;
    }

    const nfs_fh = data.?;
    _ = c.printf("[pagefile] Pagefile opened successfully (fh=%p)\n", nfs_fh);

    // Wrap NFS handle in KernelFileHandle
    const fh = KernelFileHandle{ .nfs_fh = nfs_fh };

    // Allocate pagefile state using SOS allocator
    global_state = PagefileState.init(sos_allocator, fh, INITIAL_SLOT_COUNT) catch {
        _ = c.printf("[pagefile] ERROR: Failed to allocate pagefile structures\n");
        // Close the file handle since we can't use it
        fh.close();
        init_failed = true;
        return;
    };

    const state = getStateConst().?;
    _ = c.printf("[pagefile] Pagefile initialised: %u slots, %zu bytes bitmap\n", @as(c_uint, state.numSlots()), @as(c_ulong, state.bitmap.words.len * @sizeOf(u64)));
}

/// Initialise pagefile subsystem asynchronously.
///
/// This function must be called during SOS bootstrap, after NFS initialisation
/// but before the syscall loop begins.
///
/// WARN: This function MUST NOT use synchronous NFS operations, as they
/// will deadlock when called before the syscall loop begins processing IRQs.
pub export fn pagefile_init() callconv(.c) void {
    if (global_state != null or init_pending) {
        _ = c.printf("[pagefile] WARNING: Pagefile already initialised or initialisation in progress\n");
        return;
    }

    _ = c.printf("[pagefile] Initialising pagefile subsystem (async, capacity: %u slots = %zu KiB)\n", @as(c_uint, INITIAL_SLOT_COUNT), @as(c_ulong, (INITIAL_SLOT_COUNT * PAGE_SIZE) / 1024));

    // Get NFS context
    const nfs_ctx = get_nfs_context();
    if (nfs_ctx == null) {
        _ = c.printf("[pagefile] ERROR: NFS context not available\n");
        init_failed = true;
        return;
    }

    // Mark initialisation as pending (async operation in progress)
    init_pending = true;

    // Queue async NFS open operation
    const path: [*:0]const u8 = "pagefile";
    const flags: c_int = c.O_CREAT | c.O_RDWR;
    const mode: c_int = DEFAULT_CREATE_MODE;

    _ = c.printf("[pagefile] Attempting to open NFS file: path='%s' flags=0x%x mode=0%o\n", path, @as(c_uint, @bitCast(flags)), @as(c_uint, @bitCast(mode)));

    const rc = nfs_open2_async(nfs_ctx, path, flags, mode, pagefileOpenCallback, null);
    if (rc < 0) {
        // Get detailed error if queuing failed
        const error_str = nfs_get_error(nfs_ctx);
        _ = c.printf("[pagefile] ERROR: Failed to queue async pagefile open (rc=%d): %s\n", rc, error_str);
        init_pending = false;
        init_failed = true;
        return;
    }

    _ = c.printf("[pagefile] Async open queued; awaiting callback via IRQ processing\n");
}

/// Shutdown pagefile subsystem.
/// Closes NFS handle and releases resources.
pub export fn pagefile_shutdown() callconv(.c) void {
    const state = getState() orelse return;

    _ = c.printf("[pagefile] Shutting down pagefile subsystem\n");

    // Close kernel file handle
    state.file_handle.close();

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

/// Check if pagefile initialisation is complete and ready for use.
///
/// Returns: true if pagefile is fully initialised and operational, false otherwise
///
/// This function allows callers to distinguish between:
/// - Not yet initialised (global_state == null && !init_pending)
/// - Initialisation in progress (init_pending == true)
/// - Initialisation complete and ready (global_state != null && !init_pending)
/// - Initialisation failed (init_failed == true)
pub export fn pagefile_is_ready() callconv(.c) bool {
    return global_state != null and !init_pending;
}

/// Check if pagefile initialisation failed.
///
/// Returns: true if initialisation was attempted but failed, false otherwise
///
/// NOTE: This should be checked after pagefile_is_ready() returns true to
/// determine if the pagefile is actually available or if initialisation
/// completed with failure.
pub export fn pagefile_init_failed() callconv(.c) bool {
    return init_failed;
}

/// Write one page to a pagefile slot asynchronously.
/// Returns 0 on success, -errno on failure.
pub export fn pagefile_write_slot(slot: u32, buf: [*]const u8, len: usize) callconv(.c) c_int {
    const state = getStateConst() orelse return -sos.ENODEV;

    if (len != PAGE_SIZE) {
        return -sos.EINVAL;
    }

    if (!state.isValidSlot(slot)) {
        return -sos.EINVAL;
    }

    const offset: usize = @as(usize, slot) * PAGE_SIZE;

    // Use positioned write (pwrite) to avoid file offset races across concurrent workers.
    // Each worker specifies its target offset explicitly, eliminating shared state.
    const bytes_written = state.file_handle.pwrite(buf[0..PAGE_SIZE], offset) catch |err| {
        // Preserve errno semantics so callers can distinguish ENOMEM from I/O faults.
        return switch (err) {
            error.OutOfMemory => -sos.ENOMEM,
            error.PoolExhausted => -sos.EAGAIN,
            error.NoNFSContext => -sos.ENODEV,
            error.NFSOperationFailed, error.OperationFailed => -sos.EIO,
        };
    };

    if (bytes_written != PAGE_SIZE) {
        return -sos.EIO;
    }

    return 0;
}

/// Read one page from a pagefile slot asynchronously.
/// Returns 0 on success, -errno on failure.
pub export fn pagefile_read_slot(slot: u32, buf: [*]u8, len: usize) callconv(.c) c_int {
    const state = getStateConst() orelse return -sos.ENODEV;

    if (len != PAGE_SIZE) {
        return -sos.EINVAL;
    }

    if (!state.isValidSlot(slot)) {
        return -sos.EINVAL;
    }

    const offset: usize = @as(usize, slot) * PAGE_SIZE;

    // Use positioned read (pread) to avoid file offset races across concurrent workers.
    const bytes_read = state.file_handle.pread(buf[0..PAGE_SIZE], offset) catch {
        return -sos.EIO;
    };

    if (bytes_read != PAGE_SIZE) {
        // Short read should still be considered fatal for swap contents.
        return -sos.EIO;
    }

    return 0;
}
