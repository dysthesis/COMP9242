pub var pending_console_read: ?PendingConsoleRead = null;

pub const PendingConsoleRead = struct {
    client: *sos.client_t,
    client_id: usize,
    fd_index: usize,
    requested: usize,
    ops: *const sos.file_ops_t,
    dev_id: c_int,
    reply: sel4.seL4_CPtr,
    reply_ut: *sos.ut_t,

    pub fn cancel(self: PendingConsoleRead, err: c_int) void {
        pending_console_read = null;
        self.complete(@as(isize, err));
    }

    fn complete(self: PendingConsoleRead, result: isize) void {
        const resp = SyscallResponse{ .Read = .{ .result = resultToCInt(result) } };
        const msg = resp.serialise();
        sel4.seL4_Send(self.reply, msg);
        _ = sos.cspace_delete(&super.cspace, self.reply);
        sos.cspace_free_slot(&super.cspace, self.reply);
        sos.ut_free(self.reply_ut);
    }
    pub fn tryComplete(self: PendingConsoleRead) void {
        if (self.client_id >= file.client_io_state.len) {
            pending_console_read = null;
            self.complete(@as(isize, -sos.EINVAL));
            return;
        }

        var state = &file.client_io_state[self.client_id];
        if (!state.initialised) {
            pending_console_read = null;
            self.complete(@as(isize, -sos.EBADF));
            return;
        }

        const entry = &state.fds[self.fd_index];
        if (!entry.used or !entry.readable or entry.ops != self.ops) {
            pending_console_read = null;
            self.complete(@as(isize, -sos.EBADF));
            return;
        }

        const read_fn = self.ops.*.read orelse {
            pending_console_read = null;
            self.complete(@as(isize, -sos.ENOSYS));
            return;
        };

        const dst_ptr = sharedBufPtr(u8, self.client);
        const dst_any: *anyopaque = @ptrCast(dst_ptr);
        const result = read_fn(self.dev_id, dst_any, self.requested);
        if (result == -sos.EWOULDBLOCK) {
            return;
        }

        pending_console_read = null;
        self.complete(result);
    }
};

const cimports = @import("cimports");
const sos = cimports.sos;
const sel4 = cimports.sel4;

const libipc = @import("libipc");
const SyscallResponse = libipc.SyscallResponse;

const helpers = @import("helpers.zig");
const resultToCInt = helpers.resultToCInt;
const sharedBufPtr = helpers.sharedBufPtr;

const super = @import("main.zig");

const file = @import("file.zig");
