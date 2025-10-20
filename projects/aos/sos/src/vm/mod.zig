//! This module is the entrypoint to the virtual memory management system.

extern var cspace: sos.cspace_t;

pub const VmHandle = struct {
    idx: usize,
    generation: u8,
    client: ?*sos.client_t,

    pub const Self = @This();

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
        return &vm_states[self.idx];
    }

    pub fn ensureVmState(self: *Self) *client.Client {
        const idx = self.idx;
        const cl = self.getClient();
        const state = self.getState();
        if (!state.initialised) {
            _ = c.printf("[vm_state] initialise idx=%lu caller=0x%lx\n", @as(c_ulong, @intCast(idx)), @as(c_ulong, @intCast(@intFromPtr(cl))));
            state.init(idx);
        } else {
            _ = c.printf("[vm_state] reuse idx=%lu caller=0x%lx heap_break=0x%lx mapped_end=0x%lx stack_low=0x%lx active_mmaps=%lu mapped_pages=%lu\n", @as(c_ulong, @intCast(idx)), @as(c_ulong, @intCast(@intFromPtr(cl))), @as(c_ulong, @intCast(state.heap_break)), @as(c_ulong, @intCast(state.heap_mapped_end)), @as(c_ulong, @intCast(state.stack_low)), @as(c_ulong, @intCast(state.active_mmaps)), @as(c_ulong, @intCast(state.mapped_count)));
        }
        return state;
    }
};

var vm_handles: [MAX_CLIENTS]VmHandle = [_]VmHandle{VmHandle{
    .idx = 0,
    .generation = 0,
    .client = null,
}} ** MAX_CLIENTS;
var vm_handle_active: [MAX_CLIENTS]bool = [_]bool{false} ** MAX_CLIENTS;

const MetadataPage = page.MetadataPage;

pub const VmError = error{
    ClientContext,
    Bounds,
    Unsupported,
    OutOfFrames,
    OutOfSlots,
    MapFailed,
    Capacity,
    InvalidArgs,
};

const MAX_CLIENTS: usize = sos.MAX_CLIENTS;
pub const PAGE_SIZE_4K: usize = sos.PAGE_SIZE_4K;
pub const HEAP_BASE: usize = 0x40000000;
pub const MMAP_BASE: usize = 0x80000000;
pub const HEAP_LIMIT: usize = MMAP_BASE - PAGE_SIZE_4K;
pub const STACK_TOP_RAW: usize = sos.PROCESS_STACK_TOP;
pub const STACK_TOP: usize = STACK_TOP_RAW & ~(PAGE_SIZE_4K - 1);
pub const STACK_MAX_BYTES: usize = 64 * 1024 * 1024;
pub const STACK_GUARD_BASE: usize = STACK_TOP - STACK_MAX_BYTES;
pub const MMAP_LIMIT: usize = STACK_GUARD_BASE - PAGE_SIZE_4K;
pub const MAX_MAPPED_PAGES: usize = 4096;
pub const MAX_MMAP_REGIONS: usize = 64;

comptime {
    if (MAX_MAPPED_PAGES == 0 or (MAX_MAPPED_PAGES & (MAX_MAPPED_PAGES - 1)) != 0) {
        @compileError("MAX_MAPPED_PAGES must be a non-zero power of two");
    }
    if (STACK_MAX_BYTES <= PAGE_SIZE_4K) {
        @compileError("Stack size must exceed one page");
    }
    if (STACK_GUARD_BASE <= MMAP_BASE) {
        @compileError("Stack guard overlaps heap or mmap regions");
    }
    if (MAX_MMAP_REGIONS == 0) {
        @compileError("MAX_MMAP_REGIONS must be non-zero");
    }
}

var vm_states: [MAX_CLIENTS]client.Client = undefined;
var vm_states_initialised = false;

fn bootstrapVmStates() void {
    if (vm_states_initialised) {
        return;
    }
    for (&vm_states) |*state| {
        state.* = client.Client{};
    }
    vm_states_initialised = true;
}

pub fn vmErrorToErrno(err: VmError) c_int {
    return switch (err) {
        VmError.ClientContext => sos.EINVAL,
        VmError.Bounds => sos.ENOMEM,
        VmError.Unsupported => sos.ENOSYS,
        VmError.OutOfFrames => sos.ENOMEM,
        VmError.OutOfSlots => sos.ENOMEM,
        VmError.MapFailed => sos.EIO,
        VmError.Capacity => sos.ENOMEM,
        VmError.InvalidArgs => sos.EINVAL,
    };
}

pub fn brkImpl(handle: *VmHandle, requested: usize) VmError!usize {
    const state = handle.ensureVmState();
    const caller_ptr: c_ulong = @intCast(@intFromPtr(handle.getClient()));
    _ = c.printf("[vm_brk] enter caller=0x%lx requested=0x%lx heap_break=0x%lx mapped_end=0x%lx limit=0x%lx\n", caller_ptr, @as(c_ulong, @intCast(requested)), @as(c_ulong, @intCast(state.heap_break)), @as(c_ulong, @intCast(state.heap_mapped_end)), @as(c_ulong, @intCast(HEAP_LIMIT)));

    if (requested == 0) {
        _ = c.printf("[vm_brk] query current break=0x%lx\n", @as(c_ulong, @intCast(state.heap_break)));
        return state.heap_break;
    }
    if (requested < HEAP_BASE or requested > HEAP_LIMIT) {
        _ = c.printf("[vm_brk] bounds violation requested=0x%lx base=0x%lx limit=0x%lx\n", @as(c_ulong, @intCast(requested)), @as(c_ulong, @intCast(HEAP_BASE)), @as(c_ulong, @intCast(HEAP_LIMIT)));
        return VmError.Bounds;
    }
    if (requested < state.heap_break) {
        _ = c.printf("[vm_brk] shrink unsupported requested=0x%lx current=0x%lx\n", @as(c_ulong, @intCast(requested)), @as(c_ulong, @intCast(state.heap_break)));
        return VmError.Unsupported;
    }

    const target_map_end = alignForward(requested, PAGE_SIZE_4K);
    if (target_map_end > HEAP_LIMIT) {
        _ = c.printf("[vm_brk] rounded target 0x%lx beyond limit 0x%lx\n", @as(c_ulong, @intCast(target_map_end)), @as(c_ulong, @intCast(HEAP_LIMIT)));
        return VmError.Bounds;
    }
    _ = c.printf("[vm_brk] aligned target_map_end=0x%lx\n", @as(c_ulong, @intCast(target_map_end)));

    var cursor = state.heap_mapped_end;
    if (cursor < HEAP_BASE) cursor = HEAP_BASE;
    while (cursor < target_map_end) : (cursor += PAGE_SIZE_4K) {
        _ = c.printf("[vm_brk] mapping cursor=0x%lx target=0x%lx\n", @as(c_ulong, @intCast(cursor)), @as(c_ulong, @intCast(target_map_end)));
        state.mapAnonymousPage(handle, cursor, &state.heap_region) catch |err| {
            const err_code: c_int = vmErrorToErrno(err);
            _ = c.printf("[vm_brk] mapAnonymousPage failed cursor=0x%lx errno=%d\n", @as(c_ulong, @intCast(cursor)), err_code);
            return err;
        };
        _ = c.printf("[vm_brk] mapped cursor=0x%lx\n", @as(c_ulong, @intCast(cursor)));
    }

    state.heap_mapped_end = if (state.heap_region.end > HEAP_BASE) state.heap_region.end else state.heap_mapped_end;
    state.heap_break = requested;
    _ = c.printf("[vm_brk] updated state heap_break=0x%lx heap_mapped_end=0x%lx\n", @as(c_ulong, @intCast(state.heap_break)), @as(c_ulong, @intCast(state.heap_mapped_end)));
    return requested;
}

pub fn mmapImpl(handle: *VmHandle, addr: usize, length: usize, prot: c_int, flags: c_int, fd: c_int, offset: usize) VmError!usize {
    const caller_ptr: c_ulong = @intCast(@intFromPtr(handle.getClient()));
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

    const state = handle.ensureVmState();
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
        state.mapAnonymousPage(handle, cursor, tracker) catch |err| {
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

fn handleVmFaultInternal(handle: *VmHandle, fault_addr: usize, want_write: bool, is_fetch: bool) VmError!void {
    _ = want_write;
    _ = is_fetch;
    const state = handle.ensureVmState();
    const base = pageBase(fault_addr);

    if (state.findPage(base) != null) {
        return;
    }

    const min_stack = state.stack_guard + PAGE_SIZE_4K;
    if (base >= min_stack and base < state.stack_top) {
        _ = c.printf("[vm_fault] growing stack at 0x%lx (low=0x%lx guard=0x%lx top=0x%lx)\n", @as(c_ulong, @intCast(base)), @as(c_ulong, @intCast(state.stack_low)), @as(c_ulong, @intCast(state.stack_guard)), @as(c_ulong, @intCast(state.stack_top)));
        try state.mapAnonymousPage(handle, base, &state.stack_region);
        return;
    }

    if (base < state.stack_top and base >= state.stack_guard) {
        _ = c.printf("[vm_fault] stack guard hit addr=0x%lx guard=0x%lx\n", @as(c_ulong, @intCast(base)), @as(c_ulong, @intCast(state.stack_guard)));
        return VmError.Bounds;
    }

    if (base >= HEAP_BASE and base < state.heap_break) {
        try state.mapAnonymousPage(handle, base, &state.heap_region);
        return;
    }

    if (state.findMmapRegion(base)) |tracker| {
        try state.mapAnonymousPage(handle, base, tracker);
        return;
    }

    return VmError.Unsupported;
}

fn vmStateIndex(caller: *sos.client_t) usize {
    const id: usize = @intCast(caller.*.id);
    _ = c.printf("[vm_state] vmStateIndex caller=0x%lx id=%lu\n", @as(c_ulong, @intCast(@intFromPtr(caller))), @as(c_ulong, @intCast(id)));
    return id;
}

fn alignForward(value: usize, alignment: usize) usize {
    if (alignment == 0) return value;
    const remainder = value % alignment;
    if (remainder == 0) return value;
    return value + (alignment - remainder);
}

fn alignDown(value: usize, alignment: usize) usize {
    if (alignment == 0) return value;
    return value - (value % alignment);
}

fn pageBase(addr: usize) usize {
    return alignDown(addr, PAGE_SIZE_4K);
}

// Interface that we export to C
pub export fn vm_state_acquire(cl: *sos.client_t) callconv(.c) *VmHandle {
    bootstrapVmStates();
    const idx = vmStateIndex(cl);
    vm_handles[idx] = VmHandle{
        .idx = idx,
        .generation = cl.*.gen,
        .client = cl,
    };
    vm_handle_active[idx] = true;
    const handle = &vm_handles[idx];
    _ = handle.ensureVmState();
    return handle;
}

pub export fn vm_state_lookup(cl: *sos.client_t) callconv(.c) ?*VmHandle {
    bootstrapVmStates();
    const idx = vmStateIndex(cl);
    if (!vm_handle_active[idx]) {
        return null;
    }
    const handle = &vm_handles[idx];
    if (handle.client != cl) {
        return null;
    }
    if (handle.generation != cl.*.gen) {
        return null;
    }
    return handle;
}

pub export fn vm_state_release(cl: *sos.client_t) callconv(.c) void {
    bootstrapVmStates();
    const idx = vmStateIndex(cl);
    if (!vm_handle_active[idx]) {
        return;
    }
    const handle = &vm_handles[idx];
    if (handle.client != null and handle.client.? != cl) {
        _ = c.printf("[vm_state] release mismatch idx=%lu stored=0x%lx provided=0x%lx\n", @as(c_ulong, @intCast(idx)), @as(c_ulong, @intCast(@intFromPtr(handle.client.?))), @as(c_ulong, @intCast(@intFromPtr(cl))));
    }
    vm_handle_active[idx] = false;
    vm_handles[idx] = VmHandle{ .idx = idx, .generation = 0, .client = null };
    _ = &vm_states[idx].teardown();
}

pub export fn vm_register_stack_mapping(handle: *VmHandle, vaddr: usize, frame_ref: usize, cap_slot: sel4.seL4_CPtr) callconv(.c) void {
    const state = handle.ensureVmState();
    _ = state.insertPage(vaddr, frame_ref, cap_slot, null, false, false) catch |err| {
        const errno = vmErrorToErrno(err);
        _ = c.printf("[vm_stack] failed to record mapping errno=%d vaddr=0x%lx\n", errno, @as(c_ulong, @intCast(vaddr)));
        @panic("unable to record stack mapping");
    };
    state.mapped_count = state.page_map.count();
    state.stack_region.updateAccess(true, true, false);
    state.stack_region.recordMapping(vaddr, PAGE_SIZE_4K);
    if (state.stack_region.start < state.stack_low) {
        state.stack_low = state.stack_region.start;
    }
}

pub export fn vm_report_initial_stack(handle: *VmHandle, mapped_bottom: usize) callconv(.c) void {
    const state = handle.ensureVmState();
    if (!state.stack_region.contains(mapped_bottom)) {
        state.stack_region.recordMapping(mapped_bottom, PAGE_SIZE_4K);
    }
    if (mapped_bottom < state.stack_low) {
        state.stack_low = mapped_bottom;
    }
}

pub export fn vm_reset_state(handle: *VmHandle) callconv(.c) void {
    handle.validate();
    bootstrapVmStates();
    const idx = handle.idx;
    const cl = handle.getClient();
    _ = c.printf("[vm_state] reset idx=%lu client=0x%lx\n", @as(c_ulong, @intCast(idx)), @as(c_ulong, @intCast(@intFromPtr(cl))));
    _ = &vm_states[idx].teardown();
    _ = &vm_states[idx].init(idx);
}

pub export fn handle_vm_fault(
    handle: *VmHandle,
    badge: sel4.seL4_Word,
    message: [*c]const sel4.seL4_MessageInfo_t,
) callconv(.c) bool {
    _ = badge;
    handle.validate();
    const info = message.*;
    if (sel4.seL4_MessageInfo_get_label(info) != sel4.seL4_Fault_VMFault) {
        return false;
    }

    if (sel4.seL4_MessageInfo_get_length(info) < 2) {
        _ = c.printf("[vm_fault] unexpected length=%lu\n", @as(c_ulong, sel4.seL4_MessageInfo_get_length(info)));
        return false;
    }

    const fault_addr_word = sel4.seL4_GetMR(sel4.seL4_VMFault_Addr);
    const fsr = sel4.seL4_GetMR(sel4.seL4_VMFault_FSR);
    const prefetch = sel4.seL4_GetMR(sel4.seL4_VMFault_PrefetchFault) != 0;
    const fault_addr: usize = @intCast(fault_addr_word);
    const want_write = (fsr & (1 << 6)) != 0;

    const addr_raw: c_ulong = @intCast(fault_addr);
    const fsr_raw: c_ulong = @intCast(fsr);
    _ = c.printf("[vm_fault] addr=0x%lx fsr=0x%lx write=%d fetch=%d\n", @as(c_ulong, addr_raw), @as(c_ulong, fsr_raw), @as(c_int, if (want_write) 1 else 0), @as(c_int, if (prefetch) 1 else 0));

    handleVmFaultInternal(handle, fault_addr, want_write, prefetch) catch |err| {
        _ = c.printf("[vm_fault] handler error=%d\n", vmErrorToErrno(err));
        return false;
    };
    return true;
}

pub const DEFAULT_HEAP_PROT: c_int = sos.PROT_READ | sos.PROT_WRITE;
pub const DEFAULT_STACK_PROT: c_int = sos.PROT_READ | sos.PROT_WRITE;

const std = @import("std");
const cimports = @import("cimports");
const c = cimports.c;
const sel4 = cimports.sel4;
const sos = cimports.sos;

pub const logging = @import("logging.zig");
pub const addr_space = @import("addr_space.zig");
pub const region = @import("region.zig");
pub const mapping = @import("mapping.zig");
pub const page = @import("page.zig");
pub const client = @import("client.zig");
pub const allocator = @import("allocator.zig");
