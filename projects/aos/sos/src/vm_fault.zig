const cimports = @import("cimports");
const sel4 = cimports.sel4;
const sos = cimports.sos;
const c = cimports.c;

const vm = @import("vm/mod.zig");
const continuation = @import("continuation.zig");
const pager = @import("vm/pager.zig");
const region = @import("vm/region.zig");
const page = @import("vm/page.zig");

const VmFaultResult = vm.VmFaultResult;

pub export fn handle_vm_fault(
    vm_handle: *vm.VmHandle,
    badge: sel4.seL4_Word,
    message: [*c]const sel4.seL4_MessageInfo_t,
    have_reply: [*c]bool,
    reply: [*c]sel4.seL4_CPtr,
    reply_ut: [*c]*sos.ut_t,
) callconv(.c) VmFaultResult {
    _ = badge;
    vm_handle.validate();

    const info = message.*;
    if (sel4.seL4_MessageInfo_get_label(info) != sel4.seL4_Fault_VMFault) {
        return .fatal;
    }

    if (sel4.seL4_MessageInfo_get_length(info) < 2) {
        _ = c.printf(
            "[vm_fault] unexpected length=%lu\n",
            @as(c_ulong, sel4.seL4_MessageInfo_get_length(info)),
        );
        return .fatal;
    }

    const fault_addr_word = sel4.seL4_GetMR(sel4.seL4_VMFault_Addr);
    const fsr = sel4.seL4_GetMR(sel4.seL4_VMFault_FSR);
    const prefetch = sel4.seL4_GetMR(sel4.seL4_VMFault_PrefetchFault) != 0;
    const fault_addr: usize = @intCast(fault_addr_word);
    const want_write = (fsr & (1 << 6)) != 0;

    const addr_raw: c_ulong = @intCast(fault_addr);
    const fsr_raw: c_ulong = @intCast(fsr);
    _ = c.printf(
        "[vm_fault] addr=0x%lx fsr=0x%lx write=%d fetch=%d\n",
        @as(c_ulong, addr_raw),
        @as(c_ulong, fsr_raw),
        @as(c_int, if (want_write) 1 else 0),
        @as(c_int, if (prefetch) 1 else 0),
    );

    vm_handle.handleFault(fault_addr, want_write, prefetch) catch |err| {
        if (err == vm.VmError.Unsupported) {
            const attempt = tryDeferPager(
                vm_handle,
                fault_addr,
                want_write,
                prefetch,
                have_reply,
                reply,
                reply_ut,
            );
            if (attempt == .deferred) {
                return .deferred;
            }
        }

        _ = c.printf("[vm_fault] handler error=%d\n", vm.vmErrorToErrno(err));
        return .fatal;
    };

    return .handled;
}

fn tryDeferPager(
    vm_handle: *vm.VmHandle,
    fault_addr: usize,
    want_write: bool,
    prefetch: bool,
    have_reply: [*c]bool,
    reply: [*c]sel4.seL4_CPtr,
    reply_ut: [*c]*sos.ut_t,
) VmFaultResult {
    const page_base = vm.pageBase(fault_addr);
    const state = vm_handle.ensureVmState();

    const tracker = findPagerRegion(state, page_base) orelse {
        _ = c.printf("[pager] no region for addr=0x%lx\n", @as(c_ulong, @intCast(page_base)));
        return .fatal;
    };

    const cont = continuation.ContinuationPool.alloc() orelse {
        _ = c.printf("[pager] continuation pool exhausted for addr=0x%lx\n", @as(c_ulong, @intCast(page_base)));
        return .fatal;
    };

    const old_reply = reply.*;
    const old_reply_ut = reply_ut.*;
    const new_reply_ut = sos.alloc_retype(reply, sel4.seL4_ReplyObject, sel4.seL4_ReplyBits);
    if (new_reply_ut == null) {
        continuation.ContinuationPool.free(cont);
        reply.* = old_reply;
        reply_ut.* = old_reply_ut;
        _ = c.printf("[pager] failed to allocate replacement reply object\n");
        return .fatal;
    }

    cont.next = null;
    cont.client = vm_handle.getClient();
    cont.reply = old_reply;
    cont.reply_ut = old_reply_ut;
    initPageFaultContinuation(cont, vm_handle, fault_addr, want_write, prefetch);

    const enqueue_result = enqueuePagerWaiter(vm_handle, cont, tracker);
    const client_id: c_uint = @intCast(cont.client.id);
    switch (enqueue_result) {
        .Reserved => |info| {
            _ = c.printf("[pager] queued primary fill client=%u page=0x%lx\n", client_id, @as(c_ulong, @intCast(info.key.page_base)));
            // TODO: submit worker job for info.page once pager plumbing exists.
        },
        .Duplicate => |info| {
            _ = c.printf("[pager] dedup hit client=%u page=0x%lx\n", client_id, @as(c_ulong, @intCast(info.key.page_base)));
        },
        .TableFull, .QueueFailed, .InvalidRegion => {
            reply.* = old_reply;
            reply_ut.* = old_reply_ut;
            sos.ut_free(new_reply_ut.?);
            cont.cleanup();
            continuation.ContinuationPool.free(cont);
            return .fatal;
        },
    }

    have_reply.* = false;
    reply_ut.* = new_reply_ut.?;
    return .deferred;
}

fn findPagerRegion(state: *vm.client.Client, page_base: usize) ?*region.Region {
    return state.findMmapRegion(page_base);
}

pub const PagerWaiterResult = union(enum) {
    Reserved: struct {
        key: pager.PagerRequestTable.Key,
        page: *page.MappedPage,
    },
    Duplicate: struct {
        key: pager.PagerRequestTable.Key,
        page: *page.MappedPage,
    },
    TableFull,
    QueueFailed,
    InvalidRegion,
};

pub fn initPageFaultContinuation(
    cont: *continuation.Continuation,
    vm_handle: *vm.VmHandle,
    fault_addr: usize,
    want_write: bool,
    prefetch: bool,
) void {
    const page_base = vm.pageBase(fault_addr);
    cont.resume_fn = continuation.pageFaultResume;
    cont.state = .{
        .PageFault = .{
            .vm_handle = vm_handle,
            .fault_addr = fault_addr,
            .page_base = page_base,
            .want_write = want_write,
            .prefetch = prefetch,
        },
    };

    const client_id: u32 = @intCast(vm_handle.getClient().*.id);
    cont.wait_on = .{ .Page = .{ .client_id = client_id, .page_base = page_base } };
}

pub fn enqueuePagerWaiter(
    vm_handle: *vm.VmHandle,
    cont: *continuation.Continuation,
    tracker: ?*region.Region,
) PagerWaiterResult {
    if (tracker == null) {
        return .InvalidRegion;
    }

    const pf_state = cont.state.PageFault;
    const state = vm_handle.ensureVmState();
    const mapped_page = state.ensurePageRecord(pf_state.page_base, tracker.?) catch {
        return .QueueFailed;
    };

    const cont_ptr: *anyopaque = @ptrCast(cont);
    if (!mapped_page.waiters.enqueue(&cont.state.PageFault.wait_node, cont_ptr)) {
        return .QueueFailed;
    }

    const client = vm_handle.getClient();
    const key = pager.PagerRequestTable.Key{
        .client_id = @intCast(client.id),
        .page_base = pf_state.page_base,
    };

    const table = pager.global();
    return switch (table.reserve(key)) {
        .Inserted => .{ .Reserved = .{ .key = key, .page = mapped_page } },
        .Duplicate => .{ .Duplicate = .{ .key = key, .page = mapped_page } },
        .TableFull => blk: {
            _ = mapped_page.waiters.remove(cont_ptr);
            cont.state.PageFault.wait_node.clear();
            break :blk .TableFull;
        },
    };
}
