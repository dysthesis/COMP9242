pub fn setupConsoleFd(fd: *file.File, ops: *const file.FileOps, readable: bool, writable: bool, dev_id: c_int) void {
    fd.* = empty_fd;
    fd.used = true;
    fd.readable = readable;
    fd.writable = writable;
    fd.kind = file.FileKind.dev_console;
    fd.obj = console_object_ptr;
    fd.ops = ops;
    fd.dev_id = dev_id;
    fd.refcnt = 1;
    fd.offset = 0;
}

pub const ConsoleAccessError = error{Busy};

pub fn acquireConsoleAccess(client_id: u16, readable: bool, writable: bool) ConsoleAccessError!void {
    if (readable) {
        if (sos.global_console.reader_in_use) {
            return ConsoleAccessError.Busy;
        }
        sos.global_console.reader_in_use = true;
        sos.global_console.reader_owner_id = client_id;
    }
    if (writable) {
        sos.global_console.write_refcnt += 1;
    }
}

pub fn releaseConsoleAccess(client_id: u16, entry: *file.File) void {
    if (entry.readable and sos.global_console.reader_in_use and sos.global_console.reader_owner_id == client_id) {
        sos.global_console.reader_in_use = false;
        sos.global_console.reader_owner_id = 0;
    }
    if (entry.writable and sos.global_console.write_refcnt > 0) {
        sos.global_console.write_refcnt -= 1;
    }
}

pub fn ensureStdio(state: *SosClientIoState, client_id: u16) void {
    if (!state.initialised) {
        initStdio(state, client_id);
    }
}

fn initStdio(state: *SosClientIoState, client_id: u16) void {
    state.reset();
    state.fds[0] = empty_fd;
    state.fds[0].used = true;
    const ops = file.vfs_lookup_ops(console_name_ptr) orelse {
        std.debug.panic("console device not registered", .{});
    };
    if (ops.*.open == null or ops.*.read == null or ops.*.write == null) {
        std.debug.panic("console device missing required operations", .{});
    }

    var id: c_int = 0;

    if (ops.*.open.?(console_name_ptr, c.O_WRONLY, &id) < 0) {
        std.debug.panic("console stdout open failed", .{});
    }
    setupConsoleFd(&state.fds[1], ops, false, true, id);
    acquireConsoleAccess(client_id, false, true) catch unreachable;
    const stdout_handle: file.FileHandle = @ptrCast(&state.fds[1]);
    const stdout_fd = state.file_table.allocFd(stdout_handle) catch unreachable;
    std.debug.assert(stdout_fd == 1);

    if (ops.*.open.?(console_name_ptr, c.O_WRONLY, &id) < 0) {
        std.debug.panic("console stderr open failed", .{});
    }
    setupConsoleFd(&state.fds[2], ops, false, true, id);
    acquireConsoleAccess(client_id, false, true) catch unreachable;
    const stderr_handle: file.FileHandle = @ptrCast(&state.fds[2]);
    const stderr_fd = state.file_table.allocFd(stderr_handle) catch unreachable;
    std.debug.assert(stderr_fd == 2);

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
