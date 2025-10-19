const std = @import("std");
const ipc = @import("libipc");

const Syscall = ipc.Syscall;
const SyscallResponse = ipc.SyscallResponse;
const SyscallCallError = ipc.SyscallCallError;

const cimports = @import("cimports");
const sel4 = cimports.sel4;
const c = cimports.c;
const sos = cimports.sos;
const sos_types = cimports.sos_types;

pub export var sos_errno: c_int = 0;

const MAX_IO_BUF: usize = 0x1000;
const PROCESS_SHBUF_ADDR: usize = 0xC0000000;
const PROCESS_SHBUF_WORD: sel4.seL4_Word = @intCast(PROCESS_SHBUF_ADDR);
const SOS_IPC_EP_CAP: sel4.seL4_CPtr = 0x1;
const INT_MAX_USIZE: usize = @intCast(std.math.maxInt(c_int));

fn sharedBuffer() [*]u8 {
    return @as([*]u8, @ptrFromInt(PROCESS_SHBUF_ADDR));
}

fn setErrno(code: c_int) c_int {
    sos_errno = code;
    return -1;
}

fn clearErrno() void {
    sos_errno = 0;
}

fn handleCallError(err: SyscallCallError) c_int {
    switch (err) {
        error.EmptyReply, error.HasExtraCaps => {},
    }
    return setErrno(sos.EINVAL);
}

fn handleCallErrorVoid(err: SyscallCallError) void {
    _ = handleCallError(err);
}

fn signedIntToWord(value: anytype) sel4.seL4_Word {
    const info = @typeInfo(@TypeOf(value));
    if (info != .int or info.int.signedness != .signed) {
        @compileError("signedIntToWord expects a signed integer");
    }
    return switch (@bitSizeOf(sel4.seL4_Word)) {
        64 => blk: {
            const as_i64: i64 = @intCast(value);
            const raw: u64 = @bitCast(as_i64);
            const word: sel4.seL4_Word = @bitCast(raw);
            break :blk word;
        },
        32 => blk: {
            const as_i32: i32 = @intCast(value);
            const raw: u32 = @bitCast(as_i32);
            const word: sel4.seL4_Word = @bitCast(raw);
            break :blk word;
        },
        else => @compileError("Unsupported seL4_Word size"),
    };
}

fn usizeToWord(value: usize) sel4.seL4_Word {
    return switch (@bitSizeOf(sel4.seL4_Word)) {
        64 => @intCast(value),
        32 => @intCast(value),
        else => @compileError("Unsupported seL4_Word size"),
    };
}

fn strnlen(ptr: [*]const u8, max: usize) usize {
    var i: usize = 0;
    while (i < max) : (i += 1) {
        if (ptr[i] == 0) break;
    }
    return i;
}

fn handleResult(result: c_int) c_int {
    if (result < 0) {
        sos_errno = -result;
        return -1;
    }
    clearErrno();
    return result;
}

pub export fn sos_open(path: [*c]const u8, mode: c_int) callconv(.c) c_int {
    if (path == null) {
        return setErrno(sos.EINVAL);
    }

    const path_bytes: [*]const u8 = @ptrCast(path);
    const len = strnlen(path_bytes, MAX_IO_BUF);
    if (len >= MAX_IO_BUF) {
        return setErrno(sos.ENAMETOOLONG);
    }

    const copy_len = len + 1;
    const shbuf = sharedBuffer();
    std.mem.copyForwards(u8, shbuf[0..copy_len], path_bytes[0..copy_len]);

    const syscall = Syscall{
        .Open = .{
            .arg = signedIntToWord(mode),
            .buf_addr = PROCESS_SHBUF_WORD,
            .buf_size = @as(sel4.seL4_Word, @intCast(copy_len)),
        },
    };

    const reply = syscall.call(SOS_IPC_EP_CAP) catch |err| return handleCallError(err);
    return switch (reply) {
        .Open => |payload| handleResult(payload.result),
        else => unreachable,
    };
}

pub export fn sos_close(file: c_int) callconv(.c) c_int {
    const syscall = Syscall{
        .Close = .{
            .arg = signedIntToWord(file),
        },
    };

    const reply = syscall.call(SOS_IPC_EP_CAP) catch |err| return handleCallError(err);
    return switch (reply) {
        .Close => |payload| handleResult(payload.result),
        else => unreachable,
    };
}

pub export fn sos_read(file: c_int, buf: [*c]u8, nbyte: usize) callconv(.c) c_int {
    if (buf == null) {
        return setErrno(sos.EINVAL);
    }
    if (nbyte == 0) {
        clearErrno();
        return 0;
    }

    const buf_ptr: [*]u8 = @ptrCast(buf);
    const limit = if (nbyte > INT_MAX_USIZE) INT_MAX_USIZE else nbyte;

    var total: usize = 0;
    while (total < limit) {
        var req = limit - total;
        if (req > MAX_IO_BUF) {
            req = MAX_IO_BUF;
        }
        if (req == 0) break;

        const syscall = Syscall{
            .Read = .{
                .arg = signedIntToWord(file),
                .buf_addr = PROCESS_SHBUF_WORD,
                .buf_size = @as(sel4.seL4_Word, @intCast(req)),
            },
        };

        const reply = syscall.call(SOS_IPC_EP_CAP) catch |err| return handleCallError(err);
        const res = switch (reply) {
            .Read => |payload| payload.result,
            else => unreachable,
        };

        if (res < 0) {
            sos_errno = -res;
            return -1;
        }
        if (res == 0) {
            break;
        }

        const chunk: usize = @intCast(res);
        const source = sharedBuffer()[0..chunk];
        std.mem.copyForwards(u8, buf_ptr[total..][0..chunk], source);

        total += chunk;
        if (chunk < req) {
            break;
        }
    }

    clearErrno();
    return @as(c_int, @intCast(total));
}

pub export fn sos_write(file: c_int, buf: [*c]const u8, nbyte: usize) callconv(.c) c_int {
    if (buf == null) {
        return setErrno(sos.EINVAL);
    }
    if (nbyte == 0) {
        clearErrno();
        return 0;
    }

    const buf_ptr: [*]const u8 = @ptrCast(buf);
    const shbuf = sharedBuffer();
    const limit = if (nbyte > INT_MAX_USIZE) INT_MAX_USIZE else nbyte;

    var total: usize = 0;
    while (total < limit) {
        var req = limit - total;
        if (req > MAX_IO_BUF) {
            req = MAX_IO_BUF;
        }
        if (req == 0) break;

        std.mem.copyForwards(u8, shbuf[0..req], buf_ptr[total..][0..req]);

        const syscall = Syscall{
            .Write = .{
                .arg = signedIntToWord(file),
                .buf_addr = PROCESS_SHBUF_WORD,
                .buf_size = @as(sel4.seL4_Word, @intCast(req)),
            },
        };

        const reply = syscall.call(SOS_IPC_EP_CAP) catch |err| return handleCallError(err);
        const res = switch (reply) {
            .Write => |payload| payload.result,
            else => unreachable,
        };

        if (res < 0) {
            sos_errno = -res;
            return -1;
        }
        if (res == 0) {
            break;
        }

        const chunk: usize = @intCast(res);
        total += chunk;
        if (chunk < req) {
            break;
        }
    }

    clearErrno();
    return @as(c_int, @intCast(total));
}

fn handleVmReturn(raw: i64) i64 {
    if (raw < 0) {
        sos_errno = @intCast(-raw);
    } else {
        clearErrno();
    }
    return raw;
}

pub export fn sos_brk_call(new_break: usize) callconv(.c) i64 {
    const syscall = Syscall{
        .Brk = .{ .new_break = usizeToWord(new_break) },
    };
    const reply = syscall.call(SOS_IPC_EP_CAP) catch |err| return switch (handleCallError(err)) {
        -1 => -@as(i64, sos.EINVAL),
        else => -@as(i64, sos.EINVAL),
    };
    return switch (reply) {
        .Brk => |payload| handleVmReturn(payload.result),
        else => unreachable,
    };
}

pub export fn sos_mmap_call(
    addr: usize,
    length: usize,
    prot: c_int,
    flags: c_int,
    fd: c_int,
    offset: usize,
) callconv(.c) i64 {
    const syscall = Syscall{
        .Mmap = .{
            .addr = usizeToWord(addr),
            .length = usizeToWord(length),
            .prot = signedIntToWord(prot),
            .flags = signedIntToWord(flags),
            .fd = signedIntToWord(fd),
            .offset = usizeToWord(offset),
        },
    };
    const reply = syscall.call(SOS_IPC_EP_CAP) catch |err| return switch (handleCallError(err)) {
        -1 => -@as(i64, sos.EINVAL),
        else => -@as(i64, sos.EINVAL),
    };
    return switch (reply) {
        .Mmap => |payload| handleVmReturn(payload.result),
        else => unreachable,
    };
}

pub export fn sos_getdirent(pos: c_int, name: [*c]u8, nbyte: usize) callconv(.c) c_int {
    _ = pos;
    _ = name;
    _ = nbyte;
    return setErrno(sos.ENOSYS);
}

pub export fn sos_stat(path: [*c]const u8, buf: ?*sos_types.sos_stat_t) callconv(.c) c_int {
    _ = path;
    _ = buf;
    return setErrno(sos.ENOSYS);
}

pub export fn sos_process_create(path: [*c]const u8) callconv(.c) sos_types.pid_t {
    _ = path;
    _ = setErrno(sos.ENOSYS);
    return -1;
}

pub export fn sos_process_delete(pid: sos_types.pid_t) callconv(.c) c_int {
    _ = pid;
    return setErrno(sos.ENOSYS);
}

pub export fn sos_my_id() callconv(.c) sos_types.pid_t {
    const syscall = Syscall{ .MyId = .{} };
    const reply = syscall.call(SOS_IPC_EP_CAP) catch |err| return handleCallError(err);
    return switch (reply) {
        .MyId => |payload| blk: {
            clearErrno();
            break :blk payload.pid;
        },
        else => unreachable,
    };
}

pub export fn sos_process_status(processes: ?*sos_types.sos_process_t, max: c_uint) callconv(.c) c_int {
    _ = processes;
    _ = max;
    return setErrno(sos.ENOSYS);
}

pub export fn sos_process_wait(pid: sos_types.pid_t) callconv(.c) sos_types.pid_t {
    _ = pid;
    _ = setErrno(sos.ENOSYS);
    return -1;
}

pub export fn sos_usleep(usec: c_int) callconv(.c) void {
    if (usec < 0) {
        _ = setErrno(sos.EINVAL);
        return;
    }

    const syscall = Syscall{
        .Usleep = .{
            .arg = signedIntToWord(usec),
        },
    };

    const reply = syscall.call(SOS_IPC_EP_CAP) catch |err| {
        handleCallErrorVoid(err);
        return;
    };

    const res = switch (reply) {
        .Usleep => |payload| payload.result,
        else => unreachable,
    };
    if (res < 0) {
        sos_errno = -res;
        return;
    }

    clearErrno();
}

pub export fn sos_time_stamp() callconv(.c) i64 {
    const syscall = Syscall{ .Timestamp = .{} };
    const reply = syscall.call(SOS_IPC_EP_CAP) catch |err| {
        handleCallErrorVoid(err);
        return -1;
    };

    return switch (reply) {
        .Timestamp => |payload| blk: {
            clearErrno();
            break :blk payload.timestamp;
        },
        else => unreachable,
    };
}
