/// Keep track of which VM client belongs to which ID
pub const VmHandle = struct {
    idx: usize,
    generation: u8,
    client: ?*sos.client_t,

    pub const Access = enum { readOnly, writeOnly };
    pub const UserSlice = struct {
        ptr: [*]allowzero u8,
        len: usize,
    };

    pub const Self = @This();

    pub const SliceOp = struct {
        ctx: *anyopaque,
        func: *const fn (*anyopaque, [*]u8, usize) anyerror!usize,
    };

    /// Run the function `f` with the given user memory slice
    pub fn withUserSlice(
        self: *Self,
        /// Address of the user slice to include
        user_addr: usize,
        /// Size of the user slice
        len: usize,
        /// Permissions
        access: Access,
        /// A function to provide access to
        op: SliceOp,
    ) !usize {
        var done: usize = 0;
        // Retry loop to run `f` until everything is consumed
        while (done < len) {
            const slice = try self.mapUserSlice(user_addr + done, len - done, access);
            // we failed to map anything of substance, try again
            if (slice.len == 0) break;
            const moved = try op.func(op.ctx, @as([*]u8, @ptrCast(slice.ptr)), slice.len);
            // we failed to run anything with the slice and the function pointer, try again
            if (moved == 0) break;
            done += moved;
            // we consumed less than we have, not good
            if (moved < slice.len) break;
        }
        return done;
    }

    /// Map a userland slice into SOS' memory
    pub fn mapUserSlice(self: *Self, user_addr: usize, want_len: usize, access: Access) VmError!UserSlice {
        // Nothing to do if caller asked for zero bytes
        if (want_len == 0) return UserSlice{ .ptr = @ptrFromInt(0), .len = 0 };

        const state = self.ensureVmState();

        const page_base = Address.init(user_addr).pageBase(PAGE_SIZE_4K).raw();
        const page_off = user_addr - page_base;

        // Ensure the page exists, or fault
        var rec = state.findPage(page_base);
        if (rec == null) {
            // Is this legal?
            try self.handleFault(page_base, access == .writeOnly, false);
            rec = state.findPage(page_base);
            if (rec == null) return VmError.Bounds;
        }
        const page = rec.?;

        if (page.frame_ref == 0) return VmError.MapFailed;

        const base: [*]u8 = @as([*]u8, @ptrCast(sos.frame_data(page.frame_ref)));

        // Clip to the end of this page
        const avail = PAGE_SIZE_4K - page_off;
        const n = if (want_len < avail) want_len else avail;

        return UserSlice{
            .ptr = base + page_off,
            .len = n,
        };
    }

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

    pub fn copyCStringFromClient(self: *Self, client_va: usize, dest: []u8) VmError!usize {
        if (dest.len == 0) return 0;
        const state = self.ensureVmState();

        var copied: usize = 0;
        var first_zero: ?usize = null;

        while (copied < dest.len) {
            const remaining = dest.len - copied;
            const slice = try self.mapUserSlice(client_va + copied, remaining, .readOnly);
            if (slice.len == 0) break;

            const chunk = @min(slice.len, remaining);
            const src_ptr: [*]const u8 = @as([*]const u8, @ptrCast(slice.ptr));
            const src_slice = src_ptr[0..chunk];
            std.mem.copyForwards(u8, dest[copied .. copied + chunk], src_slice);
            markPageAccess(state, client_va + copied, false);

            if (first_zero == null) {
                if (std.mem.indexOfScalar(u8, src_slice, 0)) |idx| {
                    first_zero = copied + idx;
                }
            }

            copied += chunk;
        }

        return first_zero orelse copied;
    }

    pub fn copyFromClient(self: *Self, dest: []u8, client_va: usize) VmError!void {
        const state = self.ensureVmState();
        var copied: usize = 0;
        while (copied < dest.len) {
            const remaining = dest.len - copied;
            const slice = try self.mapUserSlice(client_va + copied, remaining, .readOnly);
            if (slice.len == 0) break;

            const chunk = @min(slice.len, remaining);
            const src_ptr: [*]const u8 = @as([*]const u8, @ptrCast(slice.ptr));
            std.mem.copyForwards(u8, dest[copied .. copied + chunk], src_ptr[0..chunk]);
            markPageAccess(state, client_va + copied, false);
            copied += chunk;
        }

        if (copied != dest.len) {
            return VmError.Bounds;
        }
    }

    pub fn copyToClient(self: *Self, src: []const u8, client_va: usize) VmError!void {
        const state = self.ensureVmState();
        var copied: usize = 0;
        while (copied < src.len) {
            const remaining = src.len - copied;
            const slice = try self.mapUserSlice(client_va + copied, remaining, .writeOnly);
            if (slice.len == 0) return VmError.Bounds;

            const chunk = @min(slice.len, remaining);
            const dst_ptr: [*]u8 = @as([*]u8, @ptrCast(slice.ptr));
            std.mem.copyForwards(u8, dst_ptr[0..chunk], src[copied .. copied + chunk]);
            markPageAccess(state, client_va + copied, true);
            copied += chunk;
        }
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

    fn markPageAccess(state: *client.Client, vaddr: usize, write: bool) void {
        const base = Address.init(vaddr).pageBase(PAGE_SIZE_4K).raw();
        if (state.findPage(base)) |page_entry| {
            page_entry.referenced = true;
            if (write) {
                page_entry.dirty = true;
            }
        }
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

    pub fn mmap(self: *Self, client_ctx: *clients.Client, addr: usize, length: usize, prot: c_int, flags: c_int, fd: c_int, offset: usize) VmError!usize {
        _ = c.printf("[vm_mmap] entered mmap...\n");
        const caller_ptr: c_ulong = @intCast(@intFromPtr(self.getClient()));
        _ = c.printf("[vm_mmap] enter caller=0x%lx addr=0x%lx length=0x%lx prot=0x%x flags=0x%x fd=%d offset=0x%lx\n", caller_ptr, @as(c_ulong, @intCast(addr)), @as(c_ulong, @intCast(length)), prot, flags, fd, @as(c_ulong, @intCast(offset)));
        if (length == 0) {
            _ = c.printf("[vm_mmap] zero length invalid\n");
            return VmError.InvalidArgs;
        }
        if ((flags & sos.MAP_PRIVATE) == 0) {
            _ = c.printf("[vm_mmap] MAP_PRIVATE required flags=0x%x\n", flags);
            return VmError.Unsupported;
        }
        const want_anonymous = (flags & sos.MAP_ANONYMOUS) != 0;
        const unsupported_flags = flags & ~(sos.MAP_ANONYMOUS | sos.MAP_PRIVATE);
        if (unsupported_flags != 0) {
            _ = c.printf("[vm_mmap] extra unsupported flags=0x%x\n", unsupported_flags);
            return VmError.Unsupported;
        }
        if (addr != 0) {
            _ = c.printf("[vm_mmap] hint addr unsupported addr=0x%lx\n", @as(c_ulong, @intCast(addr)));
            return VmError.Unsupported;
        }
        if (want_anonymous) {
            if (fd != -1 or offset != 0) {
                _ = c.printf("[vm_mmap] anonymous mapping must use fd=-1 offset=0\n");
                return VmError.Unsupported;
            }
        } else {
            if (fd < 0) {
                _ = c.printf("[vm_mmap] file-backed mmap missing fd\n");
                return VmError.Unsupported;
            }
            if ((offset & (PAGE_SIZE_4K - 1)) != 0) {
                _ = c.printf("[vm_mmap] file-backed offset must be page-aligned offset=0x%lx\n", @as(c_ulong, @intCast(offset)));
                return VmError.InvalidArgs;
            }
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
        var retained_handle: ?*anyopaque = null;
        if (!want_anonymous) {
            const retained = client_ctx.retainFileHandleOpaque(@intCast(fd)) catch {
                _ = c.printf("[vm_mmap] retainFileHandleOpaque failed fd=%d\n", fd);
                return VmError.InvalidArgs;
            };
            retained_handle = retained;
        }
        errdefer if (retained_handle) |ref| {
            client_ctx.releaseFileHandleOpaque(ref);
        };

        const backing_info: region.Backing = if (want_anonymous)
            .Anonymous
        else
            .{ .File = .{
                .fd = fd,
                .offset = offset,
                .length = aligned,
                .handle_ref = retained_handle,
                .handle_owner = if (retained_handle != null) client_ctx.ioState() else null,
            } };

        const tracker = state.leaseMmapRegion(base, prot, backing_info) catch |err| {
            return err;
        };

        const end_addr = base + aligned;
        if (want_anonymous) {
            var cursor = base;
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
        } else {
            tracker.start = base;
            tracker.end = base + aligned;
            tracker.mapped = true;
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
        const base_addr = Address.init(fault_addr).pageBase(PAGE_SIZE_4K);
        const base = base_addr.raw();

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
            switch (tracker.backing) {
                .Anonymous => {
                    try state.mapAnonymousPage(self, base, tracker);
                    return;
                },
                .File => {
                    _ = c.printf("[vm_fault] file-backed page needs pager base=0x%lx\n", @as(c_ulong, @intCast(base)));
                    return VmError.Unsupported;
                },
            }
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

    pub fn mapOwnedFrame(
        self: *Self,
        vaddr: usize,
        frame_ref: usize,
        cap_slot: sel4.seL4_CPtr,
        readable: bool,
        writable: bool,
        executable: bool,
        owns_frame: bool,
        owns_cap: bool,
    ) VmError!void {
        const state = self.ensureVmState();
        try state.mapOwnedFrame(vaddr, frame_ref, cap_slot, readable, writable, executable, owns_frame, owns_cap);
    }

    /// Get direct access to a user page's frame data
    pub fn getUserPageData(self: *Self, user_vaddr: usize) ?[*]u8 {
        const state = self.ensureVmState();
        const page_base = Address.init(user_vaddr).pageBase(PAGE_SIZE_4K);

        const mapped_page = state.findPage(page_base.raw()) orelse {
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
const clients = @import("../client.zig");
const region = @import("region.zig");
const super = @import("mod.zig");
const Address = super.Address;
const vm_get_user_page_data = super.vm_get_user_page_data;
const bootstrapVmStates = super.bootstrapVmStates;
const VmError = super.VmError;
const HEAP_BASE = super.HEAP_BASE;
const HEAP_LIMIT = super.HEAP_LIMIT;
pub const MMAP_LIMIT = super.MMAP_BASE;
const alignForward = super.alignForward;
const vmStateIndex = super.vmStateIndex;
const vmErrorToErrno = super.vmErrorToErrno;

const std = @import("std");
