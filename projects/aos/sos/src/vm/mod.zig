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

    pub fn getState(self: *Self) *client.VmClientState {
        validate(self);
        bootstrapVmStates();
        return &vm_states[self.idx];
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

var vm_states: [MAX_CLIENTS]client.VmClientState = undefined;
var vm_states_initialised = false;

fn initVmState(state: *client.VmClientState, idx: usize) void {
    state.initialised = true;
    state.heap_break = HEAP_BASE;
    state.heap_mapped_end = HEAP_BASE;
    state.mmap_next = MMAP_BASE;
    state.stack_guard = STACK_GUARD_BASE;
    state.stack_low = STACK_TOP;
    state.stack_top = STACK_TOP;
    state.mapped_count = 0;
    state.active_mmaps = 0;

    state.heap_region.reset(region.RegionKind.Heap);
    state.heap_region.configure(HEAP_BASE, region.RegionKind.Heap, DEFAULT_HEAP_PROT);

    state.stack_region.reset(region.RegionKind.Stack);
    state.stack_region.configure(STACK_TOP, region.RegionKind.Stack, DEFAULT_STACK_PROT);

    state.metadata_base = allocator.METADATA_REGION_START + idx * allocator.METADATA_REGION_BYTES;
    state.metadata_cursor = state.metadata_base;
    state.metadata_mapped = 0;
    state.metadata_page_count = 0;
    state.metadata_allocator.init(state);
    state.metadata_alloc_handle = state.metadata_allocator.allocator();
    state.page_map = client.PageMap.init(state.metadata_alloc_handle);
    state.mmap_regions = client.RegionList{};
}

fn releaseAllVmPages(state: *client.VmClientState) void {
    var it = state.page_map.iterator();
    while (it.next()) |kv| {
        kv.value_ptr.release();
    }
    state.page_map.clearRetainingCapacity();
    state.mapped_count = 0;
}

fn teardownVmState(state: *client.VmClientState) void {
    if (!state.initialised) {
        state.* = client.VmClientState{};
        return;
    }
    releaseAllVmPages(state);
    state.page_map.deinit();
    state.mmap_regions.deinit(state.metadata_alloc_handle);
    state.metadata_allocator.deinit();
    state.* = client.VmClientState{};
}

fn bootstrapVmStates() void {
    if (vm_states_initialised) {
        return;
    }
    for (&vm_states) |*state| {
        state.* = client.VmClientState{};
    }
    vm_states_initialised = true;
}

fn ensureVmState(handle: *VmHandle) *client.VmClientState {
    const idx = handle.idx;
    const cl = handle.getClient();
    const state = handle.getState();
    if (!state.initialised) {
        _ = c.printf("[vm_state] initialise idx=%lu caller=0x%lx\n", @as(c_ulong, @intCast(idx)), @as(c_ulong, @intCast(@intFromPtr(cl))));
        initVmState(state, idx);
    } else {
        _ = c.printf("[vm_state] reuse idx=%lu caller=0x%lx heap_break=0x%lx mapped_end=0x%lx stack_low=0x%lx active_mmaps=%lu mapped_pages=%lu\n", @as(c_ulong, @intCast(idx)), @as(c_ulong, @intCast(@intFromPtr(cl))), @as(c_ulong, @intCast(state.heap_break)), @as(c_ulong, @intCast(state.heap_mapped_end)), @as(c_ulong, @intCast(state.stack_low)), @as(c_ulong, @intCast(state.active_mmaps)), @as(c_ulong, @intCast(state.mapped_count)));
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

fn mapAnonymousPage(handle: *VmHandle, state: *client.VmClientState, vaddr: usize, tracker: *region.Region) VmError!void {
    if (!tracker.used) {
        return VmError.InvalidArgs;
    }

    const caller = handle.getClient();

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

    const rights = region.rightsFromBooleans(readable, writable);
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
        if (err == VmError.Capacity) {
            const meta_used = state.metadata_cursor - state.metadata_base;
            _ = c.printf("[vm_meta] capacity hit vaddr=0x%lx mapped_count=%lu max_mapped=%lu used_bytes=%lu limit_bytes=%lu pages=%lu\n", @as(c_ulong, @intCast(vaddr)), @as(c_ulong, @intCast(state.mapped_count)), @as(c_ulong, @intCast(MAX_MAPPED_PAGES)), @as(c_ulong, @intCast(meta_used)), @as(c_ulong, @intCast(allocator.METADATA_REGION_BYTES)), @as(c_ulong, @intCast(state.metadata_page_count)));
        }
        _ = sos.cspace_delete(&cspace, slot);
        _ = sos.cspace_free_slot(&cspace, slot);
        sos.free_frame(frame_ref);
        return err;
    };
    state.mapped_count = state.page_map.count();
    _ = c.printf("[vm_map] recorded mapping vaddr=0x%lx frame_ref=%lu slot=%lu new_mapped_count=%lu\n", @as(c_ulong, @intCast(vaddr)), @as(c_ulong, @intCast(frame_ref)), @as(c_ulong, @intCast(slot)), @as(c_ulong, @intCast(state.mapped_count)));

    tracker.updateAccess(readable, writable, executable);
    tracker.recordMapping(vaddr, PAGE_SIZE_4K);

    switch (tracker.attr.kind) {
        .Stack => {
            if (tracker.start < state.stack_low) {
                state.stack_low = tracker.start;
            }
        },
        .Heap => {
            if (tracker.end > state.heap_mapped_end) {
                state.heap_mapped_end = tracker.end;
            }
        },
        else => {},
    }
}

pub fn brkImpl(handle: *VmHandle, requested: usize) VmError!usize {
    const state = ensureVmState(handle);
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
        mapAnonymousPage(handle, state, cursor, &state.heap_region) catch |err| {
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

fn findPage(state: *client.VmClientState, vaddr: usize) ?*page.MappedPage {
    return state.page_map.getPtr(vaddr);
}

fn insertPage(
    state: *client.VmClientState,
    vaddr: usize,
    frame_ref: usize,
    cap_slot: sel4.seL4_CPtr,
    cap_owner: ?*sos.cspace_t,
    owns_frame: bool,
    owns_cap: bool,
) VmError!*page.MappedPage {
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

    state.page_map.put(vaddr, page.MappedPage{
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

fn leaseMmapRegion(state: *client.VmClientState, base: usize, prot: c_int) VmError!*region.Region {
    if (state.mmap_regions.items.len >= MAX_MMAP_REGIONS) {
        _ = c.printf("[vm_mmap] no free region slots\n");
        return VmError.Capacity;
    }

    state.mmap_regions.append(state.metadataAllocator(), region.Region{}) catch {
        return VmError.Capacity;
    };
    const reg = &state.mmap_regions.items[state.mmap_regions.items.len - 1];
    reg.reset(region.RegionKind.Mmap);
    reg.configure(base, region.RegionKind.Mmap, prot);
    state.active_mmaps += 1;
    return reg;
}

fn releaseMmapRegion(state: *client.VmClientState, tracker: *region.Region) void {
    if (!tracker.used) return;
    if (state.active_mmaps > 0) state.active_mmaps -= 1;
    const base_ptr = state.mmap_regions.items.ptr;
    const idx: usize = @intCast(tracker - base_ptr);
    _ = state.mmap_regions.swapRemove(idx);
}

fn findMmapRegion(state: *client.VmClientState, addr: usize) ?*region.Region {
    for (state.mmap_regions.items) |*reg| {
        if (reg.contains(addr)) return reg;
    }
    return null;
}

pub fn toSosRights(rights: sel4.seL4_CapRights_t) sos.seL4_CapRights_t {
    var converted: sos.seL4_CapRights_t = undefined;
    converted.words[0] = rights.words[0];
    return converted;
}

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
    _ = ensureVmState(handle);
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
    if (state.stack_region.start < state.stack_low) {
        state.stack_low = state.stack_region.start;
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
    handle.validate();
    bootstrapVmStates();
    const idx = handle.idx;
    const cl = handle.getClient();
    _ = c.printf("[vm_state] reset idx=%lu client=0x%lx\n", @as(c_ulong, @intCast(idx)), @as(c_ulong, @intCast(@intFromPtr(cl))));
    teardownVmState(&vm_states[idx]);
    initVmState(&vm_states[idx], idx);
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

const DEFAULT_HEAP_PROT: c_int = sos.PROT_READ | sos.PROT_WRITE;
const DEFAULT_STACK_PROT: c_int = sos.PROT_READ | sos.PROT_WRITE;

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
