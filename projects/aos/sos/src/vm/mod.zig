//! This module is the entrypoint to the virtual memory management system.
pub const DebugVmLogs = false;

pub extern var cspace: sos.cspace_t;

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
    AlreadyMapped,
};

const MAX_CLIENTS: usize = sos.MAX_CLIENTS;
pub const Address = @import("address.zig").Address;
pub const PAGE_SIZE_4K: usize = sos.PAGE_SIZE_4K;
pub const HEAP_BASE: usize = 0x40000000;
pub const MMAP_BASE: usize = 0x80000000;
pub const HEAP_LIMIT: usize = MMAP_BASE - PAGE_SIZE_4K;
pub const STACK_TOP_RAW: usize = sos.PROCESS_STACK_TOP;
pub const STACK_TOP: usize = STACK_TOP_RAW & ~(PAGE_SIZE_4K - 1);
pub const STACK_MAX_BYTES: usize = 64 * 1024 * 1024;
pub const STACK_GUARD_BASE: usize = STACK_TOP - STACK_MAX_BYTES;
pub const MMAP_LIMIT: usize = STACK_GUARD_BASE - PAGE_SIZE_4K;
pub const MAX_MMAP_REGIONS: usize = 64;

comptime {
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

pub var vm_states: [MAX_CLIENTS]client.Client = undefined;
var vm_states_initialised = false;

pub fn bootstrapVmStates() void {
    if (vm_states_initialised) {
        return;
    }
    for (&vm_states) |*state| {
        state.* = client.Client{};
    }
    vm_states_initialised = true;
}

pub inline fn vmErrorToErrno(err: anyerror) c_int {
    return switch (err) {
        VmError.ClientContext => sos.EINVAL,
        VmError.Bounds => sos.ENOMEM,
        VmError.Unsupported => sos.ENOSYS,
        VmError.OutOfFrames => sos.ENOMEM,
        VmError.OutOfSlots => sos.ENOMEM,
        VmError.MapFailed => sos.EIO,
        VmError.Capacity => sos.ENOMEM,
        VmError.InvalidArgs => sos.EINVAL,
        VmError.AlreadyMapped => sos.EEXIST,
        else => sos.EIO,
    };
}

fn vmStateIndex(caller: *sos.client_t) usize {
    const id: usize = @intCast(caller.*.id);
    if (DebugVmLogs) {
        _ = c.printf("[vm_state] vmStateIndex caller=0x%lx id=%lu\n", @as(c_ulong, @intCast(@intFromPtr(caller))), @as(c_ulong, @intCast(id)));
    }
    return id;
}

pub fn alignForward(value: usize, alignment: usize) usize {
    return Address.init(value).alignUp(alignment).raw();
}

pub inline fn alignDown(value: usize, alignment: usize) usize {
    return Address.init(value).alignDown(alignment).raw();
}

pub inline fn pageBase(addr: usize) usize {
    return Address.init(addr).pageBase(PAGE_SIZE_4K).raw();
}

pub export fn vm_state_acquire(cl: *sos.client_t) callconv(.c) *VmHandle {
    if (DebugVmLogs) {
        _ = c.printf("[vm_state_acquire] entered vm_state_acquire...\n");
    }
    bootstrapVmStates();
    const idx = vmStateIndex(cl);
    handle.vm_handles[idx] = VmHandle{
        .idx = idx,
        .generation = cl.*.gen,
        .client = cl,
    };
    handle.vm_handle_active[idx] = true;
    const vm_handle = &handle.vm_handles[idx];
    // _ = handle.ensureVmState();
    return vm_handle;
}

pub export fn vm_state_lookup(cl: *sos.client_t) callconv(.c) ?*VmHandle {
    bootstrapVmStates();
    const idx = vmStateIndex(cl);
    if (!handle.vm_handle_active[idx]) {
        return null;
    }
    const vm_handle = &handle.vm_handles[idx];
    if (vm_handle.client != cl) {
        return null;
    }
    if (vm_handle.generation != cl.*.gen) {
        return null;
    }
    return vm_handle;
}

pub export fn vm_state_release(cl: *sos.client_t) callconv(.c) void {
    bootstrapVmStates();
    const idx = vmStateIndex(cl);
    if (!handle.vm_handle_active[idx]) {
        return;
    }
    const vm_handle = &handle.vm_handles[idx];
    if (vm_handle.client != null and vm_handle.client.? != cl) {
        _ = c.printf("[vm_state] release mismatch idx=%lu stored=0x%lx provided=0x%lx\n", @as(c_ulong, @intCast(idx)), @as(c_ulong, @intCast(@intFromPtr(vm_handle.client.?))), @as(c_ulong, @intCast(@intFromPtr(cl))));
    }
    handle.vm_handle_active[idx] = false;
    handle.vm_handles[idx] = VmHandle{ .idx = idx, .generation = 0, .client = null };
    vm_states[idx].teardown();
}

/// Finalise page-out for a given frame by unmapping it from any client address
/// space and transitioning the page record to SWAPPED with the supplied
/// pagefile slot. Returns 0 on success, -errno on failure.
pub export fn vm_pageout_finalise(frame_ref: usize, slot: u32) callconv(.c) c_int {
    bootstrapVmStates();

    var unmapped: bool = false;

    for (&vm_states) |*state| {
        if (!state.initialised) continue;

        var it = state.addr_space.iterator();
        while (it.next()) |entry| {
            const vaddr = entry.key_ptr.*;
            var page_entry = entry.value_ptr;

            if (page_entry.frame_ref != frame_ref or page_entry.state != page.PageState.RESIDENT) {
                continue;
            }

            page_entry.transitionState(.PAGEOUT_PENDING);

            if (page_entry.cap_slot != sel4.seL4_CapNull) {
                const unmap_err = sel4.seL4_ARM_Page_Unmap(page_entry.cap_slot);
                if (unmap_err != sel4.seL4_NoError) {
                    _ = c.printf("[vm_pageout_finalise] Page_Unmap err=%d vaddr=0x%lx\n", @as(c_int, @intCast(unmap_err)), @as(c_ulong, @intCast(vaddr)));
                    return -sos.EIO;
                }
            }

            if (page_entry.owns_cap and page_entry.cap_owner != null) {
                const owner = page_entry.cap_owner.?;
                const del_err = sos.cspace_delete(owner, page_entry.cap_slot);
                if (del_err != sel4.seL4_NoError) {
                    _ = c.printf("[vm_pageout_finalise] cspace_delete err=%d vaddr=0x%lx\n", @as(c_int, @intCast(del_err)), @as(c_ulong, @intCast(vaddr)));
                    return -sos.EIO;
                }
                _ = sos.cspace_free_slot(owner, page_entry.cap_slot);
            }

            state.addr_space.recordLeafUnmap(vaddr);

            page_entry.cap_slot = sel4.seL4_CapNull;
            page_entry.cap_owner = null;
            page_entry.owns_cap = false;
            page_entry.pagefile_slot = @intCast(slot);
            page_entry.dirty = false;
            page_entry.referenced = false;
            page_entry.transitionState(.SWAPPED);
            page_entry.frame_ref = 0;
            page_entry.owns_frame = false;

            unmapped = true;
        }
    }

    if (!unmapped) {
        return -sos.ENOENT;
    }

    sos.free_frame(frame_ref);

    return 0;
}

pub export fn vm_register_stack_mapping(vm_handle: *VmHandle, vaddr: usize, frame_ref: usize, cap_slot: sel4.seL4_CPtr) callconv(.c) void {
    vm_handle.registerStackMapping(vaddr, frame_ref, cap_slot) catch |err| {
        const errno = vmErrorToErrno(err);
        _ = c.printf("[vm_stack] registerStackMapping failed errno=%d vaddr=0x%lx\n", errno, @as(c_ulong, @intCast(vaddr)));
        @panic("unable to record stack mapping");
    };
}

pub export fn vm_report_initial_stack(vm_handle: *VmHandle, mapped_bottom: usize) callconv(.c) void {
    vm_handle.reportInitialStack(mapped_bottom);
}

/// Register an ELF segment mapping in the VM subsystem
/// This should be called after successfully mapping ELF segments to track them
pub export fn vm_map_owned_frame(
    vm_handle: *VmHandle,
    vaddr: usize,
    frame_ref: usize,
    cap_slot: sel4.seL4_CPtr,
    readable: bool,
    writable: bool,
    executable: bool,
    owns_frame: bool,
    owns_cap: bool,
) callconv(.c) c_int {
    vm_handle.mapOwnedFrame(vaddr, frame_ref, cap_slot, readable, writable, executable, owns_frame, owns_cap) catch |err| {
        return -vmErrorToErrno(err);
    };
    return 0;
}

/// Access a user buffer directly for read/write operations
/// Returns a pointer to the frame data for a given user virtual address
/// Returns NULL if the page is not mapped
pub export fn vm_get_user_page_data(
    vm_handle: *VmHandle,
    user_vaddr: usize,
) callconv(.c) ?[*]u8 {
    return vm_handle.getUserPageData(user_vaddr);
}

pub export fn vm_reset_state(vm_handle: *VmHandle) callconv(.c) void {
    vm_handle.reset();
}

pub const VmFaultResult = enum(c_int) {
    handled = 0,
    deferred = 1,
    fatal = 2,
};

pub const VmHandle = handle.VmHandle;

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
// pub const mapping = @import("mapping.zig");
pub const page = @import("page.zig");
pub const client = @import("client.zig");
pub const allocator = @import("allocator.zig");
pub const page_table = @import("page_table.zig");
pub const handle = @import("handle.zig");
