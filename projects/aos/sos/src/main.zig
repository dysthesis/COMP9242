const MAX_CLIENTS: usize = sos.MAX_CLIENTS;
const SOS_MAX_OPEN_FILES: usize = 32;
const PROCESS_SHBUF_UVA = sos.PROCESS_SHBUF_UVA;
const PAGE_SIZE_4K: usize = sos.PAGE_SIZE_4K;
const console_name = "console";
const console_name_ptr: [*c]const u8 = @ptrCast(&console_name[0]);
const console_object_ptr: ?*anyopaque = @ptrCast(&sos.global_console);
const hi_msg = "hi from zig!\n";

const empty_fd: sos.sos_fd_entry_t = std.mem.zeroes(sos.sos_fd_entry_t);
const empty_fd_table = [_]sos.sos_fd_entry_t{empty_fd} ** SOS_MAX_OPEN_FILES;

const SosClientIoState = struct {
    initialised: bool = false,
    fds: [SOS_MAX_OPEN_FILES]sos.sos_fd_entry_t = empty_fd_table,
};

var client_io_state: [MAX_CLIENTS]SosClientIoState = [_]SosClientIoState{SosClientIoState{}} ** MAX_CLIENTS;

const HEAP_BASE: usize = 0x40000000;
const MMAP_BASE: usize = 0x80000000;
const HEAP_LIMIT: usize = MMAP_BASE - PAGE_SIZE_4K;
const MMAP_LIMIT: usize = sos.PROCESS_STACK_TOP - PAGE_SIZE_4K;
const MAX_MAPPED_PAGES: usize = 256;

const VmPage = struct {
    vaddr: usize,
    frame_ref: usize,
    cap_slot: sel4.seL4_CPtr,
};

const VmClientState = struct {
    initialised: bool = false,
    heap_break: usize = HEAP_BASE,
    heap_mapped_end: usize = HEAP_BASE,
    mmap_next: usize = MMAP_BASE,
    mapped_count: usize = 0,
    pages: [MAX_MAPPED_PAGES]VmPage = [_]VmPage{VmPage{ .vaddr = 0, .frame_ref = 0, .cap_slot = 0 }} ** MAX_MAPPED_PAGES,
};

var vm_states: [MAX_CLIENTS]VmClientState = [_]VmClientState{VmClientState{}} ** MAX_CLIENTS;

const PendingConsoleRead = struct {
    client: *sos.client_t,
    client_id: usize,
    fd_index: usize,
    requested: usize,
    ops: *const sos.file_ops_t,
    dev_id: c_int,
    reply: sel4.seL4_CPtr,
    reply_ut: *sos.ut_t,

    fn cancel(self: PendingConsoleRead, err: c_int) void {
        pending_console_read = null;
        self.complete(@as(isize, err));
    }

    fn complete(self: PendingConsoleRead, result: isize) void {
        const resp = SyscallResponse{ .Read = .{ .result = resultToCInt(result) } };
        const msg = resp.serialise();
        sel4.seL4_Send(self.reply, msg);
        _ = sos.cspace_delete(&cspace, self.reply);
        sos.cspace_free_slot(&cspace, self.reply);
        sos.ut_free(self.reply_ut);
    }
    fn tryComplete(self: PendingConsoleRead) void {
        if (self.client_id >= client_io_state.len) {
            pending_console_read = null;
            self.complete(@as(isize, -c.EINVAL));
            return;
        }

        var state = &client_io_state[self.client_id];
        if (!state.initialised) {
            pending_console_read = null;
            self.complete(@as(isize, -c.EBADF));
            return;
        }

        const entry = &state.fds[self.fd_index];
        if (!entry.used or !entry.readable or entry.ops != self.ops) {
            pending_console_read = null;
            self.complete(@as(isize, -c.EBADF));
            return;
        }

        const read_fn = self.ops.*.read orelse {
            pending_console_read = null;
            self.complete(@as(isize, -c.ENOSYS));
            return;
        };

        const dst_ptr = sharedBufPtr(u8, self.client);
        const dst_any: *anyopaque = @ptrCast(dst_ptr);
        const result = read_fn(self.dev_id, dst_any, self.requested);
        if (result == -c.EWOULDBLOCK) {
            return;
        }

        pending_console_read = null;
        self.complete(result);
    }
};

var pending_console_read: ?PendingConsoleRead = null;

const ServerContext = struct {
    badge: sel4.seL4_Word,
    have_reply: [*c]bool,
    caller: ?*sos.client_t,
    reply: [*c]sel4.seL4_CPtr,
    reply_ut: [*c]*sos.ut_t,
};

const VmError = error{
    ClientContext,
    Bounds,
    Unsupported,
    OutOfFrames,
    OutOfSlots,
    MapFailed,
    Capacity,
    InvalidArgs,
};

fn vmStateIndex(caller: *sos.client_t) usize {
    const id: usize = @intCast(caller.*.id);
    _ = c.printf("[vm_state] vmStateIndex caller=0x%lx id=%lu\n", @as(c_ulong, @intCast(@intFromPtr(caller))), @as(c_ulong, @intCast(id)));
    return id;
}

fn ensureVmState(caller: *sos.client_t) *VmClientState {
    const idx = vmStateIndex(caller);
    const state = &vm_states[idx];
    if (!state.initialised) {
        _ = c.printf("[vm_state] ensureVmState initialise idx=%lu caller=0x%lx\n", @as(c_ulong, @intCast(idx)), @as(c_ulong, @intCast(@intFromPtr(caller))));
        state.* = VmClientState{
            .initialised = true,
            .heap_break = HEAP_BASE,
            .heap_mapped_end = HEAP_BASE,
            .mmap_next = MMAP_BASE,
            .mapped_count = 0,
            .pages = [_]VmPage{VmPage{ .vaddr = 0, .frame_ref = 0, .cap_slot = 0 }} ** MAX_MAPPED_PAGES,
        };
    } else {
        _ = c.printf("[vm_state] ensureVmState reuse idx=%lu caller=0x%lx heap_break=0x%lx mapped_end=0x%lx mapped_count=%lu\n", @as(c_ulong, @intCast(idx)), @as(c_ulong, @intCast(@intFromPtr(caller))), @as(c_ulong, @intCast(state.heap_break)), @as(c_ulong, @intCast(state.heap_mapped_end)), @as(c_ulong, @intCast(state.mapped_count)));
    }
    return state;
}

fn vmErrorToErrno(err: VmError) c_int {
    return switch (err) {
        VmError.ClientContext => c.EINVAL,
        VmError.Bounds => c.ENOMEM,
        VmError.Unsupported => c.ENOSYS,
        VmError.OutOfFrames => c.ENOMEM,
        VmError.OutOfSlots => c.ENOMEM,
        VmError.MapFailed => c.EIO,
        VmError.Capacity => c.ENOMEM,
        VmError.InvalidArgs => c.EINVAL,
    };
}

fn mapAnonymousPage(state: *VmClientState, caller: *sos.client_t, vaddr: usize, readable: bool, writable: bool, executable: bool) VmError!void {
    _ = c.printf("[vm_map] mapAnonymousPage enter caller=0x%lx vaddr=0x%lx read=%d write=%d exec=%d mapped_count=%lu\n", @as(c_ulong, @intCast(@intFromPtr(caller))), @as(c_ulong, @intCast(vaddr)), @as(c_int, if (readable) 1 else 0), @as(c_int, if (writable) 1 else 0), @as(c_int, if (executable) 1 else 0), @as(c_ulong, @intCast(state.mapped_count)));
    if (findPage(state, vaddr) != null) {
        _ = c.printf("[vm_map] page already mapped vaddr=0x%lx\n", @as(c_ulong, @intCast(vaddr)));
        return;
    }
    if (state.mapped_count >= MAX_MAPPED_PAGES) {
        _ = c.printf("[vm_map] capacity reached mapped_count=%lu max=%lu\n", @as(c_ulong, @intCast(state.mapped_count)), @as(c_ulong, @intCast(MAX_MAPPED_PAGES)));
        return VmError.Capacity;
    }

    const caller_c: [*c]c.client_t = @ptrCast(caller);
    const proc_cspace = c.client_get_cspace(caller_c) orelse return VmError.ClientContext;
    const proc_vspace = sos.client_get_vspace(caller);
    if (proc_vspace == 0) {
        return VmError.ClientContext;
    }

    const frame_ref = c.alloc_frame();
    if (frame_ref == 0) {
        _ = c.printf("[vm_map] alloc_frame failed caller=0x%lx\n", @as(c_ulong, @intCast(@intFromPtr(caller))));
        return VmError.OutOfFrames;
    }
    _ = c.printf("[vm_map] alloc_frame ok frame_ref=%lu\n", @as(c_ulong, @intCast(frame_ref)));

    const frame_raw = c.frame_data(frame_ref);
    const frame_bytes = @ptrCast([*]u8, frame_raw);
    @memset(frame_bytes[0..PAGE_SIZE_4K], 0);
    _ = c.printf("[vm_map] cleared frame_data addr=0x%lx size=%lu\n", @as(c_ulong, @intCast(@intFromPtr(frame_raw))), @as(c_ulong, @intCast(PAGE_SIZE_4K)));

    const slot = c.cspace_alloc_slot(proc_cspace);
    if (slot == sel4.seL4_CapNull) {
        c.free_frame(frame_ref);
        _ = c.printf("[vm_map] cspace_alloc_slot failed frame_ref=%lu\n", @as(c_ulong, @intCast(frame_ref)));
        return VmError.OutOfSlots;
    }
    _ = c.printf("[vm_map] allocated slot=%lu for frame_ref=%lu\n", @as(c_ulong, @intCast(slot)), @as(c_ulong, @intCast(frame_ref)));

    const src_cspace = c.frame_table_cspace();
    const frame_cap = c.frame_page(frame_ref);
    const copy_err = c.cspace_copy(proc_cspace, slot, src_cspace, frame_cap, c.seL4_AllRights);
    if (copy_err != sel4.seL4_NoError) {
        _ = c.cspace_free_slot(proc_cspace, slot);
        c.free_frame(frame_ref);
        _ = c.printf("[vm_map] cspace_copy failed err=%d slot=%lu frame_ref=%lu\n", @as(c_int, copy_err), @as(c_ulong, @intCast(slot)), @as(c_ulong, @intCast(frame_ref)));
        return VmError.MapFailed;
    }
    _ = c.printf("[vm_map] copied frame cap slot=%lu frame_ref=%lu\n", @as(c_ulong, @intCast(slot)), @as(c_ulong, @intCast(frame_ref)));

    const rights = c.seL4_CapRights_new(
        0,
        0,
        if (readable) 1 else 0,
        if (writable) 1 else 0,
    );

    const attrs = c.seL4_ARM_Default_VMAttributes;
    const map_err = c.map_frame(proc_cspace, slot, proc_vspace, vaddr, rights, attrs);
    if (map_err != sel4.seL4_NoError) {
        _ = c.cspace_delete(proc_cspace, slot);
        _ = c.cspace_free_slot(proc_cspace, slot);
        c.free_frame(frame_ref);
        _ = c.printf("[vm_map] map_frame failed err=%d slot=%lu frame_ref=%lu vaddr=0x%lx\n", @as(c_int, map_err), @as(c_ulong, @intCast(slot)), @as(c_ulong, @intCast(frame_ref)), @as(c_ulong, @intCast(vaddr)));
        return VmError.MapFailed;
    }
    _ = c.printf("[vm_map] map_frame success slot=%lu frame_ref=%lu vaddr=0x%lx\n", @as(c_ulong, @intCast(slot)), @as(c_ulong, @intCast(frame_ref)), @as(c_ulong, @intCast(vaddr)));

    state.pages[state.mapped_count] = VmPage{
        .vaddr = vaddr,
        .frame_ref = frame_ref,
        .cap_slot = slot,
    };
    state.mapped_count += 1;
    _ = c.printf("[vm_map] recorded mapping idx=%lu vaddr=0x%lx frame_ref=%lu slot=%lu new_mapped_count=%lu\n", @as(c_ulong, @intCast(state.mapped_count - 1)), @as(c_ulong, @intCast(vaddr)), @as(c_ulong, @intCast(frame_ref)), @as(c_ulong, @intCast(slot)), @as(c_ulong, @intCast(state.mapped_count)));

    _ = executable; // executable currently unused in minimal implementation
}

fn brkImpl(caller: *sos.client_t, requested: usize) VmError!usize {
    const state = ensureVmState(caller);
    _ = c.printf("[vm_brk] enter caller=0x%lx requested=0x%lx heap_break=0x%lx mapped_end=0x%lx limit=0x%lx\n", @as(c_ulong, @intCast(@intFromPtr(caller))), @as(c_ulong, @intCast(requested)), @as(c_ulong, @intCast(state.heap_break)), @as(c_ulong, @intCast(state.heap_mapped_end)), @as(c_ulong, @intCast(HEAP_LIMIT)));

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
        mapAnonymousPage(state, caller, cursor, true, true, false) catch |err| {
            const err_code: c_int = vmErrorToErrno(err);
            _ = c.printf("[vm_brk] mapAnonymousPage failed cursor=0x%lx errno=%d\n", @as(c_ulong, @intCast(cursor)), err_code);
            return err;
        };
        _ = c.printf("[vm_brk] mapped cursor=0x%lx\n", @as(c_ulong, @intCast(cursor)));
    }

    state.heap_mapped_end = target_map_end;
    state.heap_break = requested;
    _ = c.printf("[vm_brk] updated state heap_break=0x%lx heap_mapped_end=0x%lx\n", @as(c_ulong, @intCast(state.heap_break)), @as(c_ulong, @intCast(state.heap_mapped_end)));
    return requested;
}

fn mmapImpl(caller: *sos.client_t, addr: usize, length: usize, prot: c_int, flags: c_int, fd: c_int, offset: usize) VmError!usize {
    _ = c.printf("[vm_mmap] enter caller=0x%lx addr=0x%lx length=0x%lx prot=0x%x flags=0x%x fd=%d offset=0x%lx\n", @as(c_ulong, @intCast(@intFromPtr(caller))), @as(c_ulong, @intCast(addr)), @as(c_ulong, @intCast(length)), prot, flags, fd, @as(c_ulong, @intCast(offset)));
    if (length == 0) {
        _ = c.printf("[vm_mmap] zero length invalid\n");
        return VmError.InvalidArgs;
    }
    if ((flags & c.MAP_ANONYMOUS) == 0 or (flags & c.MAP_PRIVATE) == 0) {
        _ = c.printf("[vm_mmap] unsupported flags combination flags=0x%x\n", flags);
        return VmError.Unsupported;
    }
    const unsupported_flags = flags & ~(c.MAP_ANONYMOUS | c.MAP_PRIVATE);
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

    const readable = (prot & c.PROT_READ) != 0;
    const writable = (prot & c.PROT_WRITE) != 0;
    const executable = (prot & c.PROT_EXEC) != 0;
    _ = c.printf("[vm_mmap] permissions read=%d write=%d exec=%d\n", @as(c_int, if (readable) 1 else 0), @as(c_int, if (writable) 1 else 0), @as(c_int, if (executable) 1 else 0));

    const state = ensureVmState(caller);
    if (state.mmap_next + aligned > MMAP_LIMIT) {
        _ = c.printf("[vm_mmap] exceeds limit mmap_next=0x%lx aligned=0x%lx limit=0x%lx\n", @as(c_ulong, @intCast(state.mmap_next)), @as(c_ulong, @intCast(aligned)), @as(c_ulong, @intCast(MMAP_LIMIT)));
        return VmError.Bounds;
    }

    const base = state.mmap_next;
    var cursor = base;
    const end_addr = base + aligned;
    _ = c.printf("[vm_mmap] base=0x%lx end=0x%lx\n", @as(c_ulong, @intCast(base)), @as(c_ulong, @intCast(end_addr)));
    while (cursor < end_addr) : (cursor += PAGE_SIZE_4K) {
        _ = c.printf("[vm_mmap] mapping cursor=0x%lx\n", @as(c_ulong, @intCast(cursor)));
        mapAnonymousPage(state, caller, cursor, readable, writable, executable) catch |err| {
            const err_code: c_int = vmErrorToErrno(err);
            _ = c.printf("[vm_mmap] mapAnonymousPage failed cursor=0x%lx errno=%d\n", @as(c_ulong, @intCast(cursor)), err_code);
            return err;
        };
        _ = c.printf("[vm_mmap] mapped cursor=0x%lx\n", @as(c_ulong, @intCast(cursor)));
    }

    state.mmap_next = end_addr;
    _ = c.printf("[vm_mmap] updated mmap_next=0x%lx returning base=0x%lx\n", @as(c_ulong, @intCast(state.mmap_next)), @as(c_ulong, @intCast(base)));
    return base;
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

fn findPage(state: *VmClientState, vaddr: usize) ?usize {
    var i: usize = 0;
    while (i < state.mapped_count) : (i += 1) {
        if (state.pages[i].vaddr == vaddr) return i;
    }
    return null;
}

fn handleVmFaultInternal(caller: *sos.client_t, fault_addr: usize, want_write: bool, is_fetch: bool) VmError!void {
    _ = want_write;
    _ = is_fetch;
    const state = ensureVmState(caller);
    const base = pageBase(fault_addr);

    if (findPage(state, base) != null) {
        return;
    }

    if (base >= HEAP_BASE and base < state.heap_break) {
        try mapAnonymousPage(state, caller, base, true, true, false);
        return;
    }

    if (base >= MMAP_BASE and base < state.mmap_next) {
        try mapAnonymousPage(state, caller, base, true, true, false);
        return;
    }

    return VmError.Unsupported;
}

pub export fn handle_vm_fault(
    badge: sel4.seL4_Word,
    message: [*c]const sel4.seL4_MessageInfo_t,
    caller: ?*sos.client_t,
) callconv(.c) bool {
    _ = badge;
    const caller_ptr = caller orelse return false;
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

    handleVmFaultInternal(caller_ptr, fault_addr, want_write, prefetch) catch |err| {
        _ = c.printf("[vm_fault] handler error=%d\n", vmErrorToErrno(err));
        return false;
    };
    return true;
}

/// Handle a singular syscall
pub export fn handle_syscall(
    /// The caller's badge
    badge: sel4.seL4_Word,
    /// The system call message
    message: [*c]const sel4.seL4_MessageInfo_t,
    /// Indicator to tell the syscall_loop that we have a reply to send back
    have_reply: [*c]bool,
    /// Identifier for who is calling
    caller: ?*sos.client_t,
    /// Pointer to the reply capability
    reply: [*c]sel4.seL4_CPtr,
    /// Untyped descriptor backing the reply capability
    reply_ut: [*c]*sos.ut_t,
) callconv(.c) sel4.seL4_MessageInfo_t {
    const msg = message.*;

    // Return empty reply on empty message
    if (sel4.seL4_MessageInfo_get_length(msg) == 0) {
        sel4.seL4_SetMR(0, 0);
        have_reply.* = true;
        return sel4.seL4_MessageInfo_new(0, 0, 0, 1);
    }

    // Otherwise, it's probably a proper syscall, so we deserialise it to figure out what it is.
    const syscall = libipc.Syscall.deserialise(msg) catch {
        have_reply.* = true;
        sel4.seL4_SetMR(0, encodeCInt(-c.EINVAL));
        return sel4.seL4_MessageInfo_new(0, 0, 0, 1);
    };

    var ctx = ServerContext{
        .badge = badge,
        .have_reply = have_reply,
        .caller = caller,
        .reply = reply,
        .reply_ut = reply_ut,
    };

    have_reply.* = true;
    // If it's a proper syscall....
    if (handleDecodedSyscall(&ctx, syscall)) |resp| {
        // ...then return its result.
        return resp.serialise();
    }

    // usleep's thing
    return sel4.seL4_MessageInfo_new(0, 0, 0, 0);
}

/// Switch on system call type to route to the correct handler
fn handleDecodedSyscall(ctx: *ServerContext, syscall: Syscall) ?SyscallResponse {
    return switch (syscall) {
        .Open => |args| handleOpen(ctx, args),
        .Close => |args| handleClose(ctx, args),
        .Read => |args| handleRead(ctx, args),
        .Write => |args| handleWrite(ctx, args),
        .Usleep => |args| handleUsleep(ctx, args),
        .Timestamp => handleTimestamp(ctx),
        .MyId => handleMyId(ctx),
        .Brk => |args| handleBrk(ctx, args),
        .Mmap => |args| handleMmap(ctx, args),
    };
}

fn handleOpen(ctx: *ServerContext, args: anytype) SyscallResponse {
    const caller = ctx.caller orelse {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-c.EINVAL)) } };
    };

    const client_id: usize = @intCast(caller.id);
    const client_id_u16 = @as(@TypeOf(sos.global_console.reader_owner_id), @intCast(client_id));
    if (client_id >= MAX_CLIENTS) {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-c.EINVAL)) } };
    }

    var state = &client_io_state[client_id];
    ensureStdio(state);

    const mode: c_int = @intCast(args.arg);
    const user_buf = args.buf_addr;
    const buf_len: usize = @intCast(args.buf_size);

    if (user_buf != PROCESS_SHBUF_UVA) {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-c.EINVAL)) } };
    }
    if (buf_len == 0 or buf_len > PAGE_SIZE_4K) {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-c.EMSGSIZE)) } };
    }

    const shared_ptr = sharedBufPtr(u8, caller);
    const max_copy = @min(buf_len, PAGE_SIZE_4K);
    const raw_len = c.strnlen(@as([*c]const u8, @ptrCast(shared_ptr)), max_copy);
    const name_len: usize = @intCast(raw_len);
    if (name_len == max_copy) {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-c.ENAMETOOLONG)) } };
    }
    if (name_len == 0) {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-c.EINVAL)) } };
    }

    var filename: [PAGE_SIZE_4K]u8 = undefined;
    std.mem.copyForwards(u8, filename[0..name_len], shared_ptr[0..name_len]);
    filename[name_len] = 0;

    const filename_ptr: [*c]const u8 = @ptrCast(&filename[0]);

    const expected = "console";
    if (name_len != expected.len or !std.mem.eql(u8, filename[0..name_len], expected)) {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-c.ENODEV)) } };
    }

    const accmode = mode & c.O_ACCMODE;
    const want_read = accmode == c.O_RDONLY or accmode == c.O_RDWR;
    const want_write = accmode == c.O_WRONLY or accmode == c.O_RDWR;
    if (!want_read and !want_write) {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-c.EINVAL)) } };
    }

    if (want_read and sos.global_console.reader_in_use) {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-c.EBUSY)) } };
    }

    var fd: c_int = -1;
    var i: usize = 0;
    while (i < SOS_MAX_OPEN_FILES) : (i += 1) {
        if (!state.fds[i].used) {
            fd = @intCast(i);
            break;
        }
    }
    if (fd < 0) {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-c.EMFILE)) } };
    }

    const ops = sos.vfs_lookup_ops(filename_ptr) orelse {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-c.ENODEV)) } };
    };

    var dev_id: c_int = 0;
    if (ops.*.open) |open_fn| {
        const ret = open_fn(filename_ptr, mode, &dev_id);
        if (ret < 0) {
            return SyscallResponse{ .Open = .{ .result = @as(c_int, (ret)) } };
        }
    }

    if (want_read) {
        sos.global_console.reader_in_use = true;
        sos.global_console.reader_owner_id = client_id_u16;
    }
    if (want_write) {
        sos.global_console.write_refcnt += 1;
    }

    const fd_index: usize = @intCast(fd);
    const slot = &state.fds[fd_index];
    setupConsoleFd(slot, ops, want_read, want_write, dev_id);

    return SyscallResponse{ .Open = .{ .result = @as(c_int, (fd)) } };
}

fn handleClose(ctx: *ServerContext, args: anytype) SyscallResponse {
    const caller = ctx.caller orelse {
        return SyscallResponse{ .Close = .{ .result = @as(c_int, (-c.EINVAL)) } };
    };
    const client_id: usize = @intCast(caller.id);
    const client_id_u16 = @as(@TypeOf(sos.global_console.reader_owner_id), @intCast(client_id));
    if (client_id >= MAX_CLIENTS) {
        return SyscallResponse{ .Close = .{ .result = @as(c_int, (-c.EINVAL)) } };
    }

    var state = &client_io_state[client_id];
    ensureStdio(state);
    if (!state.initialised) {
        return SyscallResponse{ .Close = .{ .result = @as(c_int, (-c.EBADF)) } };
    }

    const fd_raw: c_int = @intCast(args.arg);
    if (fd_raw < 0 or fd_raw >= SOS_MAX_OPEN_FILES) {
        return SyscallResponse{ .Close = .{ .result = @as(c_int, (-c.EBADF)) } };
    }

    if (fd_raw < 3) {
        return SyscallResponse{ .Close = .{ .result = @as(c_int, (0)) } };
    }

    const fd_index: usize = @intCast(fd_raw);
    const entry = &state.fds[fd_index];
    if (!entry.used) {
        return SyscallResponse{ .Close = .{ .result = @as(c_int, (-c.EBADF)) } };
    }
    if (entry.refcnt != 0) {
        return SyscallResponse{ .Close = .{ .result = @as(c_int, (-c.EBUSY)) } };
    }

    if (entry.kind == sos.FD_DEV_CONSOLE and entry.obj == console_object_ptr) {
        if (pending_console_read) |pending| {
            if (pending.client_id == client_id and pending.fd_index == fd_index) {
                pending.cancel(-c.ECANCELED);
            }
        }
        if (entry.readable and sos.global_console.reader_in_use and sos.global_console.reader_owner_id == client_id_u16) {
            sos.global_console.reader_in_use = false;
            sos.global_console.reader_owner_id = 0;
        }
        if (entry.writable and sos.global_console.write_refcnt > 0) {
            sos.global_console.write_refcnt -= 1;
        }
    }

    const ops_ptr = entry.ops;
    if (ops_ptr != null and ops_ptr.*.close != null) {
        _ = ops_ptr.*.close.?(entry.dev_id);
    }

    entry.* = empty_fd;
    return SyscallResponse{ .Close = .{ .result = @as(c_int, (0)) } };
}

fn handleRead(ctx: *ServerContext, args: anytype) ?SyscallResponse {
    const caller = ctx.caller orelse {
        return SyscallResponse{ .Read = .{ .result = @as(c_int, (-c.EINVAL)) } };
    };

    const client_id: usize = @intCast(caller.id);
    if (client_id >= MAX_CLIENTS) {
        return SyscallResponse{ .Read = .{ .result = @as(c_int, (-c.EINVAL)) } };
    }

    var state = &client_io_state[client_id];
    ensureStdio(state);
    if (!state.initialised) {
        return SyscallResponse{ .Read = .{ .result = @as(c_int, (-c.EBADF)) } };
    }

    const fd_raw: c_int = @intCast(args.arg);
    if (fd_raw < 0 or fd_raw >= SOS_MAX_OPEN_FILES) {
        return SyscallResponse{ .Read = .{ .result = @as(c_int, (-c.EBADF)) } };
    }

    const fd_index: usize = @intCast(fd_raw);
    const entry = &state.fds[fd_index];
    if (!entry.used or !entry.readable) {
        return SyscallResponse{ .Read = .{ .result = @as(c_int, (-c.EBADF)) } };
    }

    if (args.buf_addr != PROCESS_SHBUF_UVA) {
        return SyscallResponse{ .Read = .{ .result = @as(c_int, (-c.EINVAL)) } };
    }

    const req: usize = @intCast(args.buf_size);
    if (req == 0 or req > PAGE_SIZE_4K) {
        return SyscallResponse{ .Read = .{ .result = @as(c_int, (-c.EMSGSIZE)) } };
    }

    const dst_ptr = sharedBufPtr(u8, caller);
    const dst_any: *anyopaque = @ptrCast(dst_ptr);
    const ops_ptr = entry.ops;
    if (ops_ptr == null or ops_ptr.*.read == null) {
        return SyscallResponse{ .Read = .{ .result = @as(c_int, (-c.ENOSYS)) } };
    }
    const read_fn = ops_ptr.*.read.?;
    const result = read_fn(entry.dev_id, dst_any, req);
    if (result == -c.EWOULDBLOCK) {
        if (pending_console_read != null) {
            return SyscallResponse{ .Read = .{ .result = @as(c_int, (-c.EBUSY)) } };
        }

        const old_reply_cap = ctx.reply.*;
        const old_reply_ut = ctx.reply_ut.*;

        const new_reply_ut = sos.alloc_retype(ctx.reply, sel4.seL4_ReplyObject, sel4.seL4_ReplyBits);
        if (new_reply_ut == null) {
            ctx.reply.* = old_reply_cap;
            ctx.reply_ut.* = old_reply_ut;
            return SyscallResponse{ .Read = .{ .result = @as(c_int, (-c.ENOMEM)) } };
        }

        pending_console_read = PendingConsoleRead{
            .client = caller,
            .client_id = client_id,
            .fd_index = fd_index,
            .requested = req,
            .ops = ops_ptr,
            .dev_id = entry.dev_id,
            .reply = old_reply_cap,
            .reply_ut = old_reply_ut,
        };

        ctx.have_reply.* = false;
        ctx.reply_ut.* = new_reply_ut.?;
        if (pending_console_read) |pending| {
            pending.tryComplete();
        }
        return null;
    }

    const n = resultToCInt(result);
    return SyscallResponse{ .Read = .{ .result = n } };
}

fn handleWrite(ctx: *ServerContext, args: anytype) SyscallResponse {
    const caller = ctx.caller orelse {
        return SyscallResponse{ .Write = .{ .result = @as(c_int, (-c.EINVAL)) } };
    };

    const client_id: usize = @intCast(caller.id);
    if (client_id >= MAX_CLIENTS) {
        return SyscallResponse{ .Write = .{ .result = @as(c_int, (-c.EINVAL)) } };
    }

    var state = &client_io_state[client_id];
    ensureStdio(state);
    if (!state.initialised) {
        return SyscallResponse{ .Write = .{ .result = @as(c_int, (-c.EBADF)) } };
    }

    const fd_raw: c_int = @intCast(args.arg);
    if (fd_raw < 0 or fd_raw >= SOS_MAX_OPEN_FILES) {
        return SyscallResponse{ .Write = .{ .result = @as(c_int, (-c.EBADF)) } };
    }

    const fd_index: usize = @intCast(fd_raw);
    const entry = &state.fds[fd_index];
    if (!entry.used or !entry.writable) {
        return SyscallResponse{ .Write = .{ .result = @as(c_int, (-c.EBADF)) } };
    }

    if (args.buf_addr != PROCESS_SHBUF_UVA) {
        return SyscallResponse{ .Write = .{ .result = @as(c_int, (-c.EINVAL)) } };
    }

    const req: usize = @intCast(args.buf_size);
    if (req == 0 or req > PAGE_SIZE_4K) {
        return SyscallResponse{ .Write = .{ .result = @as(c_int, (-c.EMSGSIZE)) } };
    }

    const raw_src = sharedBufPtr(u8, caller);
    const src_ptr: [*]const u8 = @ptrCast(raw_src);
    const src_mut: [*]u8 = @constCast(src_ptr);
    const src_any: *anyopaque = @ptrCast(src_mut);
    const ops_ptr = entry.ops;
    if (ops_ptr == null or ops_ptr.*.write == null) {
        return SyscallResponse{ .Write = .{ .result = @as(c_int, (-c.ENOSYS)) } };
    }
    const write_fn = ops_ptr.*.write.?;
    const result = write_fn(entry.dev_id, src_any, req);
    const n: c_int = @intCast(result);
    return SyscallResponse{ .Write = .{ .result = @as(c_int, (n)) } };
}

fn handleTimestamp(ctx: *ServerContext) SyscallResponse {
    _ = ctx;
    const timestamp = sos.ts_get_timestamp();
    const value: i64 = @intCast(timestamp);
    return .{ .Timestamp = .{ .timestamp = value } };
}

fn handleMyId(ctx: *ServerContext) SyscallResponse {
    return .{ .MyId = .{ .pid = @intCast(ctx.badge) } };
}

fn handleBrk(ctx: *ServerContext, args: anytype) SyscallResponse {
    const caller_ptr_value: usize = if (ctx.caller) |ptr| @intFromPtr(ptr) else 0;
    _ = c.printf("[vm_brk] handleBrk badge=%lu new_break=0x%lx caller_ptr=0x%lx\n", @as(c_ulong, @intCast(ctx.badge)), @as(c_ulong, @intCast(args.new_break)), @as(c_ulong, @intCast(caller_ptr_value)));
    const caller = ctx.caller orelse {
        _ = c.printf("[vm_brk] handleBrk no caller context\n");
        return SyscallResponse{ .Brk = .{ .result = -@as(i64, c.EINVAL) } };
    };
    const requested: usize = @intCast(args.new_break);
    const result = brkImpl(caller, requested) catch |err| {
        const errno = vmErrorToErrno(err);
        _ = c.printf("[vm_brk] handleBrk error errno=%d\n", errno);
        return SyscallResponse{ .Brk = .{ .result = -@as(i64, errno) } };
    };
    _ = c.printf("[vm_brk] handleBrk success result=0x%lx\n", @as(c_ulong, @intCast(result)));
    return SyscallResponse{ .Brk = .{ .result = @as(i64, @intCast(result)) } };
}

fn handleMmap(ctx: *ServerContext, args: anytype) SyscallResponse {
    const caller = ctx.caller orelse {
        return SyscallResponse{ .Mmap = .{ .result = -@as(i64, c.EINVAL) } };
    };
    const addr: usize = @intCast(args.addr);
    const length: usize = @intCast(args.length);
    const prot: c_int = @intCast(wordToI64(args.prot));
    const flags: c_int = @intCast(wordToI64(args.flags));
    const fd: c_int = @intCast(wordToI64(args.fd));
    const offset: usize = @intCast(args.offset);

    const base = mmapImpl(caller, addr, length, prot, flags, fd, offset) catch |err| {
        const errno = vmErrorToErrno(err);
        return SyscallResponse{ .Mmap = .{ .result = -@as(i64, errno) } };
    };
    return SyscallResponse{ .Mmap = .{ .result = @as(i64, @intCast(base)) } };
}

fn handleUsleep(ctx: *ServerContext, args: anytype) ?SyscallResponse {
    const duration: isize = @bitCast(args.arg);
    const res = sos.ts_usleep(duration, ctx.reply.*, ctx.reply_ut.*);
    if (res < 0) {
        return SyscallResponse{ .Usleep = .{ .result = @as(c_int, (-c.EINVAL)) } };
    } else if (res == 1) {
        return SyscallResponse{ .Usleep = .{ .result = @as(c_int, (0)) } };
    }

    ctx.have_reply.* = false;
    const new_reply_ut = sos.alloc_retype(ctx.reply, sel4.seL4_ReplyObject, sel4.seL4_ReplyBits);
    if (new_reply_ut == null) {
        @panic("Failed to alloc new reply object");
    }
    ctx.reply_ut.* = new_reply_ut.?;
    return null;
}

fn encodeI64(value: i64) sel4.seL4_Word {
    return switch (@bitSizeOf(sel4.seL4_Word)) {
        64 => blk: {
            const unsigned: u64 = @bitCast(value);
            break :blk @as(sel4.seL4_Word, @bitCast(unsigned));
        },
        32 => blk: {
            const trunc: i32 = @truncate(value);
            const unsigned: u32 = @bitCast(trunc);
            break :blk @as(sel4.seL4_Word, @bitCast(unsigned));
        },
        else => @compileError("Unsupported seL4_Word size"),
    };
}

fn wordToI64(word: sel4.seL4_Word) i64 {
    return switch (@bitSizeOf(sel4.seL4_Word)) {
        64 => @bitCast(word),
        32 => blk: {
            const as_u32: u32 = @intCast(word);
            const as_i32: i32 = @bitCast(as_u32);
            break :blk @as(i64, as_i32);
        },
        else => @compileError("Unsupported seL4_Word size"),
    };
}

fn encodeCInt(value: c_int) sel4.seL4_Word {
    return encodeI64(@as(i64, value));
}

fn sharedBufPtr(comptime T: type, caller: *sos.client_t) [*]T {
    const shbuf = caller.shbuf orelse {
        std.debug.panic("caller missing shared buffer", .{});
    };
    const addr_value = sos.sos_shared_page_kernel_va(shbuf);
    if (addr_value == 0) {
        std.debug.panic("shared buffer has no kernel mapping", .{});
    }
    const addr: usize = @intCast(addr_value);
    return @ptrFromInt(addr);
}

fn setupConsoleFd(fd: *sos.sos_fd_entry_t, ops: *const sos.file_ops_t, readable: bool, writable: bool, dev_id: c_int) void {
    fd.* = empty_fd;
    fd.used = true;
    fd.readable = readable;
    fd.writable = writable;
    fd.kind = sos.FD_DEV_CONSOLE;
    fd.obj = console_object_ptr;
    fd.ops = ops;
    fd.dev_id = dev_id;
}

fn ensureStdio(state: *SosClientIoState) void {
    if (!state.initialised) {
        initStdio(state);
    }
}

fn initStdio(state: *SosClientIoState) void {
    state.* = SosClientIoState{};
    const ops = sos.vfs_lookup_ops(console_name_ptr) orelse {
        std.debug.panic("console device not registered", .{});
    };
    if (ops.*.open == null or ops.*.read == null or ops.*.write == null) {
        std.debug.panic("console device missing required operations", .{});
    }

    var id: c_int = 0;

    if (ops.*.open.?(console_name_ptr, c.O_RDONLY, &id) < 0) {
        std.debug.panic("console stdin open failed", .{});
    }
    setupConsoleFd(&state.fds[0], ops, true, false, id);

    if (ops.*.open.?(console_name_ptr, c.O_WRONLY, &id) < 0) {
        std.debug.panic("console stdout open failed", .{});
    }
    setupConsoleFd(&state.fds[1], ops, false, true, id);

    if (ops.*.open.?(console_name_ptr, c.O_WRONLY, &id) < 0) {
        std.debug.panic("console stderr open failed", .{});
    }
    setupConsoleFd(&state.fds[2], ops, false, true, id);

    state.initialised = true;
}

fn resultToCInt(value: isize) c_int {
    return std.math.cast(c_int, value) orelse {
        return if (value < 0) @as(c_int, (-c.EIO)) else std.math.maxInt(c_int);
    };
}

pub export fn sos_console_data_ready() callconv(.c) void {
    const pending = pending_console_read orelse return;
    pending.tryComplete();
}

const std = @import("std");
const libipc = @import("libipc");
const Syscall = libipc.Syscall;
const SyscallResponse = libipc.SyscallResponse;

const cimports = @import("cimports");
const c = cimports.c;
const sel4 = cimports.sel4;
const sos = cimports.sos;
const vm = @import("vm/mod.zig");

extern var cspace: sos.cspace_t;
