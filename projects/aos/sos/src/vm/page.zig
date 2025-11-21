pub const WaitQueue = struct {
    pub const Node = struct {
        cont: ?*anyopaque = null,
        next: ?*Node = null,

        pub fn clear(self: *Node) void {
            self.cont = null;
            self.next = null;
        }
    };

    head: ?*Node = null,
    tail: ?*Node = null,
    count: u16 = 0,

    pub fn reset(self: *WaitQueue) void {
        self.head = null;
        self.tail = null;
        self.count = 0;
    }

    pub fn isEmpty(self: *const WaitQueue) bool {
        return self.count == 0;
    }

    pub fn contains(self: *const WaitQueue, target: *anyopaque) bool {
        var cursor = self.head;
        while (cursor) |node| : (cursor = node.next) {
            if (node.cont == target) {
                return true;
            }
        }
        return false;
    }

    pub fn enqueue(self: *WaitQueue, node: *Node, cont: *anyopaque) bool {
        if (node.cont != null or node.next != null) {
            _ = c.printf("[wait_queue] node already enqueued %p\n", node);
            return false;
        }
        if (self.contains(cont)) {
            _ = c.printf("[wait_queue] duplicate continuation %p\n", cont);
            return false;
        }

        node.cont = cont;
        node.next = null;

        if (self.tail) |tail_node| {
            tail_node.next = node;
        } else {
            self.head = node;
        }
        self.tail = node;

        if (self.count < std.math.maxInt(u16)) {
            self.count += 1;
        } else {
            _ = c.printf("[wait_queue] queue length saturated\n");
        }

        return true;
    }

    pub fn detachAll(self: *WaitQueue) ?*Node {
        const head = self.head;
        self.head = null;
        self.tail = null;
        self.count = 0;
        return head;
    }

    pub fn remove(self: *WaitQueue, cont: *anyopaque) ?*Node {
        var prev: ?*Node = null;
        var cursor = self.head;
        while (cursor) |node| {
            const next = node.next;
            if (node.cont == cont) {
                if (prev) |p| {
                    p.next = next;
                } else {
                    self.head = next;
                }
                if (self.tail == node) {
                    self.tail = prev;
                }
                if (self.count > 0) {
                    self.count -= 1;
                }
                node.clear();
                return node;
            }
            prev = node;
            cursor = next;
        }
        return null;
    }
};

/// Page state machine for tracking lifecycle of mapped pages.
pub const PageState = enum(u8) {
    FREE = 0, // No frame allocated, no data
    RESIDENT = 1, // Frame allocated, mapped in hardware
    PAGEOUT_PENDING = 2, // Async write to pagefile in progress
    SWAPPED = 3, // Frame deallocated, data in pagefile
    PAGEIN_PENDING = 4, // Async read from pagefile in progress
};

/// Bookkeeping for a page mapped into a client address space.
pub const MappedPage = struct {
    frame_ref: usize,
    cap_slot: sel4.seL4_CPtr,
    cap_owner: ?*sos.cspace_t,
    owns_frame: bool,
    owns_cap: bool,
    region: ?*region.Region = null,

    /// State machine
    state: PageState = .FREE,

    /// Dirty tracking
    dirty: bool = false,

    /// Reference tracking
    referenced: bool = false,

    // Pagefile
    pagefile_slot: i32 = -1,

    // Synchronisation
    waiters: WaitQueue = .{},

    pub const Self = @This();

    pub fn release(self: *Self) void {
        if (self.cap_owner) |owner| {
            if (self.cap_slot != sel4.seL4_CapNull and self.owns_cap) {
                const unmap_err = sel4.seL4_ARM_Page_Unmap(self.cap_slot);
                if (unmap_err != sel4.seL4_NoError) {
                    const unmap_err_i32: c_int = @intCast(unmap_err);
                    _ = c.printf("[vm_release] Page_Unmap err=%d slot=%lu\n", unmap_err_i32, @as(c_ulong, @intCast(self.cap_slot)));
                }
                const delete_err = sos.cspace_delete(owner, self.cap_slot);
                if (delete_err != sel4.seL4_NoError) {
                    const delete_err_i32: c_int = @intCast(delete_err);
                    _ = c.printf("[vm_release] cspace_delete err=%d slot=%lu\n", delete_err_i32, @as(c_ulong, @intCast(self.cap_slot)));
                }
                sos.cspace_free_slot(owner, self.cap_slot);
            }
        }
        if (self.owns_frame and self.frame_ref != 0) {
            sos.free_frame(self.frame_ref);
        }
        self.region = null;
        self.state = .FREE;
        self.dirty = false;
        self.referenced = false;
        self.pagefile_slot = -1;
        self.waiters.reset();
    }

    /// Transition page state with validation.
    pub fn transitionState(self: *Self, new_state: PageState) void {
        if (comptime std.debug.runtime_safety) {
            if (!isValidTransition(self.state, new_state)) {
                _ = c.printf(
                    "[page_state] PANIC: Invalid state transition: %u -> %u (frame=%zu)\n",
                    @intFromEnum(self.state),
                    @intFromEnum(new_state),
                    self.frame_ref,
                );
                @panic("Invalid page state transition");
            }
        }
        self.state = new_state;
    }

    /// Validate state transition
    fn isValidTransition(old: PageState, new: PageState) bool {
        return switch (old) {
            .FREE => new == .RESIDENT,
            .RESIDENT => new == .PAGEOUT_PENDING or new == .FREE,
            .PAGEOUT_PENDING => new == .SWAPPED or new == .RESIDENT or new == .FREE,
            .SWAPPED => new == .PAGEIN_PENDING or new == .FREE,
            .PAGEIN_PENDING => new == .RESIDENT or new == .FREE,
        };
    }
};

/// Bookkeeping for kernel metadata pages backing VM state.
pub const MetadataPage = struct {
    frame_ref: usize,
    cap_slot: sel4.seL4_CPtr,
    vaddr: usize,
};

const cimports = @import("cimports");
const c = cimports.c;
const sel4 = cimports.sel4;
const sos = cimports.sos;
const region = @import("region.zig");
const std = @import("std");
