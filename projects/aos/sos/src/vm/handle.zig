/// Keep track of which VM client belongs to which ID
pub const VmHandle = struct {
    idx: usize,
    generation: u8,
    client: ?*sos.client_t,

    pub const Self = @This();
    /// Copy data from kernel buffer to user buffer
    pub fn copyToUserBuffer(self: *Self, user_vaddr: usize, src_data: [*]const u8, length: usize) bool {
        var offset: usize = 0;
        while (offset < length) {
            const cur_vaddr = user_vaddr + offset;
            const page_offset = cur_vaddr & (PAGE_SIZE_4K - 1);
            const remaining_in_page = PAGE_SIZE_4K - page_offset;
            const to_copy = @min(remaining_in_page, length - offset);

            const page_data = vm_get_user_page_data(self, cur_vaddr) orelse return false;
            std.mem.copyForwards(u8, page_data[page_offset..][0..to_copy], src_data[offset..][0..to_copy]);
            offset += to_copy;
        }
        return true;
    }

    /// Copy data from user buffer to kernel buffer
    pub fn copyFromUserBuffer(self: *Self, dst_data: [*]u8, user_vaddr: usize, length: usize) bool {
        var offset: usize = 0;
        while (offset < length) {
            const cur_vaddr = user_vaddr + offset;
            const page_offset = cur_vaddr & (PAGE_SIZE_4K - 1);
            const remaining_in_page = PAGE_SIZE_4K - page_offset;
            const to_copy = @min(remaining_in_page, length - offset);

            const page_data = vm_get_user_page_data(self, cur_vaddr) orelse return false;
            std.mem.copyForwards(u8, dst_data[offset..][0..to_copy], page_data[page_offset..][0..to_copy]);
            offset += to_copy;
        }
        return true;
    }

    pub fn validate(self: *Self) void {
        const idx = self.idx;
        if (idx >= MAX_CLIENTS) {
            @panic("VM handle index out of range");
        }
        if (!vm_handle_active[idx]) {
            @panic("VM handle inactive");
        }
        const cl = self.client orelse @panic("VM handle missing client reference");
        const stored_id: usize = @intCast(cl.*.id);
        if (stored_id != idx) {
            @panic("VM handle/client ID mismatch");
        }
        if (cl.*.gen != self.generation) {
            @panic("VM handle stale generation");
        }
    }

    pub fn getClient(self: *Self) *sos.client_t {
        validate(self);
        return self.client.?;
    }

    pub fn getState(self: *Self) *client.Client {
        validate(self);
        bootstrapVmStates();
        return &super.vm_states[self.idx];
    }

    pub fn ensureVmState(self: *Self) *client.Client {
        _ = c.printf("[vm_state] entered ensureVmState...\n");
        const idx = self.idx;
        const cl = self.getClient();
        const state = self.getState();
        if (!state.initialised) {
            _ = c.printf("[vm_state] initialise idx=%lu caller=0x%lx\n", @as(c_ulong, @intCast(idx)), @as(c_ulong, @intCast(@intFromPtr(cl))));
            state.init(idx, cl) catch {
                @panic("Client.init failed");
            };
        } else {
            _ = c.printf("[vm_state] reuse idx=%lu caller=0x%lx heap_break=0x%lx mapped_end=0x%lx stack_low=0x%lx active_mmaps=%lu mapped_pages=%lu\n", @as(c_ulong, @intCast(idx)), @as(c_ulong, @intCast(@intFromPtr(cl))), @as(c_ulong, @intCast(state.heap_break)), @as(c_ulong, @intCast(state.heap_mapped_end)), @as(c_ulong, @intCast(state.stack_low)), @as(c_ulong, @intCast(state.active_mmaps)), @as(c_ulong, @intCast(state.mapped_count)));
        }

        _ = c.printf("[vm_state] ensureVmState done!\n");
        return state;
    }

    pub fn brk(self: *Self, requested: usize) VmError!usize {
        _ = c.printf("[vm_brk] entered brk...\n");
        const state = self.ensureVmState();

        if (requested == 0) return state.heap_break;
        if (requested < HEAP_BASE or requested > HEAP_LIMIT) return VmError.Bounds;
        if (requested < state.heap_break) return VmError.Unsupported;

        state.heap_break = requested;

        _ = c.printf("[vm_brk] set break lazily to 0x%lx (mapping deferred)\n", @as(c_ulong, @intCast(state.heap_break)));

        return requested;
    }

    pub fn mmap(self: *Self, addr: usize, length: usize, prot: c_int, flags: c_int, fd: c_int, offset: usize) VmError!usize {
        _ = c.printf("[vm_mmap] entered mmap...\n");
        const caller_ptr: c_ulong = @intCast(@intFromPtr(self.getClient()));
        _ = c.printf("[vm_mmap] enter caller=0x%lx addr=0x%lx length=0x%lx prot=0x%x flags=0x%x fd=%d offset=0x%lx\n", caller_ptr, @as(c_ulong, @intCast(addr)), @as(c_ulong, @intCast(length)), prot, flags, fd, @as(c_ulong, @intCast(offset)));
        if (length == 0) {
            _ = c.printf("[vm_mmap] zero length invalid\n");
            return VmError.InvalidArgs;
        }
        if ((flags & sos.MAP_ANONYMOUS) == 0 or (flags & sos.MAP_PRIVATE) == 0) {
            _ = c.printf("[vm_mmap] unsupported flags combination flags=0x%x\n", flags);
            return VmError.Unsupported;
        }
        const unsupported_flags = flags & ~(sos.MAP_ANONYMOUS | sos.MAP_PRIVATE);
        if (unsupported_flags != 0) {
            _ = c.printf("[vm_mmap] extra unsupported flags=0x%x\n", unsupported_flags);
            return VmError.Unsupported;
        }
        if (addr != 0 or offset != 0 or fd != -1) {
            _ = c.printf("[vm_mmap] unsupported addr/offset/fd addr=0x%lx offset=0x%lx fd=%d\n", @as(c_ulong, @intCast(addr)), @as(c_ulong, @intCast(offset)), fd);
            return VmError.Unsupported;
        }

        const aligned = alignForward(length, PAGE_SIZE_4K);
        if (aligned == 0) {
            _ = c.printf("[vm_mmap] alignForward produced zero\n");
            return VmError.InvalidArgs;
        }
        _ = c.printf("[vm_mmap] aligned length=0x%lx\n", @as(c_ulong, @intCast(aligned)));

        const readable = (prot & sos.PROT_READ) != 0;
        const writable = (prot & sos.PROT_WRITE) != 0;
        const executable = (prot & sos.PROT_EXEC) != 0;
        _ = c.printf("[vm_mmap] permissions read=%d write=%d exec=%d\n", @as(c_int, if (readable) 1 else 0), @as(c_int, if (writable) 1 else 0), @as(c_int, if (executable) 1 else 0));

        const state = self.ensureVmState();
        if (state.mmap_next + aligned > MMAP_LIMIT) {
            _ = c.printf("[vm_mmap] exceeds limit mmap_next=0x%lx aligned=0x%lx limit=0x%lx\n", @as(c_ulong, @intCast(state.mmap_next)), @as(c_ulong, @intCast(aligned)), @as(c_ulong, @intCast(MMAP_LIMIT)));
            return VmError.Bounds;
        }

        const base = state.mmap_next;
        const tracker = state.leaseMmapRegion(base, prot) catch |err| {
            return err;
        };

        var cursor = base;
        const end_addr = base + aligned;
        var map_failed = false;
        _ = c.printf("[vm_mmap] base=0x%lx end=0x%lx\n", @as(c_ulong, @intCast(base)), @as(c_ulong, @intCast(end_addr)));
        while (cursor < end_addr) : (cursor += PAGE_SIZE_4K) {
            _ = c.printf("[vm_mmap] mapping cursor=0x%lx\n", @as(c_ulong, @intCast(cursor)));
            state.mapAnonymousPage(self, cursor, tracker) catch |err| {
                const err_code: c_int = vmErrorToErrno(err);
                _ = c.printf("[vm_mmap] mapAnonymousPage failed cursor=0x%lx errno=%d\n", @as(c_ulong, @intCast(cursor)), err_code);
                map_failed = true;
                break;
            };
            _ = c.printf("[vm_mmap] mapped cursor=0x%lx\n", @as(c_ulong, @intCast(cursor)));
        }

        if (map_failed) {
            state.releaseMmapRegion(tracker);
            return VmError.MapFailed;
        }

        state.mmap_next = end_addr;
        _ = c.printf("[vm_mmap] updated mmap_next=0x%lx returning base=0x%lx\n", @as(c_ulong, @intCast(state.mmap_next)), @as(c_ulong, @intCast(base)));
        return base;
    }

    /// Handle a VM fault
    pub fn handleFault(self: *Self, fault_addr: usize, want_write: bool, is_fetch: bool) VmError!void {
        _ = c.printf(
            "[vm_fault] entered handleFault...\n",
        );
        _ = want_write;
        _ = is_fetch;
        const state = self.ensureVmState();
        const base = pageBase(fault_addr);

        if (state.findPage(base) != null) {
            return;
        }

        const min_stack = state.stack_guard + PAGE_SIZE_4K;
        if (base >= min_stack and base < state.stack_top) {
            _ = c.printf("[vm_fault] growing stack at 0x%lx (low=0x%lx guard=0x%lx top=0x%lx)\n", @as(c_ulong, @intCast(base)), @as(c_ulong, @intCast(state.stack_low)), @as(c_ulong, @intCast(state.stack_guard)), @as(c_ulong, @intCast(state.stack_top)));
            try state.mapAnonymousPage(self, base, &state.stack_region);
            return;
        }

        if (base < state.stack_top and base >= state.stack_guard) {
            _ = c.printf("[vm_fault] stack guard hit addr=0x%lx guard=0x%lx\n", @as(c_ulong, @intCast(base)), @as(c_ulong, @intCast(state.stack_guard)));
            return VmError.Bounds;
        }

        if (base >= HEAP_BASE and base < state.heap_break) {
            try state.mapAnonymousPage(self, base, &state.heap_region);
            return;
        }

        if (state.findMmapRegion(base)) |tracker| {
            try state.mapAnonymousPage(self, base, tracker);
            return;
        }

        return VmError.Unsupported;
    }

    /// Register a stack mapping
    pub fn registerStackMapping(self: *Self, vaddr: usize, frame_ref: usize, cap_slot: sel4.seL4_CPtr) !void {
        _ = c.printf(
            "[vm_stack] entered registerStackMapping...\n",
        );
        const state = self.ensureVmState();
        _ = state.insertPage(vaddr, frame_ref, cap_slot, null, false, false) catch |err| {
            const errno = vmErrorToErrno(err);
            _ = c.printf("[vm_stack] failed to record mapping errno=%d vaddr=0x%lx\n", errno, @as(c_ulong, @intCast(vaddr)));
            return err;
        };
        state.mapped_count = state.addr_space.num_mapped();
        state.stack_region.updateAccess(true, true, false);
        state.stack_region.recordMapping(vaddr, PAGE_SIZE_4K);
        if (state.stack_region.start < state.stack_low) {
            state.stack_low = state.stack_region.start;
        }
    }

    /// Report initial stack bottom
    pub fn reportInitialStack(self: *Self, mapped_bottom: usize) void {
        _ = c.printf(
            "[vm_report_initial_stack] entered reportInitialStack...\n",
        );
        const state = self.ensureVmState();
        if (!state.stack_region.contains(mapped_bottom)) {
            state.stack_region.recordMapping(mapped_bottom, PAGE_SIZE_4K);
        }
        if (mapped_bottom < state.stack_low) {
            state.stack_low = mapped_bottom;
        }
    }

    /// Register an ELF segment mapping
    pub fn registerElfMapping(
        self: *Self,
        vaddr: usize,
        frame_ref: usize,
        cap_slot: sel4.seL4_CPtr,
        readable: bool,
        writable: bool,
        executable: bool,
    ) VmError!void {
        _ = c.printf(
            "[vm_elf] registering ELF mapping vaddr=0x%lx frame_ref=%lu cap_slot=%lu r=%d w=%d x=%d\n",
            @as(c_ulong, @intCast(vaddr)),
            @as(c_ulong, @intCast(frame_ref)),
            @as(c_ulong, @intCast(cap_slot)),
            @as(c_int, if (readable) 1 else 0),
            @as(c_int, if (writable) 1 else 0),
            @as(c_int, if (executable) 1 else 0),
        );

        const state = self.ensureVmState();

        // Track this mapping with ownership (VM will clean up on process exit)
        _ = state.insertPage(vaddr, frame_ref, cap_slot, &super.cspace, true, true) catch |err| {
            _ = c.printf("[vm_elf] failed to record ELF mapping vaddr=0x%lx\n", @as(c_ulong, @intCast(vaddr)));
            return err;
        };

        state.mapped_count = state.addr_space.num_mapped();
        state.addr_space.recordLeafMap(vaddr);

        _ = c.printf("[vm_elf] successfully registered ELF mapping vaddr=0x%lx mapped_count=%lu\n", @as(c_ulong, @intCast(vaddr)), @as(c_ulong, @intCast(state.mapped_count)));
    }

    /// Get direct access to a user page's frame data
    pub fn getUserPageData(self: *Self, user_vaddr: usize) ?[*]u8 {
        const state = self.ensureVmState();
        const page_base = pageBase(user_vaddr);

        const mapped_page = state.findPage(page_base) orelse {
            _ = c.printf("[vm_access] page not mapped at vaddr=0x%lx\n", @as(c_ulong, @intCast(user_vaddr)));
            return null;
        };

        if (mapped_page.frame_ref == 0) {
            _ = c.printf("[vm_access] invalid frame_ref at vaddr=0x%lx\n", @as(c_ulong, @intCast(user_vaddr)));
            return null;
        }

        const frame_data_ptr = sos.frame_data(mapped_page.frame_ref);
        return @as([*]u8, @ptrCast(frame_data_ptr));
    }

    /// Reset VM state for this handle
    pub fn reset(self: *Self) void {
        self.validate();
        bootstrapVmStates();
        const idx = self.idx;
        const cl = self.getClient();
        _ = c.printf("[vm_state] reset idx=%lu client=0x%lx\n", @as(c_ulong, @intCast(idx)), @as(c_ulong, @intCast(@intFromPtr(cl))));
        super.vm_states[idx].teardown();
        super.vm_states[idx].init(idx, cl) catch |err| {
            const name = @errorName(err);
            _ = c.printf("[vm_state] reset: Client.init failed: %.*s\n", @as(c_int, @intCast(name.len)), name.ptr);
            @panic("[vm_reset_state] Client.init failed");
        };
    }
};

pub var vm_handles: [MAX_CLIENTS]VmHandle = [_]VmHandle{VmHandle{
    .idx = 0,
    .generation = 0,
    .client = null,
}} ** MAX_CLIENTS;
pub var vm_handle_active: [MAX_CLIENTS]bool = [_]bool{false} ** MAX_CLIENTS;

const MAX_CLIENTS: usize = sos.MAX_CLIENTS;
pub const PAGE_SIZE_4K: usize = sos.PAGE_SIZE_4K;

const cimports = @import("cimports");
const sos = cimports.sos;
const c = cimports.c;
const sel4 = cimports.sel4;
pub const client = @import("client.zig");

const super = @import("mod.zig");
const vm_get_user_page_data = super.vm_get_user_page_data;
const bootstrapVmStates = super.bootstrapVmStates;
const VmError = super.VmError;
const HEAP_BASE = super.HEAP_BASE;
const HEAP_LIMIT = super.HEAP_LIMIT;
pub const MMAP_LIMIT = super.MMAP_BASE;
const alignForward = super.alignForward;
const pageBase = super.pageBase;
const vmErrorToErrno = super.vmErrorToErrno;

const std = @import("std");
