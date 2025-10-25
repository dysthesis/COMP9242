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

pub fn setupConsoleFd(fd: *sos.sos_fd_entry_t, ops: *const sos.file_ops_t, readable: bool, writable: bool, dev_id: c_int) void {
    fd.* = empty_fd;
    fd.used = true;
    fd.readable = readable;
    fd.writable = writable;
    fd.kind = sos.FD_DEV_CONSOLE;
    fd.obj = console_object_ptr;
    fd.ops = ops;
    fd.dev_id = dev_id;
}

pub fn ensureStdio(state: *SosClientIoState) void {
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

pub export fn sos_console_data_ready() callconv(.c) void {
    const pending = pending_console_read orelse return;
    pending.tryComplete();
}

pub const console_object_ptr: ?*anyopaque = @ptrCast(&sos.global_console);

const cimports = @import("cimports");
const sos = cimports.sos;
const sel4 = cimports.sel4;
const c = cimports.c;

const libipc = @import("libipc");
const SyscallResponse = libipc.SyscallResponse;

const helpers = @import("helpers.zig");
const resultToCInt = helpers.resultToCInt;
const sharedBufPtr = helpers.sharedBufPtr;

const super = @import("main.zig");

const file = @import("file.zig");
const empty_fd = file.empty_fd;
const SosClientIoState = file.SosClientIoState;
const console_name_ptr = file.console_name_ptr;

const std = @import("std");
