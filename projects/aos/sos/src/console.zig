pub fn setupConsoleFd(fd: *file.File, ops: *const file.FileOps, readable: bool, writable: bool, dev_id: c_int) void {
    fd.* = empty_fd;
    fd.used = true;
    fd.readable = readable;
    fd.writable = writable;
    fd.kind = file.FileKind.dev_console;
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
    const ops = file.vfs_lookup_ops(console_name_ptr) orelse {
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
    continuation.continuation_resume_io(continuation.CONSOLE_STDIN_FD);
}

pub const console_object_ptr: ?*anyopaque = @ptrCast(&sos.global_console);

const cimports = @import("cimports");
const sos = cimports.sos;
const c = cimports.c;

const file = @import("file.zig");
const empty_fd = file.empty_fd;
const SosClientIoState = file.ClientIoState;
const console_name_ptr = file.console_name_ptr;

const continuation = @import("continuation.zig");

const std = @import("std");
