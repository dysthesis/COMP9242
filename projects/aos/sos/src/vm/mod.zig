const std = @import("std");
const cimports = @import("cimports");
const logging_pkg = @import("logging.zig");
const addr_space_pkg = @import("addr_space.zig");
const region_mod = @import("region.zig");
const mapping_mod = @import("mapping.zig");
const page_mod = @import("page.zig");

const c = cimports.c;
const sel4 = cimports.sel4;
const sos = cimports.sos;

extern var cspace: sos.cspace_t;

pub const VmHandle = struct {
    idx: usize,
    generation: u8,
    client: ?*sos.client_t,
};

var vm_handles: [MAX_CLIENTS]VmHandle = [_]VmHandle{VmHandle{
    .idx = 0,
    .generation = 0,
    .client = null,
}} ** MAX_CLIENTS;
var vm_handle_active: [MAX_CLIENTS]bool = [_]bool{false} ** MAX_CLIENTS;

const VM_ARENA_BYTES = 64 * 1024;
const PageEntry = struct {
    frame_ref: usize,
    cap_slot: sel4.seL4_CPtr,
    cap_owner: ?*sos.cspace_t,
    owns_frame: bool,
    owns_cap: bool,
};
const PageMap = std.AutoHashMap(usize, PageEntry);
const RegionList = std.ArrayListUnmanaged(VmRegion);

fn validateHandle(handle: *VmHandle) void {
    const idx = handle.idx;
    if (idx >= MAX_CLIENTS) {
        @panic("VM handle index out of range");
    }
    if (!vm_handle_active[idx]) {
        @panic("VM handle inactive");
    }
    const client = handle.client orelse @panic("VM handle missing client reference");
    const stored_id: usize = @intCast(client.*.id);
    if (stored_id != idx) {
        @panic("VM handle/client ID mismatch");
    }
    if (client.*.gen != handle.generation) {
        @panic("VM handle stale generation");
    }
}

fn clientFromHandle(handle: *VmHandle) *sos.client_t {
    validateHandle(handle);
    return handle.client.?;
}

fn stateFromHandle(handle: *VmHandle) *VmClientState {
    validateHandle(handle);
    bootstrapVmStates();
    return &vm_states[handle.idx];
}

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

const VmRegion = struct {
    region: region_mod.Region = .{
        .start = 0,
        .end = 0,
        .attr = .{ .kind = region_mod.RegionKind.Normal, .data = 0 },
        .perm = std.mem.zeroes(sel4.seL4_CapRights_t),
    },
    used: bool = false,
    mapped: bool = false,

    pub fn configure(self: *VmRegion, start: usize, kind: region_mod.RegionKind, prot_flags: c_int) void {
        const readable = (prot_flags & sos.PROT_READ) != 0;
        const writable = (prot_flags & sos.PROT_WRITE) != 0;
        self.region.start = start;
        self.region.end = start;
        self.region.attr = .{ .kind = kind, .data = protToData(prot_flags) };
        self.region.perm = rightsFromBooleans(readable, writable);
        self.used = true;
        self.mapped = false;
    }

    pub fn reset(self: *VmRegion, kind: region_mod.RegionKind) void {
        self.region.start = 0;
        self.region.end = 0;
        self.region.attr = .{ .kind = kind, .data = 0 };
        self.region.perm = std.mem.zeroes(sel4.seL4_CapRights_t);
        self.used = false;
        self.mapped = false;
    }

    pub fn updateAccess(self: *VmRegion, readable: bool, writable: bool, executable: bool) void {
        const prot_flags = encodeProtFlags(readable, writable, executable);
        if (!self.mapped) {
            self.region.attr.data = protToData(prot_flags);
            self.region.perm = rightsFromBooleans(readable, writable);
        } else {
            const merged = dataToProt(self.region.attr.data) | prot_flags;
            self.region.attr.data = protToData(merged);
            self.region.perm = mergeCapRights(self.region.perm, rightsFromBooleans(readable, writable));
        }
    }

    pub fn recordMapping(self: *VmRegion, addr: usize, page_size: usize) void {
        const base = alignDown(addr, page_size);
        const end_addr = base + page_size;
        if (!self.mapped) {
            self.region.start = base;
            self.region.end = end_addr;
            self.mapped = true;
        } else {
            if (base < self.region.start) self.region.start = base;
            if (end_addr > self.region.end) self.region.end = end_addr;
        }
    }

    pub fn contains(self: *const VmRegion, addr: usize) bool {
        if (!self.used) return false;
        if (!self.mapped) return false;
        return addr >= self.region.start and addr < self.region.end;
    }

    pub fn prot(self: *const VmRegion) c_int {
        return dataToProt(self.region.attr.data);
    }
};

pub const VmClientState = struct {
    initialised: bool = false,
    heap_break: usize = 0,
    heap_mapped_end: usize = 0,
    mmap_next: usize = 0,
    stack_guard: usize = 0,
    stack_low: usize = 0,
    stack_top: usize = 0,
    mapped_count: usize = 0,
    active_mmaps: usize = 0,

    heap_region: VmRegion = VmRegion{},
    stack_region: VmRegion = VmRegion{},

    arena_buf: [VM_ARENA_BYTES]u8 = undefined,
    arena_fixed: std.heap.FixedBufferAllocator = undefined,
    base_allocator: std.mem.Allocator = undefined,
    arena_allocator: std.heap.ArenaAllocator = undefined,
    page_map: PageMap = undefined,
    mmap_regions: RegionList = .{},
};

const MAX_CLIENTS: usize = sos.MAX_CLIENTS;
const PAGE_SIZE_4K: usize = sos.PAGE_SIZE_4K;
const HEAP_BASE: usize = 0x40000000;
const MMAP_BASE: usize = 0x80000000;
const HEAP_LIMIT: usize = MMAP_BASE - PAGE_SIZE_4K;
const STACK_TOP_RAW: usize = sos.PROCESS_STACK_TOP;
const STACK_TOP: usize = STACK_TOP_RAW & ~(PAGE_SIZE_4K - 1);
const STACK_MAX_BYTES: usize = 64 * 1024 * 1024;
const STACK_GUARD_BASE: usize = STACK_TOP - STACK_MAX_BYTES;
const MMAP_LIMIT: usize = STACK_GUARD_BASE - PAGE_SIZE_4K;
const MAX_MAPPED_PAGES: usize = 4096;
const MAX_MMAP_REGIONS: usize = 64;

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

var vm_states: [MAX_CLIENTS]VmClientState = undefined;
var vm_states_initialised = false;

fn initVmState(state: *VmClientState) void {
    state.initialised = true;
    state.heap_break = HEAP_BASE;
    state.heap_mapped_end = HEAP_BASE;
    state.mmap_next = MMAP_BASE;
    state.stack_guard = STACK_GUARD_BASE;
    state.stack_low = STACK_TOP;
    state.stack_top = STACK_TOP;
    state.mapped_count = 0;
    state.active_mmaps = 0;

    state.heap_region.reset(region_mod.RegionKind.Heap);
    state.heap_region.configure(HEAP_BASE, region_mod.RegionKind.Heap, DEFAULT_HEAP_PROT);

    state.stack_region.reset(region_mod.RegionKind.Stack);
    state.stack_region.configure(STACK_TOP, region_mod.RegionKind.Stack, DEFAULT_STACK_PROT);

    state.arena_fixed = std.heap.FixedBufferAllocator.init(state.arena_buf[0..]);
    state.base_allocator = state.arena_fixed.allocator();
    state.arena_allocator = std.heap.ArenaAllocator.init(state.base_allocator);
    state.page_map = PageMap.init(state.arena_allocator.allocator());
    state.mmap_regions = RegionList{};
}

fn releasePageEntry(entry: *PageEntry) void {
    if (entry.cap_owner) |owner| {
        if (entry.cap_slot != sel4.seL4_CapNull and entry.owns_cap) {
            const unmap_err = sel4.seL4_ARM_Page_Unmap(entry.cap_slot);
            if (unmap_err != sel4.seL4_NoError) {
                const unmap_err_i32: c_int = @intCast(unmap_err);
                _ = c.printf("[vm_release] Page_Unmap err=%d slot=%lu\n", unmap_err_i32, @as(c_ulong, @intCast(entry.cap_slot)));
            }
            const delete_err = sos.cspace_delete(owner, entry.cap_slot);
            if (delete_err != sel4.seL4_NoError) {
                const delete_err_i32: c_int = @intCast(delete_err);
                _ = c.printf("[vm_release] cspace_delete err=%d slot=%lu\n", delete_err_i32, @as(c_ulong, @intCast(entry.cap_slot)));
            }
            sos.cspace_free_slot(owner, entry.cap_slot);
        }
    }
    if (entry.owns_frame and entry.frame_ref != 0) {
        sos.free_frame(entry.frame_ref);
    }
}

fn releaseAllPages(state: *VmClientState) void {
    var it = state.page_map.iterator();
    while (it.next()) |kv| {
        releasePageEntry(kv.value_ptr);
    }
    state.page_map.clearRetainingCapacity();
    state.mapped_count = 0;
}

fn teardownVmState(state: *VmClientState) void {
    if (!state.initialised) {
        state.* = VmClientState{};
        return;
    }
    const arena_alloc = state.arena_allocator.allocator();
    releaseAllPages(state);
    state.page_map.deinit();
    state.mmap_regions.deinit(arena_alloc);
    state.arena_allocator.deinit();
    state.arena_fixed.reset();
    state.* = VmClientState{};
}

fn bootstrapVmStates() void {
    if (vm_states_initialised) {
        return;
    }
    for (&vm_states) |*state| {
        state.* = VmClientState{};
    }
    vm_states_initialised = true;
}

fn ensureVmState(handle: *VmHandle) *VmClientState {
    const idx = handle.idx;
    const client = clientFromHandle(handle);
    const state = stateFromHandle(handle);
    if (!state.initialised) {
        _ = c.printf("[vm_state] initialise idx=%lu caller=0x%lx\n", @as(c_ulong, @intCast(idx)), @as(c_ulong, @intCast(@intFromPtr(client))));
        initVmState(state);
    } else {
        _ = c.printf("[vm_state] reuse idx=%lu caller=0x%lx heap_break=0x%lx mapped_end=0x%lx stack_low=0x%lx active_mmaps=%lu mapped_pages=%lu\n", @as(c_ulong, @intCast(idx)), @as(c_ulong, @intCast(@intFromPtr(client))), @as(c_ulong, @intCast(state.heap_break)), @as(c_ulong, @intCast(state.heap_mapped_end)), @as(c_ulong, @intCast(state.stack_low)), @as(c_ulong, @intCast(state.active_mmaps)), @as(c_ulong, @intCast(state.mapped_count)));
    }
    return state;
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

fn mapAnonymousPage(handle: *VmHandle, state: *VmClientState, vaddr: usize, tracker: *VmRegion) VmError!void {
    if (!tracker.used) {
        return VmError.InvalidArgs;
    }

    const caller = clientFromHandle(handle);

    const prot_flags = tracker.prot();
    const readable = (prot_flags & sos.PROT_READ) != 0;
    const writable = (prot_flags & sos.PROT_WRITE) != 0;
    const executable = (prot_flags & sos.PROT_EXEC) != 0;

    _ = c.printf("[vm_map] enter caller=0x%lx vaddr=0x%lx read=%d write=%d exec=%d mapped_count=%lu\n", @as(c_ulong, @intCast(@intFromPtr(caller))), @as(c_ulong, @intCast(vaddr)), @as(c_int, if (readable) 1 else 0), @as(c_int, if (writable) 1 else 0), @as(c_int, if (executable) 1 else 0), @as(c_ulong, @intCast(state.mapped_count)));

    if (findPage(state, vaddr) != null) {
        _ = c.printf("[vm_map] already mapped vaddr=0x%lx\n", @as(c_ulong, @intCast(vaddr)));
        return;
    }

    if (state.page_map.count() >= MAX_MAPPED_PAGES) {
        _ = c.printf("[vm_map] capacity reached mapped_count=%lu max=%lu\n", @as(c_ulong, @intCast(state.page_map.count())), @as(c_ulong, @intCast(MAX_MAPPED_PAGES)));
        return VmError.Capacity;
    }

    const proc_vspace = sos.client_get_vspace(caller);
    if (proc_vspace == 0) {
        return VmError.ClientContext;
    }

    const frame_ref = sos.alloc_frame();
    if (frame_ref == 0) {
        _ = c.printf("[vm_map] alloc_frame failed caller=0x%lx\n", @as(c_ulong, @intCast(@intFromPtr(caller))));
        return VmError.OutOfFrames;
    }
    _ = c.printf("[vm_map] alloc_frame ok frame_ref=%lu\n", @as(c_ulong, @intCast(frame_ref)));

    const frame_raw = sos.frame_data(frame_ref);
    const frame_bytes = @as([*]u8, @ptrCast(frame_raw));
    @memset(frame_bytes[0..PAGE_SIZE_4K], 0);
    _ = c.printf("[vm_map] cleared frame_data addr=0x%lx size=%lu\n", @as(c_ulong, @intCast(@intFromPtr(frame_raw))), @as(c_ulong, @intCast(PAGE_SIZE_4K)));

    const slot = sos.cspace_alloc_slot(&cspace);
    if (slot == sel4.seL4_CapNull) {
        sos.free_frame(frame_ref);
        _ = c.printf("[vm_map] cspace_alloc_slot failed frame_ref=%lu\n", @as(c_ulong, @intCast(frame_ref)));
        return VmError.OutOfSlots;
    }
    _ = c.printf("[vm_map] allocated slot=%lu owner_cspace=0x%lx\n", @as(c_ulong, @intCast(slot)), @as(c_ulong, @intCast(@intFromPtr(&cspace))));
    _ = c.printf("[vm_map] allocated slot=%lu for frame_ref=%lu\n", @as(c_ulong, @intCast(slot)), @as(c_ulong, @intCast(frame_ref)));

    const src_cspace = sos.frame_table_cspace();
    const frame_cap = sos.frame_page(frame_ref);
    const copy_err = sos.cspace_copy(&cspace, slot, src_cspace, frame_cap, toSosRights(sel4.seL4_AllRights));
    if (copy_err != sel4.seL4_NoError) {
        _ = sos.cspace_free_slot(&cspace, slot);
        sos.free_frame(frame_ref);
        const copy_err_i32: c_int = @intCast(copy_err);
        _ = c.printf("[vm_map] cspace_copy failed err=%d slot=%lu frame_ref=%lu\n", copy_err_i32, @as(c_ulong, @intCast(slot)), @as(c_ulong, @intCast(frame_ref)));
        return VmError.MapFailed;
    }
    _ = c.printf("[vm_map] copied frame cap slot=%lu frame_ref=%lu\n", @as(c_ulong, @intCast(slot)), @as(c_ulong, @intCast(frame_ref)));

    const rights = rightsFromBooleans(readable, writable);
    const rights_sos = toSosRights(rights);
    var attrs = sel4.seL4_ARM_Default_VMAttributes;
    if (!executable) {
        attrs = attrs | sel4.seL4_ARM_ExecuteNever;
    }
    const map_err = sos.map_frame(&cspace, slot, proc_vspace, vaddr, rights_sos, attrs);
    if (map_err != sel4.seL4_NoError) {
        _ = sos.cspace_delete(&cspace, slot);
        _ = sos.cspace_free_slot(&cspace, slot);
        sos.free_frame(frame_ref);
        const map_err_i32: c_int = @intCast(map_err);
        _ = c.printf("[vm_map] map_frame failed err=%d slot=%lu frame_ref=%lu vaddr=0x%lx\n", map_err_i32, @as(c_ulong, @intCast(slot)), @as(c_ulong, @intCast(frame_ref)), @as(c_ulong, @intCast(vaddr)));
        return VmError.MapFailed;
    }
    _ = c.printf("[vm_map] map_frame success slot=%lu frame_ref=%lu vaddr=0x%lx\n", @as(c_ulong, @intCast(slot)), @as(c_ulong, @intCast(frame_ref)), @as(c_ulong, @intCast(vaddr)));

    _ = insertPage(state, vaddr, frame_ref, slot, &cspace, true, true) catch |err| {
        _ = sos.cspace_delete(&cspace, slot);
        _ = sos.cspace_free_slot(&cspace, slot);
        sos.free_frame(frame_ref);
        return err;
    };
    state.mapped_count = state.page_map.count();
    _ = c.printf("[vm_map] recorded mapping vaddr=0x%lx frame_ref=%lu slot=%lu new_mapped_count=%lu\n", @as(c_ulong, @intCast(vaddr)), @as(c_ulong, @intCast(frame_ref)), @as(c_ulong, @intCast(slot)), @as(c_ulong, @intCast(state.mapped_count)));

    tracker.updateAccess(readable, writable, executable);
    tracker.recordMapping(vaddr, PAGE_SIZE_4K);

    switch (tracker.region.attr.kind) {
        .Stack => {
            if (tracker.region.start < state.stack_low) {
                state.stack_low = tracker.region.start;
            }
        },
        .Heap => {
            if (tracker.region.end > state.heap_mapped_end) {
                state.heap_mapped_end = tracker.region.end;
            }
        },
        else => {},
    }
}

pub fn brkImpl(handle: *VmHandle, requested: usize) VmError!usize {
    const state = ensureVmState(handle);
    const caller_ptr: c_ulong = @intCast(@intFromPtr(clientFromHandle(handle)));
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
        mapAnonymousPage(handle, state, cursor, &state.heap_region) catch |err| {
            const err_code: c_int = vmErrorToErrno(err);
            _ = c.printf("[vm_brk] mapAnonymousPage failed cursor=0x%lx errno=%d\n", @as(c_ulong, @intCast(cursor)), err_code);
            return err;
        };
        _ = c.printf("[vm_brk] mapped cursor=0x%lx\n", @as(c_ulong, @intCast(cursor)));
    }

    state.heap_mapped_end = if (state.heap_region.region.end > HEAP_BASE) state.heap_region.region.end else state.heap_mapped_end;
    state.heap_break = requested;
    _ = c.printf("[vm_brk] updated state heap_break=0x%lx heap_mapped_end=0x%lx\n", @as(c_ulong, @intCast(state.heap_break)), @as(c_ulong, @intCast(state.heap_mapped_end)));
    return requested;
}

pub fn mmapImpl(handle: *VmHandle, addr: usize, length: usize, prot: c_int, flags: c_int, fd: c_int, offset: usize) VmError!usize {
    const caller_ptr: c_ulong = @intCast(@intFromPtr(clientFromHandle(handle)));
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

    const state = ensureVmState(handle);
    if (state.mmap_next + aligned > MMAP_LIMIT) {
        _ = c.printf("[vm_mmap] exceeds limit mmap_next=0x%lx aligned=0x%lx limit=0x%lx\n", @as(c_ulong, @intCast(state.mmap_next)), @as(c_ulong, @intCast(aligned)), @as(c_ulong, @intCast(MMAP_LIMIT)));
        return VmError.Bounds;
    }

    const base = state.mmap_next;
    const tracker = leaseMmapRegion(state, base, prot) catch |err| {
        return err;
    };

    var cursor = base;
    const end_addr = base + aligned;
    var map_failed = false;
    _ = c.printf("[vm_mmap] base=0x%lx end=0x%lx\n", @as(c_ulong, @intCast(base)), @as(c_ulong, @intCast(end_addr)));
    while (cursor < end_addr) : (cursor += PAGE_SIZE_4K) {
        _ = c.printf("[vm_mmap] mapping cursor=0x%lx\n", @as(c_ulong, @intCast(cursor)));
        mapAnonymousPage(handle, state, cursor, tracker) catch |err| {
            const err_code: c_int = vmErrorToErrno(err);
            _ = c.printf("[vm_mmap] mapAnonymousPage failed cursor=0x%lx errno=%d\n", @as(c_ulong, @intCast(cursor)), err_code);
            map_failed = true;
            break;
        };
        _ = c.printf("[vm_mmap] mapped cursor=0x%lx\n", @as(c_ulong, @intCast(cursor)));
    }

    if (map_failed) {
        releaseMmapRegion(state, tracker);
        return VmError.MapFailed;
    }

    state.mmap_next = end_addr;
    _ = c.printf("[vm_mmap] updated mmap_next=0x%lx returning base=0x%lx\n", @as(c_ulong, @intCast(state.mmap_next)), @as(c_ulong, @intCast(base)));
    return base;
}

fn handleVmFaultInternal(handle: *VmHandle, fault_addr: usize, want_write: bool, is_fetch: bool) VmError!void {
    _ = want_write;
    _ = is_fetch;
    const state = ensureVmState(handle);
    const base = pageBase(fault_addr);

    if (findPage(state, base) != null) {
        return;
    }

    const min_stack = state.stack_guard + PAGE_SIZE_4K;
    if (base >= min_stack and base < state.stack_top) {
        _ = c.printf("[vm_fault] growing stack at 0x%lx (low=0x%lx guard=0x%lx top=0x%lx)\n", @as(c_ulong, @intCast(base)), @as(c_ulong, @intCast(state.stack_low)), @as(c_ulong, @intCast(state.stack_guard)), @as(c_ulong, @intCast(state.stack_top)));
        try mapAnonymousPage(handle, state, base, &state.stack_region);
        return;
    }

    if (base < state.stack_top and base >= state.stack_guard) {
        _ = c.printf("[vm_fault] stack guard hit addr=0x%lx guard=0x%lx\n", @as(c_ulong, @intCast(base)), @as(c_ulong, @intCast(state.stack_guard)));
        return VmError.Bounds;
    }

    if (base >= HEAP_BASE and base < state.heap_break) {
        try mapAnonymousPage(handle, state, base, &state.heap_region);
        return;
    }

    if (findMmapRegion(state, base)) |tracker| {
        try mapAnonymousPage(handle, state, base, tracker);
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

fn findPage(state: *VmClientState, vaddr: usize) ?*PageEntry {
    return state.page_map.getPtr(vaddr);
}

fn insertPage(
    state: *VmClientState,
    vaddr: usize,
    frame_ref: usize,
    cap_slot: sel4.seL4_CPtr,
    cap_owner: ?*sos.cspace_t,
    owns_frame: bool,
    owns_cap: bool,
) VmError!*PageEntry {
    if (owns_cap and cap_owner == null) {
        _ = c.printf("[vm_map] insertPage missing cap_owner for vaddr=0x%lx\n", @as(c_ulong, @intCast(vaddr)));
        return VmError.InvalidArgs;
    }
    if (state.page_map.getPtr(vaddr)) |entry| {
        entry.frame_ref = frame_ref;
        entry.cap_slot = cap_slot;
        entry.cap_owner = cap_owner;
        entry.owns_frame = owns_frame;
        entry.owns_cap = owns_cap;
        return entry;
    }

    if (state.page_map.count() >= MAX_MAPPED_PAGES) {
        return VmError.Capacity;
    }

    state.page_map.put(vaddr, PageEntry{
        .frame_ref = frame_ref,
        .cap_slot = cap_slot,
        .cap_owner = cap_owner,
        .owns_frame = owns_frame,
        .owns_cap = owns_cap,
    }) catch {
        return VmError.Capacity;
    };
    state.mapped_count = state.page_map.count();
    return state.page_map.getPtr(vaddr).?;
}

fn leaseMmapRegion(state: *VmClientState, base: usize, prot: c_int) VmError!*VmRegion {
    if (state.mmap_regions.items.len >= MAX_MMAP_REGIONS) {
        _ = c.printf("[vm_mmap] no free region slots\n");
        return VmError.Capacity;
    }

    state.mmap_regions.append(state.arena_allocator.allocator(), VmRegion{}) catch {
        return VmError.Capacity;
    };
    const reg = &state.mmap_regions.items[state.mmap_regions.items.len - 1];
    reg.reset(region_mod.RegionKind.Mmap);
    reg.configure(base, region_mod.RegionKind.Mmap, prot);
    state.active_mmaps += 1;
    return reg;
}

fn releaseMmapRegion(state: *VmClientState, tracker: *VmRegion) void {
    if (!tracker.used) return;
    if (state.active_mmaps > 0) state.active_mmaps -= 1;
    const base_ptr = state.mmap_regions.items.ptr;
    const idx: usize = @intCast(tracker - base_ptr);
    _ = state.mmap_regions.swapRemove(idx);
}

fn findMmapRegion(state: *VmClientState, addr: usize) ?*VmRegion {
    for (state.mmap_regions.items) |*reg| {
        if (reg.contains(addr)) return reg;
    }
    return null;
}

fn encodeProtFlags(readable: bool, writable: bool, executable: bool) c_int {
    var prot: c_int = 0;
    if (readable) prot |= sos.PROT_READ;
    if (writable) prot |= sos.PROT_WRITE;
    if (executable) prot |= sos.PROT_EXEC;
    return prot;
}

fn rightsFromBooleans(readable: bool, writable: bool) sel4.seL4_CapRights_t {
    return sel4.seL4_CapRights_new(
        0,
        0,
        if (readable) 1 else 0,
        if (writable) 1 else 0,
    );
}

fn mergeCapRights(a: sel4.seL4_CapRights_t, b: sel4.seL4_CapRights_t) sel4.seL4_CapRights_t {
    var merged = a;
    merged.words[0] = merged.words[0] | b.words[0];
    return merged;
}

fn toSosRights(rights: sel4.seL4_CapRights_t) sos.seL4_CapRights_t {
    var converted: sos.seL4_CapRights_t = undefined;
    converted.words[0] = rights.words[0];
    return converted;
}

fn protToData(prot: c_int) u60 {
    const masked: u64 = @as(u64, @intCast(prot)) & ((@as(u64, 1) << 60) - 1);
    return @intCast(masked);
}

fn dataToProt(data: u60) c_int {
    return @intCast(@as(u64, data));
}

pub export fn vm_state_acquire(client: *sos.client_t) callconv(.c) *VmHandle {
    bootstrapVmStates();
    const idx = vmStateIndex(client);
    vm_handles[idx] = VmHandle{
        .idx = idx,
        .generation = client.*.gen,
        .client = client,
    };
    vm_handle_active[idx] = true;
    const handle = &vm_handles[idx];
    _ = ensureVmState(handle);
    return handle;
}

pub export fn vm_state_lookup(client: *sos.client_t) callconv(.c) ?*VmHandle {
    bootstrapVmStates();
    const idx = vmStateIndex(client);
    if (!vm_handle_active[idx]) {
        return null;
    }
    const handle = &vm_handles[idx];
    if (handle.client != client) {
        return null;
    }
    if (handle.generation != client.*.gen) {
        return null;
    }
    return handle;
}

pub export fn vm_state_release(client: *sos.client_t) callconv(.c) void {
    bootstrapVmStates();
    const idx = vmStateIndex(client);
    if (!vm_handle_active[idx]) {
        return;
    }
    const handle = &vm_handles[idx];
    if (handle.client != null and handle.client.? != client) {
        _ = c.printf("[vm_state] release mismatch idx=%lu stored=0x%lx provided=0x%lx\n", @as(c_ulong, @intCast(idx)), @as(c_ulong, @intCast(@intFromPtr(handle.client.?))), @as(c_ulong, @intCast(@intFromPtr(client))));
    }
    vm_handle_active[idx] = false;
    vm_handles[idx] = VmHandle{ .idx = idx, .generation = 0, .client = null };
    teardownVmState(&vm_states[idx]);
}

pub export fn vm_register_stack_mapping(handle: *VmHandle, vaddr: usize, frame_ref: usize, cap_slot: sel4.seL4_CPtr) callconv(.c) void {
    const state = ensureVmState(handle);
    _ = insertPage(state, vaddr, frame_ref, cap_slot, null, false, false) catch |err| {
        const errno = vmErrorToErrno(err);
        _ = c.printf("[vm_stack] failed to record mapping errno=%d vaddr=0x%lx\n", errno, @as(c_ulong, @intCast(vaddr)));
        @panic("unable to record stack mapping");
    };
    state.mapped_count = state.page_map.count();
    state.stack_region.updateAccess(true, true, false);
    state.stack_region.recordMapping(vaddr, PAGE_SIZE_4K);
    if (state.stack_region.region.start < state.stack_low) {
        state.stack_low = state.stack_region.region.start;
    }
}

pub export fn vm_report_initial_stack(handle: *VmHandle, mapped_bottom: usize) callconv(.c) void {
    const state = ensureVmState(handle);
    if (!state.stack_region.contains(mapped_bottom)) {
        state.stack_region.recordMapping(mapped_bottom, PAGE_SIZE_4K);
    }
    if (mapped_bottom < state.stack_low) {
        state.stack_low = mapped_bottom;
    }
}

pub export fn vm_reset_state(handle: *VmHandle) callconv(.c) void {
    validateHandle(handle);
    bootstrapVmStates();
    const idx = handle.idx;
    const client = clientFromHandle(handle);
    _ = c.printf("[vm_state] reset idx=%lu client=0x%lx\n", @as(c_ulong, @intCast(idx)), @as(c_ulong, @intCast(@intFromPtr(client))));
    teardownVmState(&vm_states[idx]);
    initVmState(&vm_states[idx]);
}

pub export fn handle_vm_fault(
    handle: *VmHandle,
    badge: sel4.seL4_Word,
    message: [*c]const sel4.seL4_MessageInfo_t,
) callconv(.c) bool {
    _ = badge;
    validateHandle(handle);
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

const DEFAULT_HEAP_PROT: c_int = sos.PROT_READ | sos.PROT_WRITE;
const DEFAULT_STACK_PROT: c_int = sos.PROT_READ | sos.PROT_WRITE;

pub const logging = logging_pkg;
pub const addr_space = addr_space_pkg;
pub const region = region_mod;
pub const mapping = mapping_mod;
pub const page = page_mod;
