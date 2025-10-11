const std = @import("std");
const libipc = @import("libipc");
const sel4 = libipc.sel4;
const Syscall = libipc.Syscall;
const SyscallResponse = libipc.SyscallResponse;

const c_std = @cImport({
    @cInclude("stdio.h");
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("string.h");
});

const c_sel4 = @cImport({
    @cInclude("sel4/sel4.h");
});

const c_sos = @cImport({
    @cInclude("ipc.h");
    @cInclude("file.h");
    @cInclude("sos_time.h");
    @cInclude("vmem_layout.h");
    @cInclude("utils/page.h");
    @cInclude("ut.h");
    @cInclude("utils.h");
});

const MAX_CLIENTS: usize = c_sos.MAX_CLIENTS;
const SOS_MAX_OPEN_FILES: usize = 32;
const PROCESS_SHBUF_UVA = c_sos.PROCESS_SHBUF_UVA;
const PAGE_SIZE_4K: usize = c_sos.PAGE_SIZE_4K;
const console_name = "console";
const console_name_ptr: [*c]const u8 = @ptrCast(&console_name[0]);
const console_object_ptr: ?*anyopaque = @ptrCast(&c_sos.global_console);
const hi_msg = "hi from zig!\n";

const empty_fd: c_sos.sos_fd_entry_t = std.mem.zeroes(c_sos.sos_fd_entry_t);
const empty_fd_table = [_]c_sos.sos_fd_entry_t{empty_fd} ** SOS_MAX_OPEN_FILES;

const SosClientIoState = struct {
    initialised: bool = false,
    fds: [SOS_MAX_OPEN_FILES]c_sos.sos_fd_entry_t = empty_fd_table,
};

var client_io_state: [MAX_CLIENTS]SosClientIoState = [_]SosClientIoState{SosClientIoState{}} ** MAX_CLIENTS;

const ServerContext = struct {
    badge: sel4.seL4_Word,
    have_reply: [*c]bool,
    caller: ?*c_sos.client_t,
    reply: [*c]sel4.seL4_CPtr,
    reply_ut: [*c]*c_sos.ut_t,
};

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

fn encodeCInt(value: c_int) sel4.seL4_Word {
    return encodeI64(@as(i64, value));
}

fn sharedBufPtr(comptime T: type, caller: *c_sos.client_t) [*]T {
    const addr: usize = @intCast(caller.shbuf.k_va);
    return @ptrFromInt(addr);
}

fn setupConsoleFd(fd: *c_sos.sos_fd_entry_t, ops: *const c_sos.file_ops_t, readable: bool, writable: bool, dev_id: c_int) void {
    fd.* = empty_fd;
    fd.used = true;
    fd.readable = readable;
    fd.writable = writable;
    fd.kind = c_sos.FD_DEV_CONSOLE;
    fd.obj = console_object_ptr;
    fd.ops = ops;
    fd.dev_id = dev_id;
}

fn initStdio(state: *SosClientIoState) void {
    state.* = SosClientIoState{};
    const ops = c_sos.vfs_lookup_ops(console_name_ptr) orelse {
        std.debug.panic("console device not registered", .{});
    };
    if (ops.*.open == null or ops.*.read == null or ops.*.write == null) {
        std.debug.panic("console device missing required operations", .{});
    }

    var id: c_int = 0;

    if (ops.*.open.?(console_name_ptr, c_std.O_RDONLY, &id) < 0) {
        std.debug.panic("console stdin open failed", .{});
    }
    setupConsoleFd(&state.fds[0], ops, true, false, id);

    if (ops.*.open.?(console_name_ptr, c_std.O_WRONLY, &id) < 0) {
        std.debug.panic("console stdout open failed", .{});
    }
    setupConsoleFd(&state.fds[1], ops, false, true, id);

    if (ops.*.open.?(console_name_ptr, c_std.O_WRONLY, &id) < 0) {
        std.debug.panic("console stderr open failed", .{});
    }
    setupConsoleFd(&state.fds[2], ops, false, true, id);

    state.initialised = true;
}

fn handleOpen(ctx: *ServerContext, args: anytype) SyscallResponse {
    const caller = ctx.caller orelse {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-c_std.EINVAL)) } };
    };

    const client_id: usize = @intCast(caller.id);
    const client_id_u16 = @as(@TypeOf(c_sos.global_console.reader_owner_id), @intCast(client_id));
    if (client_id >= MAX_CLIENTS) {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-c_std.EINVAL)) } };
    }

    var state = &client_io_state[client_id];
    if (!state.initialised) {
        initStdio(state);
    }

    const mode: c_int = @intCast(args.arg);
    const user_buf = args.buf_addr;
    const buf_len: usize = @intCast(args.buf_size);

    if (user_buf != PROCESS_SHBUF_UVA) {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-c_std.EINVAL)) } };
    }
    if (buf_len == 0 or buf_len > PAGE_SIZE_4K) {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-c_std.EMSGSIZE)) } };
    }

    const shared_ptr = sharedBufPtr(u8, caller);
    const max_copy = @min(buf_len, PAGE_SIZE_4K);
    const raw_len = c_std.strnlen(@as([*c]const u8, @ptrCast(shared_ptr)), max_copy);
    const name_len: usize = @intCast(raw_len);
    if (name_len == max_copy) {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-c_std.ENAMETOOLONG)) } };
    }
    if (name_len == 0) {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-c_std.EINVAL)) } };
    }

    var filename: [PAGE_SIZE_4K]u8 = undefined;
    std.mem.copyForwards(u8, filename[0..name_len], shared_ptr[0..name_len]);
    filename[name_len] = 0;

    const filename_ptr: [*c]const u8 = @ptrCast(&filename[0]);

    const expected = "console";
    if (name_len != expected.len or !std.mem.eql(u8, filename[0..name_len], expected)) {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-c_std.ENODEV)) } };
    }

    const accmode = mode & c_std.O_ACCMODE;
    const want_read = accmode == c_std.O_RDONLY or accmode == c_std.O_RDWR;
    const want_write = accmode == c_std.O_WRONLY or accmode == c_std.O_RDWR;
    if (!want_read and !want_write) {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-c_std.EINVAL)) } };
    }

    if (want_read and c_sos.global_console.reader_in_use) {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-c_std.EBUSY)) } };
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
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-c_std.EMFILE)) } };
    }

    const ops = c_sos.vfs_lookup_ops(filename_ptr) orelse {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-c_std.ENODEV)) } };
    };

    var dev_id: c_int = 0;
    if (ops.*.open) |open_fn| {
        const rc = open_fn(filename_ptr, mode, &dev_id);
        if (rc < 0) {
            return SyscallResponse{ .Open = .{ .result = @as(c_int, (rc)) } };
        }
    }

    if (want_read) {
        c_sos.global_console.reader_in_use = true;
        c_sos.global_console.reader_owner_id = client_id_u16;
    }
    if (want_write) {
        c_sos.global_console.write_refcnt += 1;
    }

    const fd_index: usize = @intCast(fd);
    const slot = &state.fds[fd_index];
    setupConsoleFd(slot, ops, want_read, want_write, dev_id);

    return SyscallResponse{ .Open = .{ .result = @as(c_int, (fd)) } };
}

fn handleClose(ctx: *ServerContext, args: anytype) SyscallResponse {
    const caller = ctx.caller orelse {
        return SyscallResponse{ .Close = .{ .result = @as(c_int, (-c_std.EINVAL)) } };
    };
    const client_id: usize = @intCast(caller.id);
    const client_id_u16 = @as(@TypeOf(c_sos.global_console.reader_owner_id), @intCast(client_id));
    if (client_id >= MAX_CLIENTS) {
        return SyscallResponse{ .Close = .{ .result = @as(c_int, (-c_std.EINVAL)) } };
    }

    var state = &client_io_state[client_id];
    if (!state.initialised) {
        return SyscallResponse{ .Close = .{ .result = @as(c_int, (-c_std.EBADF)) } };
    }

    const fd_raw: c_int = @intCast(args.arg);
    if (fd_raw < 0 or fd_raw >= SOS_MAX_OPEN_FILES) {
        return SyscallResponse{ .Close = .{ .result = @as(c_int, (-c_std.EBADF)) } };
    }

    if (fd_raw < 3) {
        return SyscallResponse{ .Close = .{ .result = @as(c_int, (0)) } };
    }

    const fd_index: usize = @intCast(fd_raw);
    const entry = &state.fds[fd_index];
    if (!entry.used) {
        return SyscallResponse{ .Close = .{ .result = @as(c_int, (-c_std.EBADF)) } };
    }
    if (entry.refcnt != 0) {
        return SyscallResponse{ .Close = .{ .result = @as(c_int, (-c_std.EBUSY)) } };
    }

    if (entry.kind == c_sos.FD_DEV_CONSOLE and entry.obj == console_object_ptr) {
        if (entry.readable and c_sos.global_console.reader_in_use and c_sos.global_console.reader_owner_id == client_id_u16) {
            c_sos.global_console.reader_in_use = false;
            c_sos.global_console.reader_owner_id = 0;
        }
        if (entry.writable and c_sos.global_console.write_refcnt > 0) {
            c_sos.global_console.write_refcnt -= 1;
        }
    }

    const ops_ptr = entry.ops;
    if (ops_ptr != null and ops_ptr.*.close != null) {
        _ = ops_ptr.*.close.?(entry.dev_id);
    }

    entry.* = empty_fd;
    return SyscallResponse{ .Close = .{ .result = @as(c_int, (0)) } };
}

fn handleRead(ctx: *ServerContext, args: anytype) SyscallResponse {
    const caller = ctx.caller orelse {
        return SyscallResponse{ .Read = .{ .result = @as(c_int, (-c_std.EINVAL)) } };
    };

    const client_id: usize = @intCast(caller.id);
    if (client_id >= MAX_CLIENTS) {
        return SyscallResponse{ .Read = .{ .result = @as(c_int, (-c_std.EINVAL)) } };
    }

    var state = &client_io_state[client_id];
    if (!state.initialised) {
        return SyscallResponse{ .Read = .{ .result = @as(c_int, (-c_std.EBADF)) } };
    }

    const fd_raw: c_int = @intCast(args.arg);
    if (fd_raw < 0 or fd_raw >= SOS_MAX_OPEN_FILES) {
        return SyscallResponse{ .Read = .{ .result = @as(c_int, (-c_std.EBADF)) } };
    }

    const fd_index: usize = @intCast(fd_raw);
    const entry = &state.fds[fd_index];
    if (!entry.used or !entry.readable) {
        return SyscallResponse{ .Read = .{ .result = @as(c_int, (-c_std.EBADF)) } };
    }

    if (args.buf_addr != PROCESS_SHBUF_UVA) {
        return SyscallResponse{ .Read = .{ .result = @as(c_int, (-c_std.EINVAL)) } };
    }

    const req: usize = @intCast(args.buf_size);
    if (req == 0 or req > PAGE_SIZE_4K) {
        return SyscallResponse{ .Read = .{ .result = @as(c_int, (-c_std.EMSGSIZE)) } };
    }

    const dst_ptr = sharedBufPtr(u8, caller);
    const dst_any: *anyopaque = @ptrCast(dst_ptr);
    const ops_ptr = entry.ops;
    if (ops_ptr == null or ops_ptr.*.read == null) {
        return SyscallResponse{ .Read = .{ .result = @as(c_int, (-c_std.ENOSYS)) } };
    }
    const read_fn = ops_ptr.*.read.?;
    const result = read_fn(entry.dev_id, dst_any, req);
    const n: c_int = @intCast(result);
    return SyscallResponse{ .Read = .{ .result = @as(c_int, (n)) } };
}

fn handleWrite(ctx: *ServerContext, args: anytype) SyscallResponse {
    const caller = ctx.caller orelse {
        return SyscallResponse{ .Write = .{ .result = @as(c_int, (-c_std.EINVAL)) } };
    };

    const client_id: usize = @intCast(caller.id);
    if (client_id >= MAX_CLIENTS) {
        return SyscallResponse{ .Write = .{ .result = @as(c_int, (-c_std.EINVAL)) } };
    }

    var state = &client_io_state[client_id];
    if (!state.initialised) {
        return SyscallResponse{ .Write = .{ .result = @as(c_int, (-c_std.EBADF)) } };
    }

    const fd_raw: c_int = @intCast(args.arg);
    if (fd_raw < 0 or fd_raw >= SOS_MAX_OPEN_FILES) {
        return SyscallResponse{ .Write = .{ .result = @as(c_int, (-c_std.EBADF)) } };
    }

    const fd_index: usize = @intCast(fd_raw);
    const entry = &state.fds[fd_index];
    if (!entry.used or !entry.writable) {
        return SyscallResponse{ .Write = .{ .result = @as(c_int, (-c_std.EBADF)) } };
    }

    if (args.buf_addr != PROCESS_SHBUF_UVA) {
        return SyscallResponse{ .Write = .{ .result = @as(c_int, (-c_std.EINVAL)) } };
    }

    const req: usize = @intCast(args.buf_size);
    if (req == 0 or req > PAGE_SIZE_4K) {
        return SyscallResponse{ .Write = .{ .result = @as(c_int, (-c_std.EMSGSIZE)) } };
    }

    const raw_src = sharedBufPtr(u8, caller);
    const src_ptr: [*]const u8 = @ptrCast(raw_src);
    const src_mut: [*]u8 = @constCast(src_ptr);
    const src_any: *anyopaque = @ptrCast(src_mut);
    const ops_ptr = entry.ops;
    if (ops_ptr == null or ops_ptr.*.write == null) {
        return SyscallResponse{ .Write = .{ .result = @as(c_int, (-c_std.ENOSYS)) } };
    }
    const write_fn = ops_ptr.*.write.?;
    const result = write_fn(entry.dev_id, src_any, req);
    const n: c_int = @intCast(result);
    return SyscallResponse{ .Write = .{ .result = @as(c_int, (n)) } };
}

fn handleTimestamp(ctx: *ServerContext) SyscallResponse {
    _ = ctx;
    const timestamp = c_sos.ts_get_timestamp();
    const value: i64 = @intCast(timestamp);
    return .{ .Timestamp = .{ .timestamp = value } };
}

fn handleMyId(ctx: *ServerContext) SyscallResponse {
    return .{ .MyId = .{ .pid = @intCast(ctx.badge) } };
}

fn handleUsleep(ctx: *ServerContext, args: anytype) ?SyscallResponse {
    const duration: isize = @bitCast(args.arg);
    const res = c_sos.ts_usleep(duration, ctx.reply.*, ctx.reply_ut.*);
    if (res < 0) {
        return SyscallResponse{ .Usleep = .{ .result = @as(c_int, (-c_std.EINVAL)) } };
    } else if (res == 1) {
        return SyscallResponse{ .Usleep = .{ .result = @as(c_int, (0)) } };
    }

    ctx.have_reply.* = false;
    const new_reply_ut = c_sos.alloc_retype(ctx.reply, sel4.seL4_ReplyObject, sel4.seL4_ReplyBits);
    if (new_reply_ut == null) {
        @panic("Failed to alloc new reply object");
    }
    ctx.reply_ut.* = new_reply_ut.?;
    return null;
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
    };
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
    caller: ?*c_sos.client_t,
    /// Pointer to the reply capability
    reply: [*c]sel4.seL4_CPtr,
    /// Untyped descriptor backing the reply capability
    reply_ut: [*c]*c_sos.ut_t,
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
        sel4.seL4_SetMR(0, encodeCInt(-c_std.EINVAL));
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
