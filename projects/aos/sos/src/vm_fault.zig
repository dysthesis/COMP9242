const cimports = @import("cimports");
const sel4 = cimports.sel4;
const sos = cimports.sos;
const c = cimports.c;

const vm = @import("vm/mod.zig");
const continuation = @import("continuation.zig");
const pager = @import("vm/pager.zig");
const region = @import("vm/region.zig");
const page = @import("vm/page.zig");
const worker = @import("worker.zig");

extern fn pagefile_free_slot(slot: u32) void;

const VmFaultResult = vm.VmFaultResult;

const PagerInstrumentation = struct {
    deferred_faults: usize = 0,
    dedup_hits: usize = 0,
    job_submissions: usize = 0,
    job_completions: usize = 0,
    job_failures: usize = 0,
};

var pager_stats: PagerInstrumentation = .{};
var last_logged_completions: usize = 0;

pub fn pagerStatsSnapshot() PagerInstrumentation {
    return pager_stats;
}

const MAX_PAGER_JOBS = pager.MAX_PAGER_REQUESTS;
const PagerJobMeta = struct {
    key: pager.PagerRequestTable.Key,
    page: *page.MappedPage,
    tracker: *region.Region,
    vm_handle: *vm.VmHandle,
};

var pager_job_states: [MAX_PAGER_JOBS]worker.FileOpState = undefined;
var pager_job_used: [MAX_PAGER_JOBS]bool = [_]bool{false} ** MAX_PAGER_JOBS;
var pager_job_meta: [MAX_PAGER_JOBS]?PagerJobMeta = [_]?PagerJobMeta{null} ** MAX_PAGER_JOBS;

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
            // Propagate result from pager (handled, deferred, or fatal)
            return attempt;
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

    pager_stats.deferred_faults += 1;

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
            submitPageFillJob(vm_handle, info.page, cont, info.tracker, info.key) catch {
                rollbackWaiter(info.key, info.page, cont);
                reply.* = old_reply;
                reply_ut.* = old_reply_ut;
                sos.ut_free(new_reply_ut.?);
                pager_stats.job_failures += 1;
                return .fatal;
            };
            pager_stats.job_submissions += 1;
        },
        .Duplicate => |info| {
            _ = c.printf("[pager] dedup hit client=%u page=0x%lx\n", client_id, @as(c_ulong, @intCast(info.key.page_base)));
            pager_stats.dedup_hits += 1;
        },
        .TableFull, .QueueFailed, .InvalidRegion => {
            reply.* = old_reply;
            reply_ut.* = old_reply_ut;
            sos.ut_free(new_reply_ut.?);
            cont.cleanup();
            continuation.ContinuationPool.free(cont);
            pager_stats.job_failures += 1;
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

fn submitPageFillJob(
    vm_handle: *vm.VmHandle,
    mapped_page: *page.MappedPage,
    cont: *continuation.Continuation,
    tracker: *region.Region,
    key: pager.PagerRequestTable.Key,
) !void {
    const slot = acquirePagerJobSlot() orelse {
        pager_stats.job_failures += 1;
        return error.JobPoolExhausted;
    };
    cont.state.PageFault.job_slot = slot.index;

    pager_job_meta[slot.index] = .{
        .key = key,
        .page = mapped_page,
        .tracker = tracker,
        .vm_handle = vm_handle,
    };

    var job = slot.state;
    job.reset();
    var source: worker.PageFillSource = .Anonymous;
    if (mapped_page.state == page.PageState.SWAPPED and mapped_page.pagefile_slot >= 0) {
        _ = c.printf("[pager] submitPageFillJob: swap-in slot=%d\n", mapped_page.pagefile_slot);
        mapped_page.transitionState(.PAGEIN_PENDING);
        source = .{ .Pagefile = .{ .slot = @intCast(mapped_page.pagefile_slot) } };
    } else switch (tracker.backing) {
        .Anonymous => {},
        .File => |info| {
            if (info.handle_ref) |handle_ptr| {
                var delta: usize = 0;
                if (key.page_base >= tracker.start) {
                    delta = key.page_base - tracker.start;
                }
                const file_offset = info.offset + delta;
                _ = c.printf("[pager] submitPageFillJob: file-backed fd=%d offset=%zu handle_ref=%p\n", info.fd, file_offset, handle_ptr);
                source = .{ .File = .{
                    .fd = info.fd,
                    .file_offset = file_offset,
                    .length = vm.PAGE_SIZE_4K,
                    .handle_ref = handle_ptr,
                } };
            } else {
                _ = c.printf("[pager] submitPageFillJob: WARNING file region has no handle_ref\n");
            }
        },
    }
    job.params = .{ .PageFill = .{
        .client_id = @intCast(vm_handle.getClient().id),
        .page_base = key.page_base,
        .prot = tracker.prot(),
        .region_kind = tracker.attr.kind,
        .want_write = cont.state.PageFault.want_write,
        .prefetch = cont.state.PageFault.prefetch,
        .source = source,
    } };
    job.vm_handle = vm_handle;
    job.payload_len = 0;

    const rc = worker.workerEnqueue(job);
    if (rc < 0) {
        _ = c.printf("[pager] submitPageFillJob: enqueue failed rc=%d\n", rc);
        pager_job_meta[slot.index] = null;
        releasePagerJobSlot(slot.index);
        cont.state.PageFault.job_slot = null;
        return error.QueueFull;
    }
    _ = c.printf("[pager] submitPageFillJob: enqueued successfully rc=%d\n", rc);
}

fn rollbackWaiter(
    key: pager.PagerRequestTable.Key,
    mapped_page: *page.MappedPage,
    cont: *continuation.Continuation,
) void {
    const table = pager.global();
    _ = table.release(key);
    const cont_ptr: *anyopaque = @ptrCast(cont);
    _ = mapped_page.waiters.remove(cont_ptr);
    cont.state.PageFault.wait_node.clear();
    if (cont.state.PageFault.job_slot) |idx| {
        pager_job_meta[idx] = null;
        releasePagerJobSlot(idx);
        cont.state.PageFault.job_slot = null;
    }
}

const PagerJobSlot = struct {
    index: usize,
    state: *worker.FileOpState,
};

fn acquirePagerJobSlot() ?PagerJobSlot {
    for (&pager_job_used, 0..) |*used, idx| {
        if (!used.*) {
            used.* = true;
            return PagerJobSlot{ .index = idx, .state = &pager_job_states[idx] };
        }
    }
    return null;
}

fn releasePagerJobSlot(idx: usize) void {
    if (idx >= pager_job_used.len) return;
    pager_job_used[idx] = false;
    pager_job_meta[idx] = null;
}

pub fn pagerPollCompletions() void {
    var found_completed: usize = 0;
    for (&pager_job_used, 0..) |used, idx| {
        if (!used) continue;
        const job_state = &pager_job_states[idx];
        if (!job_state.isCompleted()) continue;
        found_completed += 1;
        _ = c.printf("[pager] pagerPollCompletions: found completed job idx=%zu\n", idx);
        processPagerJob(idx, job_state);
    }
    if (found_completed > 0) {
        _ = c.printf("[pager] pagerPollCompletions: processed %zu completed jobs\n", found_completed);
    }

    // Log stats when completions crosses a multiple of 8, not every poll
    if (pager_stats.job_completions != last_logged_completions and
        pager_stats.job_completions % 8 == 0)
    {
        logPagerStats();
        last_logged_completions = pager_stats.job_completions;
    }
}

fn logPagerStats() void {
    _ = c.printf(
        "[pager] stats: deferred=%lu dedup=%lu submissions=%lu completions=%lu failures=%lu active=%lu\n",
        @as(c_ulong, @intCast(pager_stats.deferred_faults)),
        @as(c_ulong, @intCast(pager_stats.dedup_hits)),
        @as(c_ulong, @intCast(pager_stats.job_submissions)),
        @as(c_ulong, @intCast(pager_stats.job_completions)),
        @as(c_ulong, @intCast(pager_stats.job_failures)),
        @as(c_ulong, @intCast(activePagerJobs())),
    );
}

fn activePagerJobs() usize {
    var count: usize = 0;
    for (pager_job_used) |used| {
        if (used) count += 1;
    }
    return count;
}

fn processPagerJob(idx: usize, job_state: *worker.FileOpState) void {
    _ = c.printf("[pager] processPagerJob: idx=%zu\n", idx);
    const meta = pager_job_meta[idx] orelse {
        _ = c.printf("[pager] processPagerJob: no meta for idx=%zu\n", idx);
        job_state.reset();
        releasePagerJobSlot(idx);
        return;
    };

    _ = c.printf("[pager] processPagerJob: page=0x%lx\n", @as(c_ulong, @intCast(meta.key.page_base)));
    var resume_errno: c_int = 0;
    switch (job_state.result) {
        .Status => |value| {
            if (value != 0) {
                resume_errno = value;
            }
        },
        .Errno => |errno| resume_errno = errno,
        else => resume_errno = sos.EIO,
    }

    if (resume_errno == 0) {
        _ = c.printf("[pager] processPagerJob: installing result\n");
        resume_errno = installPagerResult(meta, job_state);
        _ = c.printf("[pager] processPagerJob: install returned errno=%d\n", resume_errno);
    } else {
        _ = c.printf("[pager] processPagerJob: skipping install due to errno=%d\n", resume_errno);
        // On failure, reset page state so the next fault can retry cleanly.
        if (meta.page.state == page.PageState.PAGEIN_PENDING) {
            meta.page.transitionState(page.PageState.SWAPPED);
            meta.page.pagefile_slot = -1;
            meta.page.referenced = false;
            meta.page.dirty = false;
        }
    }

    finalisePagerJob(idx, meta, resume_errno);
}

fn installPagerResult(meta: PagerJobMeta, job_state: *worker.FileOpState) c_int {
    const vm_handle = meta.vm_handle;
    const page_base = meta.key.page_base;
    const tracker = meta.tracker;
    const state = vm_handle.ensureVmState();

    if (meta.page.state == page.PageState.SWAPPED) {
        meta.page.transitionState(page.PageState.PAGEIN_PENDING);
    } else if (meta.page.state != page.PageState.PAGEIN_PENDING) {
        return sos.EINVAL;
    }

    state.mapAnonymousPage(vm_handle, page_base, tracker) catch |err| {
        return vm.vmErrorToErrno(err);
    };

    const payload = job_state.payloadSlice();
    if (payload.len > 0) {
        vm_handle.copyToClient(payload, page_base) catch |err| {
            return vm.vmErrorToErrno(err);
        };
    }

    if (meta.page.pagefile_slot >= 0) {
        pagefile_free_slot(@intCast(meta.page.pagefile_slot));
        meta.page.pagefile_slot = -1;
    }
    meta.page.dirty = false;
    meta.page.referenced = false;
    meta.page.transitionState(page.PageState.RESIDENT);

    return 0;
}

fn finalisePagerJob(idx: usize, meta: PagerJobMeta, errno: c_int) void {
    _ = c.printf("[pager] finalizePagerJob: idx=%zu errno=%d\n", idx, errno);
    const table = pager.global();
    _ = table.release(meta.key);

    // Check wait queue state before detaching
    const waiter_count = meta.page.waiters.count;
    _ = c.printf("[pager] finalizePagerJob: page=0x%lx waiter_count=%u\n", @as(c_ulong, @intCast(meta.key.page_base)), @as(c_uint, waiter_count));

    const wait_head = meta.page.waiters.detachAll();
    const head_ptr = if (wait_head) |h| @intFromPtr(h) else 0;
    _ = c.printf("[pager] finalizePagerJob: detached wait_head=0x%lx\n", @as(c_ulong, head_ptr));

    continuation.resumePageWaiters(wait_head, errno);
    _ = c.printf("[pager] finalisePagerJob: resumePageWaiters returned\n");

    pager_job_states[idx].reset();
    releasePagerJobSlot(idx);
    pager_stats.job_completions += 1;
}

pub const PagerWaiterResult = union(enum) {
    Reserved: struct {
        key: pager.PagerRequestTable.Key,
        page: *page.MappedPage,
        tracker: *region.Region,
    },
    Duplicate: struct {
        key: pager.PagerRequestTable.Key,
        page: *page.MappedPage,
        tracker: *region.Region,
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

    // Log before enqueue attempt
    _ = c.printf("[pager] enqueuePagerWaiter: page=0x%lx cont=%p current_waiters=%u\n", @as(c_ulong, @intCast(pf_state.page_base)), cont, @as(c_uint, mapped_page.waiters.count));

    const cont_ptr: *anyopaque = @ptrCast(cont);
    if (!mapped_page.waiters.enqueue(&cont.state.PageFault.wait_node, cont_ptr)) {
        _ = c.printf("[pager] enqueuePagerWaiter: FAILED to enqueue continuation %p\n", cont);
        return .QueueFailed;
    }

    // Log successful enqueue
    _ = c.printf("[pager] enqueuePagerWaiter: SUCCESS enqueued cont=%p, new_count=%u\n", cont, @as(c_uint, mapped_page.waiters.count));

    const client = vm_handle.getClient();
    const key = pager.PagerRequestTable.Key{
        .client_id = @intCast(client.id),
        .page_base = pf_state.page_base,
    };

    const table = pager.global();
    return switch (table.reserve(key)) {
        .Inserted => .{ .Reserved = .{ .key = key, .page = mapped_page, .tracker = tracker.? } },
        .Duplicate => .{ .Duplicate = .{ .key = key, .page = mapped_page, .tracker = tracker.? } },
        .TableFull => blk: {
            _ = mapped_page.waiters.remove(cont_ptr);
            cont.state.PageFault.wait_node.clear();
            break :blk .TableFull;
        },
    };
}
