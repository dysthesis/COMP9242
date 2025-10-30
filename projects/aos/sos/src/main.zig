const MAX_CLIENTS: usize = sos.MAX_CLIENTS;
pub const SOS_MAX_OPEN_FILES: usize = 32;
const PAGE_SIZE_4K: usize = sos.PAGE_SIZE_4K;
const console_name = "console";
const console_name_ptr: [*c]const u8 = @ptrCast(&console_name[0]);

const ServerContext = struct {
    badge: sel4.seL4_Word,
    have_reply: [*c]bool,
    caller: ?*sos.client_t,
    vm_handle: ?*vm.VmHandle,
    reply: [*c]sel4.seL4_CPtr,
    reply_ut: [*c]*sos.ut_t,
};

/// Handle a singular syscall
pub export fn handle_syscall(
    /// The caller's badge
    badge: sel4.seL4_Word,
    /// The system call message
    message: [*c]const sel4.seL4_MessageInfo_t,
    /// Indicator to tell the syscall_loop that we have a reply to send back
    have_reply: [*c]bool,
    /// Identifier for who is calling
    caller: ?*sos.client_t,
    /// Pointer to the reply capability
    reply: [*c]sel4.seL4_CPtr,
    /// Untyped descriptor backing the reply capability
    reply_ut: [*c]*sos.ut_t,
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
        sel4.seL4_SetMR(0, encodeCInt(-sos.EINVAL));
        return sel4.seL4_MessageInfo_new(0, 0, 0, 1);
    };

    const vm_handle = if (caller) |cptr| vm.vm_state_lookup(cptr) else null;

    var ctx = ServerContext{
        .badge = badge,
        .have_reply = have_reply,
        .caller = caller,
        .vm_handle = vm_handle,
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
        .Brk => |args| handleBrk(ctx, args),
        .Mmap => |args| handleMmap(ctx, args),
    };
}

fn handleOpen(ctx: *ServerContext, args: anytype) SyscallResponse {
    const caller = ctx.caller orelse {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-sos.EINVAL)) } };
    };

    const client_id: usize = @intCast(caller.id);
    const client_id_u16 = @as(@TypeOf(sos.global_console.reader_owner_id), @intCast(client_id));
    if (client_id >= MAX_CLIENTS) {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-sos.EINVAL)) } };
    }

    var state = &file.client_io_state[client_id];
    ensureStdio(state);

    const mode: c_int = @intCast(args.arg);
    const user_buf = args.buf_addr;
    const buf_len: usize = @intCast(args.buf_size);

    if (buf_len == 0 or buf_len > PAGE_SIZE_4K) {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-sos.EMSGSIZE)) } };
    }

    const handle = ctx.vm_handle orelse {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-sos.EINVAL)) } };
    };

    var name_storage: [PAGE_SIZE_4K]u8 = undefined;
    if (handle.copyFromUserBuffer(&name_storage, @intCast(user_buf), buf_len) == false) {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-sos.EFAULT)) } };
    }

    const slice = name_storage[0..buf_len];
    const nul_index = std.mem.indexOfScalar(u8, slice, 0) orelse {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-sos.ENAMETOOLONG)) } };
    };
    const name_len: usize = nul_index;

    if (name_len == 0) {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-sos.EINVAL)) } };
    }

    name_storage[name_len] = 0;
    const filename = name_storage[0..name_len];
    const filename_ptr: [*c]const u8 = @ptrCast(&name_storage[0]);

    const expected = "console";
    if (name_len != expected.len or !std.mem.eql(u8, filename, expected)) {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-sos.ENODEV)) } };
    }

    const accmode = mode & c.O_ACCMODE;
    const want_read = accmode == c.O_RDONLY or accmode == c.O_RDWR;
    const want_write = accmode == c.O_WRONLY or accmode == c.O_RDWR;
    if (!want_read and !want_write) {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-sos.EINVAL)) } };
    }

    if (want_read and sos.global_console.reader_in_use) {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-sos.EBUSY)) } };
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
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-sos.EMFILE)) } };
    }

    const ops = sos.vfs_lookup_ops(filename_ptr) orelse {
        return SyscallResponse{ .Open = .{ .result = @as(c_int, (-sos.ENODEV)) } };
    };

    var dev_id: c_int = 0;
    if (ops.*.open) |open_fn| {
        const ret = open_fn(filename_ptr, mode, &dev_id);
        if (ret < 0) {
            return SyscallResponse{ .Open = .{ .result = @as(c_int, (ret)) } };
        }
    }

    if (want_read) {
        sos.global_console.reader_in_use = true;
        sos.global_console.reader_owner_id = client_id_u16;
    }
    if (want_write) {
        sos.global_console.write_refcnt += 1;
    }

    const fd_index: usize = @intCast(fd);
    const slot = &state.fds[fd_index];
    setupConsoleFd(slot, ops, want_read, want_write, dev_id);

    return SyscallResponse{ .Open = .{ .result = @as(c_int, (fd)) } };
}

fn handleClose(ctx: *ServerContext, args: anytype) SyscallResponse {
    const caller = ctx.caller orelse {
        return SyscallResponse{ .Close = .{ .result = @as(c_int, (-sos.EINVAL)) } };
    };
    const client_id: usize = @intCast(caller.id);
    const client_id_u16 = @as(@TypeOf(sos.global_console.reader_owner_id), @intCast(client_id));
    if (client_id >= MAX_CLIENTS) {
        return SyscallResponse{ .Close = .{ .result = @as(c_int, (-sos.EINVAL)) } };
    }

    var state = &file.client_io_state[client_id];
    ensureStdio(state);
    if (!state.initialised) {
        return SyscallResponse{ .Close = .{ .result = @as(c_int, (-sos.EBADF)) } };
    }

    const fd_raw: c_int = @intCast(args.arg);
    if (fd_raw < 0 or fd_raw >= SOS_MAX_OPEN_FILES) {
        return SyscallResponse{ .Close = .{ .result = @as(c_int, (-sos.EBADF)) } };
    }

    if (fd_raw < 3) {
        return SyscallResponse{ .Close = .{ .result = @as(c_int, (0)) } };
    }

    const fd_index: usize = @intCast(fd_raw);
    const entry = &state.fds[fd_index];
    if (!entry.used) {
        return SyscallResponse{ .Close = .{ .result = @as(c_int, (-sos.EBADF)) } };
    }
    if (entry.refcnt != 0) {
        return SyscallResponse{ .Close = .{ .result = @as(c_int, (-sos.EBUSY)) } };
    }

    if (entry.kind == sos.FD_DEV_CONSOLE and entry.obj == console_object_ptr) {
        if (entry.readable and sos.global_console.reader_in_use and sos.global_console.reader_owner_id == client_id_u16) {
            sos.global_console.reader_in_use = false;
            sos.global_console.reader_owner_id = 0;
        }
        if (entry.writable and sos.global_console.write_refcnt > 0) {
            sos.global_console.write_refcnt -= 1;
        }
    }

    const ops_ptr = entry.ops;
    if (ops_ptr != null and ops_ptr.*.close != null) {
        _ = ops_ptr.*.close.?(entry.dev_id);
    }

    entry.* = empty_fd;
    return SyscallResponse{ .Close = .{ .result = @as(c_int, (0)) } };
}

/// Resume function for blocked read operations
fn readResumeFn(cont: *continuation.Continuation, event_data: ?*anyopaque, result: *continuation.ContinuationResult) callconv(.c) void {
    _ = event_data; // Unused for console reads

    // Extract state from continuation
    const state = cont.state.Read;

    // Validate client still exists
    if (cont.client.id >= MAX_CLIENTS) {
        result.* = .{ .Error = .{ .errno = sos.EINVAL } };
        return;
    }

    // Validate file descriptor is still valid
    var io_state = &file.client_io_state[@intCast(cont.client.id)];
    if (!io_state.initialised) {
        result.* = .{ .Error = .{ .errno = sos.EBADF } };
        return;
    }

    const entry = &io_state.fds[state.fd_index];
    if (!entry.used or !entry.readable or entry.ops != state.ops) {
        result.* = .{ .Error = .{ .errno = sos.EBADF } };
        return;
    }

    const read_fn = state.ops.*.read orelse {
        result.* = .{ .Error = .{ .errno = sos.ENOSYS } };
        return;
    };

    // Attempt to read into temporary buffer
    var temp_buf: [sos.PAGE_SIZE_4K]u8 = undefined;
    const dst_any: *anyopaque = @ptrCast(&temp_buf[0]);
    const read_len = @min(state.requested, sos.PAGE_SIZE_4K);
    const read_result = read_fn(state.dev_id, dst_any, read_len);

    if (read_result == -sos.EWOULDBLOCK) {
        // Still would block, retry later
        result.* = .Retry;
        return;
    }

    if (read_result < 0) {
        // Error occurred
        result.* = .{ .Error = .{ .errno = @intCast(-read_result) } };
        return;
    }

    // Success - copy to user buffer
    if (read_result > 0) {
        const copied = state.vm_handle.copyToUserBuffer(state.user_buf_addr, &temp_buf, @intCast(read_result));
        if (!copied) {
            result.* = .{ .Error = .{ .errno = sos.EFAULT } };
            return;
        }
    }

    // Serialize response
    const resp = SyscallResponse{ .Read = .{ .result = @intCast(read_result) } };
    const msg = resp.serialise();
    result.* = .{ .Complete = .{ .response = msg } };
}

fn handleRead(ctx: *ServerContext, args: anytype) ?SyscallResponse {
    const caller = ctx.caller orelse return .{ .Read = .{ .result = -sos.EINVAL } };
    const client_id: usize = @intCast(caller.id);
    if (client_id >= MAX_CLIENTS) return .{ .Read = .{ .result = -sos.EINVAL } };

    var state = &file.client_io_state[client_id];
    ensureStdio(state);
    if (!state.initialised) return .{ .Read = .{ .result = -sos.EBADF } };

    const fd_raw: c_int = @intCast(args.arg);
    if (fd_raw < 0 or fd_raw >= SOS_MAX_OPEN_FILES) return .{ .Read = .{ .result = -sos.EBADF } };

    const fd_index: usize = @intCast(fd_raw);
    const entry = &state.fds[fd_index];
    if (!entry.used or !entry.readable) return .{ .Read = .{ .result = -sos.EBADF } };

    const user_buf_addr: usize = @intCast(args.buf_addr);
    const req: usize = @intCast(args.buf_size);
    if (req == 0) return .{ .Read = .{ .result = 0 } };

    const handle = ctx.vm_handle orelse return .{ .Read = .{ .result = -sos.EINVAL } };

    const ops_ptr = entry.ops;
    if (ops_ptr == null or ops_ptr.*.read == null) return .{ .Read = .{ .result = -sos.ENOSYS } };
    const read_fn = ops_ptr.*.read.?;

    const ReadCtx = struct {
        dev_id: c_int,
        read_fn: *const fn (c_int, ?*anyopaque, usize) callconv(.c) isize,
        would_block: bool = false,
        errno: c_int = 0,
        pub const Self = @This();
        pub fn op(ctx_opaque: *anyopaque, p: [*]u8, n: usize) anyerror!usize {
            const rctx: *Self = @ptrCast(@alignCast(ctx_opaque));
            const anyptr: *anyopaque = @ptrCast(p);
            const r: isize = rctx.read_fn(rctx.dev_id, anyptr, n);

            if (r == -sos.EWOULDBLOCK) {
                rctx.would_block = true;
                return 0;
            }
            if (r < 0) {
                rctx.errno = @intCast(-r);
                return error.DeviceError;
            }
            return @intCast(r);
        }
    };

    var read_ctx = ReadCtx{
        .dev_id = entry.dev_id,
        .read_fn = read_fn,
        .would_block = false,
        .errno = 0,
    };

    const moved_or_err = handle.withUserSlice(
        user_buf_addr,
        req,
        .writeOnly,
        .{ .ctx = &read_ctx, .func = ReadCtx.op },
    );
    var moved: usize = 0;

    // Run the reader with the given user slice
    moved = moved_or_err catch |err| {
        if (err == error.DeviceError) {
            return .{ .Read = .{ .result = -read_ctx.errno } };
        }

        const errno: c_int = vm.vmErrorToErrno(err);

        return .{ .Read = .{ .result = -errno } };
    };

    if (moved == 0 and read_ctx.would_block) {
        // Allocate continuation from pool
        const cont = continuation.ContinuationPool.alloc() orelse {
            return .{ .Read = .{ .result = -sos.ENOMEM } };
        };

        // Allocate new reply capability for this continuation
        const old_reply_cap = ctx.reply.*;
        const old_reply_ut = ctx.reply_ut.*;
        const new_reply_ut = sos.alloc_retype(ctx.reply, sel4.seL4_ReplyObject, sel4.seL4_ReplyBits);
        if (new_reply_ut == null) {
            continuation.ContinuationPool.free(cont);
            ctx.reply.* = old_reply_cap;
            ctx.reply_ut.* = old_reply_ut;
            return .{ .Read = .{ .result = -sos.ENOMEM } };
        }

        // Populate continuation
        cont.client = caller;
        cont.reply = old_reply_cap;
        cont.reply_ut = old_reply_ut;
        cont.resume_fn = readResumeFn;
        cont.state = .{
            .Read = .{
                .fd_index = fd_index,
                .vm_handle = handle,
                .user_buf_addr = user_buf_addr,
                .requested = req,
                .ops = ops_ptr,
                .dev_id = entry.dev_id,
            },
        };

        // Enqueue to wait for console stdin
        continuation.WaitQueues.waitIO(cont, continuation.CONSOLE_STDIN_FD);

        // Mark that we have a new reply cap and won't send reply immediately
        ctx.have_reply.* = false;
        ctx.reply_ut.* = new_reply_ut.?;
        return null;
    }

    // Either we read some bytes, or EOF
    return .{ .Read = .{ .result = @intCast(moved) } };
}

fn handleWrite(ctx: *ServerContext, args: anytype) SyscallResponse {
    const caller = ctx.caller orelse return .{ .Write = .{ .result = -sos.EINVAL } };
    const client_id: usize = @intCast(caller.id);
    if (client_id >= MAX_CLIENTS) return .{ .Write = .{ .result = -sos.EINVAL } };

    var state = &file.client_io_state[client_id];
    ensureStdio(state);
    if (!state.initialised) return .{ .Write = .{ .result = -sos.EBADF } };

    const fd_raw: c_int = @intCast(args.arg);
    if (fd_raw < 0 or fd_raw >= SOS_MAX_OPEN_FILES) return .{ .Write = .{ .result = -sos.EBADF } };

    const entry = &state.fds[@intCast(fd_raw)];
    if (!entry.used or !entry.writable) return .{ .Write = .{ .result = -sos.EBADF } };

    const user_buf_addr: usize = @intCast(args.buf_addr);
    const req: usize = @intCast(args.buf_size);
    if (req == 0) return .{ .Write = .{ .result = 0 } };

    const handle = ctx.vm_handle orelse return .{ .Write = .{ .result = -sos.EINVAL } };

    const write_fn = entry.ops.?.*.write orelse return .{ .Write = .{ .result = -sos.ENOSYS } };

    const WriteCtx = struct {
        dev_id: c_int,
        write_fn: *const fn (c_int, ?*const anyopaque, usize) callconv(.c) isize,
        errno: c_int = 0,
        pub const Self = @This();
        pub fn op(ctx_opaque: *anyopaque, p: [*]u8, n: usize) anyerror!usize {
            const self: *Self = @ptrCast(@alignCast(ctx_opaque));
            const ro: [*]const u8 = p; // treat mapped bytes as const
            const any_ro: *const anyopaque = @ptrCast(ro);
            const r: isize = self.write_fn(self.dev_id, any_ro, n);
            if (r < 0) {
                self.errno = @intCast(-r);
                return error.DeviceError;
            }
            return @intCast(r);
        }
    };

    var wctx = WriteCtx{ .dev_id = entry.dev_id, .write_fn = write_fn };
    const moved_or_err = handle.withUserSlice(user_buf_addr, req, .readOnly, .{ .ctx = &wctx, .func = WriteCtx.op });

    const moved: usize = moved_or_err catch |err| {
        if (err == error.DeviceError) return .{ .Write = .{ .result = -wctx.errno } };
        const errno: c_int = switch (err) {
            vm.VmError.ClientContext => sos.EINVAL,
            vm.VmError.Bounds => sos.ENOMEM,
            vm.VmError.Unsupported => sos.ENOSYS,
            vm.VmError.OutOfFrames, vm.VmError.OutOfSlots, vm.VmError.Capacity => sos.ENOMEM,
            vm.VmError.MapFailed => sos.EIO,
            vm.VmError.InvalidArgs => sos.EINVAL,
            vm.VmError.AlreadyMapped => sos.EEXIST,
            else => sos.EIO,
        };
        return .{ .Write = .{ .result = -errno } };
    };

    return .{ .Write = .{ .result = @intCast(moved) } };
}

fn handleTimestamp(ctx: *ServerContext) SyscallResponse {
    _ = ctx;
    const timestamp = sos.ts_get_timestamp();
    const value: i64 = @intCast(timestamp);
    return .{ .Timestamp = .{ .timestamp = value } };
}

fn handleMyId(ctx: *ServerContext) SyscallResponse {
    return .{ .MyId = .{ .pid = @intCast(ctx.badge) } };
}

fn handleBrk(ctx: *ServerContext, args: anytype) SyscallResponse {
    const caller_ptr_value: usize = if (ctx.caller) |ptr| @intFromPtr(ptr) else 0;
    _ = c.printf("[vm_brk] handleBrk badge=%lu new_break=0x%lx caller_ptr=0x%lx\n", @as(c_ulong, @intCast(ctx.badge)), @as(c_ulong, @intCast(args.new_break)), @as(c_ulong, @intCast(caller_ptr_value)));
    if (ctx.caller == null) {
        _ = c.printf("[vm_brk] handleBrk no caller context\n");
        return SyscallResponse{ .Brk = .{ .result = -@as(i64, sos.EINVAL) } };
    }
    const handle = ctx.vm_handle orelse {
        _ = c.printf("[vm_brk] handleBrk missing vm_handle\n");
        return SyscallResponse{ .Brk = .{ .result = -@as(i64, sos.EINVAL) } };
    };
    const requested: usize = @intCast(args.new_break);
    const result = handle.brk(requested) catch |err| {
        const errno = vm.vmErrorToErrno(err);
        _ = c.printf("[vm_brk] handleBrk error errno=%d\n", errno);
        return SyscallResponse{ .Brk = .{ .result = -@as(i64, errno) } };
    };
    _ = c.printf("[vm_brk] handleBrk success result=0x%lx\n", @as(c_ulong, @intCast(result)));
    return SyscallResponse{ .Brk = .{ .result = @as(i64, @intCast(result)) } };
}

fn handleMmap(ctx: *ServerContext, args: anytype) SyscallResponse {
    if (ctx.caller == null) {
        return SyscallResponse{ .Mmap = .{ .result = -@as(i64, sos.EINVAL) } };
    }
    const handle = ctx.vm_handle orelse {
        return SyscallResponse{ .Mmap = .{ .result = -@as(i64, sos.EINVAL) } };
    };
    const addr: usize = @intCast(args.addr);
    const length: usize = @intCast(args.length);
    const prot: c_int = @intCast(wordToI64(args.prot));
    const flags: c_int = @intCast(wordToI64(args.flags));
    const fd: c_int = @intCast(wordToI64(args.fd));
    const offset: usize = @intCast(args.offset);

    const base = handle.mmap(addr, length, prot, flags, fd, offset) catch |err| {
        const errno = vm.vmErrorToErrno(err);
        return SyscallResponse{ .Mmap = .{ .result = -@as(i64, errno) } };
    };
    return SyscallResponse{ .Mmap = .{ .result = @as(i64, @intCast(base)) } };
}

fn handleUsleep(ctx: *ServerContext, args: anytype) ?SyscallResponse {
    const duration: isize = @bitCast(args.arg);
    const res = sos.ts_usleep(duration, ctx.reply.*, ctx.reply_ut.*);
    if (res < 0) {
        return SyscallResponse{ .Usleep = .{ .result = @as(c_int, (-sos.EINVAL)) } };
    } else if (res == 1) {
        return SyscallResponse{ .Usleep = .{ .result = @as(c_int, (0)) } };
    }

    ctx.have_reply.* = false;
    const new_reply_ut = sos.alloc_retype(ctx.reply, sel4.seL4_ReplyObject, sel4.seL4_ReplyBits);
    if (new_reply_ut == null) {
        @panic("Failed to alloc new reply object");
    }
    ctx.reply_ut.* = new_reply_ut.?;
    return null;
}

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

fn wordToI64(word: sel4.seL4_Word) i64 {
    return switch (@bitSizeOf(sel4.seL4_Word)) {
        64 => @bitCast(word),
        32 => blk: {
            const as_u32: u32 = @intCast(word);
            const as_i32: i32 = @bitCast(as_u32);
            break :blk @as(i64, as_i32);
        },
        else => @compileError("Unsupported seL4_Word size"),
    };
}

fn encodeCInt(value: c_int) sel4.seL4_Word {
    return encodeI64(@as(i64, value));
}

const std = @import("std");
const libipc = @import("libipc");
const Syscall = libipc.Syscall;
const SyscallResponse = libipc.SyscallResponse;

const cimports = @import("cimports");
const c = cimports.c;
const sel4 = cimports.sel4;
const sos = cimports.sos;

const vm = @import("vm/mod.zig");
pub const worker = @import("worker.zig");
// Force worker module to be compiled so its exported C functions are available
comptime {
    _ = worker;
}

pub extern var cspace: sos.cspace_t;

const helpers = @import("helpers.zig");
const resultToCInt = helpers.resultToCInt;

const file = @import("file.zig");
const empty_fd = file.empty_fd;
const SosClientIoState = file.SosClientIoState;

const console = @import("console.zig");
const PendingConsoleRead = console.PendingConsoleRead;
const ensureStdio = console.ensureStdio;
const setupConsoleFd = console.setupConsoleFd;
const console_object_ptr = console.console_object_ptr;

pub const continuation = @import("continuation.zig");

// Force continuation module to be fully compiled and linked
comptime {
    _ = continuation;
    // Ensure all exports from continuation are included
    _ = &continuation.continuation_bootstrap;
}
