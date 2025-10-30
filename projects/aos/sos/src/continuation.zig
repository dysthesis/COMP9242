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
pub const ResumeFn = *const fn (cont: *Continuation, event_data: ?*anyopaque) callconv(.c) ContinuationResult;

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

const cimports = @import("cimports");
const sos = cimports.sos;
const sel4 = cimports.sel4;
const c = cimports.c;

const std = @import("std");
const vm = @import("vm/mod.zig");
const libipc = @import("libipc");
