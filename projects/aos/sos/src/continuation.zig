/// Maximum serialised response size in seL4 message registers.
pub const MAX_RESPONSE_SIZE: usize = 64;

/// State specific to the type of operation being suspended.
pub const ContinuationState = union(enum) {
    /// Blocked read operation
    Read: struct {
        fd_index: usize,
        vm_handle: *vm.VmHandle,
        user_buf_addr: usize,
        requested: usize,
        ops: *const sos.file_ops_t,
        dev_id: c_int,
    },

    /// Timer sleep
    Timer: struct {
        timer_id: u32,
    },

    /// Custom state for miscellaneous operations
    Custom: struct {
        data: ?*anyopaque,
    },
};

/// What we are waiting on. Used to index into the appropriate wait queue.
pub const WaitOn = union(enum) {
    /// Waiting for I/O readiness on a file descriptor
    IO: struct {
        fd: c_int,
    },

    /// Waiting for a timer to expire.
    Timer: struct {
        id: u32,
    },

    /// Waiting for an interrupt
    IRQ: struct {
        badge: sel4.seL4_Word,
    },
};

/// Result of a continuation's resume function
pub const ContinuationResult = union(enum) {
    /// Operation completed successfully
    Complete: struct {
        /// Serialised syscall response
        response: sel4.seL4_MessageInfo_t,
    },

    /// Operation failed with an error
    Error: struct {
        errno: c_int,
    },

    /// Operation still blocked, re-enqueue continuation
    Retry,
};

/// Function pointer type for continuation resume logic.
/// Returns result via pointer parameter to avoid ABI issues with unions across C boundary.
pub const ResumeFn = *const fn (cont: *Continuation, event_data: ?*anyopaque, result: *ContinuationResult) callconv(.c) void;

/// A suspended syscall awaiting an asynchronous event
pub const Continuation = struct {
    /// Intrusive linked list pointer for wait queue management
    next: ?*Continuation,

    /// Client that initiated the syscall
    client: *sos.client_t,

    /// Reply capability to use when resuming
    reply: sel4.seL4_CPtr,

    /// Untyped memory backing the reply capability
    reply_ut: *sos.ut_t,

    /// Function to invoke when the awaited event occurs
    resume_fn: ResumeFn,

    /// Operation-specific state needed for resumption
    state: ContinuationState,

    /// Event type this continuation is waiting on
    wait_on: WaitOn,

    /// Send a successful reply to the client and clean up resources
    pub fn sendReply(self: *Continuation, response: sel4.seL4_MessageInfo_t) void {
        sel4.seL4_Send(self.reply, response);
        self.cleanup();
    }

    /// Send an error reply to the client and clean up resources.
    pub fn sendError(self: *Continuation, errno: c_int) void {
        // Construct a minimal error response.
        // The exact format depends on syscall type; for now we use a generic single-word response.
        sel4.seL4_SetMR(0, @bitCast(@as(i64, -@as(i64, errno))));
        const msg = sel4.seL4_MessageInfo_new(0, 0, 0, 1);
        sel4.seL4_Send(self.reply, msg);
        self.cleanup();
    }

    /// Clean up reply capability and untyped memory
    fn cleanup(self: *Continuation) void {
        _ = sos.cspace_delete(&cspace, self.reply);
        sos.cspace_free_slot(&cspace, self.reply);
        sos.ut_free(self.reply_ut);
    }
};

// Global cspace defined in main.c, accessible via extern.
extern var cspace: sos.cspace_t;

// A cache line on ARM64 is typically 64 bytes, `Continuation` should fit within a small number of cache lines to minimise memory overhead.
comptime {
    const cont_size = @sizeOf(Continuation);
    const state_size = @sizeOf(ContinuationState);
    const waiton_size = @sizeOf(WaitOn);
    const cache_line_size = 64;

    // Continuation should ideally fit within 2 cache lines.
    if (cont_size > 2 * cache_line_size) {
        @compileLog("Continuation is larger than two cache lines!");
    }

    // Ensure reasonable upper bounds to catch egregious layout issues.
    if (cont_size > 256) {
        @compileError("Continuation size exceeds 256 bytes; review field layout.");
    }

    // Sanity checks
    _ = state_size;
    _ = waiton_size;
    // _ = cache_line_size;
}
/// Maximum number of concurrent continuation objects
pub const CONT_POOL_SIZE: usize = 64;

/// Fixed-size slab allocator for continuation objects.
pub const ContinuationPool = struct {
    /// Pre-allocated array of continuation objects
    pool: [CONT_POOL_SIZE]Continuation,

    /// Head of the free list
    free_list: ?*Continuation,

    /// Count of currently allocated continuations
    in_use: usize,

    /// Global pool instance
    var global: ContinuationPool = undefined;
    var initialised: bool = false;

    /// Initialise the continuation pool by threading all entries into the free list.
    pub fn bootstrap() void {
        if (initialised) {
            _ = c.printf("[continuation] Pool already initialised, skipping bootstrap\n");
            return;
        }

        global.in_use = 0;
        global.free_list = null;

        // Thread all pool entries into the free list
        var i: usize = CONT_POOL_SIZE;
        while (i > 0) {
            i -= 1;
            global.pool[i].next = global.free_list;
            global.free_list = &global.pool[i];
        }

        initialised = true;
        _ = c.printf("[continuation] Pool bootstrapped: %u entries available\n", CONT_POOL_SIZE);
    }

    /// Allocate a continuation from the pool.
    pub fn alloc() ?*Continuation {
        if (global.free_list == null) {
            _ = c.printf("[continuation] ERROR: Pool exhausted (%u/%u in use)\n", global.in_use, CONT_POOL_SIZE);
            return null;
        }

        // Pop from free list head
        const cont = global.free_list.?;
        global.free_list = cont.next;
        global.in_use += 1;

        // Zero-initialize the continuation structure
        cont.* = std.mem.zeroes(Continuation);

        return cont;
    }

    /// Free a continuation back to the pool.
    pub fn free(cont: *Continuation) void {
        //  verify continuation is not already in the free list
        if (comptime std.debug.runtime_safety) {
            var cursor = global.free_list;
            while (cursor) |node| {
                if (node == cont) {
                    _ = c.printf("[continuation] FATAL: Double-free detected at %p\n", cont);
                    @panic("Continuation double-free");
                }
                cursor = node.next;
            }
        }

        // Push to free list head
        cont.next = global.free_list;
        global.free_list = cont;
        global.in_use -= 1;
    }

    /// Get current pool usage statistics
    pub fn getStats() struct { in_use: usize, capacity: usize } {
        return .{
            .in_use = global.in_use,
            .capacity = CONT_POOL_SIZE,
        };
    }
};

/// Maximum number of file descriptors that can have waiting continuations
pub const MAX_FDS: usize = 32;

/// Standard file descriptor for console stdin (FD 0)
pub const CONSOLE_STDIN_FD: c_int = 0;

/// Wait queues for different event types
pub const WaitQueues = struct {
    /// Per-FD queues for I/O readiness events
    io_queues: [MAX_FDS]?*Continuation,

    /// Global queue for timer expiry events
    timer_list: ?*Continuation,

    /// Global queue for IRQ events (future use)
    irq_list: ?*Continuation,

    /// Global wait queue instance
    var global: WaitQueues = .{
        .io_queues = [_]?*Continuation{null} ** MAX_FDS,
        .timer_list = null,
        .irq_list = null,
    };

    /// Enqueue a continuation to wait for I/O readiness on a file descriptor
    pub fn waitIO(cont: *Continuation, fd: c_int) void {
        const fd_usize: usize = @intCast(fd);
        if (fd_usize >= MAX_FDS) {
            _ = c.printf("[continuation] ERROR: Invalid FD %d (max %u)\n", fd, MAX_FDS);
            @panic("Invalid file descriptor for continuation");
        }

        // Prepend to the FD's wait queue
        cont.next = global.io_queues[fd_usize];
        global.io_queues[fd_usize] = cont;
        cont.wait_on = .{ .IO = .{ .fd = fd } };

        _ = c.printf("[continuation] Enqueued continuation for FD %d\n", fd);
    }

    /// Enqueue a continuation to wait for a timer to expire
    pub fn waitTimer(cont: *Continuation, timer_id: u32) void {
        cont.next = global.timer_list;
        global.timer_list = cont;
        cont.wait_on = .{ .Timer = .{ .id = timer_id } };

        _ = c.printf("[continuation] Enqueued continuation for timer %u\n", timer_id);
    }

    /// Resume all continuations waiting on I/O for a specific file descriptor
    pub fn resumeIO(fd: c_int, event_data: ?*anyopaque) void {
        const fd_usize: usize = @intCast(fd);
        if (fd_usize >= MAX_FDS) {
            _ = c.printf("[continuation] ERROR: Invalid FD %d in resumeIO\n", fd);
            return;
        }

        // Atomically dequeue entire list for this FD
        const head = global.io_queues[fd_usize];
        global.io_queues[fd_usize] = null;

        var cursor = head;
        var count: usize = 0;
        while (cursor) |cont| {
            const next = cont.next;
            resumeContinuation(cont, event_data);
            cursor = next;
            count += 1;
        }

        _ = c.printf("[continuation] Resumed %u continuations for FD %d\n", count, fd);
    }

    /// Resume a specific continuation waiting on a timer
    pub fn resumeTimer(timer_id: u32, event_data: ?*anyopaque) void {
        // Search the timer list for matching timer_id
        var prev: ?*Continuation = null;
        var cursor = global.timer_list;

        while (cursor) |cont| {
            // Check if this continuation is waiting on the specified timer
            if (cont.wait_on == .Timer and cont.wait_on.Timer.id == timer_id) {
                // Remove from list
                if (prev) |p| {
                    p.next = cont.next;
                } else {
                    global.timer_list = cont.next;
                }

                _ = c.printf("[continuation] Resuming continuation for timer %u\n", timer_id);
                resumeContinuation(cont, event_data);
                return;
            }

            prev = cont;
            cursor = cont.next;
        }

        _ = c.printf("[continuation] WARNING: No continuation found for timer %u\n", timer_id);
    }

    /// Resume a continuation by invoking its resume function
    fn resumeContinuation(cont: *Continuation, event_data: ?*anyopaque) void {
        var result: ContinuationResult = undefined;
        cont.resume_fn(cont, event_data, &result);

        switch (result) {
            .Complete => |r| {
                cont.sendReply(r.response);
                ContinuationPool.free(cont);
            },
            .Error => |e| {
                cont.sendError(e.errno);
                ContinuationPool.free(cont);
            },
            .Retry => {
                // Re-enqueue based on what we're waiting on
                switch (cont.wait_on) {
                    .IO => |io| waitIO(cont, io.fd),
                    .Timer => |timer| waitTimer(cont, timer.id),
                    .IRQ => {
                        _ = c.printf("[continuation] ERROR: IRQ retry not yet implemented\n");
                        cont.sendError(sos.ENOSYS);
                        ContinuationPool.free(cont);
                    },
                }
            },
        }
    }

    /// Cancel all continuations belonging to a specific client
    pub fn cancelClient(client: *sos.client_t) void {
        var cancelled: usize = 0;

        // Cancel all I/O wait queues
        for (&global.io_queues, 0..) |*queue, fd| {
            var prev: ?*Continuation = null;
            var cursor = queue.*;

            while (cursor) |cont| {
                const next = cont.next;

                if (cont.client == client) {
                    // Remove from list
                    if (prev) |p| {
                        p.next = next;
                    } else {
                        queue.* = next;
                    }

                    // Cleanup without sending reply (client is dead)
                    cont.cleanup();
                    ContinuationPool.free(cont);
                    cancelled += 1;

                    _ = c.printf("[continuation] Cancelled continuation for client on FD %u\n", fd);
                } else {
                    prev = cont;
                }

                cursor = next;
            }
        }

        // Cancel timer wait queue
        {
            var prev: ?*Continuation = null;
            var cursor = global.timer_list;

            while (cursor) |cont| {
                const next = cont.next;

                if (cont.client == client) {
                    // Remove from list
                    if (prev) |p| {
                        p.next = next;
                    } else {
                        global.timer_list = next;
                    }

                    // Cleanup without sending reply
                    cont.cleanup();
                    ContinuationPool.free(cont);
                    cancelled += 1;

                    _ = c.printf("[continuation] Cancelled timer continuation for client\n");
                } else {
                    prev = cont;
                }

                cursor = next;
            }
        }

        if (cancelled > 0) {
            _ = c.printf("[continuation] Cancelled %u total continuations for client %p\n", cancelled, client);
        }
    }
};

/// Initialise the continuation pool from C code.
pub export fn continuation_bootstrap() callconv(.c) void {
    ContinuationPool.bootstrap();
}

/// Resume continuations waiting on I/O for a file descriptor
pub export fn continuation_resume_io(fd: c_int) callconv(.c) void {
    WaitQueues.resumeIO(fd, null);
}

/// Resume a continuation waiting on a specific timer
pub export fn continuation_resume_timer(timer_id: u32) callconv(.c) void {
    WaitQueues.resumeTimer(timer_id, null);
}

/// Cancel all continuations belonging to a client
pub export fn continuation_cancel_client(client: *sos.client_t) callconv(.c) void {
    WaitQueues.cancelClient(client);
}

const cimports = @import("cimports");
const sos = cimports.sos;
const sel4 = cimports.sel4;
const c = cimports.c;

const std = @import("std");
const vm = @import("vm/mod.zig");
const libipc = @import("libipc");
