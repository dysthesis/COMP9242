const MAX_CLIENTS: usize = sos.MAX_CLIENTS;
pub const SOS_MAX_OPEN_FILES: usize = 32;
const PAGE_SIZE_4K: usize = sos.PAGE_SIZE_4K;
const console_name = "console";
const console_name_ptr: [*c]const u8 = @ptrCast(&console_name[0]);

const NormalisePathError = error{
    NameTooLong,
    InvalidComponent,
    Empty,
};

const Path = struct {
    buf: [worker.OPEN_PATH_CAPACITY:0]u8,
    len: usize,

    pub fn initFromSlice(input: []const u8) NormalisePathError!Path {
        var self = Path{
            .buf = [_:0]u8{0} ** worker.OPEN_PATH_CAPACITY,
            .len = 0,
        };
        self.len = try normaliseInto(self.buf[0..], input);
        return self;
    }

    pub fn isEmpty(self: *const Path) bool {
        return self.len == 0;
    }

    pub fn copyTo(self: *const Path, dest: []u8) NormalisePathError!void {
        if (self.len >= dest.len) return error.NameTooLong;
        if (self.len > 0) {
            std.mem.copyForwards(u8, dest[0..self.len], self.buf[0..self.len]);
        }
        dest[self.len] = 0;
    }

    pub fn cStr(self: *const Path) [*:0]const u8 {
        return @ptrCast(&self.buf);
    }
};

fn normaliseInto(out: []u8, input: []const u8) NormalisePathError!usize {
    if (out.len == 0) return error.NameTooLong;
    if (input.len == 0) return error.Empty;
    if (input.len >= out.len) return error.NameTooLong;

    if (std.mem.indexOfScalar(u8, input, '/')) |_| {
        return error.InvalidComponent;
    }
    if (std.mem.indexOfScalar(u8, input, '\\')) |_| {
        return error.InvalidComponent;
    }
    if (std.mem.indexOf(u8, input, "..")) |_| {
        return error.InvalidComponent;
    }

    std.mem.copyForwards(u8, out[0..input.len], input);
    out[input.len] = 0;
    return input.len;
}

fn mapFileTableError(err: file.FileTableError) c_int {
    return switch (err) {
        file.FileTableError.TableFull => sos.EMFILE,
        file.FileTableError.InvalidFd,
        file.FileTableError.SlotUnused,
        file.FileTableError.MissingHandle,
        => sos.EBADF,
    };
}

const ServerContext = struct {
    badge: sel4.seL4_Word,
    have_reply: [*c]bool,
    caller: ?*sos.client_t,
    vm_handle: ?*vm.VmHandle,
    reply: [*c]sel4.seL4_CPtr,
    reply_ut: [*c]*sos.ut_t,

    fn handleOpen(self: *ServerContext, args: anytype) ?SyscallResponse {
        const caller = self.caller orelse {
            return SyscallResponse{ .Open = .{ .result = -sos.EINVAL } };
        };

        const client_id: usize = @intCast(caller.id);
        if (client_id >= MAX_CLIENTS) {
            return SyscallResponse{ .Open = .{ .result = -sos.EINVAL } };
        }

        const client_ctx = clients.get(client_id) orelse {
            return SyscallResponse{ .Open = .{ .result = -sos.EINVAL } };
        };
        const client_id_u16 = @as(u16, @intCast(client_ctx.id));
        const state = client_ctx.ioState();
        ensureStdio(state, client_id_u16);

        const flags: c_int = @intCast(args.arg);
        const user_buf_addr: usize = @intCast(args.buf_addr);
        const buf_len: usize = @intCast(args.buf_size);

        if (buf_len == 0) {
            return SyscallResponse{ .Open = .{ .result = -sos.EINVAL } };
        }
        if (buf_len > worker.OPEN_PATH_CAPACITY) {
            return SyscallResponse{ .Open = .{ .result = -sos.ENAMETOOLONG } };
        }

        const vm_handle = self.vm_handle orelse {
            return SyscallResponse{ .Open = .{ .result = -sos.EINVAL } };
        };

        var path_buf: [worker.OPEN_PATH_CAPACITY:0]u8 = undefined;
        @memset(path_buf[0..], 0);

        const copied = vm_handle.copyCStringFromClient(user_buf_addr, path_buf[0..path_buf.len]) catch |err| {
            const errno: c_int = vm.vmErrorToErrno(err);
            return SyscallResponse{ .Open = .{ .result = -errno } };
        };

        if (copied == 0) {
            return SyscallResponse{ .Open = .{ .result = -sos.EINVAL } };
        }
        if (copied >= path_buf.len) {
            return SyscallResponse{ .Open = .{ .result = -sos.ENAMETOOLONG } };
        }

        path_buf[copied] = 0;
        const path_slice = path_buf[0..copied];

        const expected = "console";
        if (path_slice.len == expected.len and std.mem.eql(u8, path_slice, expected)) {
            return self.handleConsoleOpen(state, flags, client_id);
        }

        return self.startAsyncOpen(caller, client_ctx, path_slice, flags);
    }

    fn handleConsoleOpen(self: *ServerContext, state: *SosClientIoState, flags: c_int, client_id: usize) SyscallResponse {
        _ = self;
        const accmode = flags & c.O_ACCMODE;
        const want_read = accmode == c.O_RDONLY or accmode == c.O_RDWR;
        const want_write = accmode == c.O_WRONLY or accmode == c.O_RDWR;
        if (!want_read and !want_write) {
            return .{ .Open = .{ .result = -sos.EINVAL } };
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
            return .{ .Open = .{ .result = -sos.EMFILE } };
        }

        const console_ops = file.vfs_lookup_ops(console_name_ptr) orelse {
            return .{ .Open = .{ .result = -sos.ENODEV } };
        };

        const client_id_u16 = @as(u16, @intCast(client_id));
        console.acquireConsoleAccess(client_id_u16, want_read, want_write) catch {
            return .{ .Open = .{ .result = -sos.EBUSY } };
        };

        var dev_id: c_int = 0;
        if (console_ops.open) |open_fn| {
            const ret = open_fn(console_name_ptr, flags, &dev_id);
            if (ret < 0) {
                var temp_entry = file.empty_fd;
                temp_entry.readable = want_read;
                temp_entry.writable = want_write;
                console.releaseConsoleAccess(client_id_u16, &temp_entry);
                return .{ .Open = .{ .result = ret } };
            }
        }

        const fd_index: usize = @intCast(fd);
        const slot = &state.fds[fd_index];
        setupConsoleFd(slot, console_ops, want_read, want_write, dev_id);
        return .{ .Open = .{ .result = fd } };
    }

    fn startAsyncGetDirent(
        self: *ServerContext,
        caller: *sos.client_t,
        client_ctx: *clients.Client,
        vm_handle: *vm.VmHandle,
        index_minus_console: usize,
        out_addr: usize,
        out_len: usize,
    ) ?SyscallResponse {
        const cont = continuation.ContinuationPool.alloc() orelse {
            return .{ .GetDirent = .{ .result = -sos.ENOMEM } };
        };

        const old_reply_cap = self.reply.*;
        const old_reply_ut = self.reply_ut.*;
        const new_reply_ut = sos.alloc_retype(self.reply, sel4.seL4_ReplyObject, sel4.seL4_ReplyBits);
        if (new_reply_ut == null) {
            continuation.ContinuationPool.free(cont);
            self.reply.* = old_reply_cap;
            self.reply_ut.* = old_reply_ut;
            return .{ .GetDirent = .{ .result = -sos.ENOMEM } };
        }

        if (out_len <= 1) {
            continuation.ContinuationPool.free(cont);
            self.reply.* = old_reply_cap;
            self.reply_ut.* = old_reply_ut;
            return .{ .GetDirent = .{ .result = -sos.ENAMETOOLONG } };
        }

        const capacity = @min(out_len - 1, worker.WRITE_BUFFER_CAPACITY);

        cont.client = caller;
        cont.reply = old_reply_cap;
        cont.reply_ut = old_reply_ut;
        cont.resume_fn = fileOpResume;
        cont.state = .{
            .FileOp = worker.FileOpState{
                .params = .{
                    .GetDirent = .{
                        .index = index_minus_console,
                        .capacity = capacity,
                        .client_id = @intCast(client_ctx.id),
                        .out_buf = out_addr,
                        .out_len = out_len,
                    },
                },
            },
        };

        var state = &cont.state.FileOp;
        state.reset();
        state.vm_handle = vm_handle;
        state.payload_len = 0;

        continuation.FileOpQueue.enqueue(cont);

        const rc: c_int = worker.workerEnqueue(state);
        if (rc < 0) {
            continuation.FileOpQueue.remove(cont);
            self.reply.* = old_reply_cap;
            self.reply_ut.* = old_reply_ut;
            sos.ut_free(new_reply_ut.?);
            cont.cleanup();
            continuation.ContinuationPool.free(cont);
            return .{ .GetDirent = .{ .result = rc } };
        }

        self.have_reply.* = false;
        self.reply_ut.* = new_reply_ut.?;
        return null;
    }

    fn startAsyncOpen(
        self: *ServerContext,
        caller: *sos.client_t,
        client_ctx: *clients.Client,
        path: []const u8,
        flags: c_int,
    ) ?SyscallResponse {
        if (path.len == 0) {
            return SyscallResponse{ .Open = .{ .result = -sos.EINVAL } };
        }

        const cont = continuation.ContinuationPool.alloc() orelse {
            return SyscallResponse{ .Open = .{ .result = -sos.ENOMEM } };
        };

        const old_reply_cap = self.reply.*;
        const old_reply_ut = self.reply_ut.*;
        const new_reply_ut = sos.alloc_retype(self.reply, sel4.seL4_ReplyObject, sel4.seL4_ReplyBits);
        if (new_reply_ut == null) {
            continuation.ContinuationPool.free(cont);
            self.reply.* = old_reply_cap;
            self.reply_ut.* = old_reply_ut;
            return SyscallResponse{ .Open = .{ .result = -sos.ENOMEM } };
        }

        cont.client = caller;
        cont.reply = old_reply_cap;
        cont.reply_ut = old_reply_ut;
        cont.resume_fn = fileOpResume;
        cont.state = .{
            .FileOp = worker.FileOpState{
                .params = .{ .Open = .{
                    .path = undefined,
                    .flags = flags,
                    .client_id = @intCast(client_ctx.id),
                } },
            },
        };

        var file_op_state = &cont.state.FileOp;
        file_op_state.reset();

        const normalized_path = Path.initFromSlice(path) catch |err| {
            const errno: c_int = switch (err) {
                error.NameTooLong => sos.ENAMETOOLONG,
                error.InvalidComponent => sos.EPERM,
                error.Empty => sos.EINVAL,
            };
            continuation.FileOpQueue.remove(cont);
            self.reply.* = old_reply_cap;
            self.reply_ut.* = old_reply_ut;
            sos.ut_free(new_reply_ut.?);
            cont.cleanup();
            continuation.ContinuationPool.free(cont);
            return SyscallResponse{ .Open = .{ .result = -errno } };
        };

        var open_params = &file_op_state.params.Open;
        normalized_path.copyTo(open_params.path[0..]) catch |err| {
            const errno: c_int = switch (err) {
                error.NameTooLong => sos.ENAMETOOLONG,
                error.InvalidComponent => sos.EPERM,
                error.Empty => sos.EINVAL,
            };
            continuation.FileOpQueue.remove(cont);
            self.reply.* = old_reply_cap;
            self.reply_ut.* = old_reply_ut;
            sos.ut_free(new_reply_ut.?);
            cont.cleanup();
            continuation.ContinuationPool.free(cont);
            return SyscallResponse{ .Open = .{ .result = -errno } };
        };
        open_params.flags = flags;
        open_params.client_id = @intCast(client_ctx.id);

        continuation.FileOpQueue.enqueue(cont);

        const enqueue_rc: c_int = worker.workerEnqueue(file_op_state);
        if (enqueue_rc < 0) {
            continuation.FileOpQueue.remove(cont);
            self.reply.* = old_reply_cap;
            self.reply_ut.* = old_reply_ut;
            sos.ut_free(new_reply_ut.?);
            cont.cleanup();
            continuation.ContinuationPool.free(cont);
            return SyscallResponse{ .Open = .{ .result = enqueue_rc } };
        }

        self.have_reply.* = false;
        self.reply_ut.* = new_reply_ut.?;
        return null;
    }

    fn startAsyncRead(
        self: *ServerContext,
        caller: *sos.client_t,
        client_ctx: *clients.Client,
        vm_handle: *vm.VmHandle,
        fd_index: usize,
        user_buf: usize,
        requested: usize,
    ) ?SyscallResponse {
        const table = client_ctx.fileTable();
        _ = table.getHandle(fd_index) catch |err| {
            const errno: c_int = mapFileTableError(err);
            return SyscallResponse{ .Read = .{ .result = -errno } };
        };
        const io_state = client_ctx.ioState();
        if (fd_index >= io_state.fds.len) {
            return SyscallResponse{ .Read = .{ .result = -sos.EBADF } };
        }
        const fd_entry = io_state.fds[fd_index];
        if (!fd_entry.used or fd_entry.kind != file.FileKind.regular) {
            return SyscallResponse{ .Read = .{ .result = -sos.EBADF } };
        }
        if (!fd_entry.readable) {
            return SyscallResponse{ .Read = .{ .result = -sos.EBADF } };
        }

        const cont = continuation.ContinuationPool.alloc() orelse {
            return SyscallResponse{ .Read = .{ .result = -sos.ENOMEM } };
        };

        const old_reply_cap = self.reply.*;
        const old_reply_ut = self.reply_ut.*;
        const new_reply_ut = sos.alloc_retype(self.reply, sel4.seL4_ReplyObject, sel4.seL4_ReplyBits);
        if (new_reply_ut == null) {
            continuation.ContinuationPool.free(cont);
            self.reply.* = old_reply_cap;
            self.reply_ut.* = old_reply_ut;
            return SyscallResponse{ .Read = .{ .result = -sos.ENOMEM } };
        }

        const count = requested;

        cont.client = caller;
        cont.reply = old_reply_cap;
        cont.reply_ut = old_reply_ut;
        cont.resume_fn = fileOpResume;
        cont.state = .{
            .FileOp = worker.FileOpState{
                .params = .{ .Read = .{
                    .fd = fd_index,
                    .count = count,
                    .client_buf = user_buf,
                    .client_id = @intCast(client_ctx.id),
                } },
            },
        };

        var file_op_state = &cont.state.FileOp;
        file_op_state.reset();
        file_op_state.vm_handle = vm_handle;
        file_op_state.payload_len = 0;

        continuation.FileOpQueue.enqueue(cont);

        const enqueue_rc: c_int = worker.workerEnqueue(file_op_state);
        if (enqueue_rc < 0) {
            continuation.FileOpQueue.remove(cont);
            self.reply.* = old_reply_cap;
            self.reply_ut.* = old_reply_ut;
            sos.ut_free(new_reply_ut.?);
            cont.cleanup();
            continuation.ContinuationPool.free(cont);
            return SyscallResponse{ .Read = .{ .result = enqueue_rc } };
        }

        self.have_reply.* = false;
        self.reply_ut.* = new_reply_ut.?;
        return null;
    }

    fn startAsyncWrite(
        self: *ServerContext,
        caller: *sos.client_t,
        client_ctx: *clients.Client,
        vm_handle: *vm.VmHandle,
        fd_index: usize,
        user_buf: usize,
        requested: usize,
    ) ?SyscallResponse {
        const table = client_ctx.fileTable();
        _ = table.getHandle(fd_index) catch |err| {
            const errno: c_int = mapFileTableError(err);
            return SyscallResponse{ .Write = .{ .result = -errno } };
        };
        const io_state = client_ctx.ioState();
        if (fd_index >= io_state.fds.len) {
            return SyscallResponse{ .Write = .{ .result = -sos.EBADF } };
        }
        const fd_entry = io_state.fds[fd_index];
        if (!fd_entry.used or fd_entry.kind != file.FileKind.regular) {
            return SyscallResponse{ .Write = .{ .result = -sos.EBADF } };
        }
        if (!fd_entry.writable) {
            return SyscallResponse{ .Write = .{ .result = -sos.EBADF } };
        }

        const cont = continuation.ContinuationPool.alloc() orelse {
            return SyscallResponse{ .Write = .{ .result = -sos.ENOMEM } };
        };

        const old_reply_cap = self.reply.*;
        const old_reply_ut = self.reply_ut.*;
        const new_reply_ut = sos.alloc_retype(self.reply, sel4.seL4_ReplyObject, sel4.seL4_ReplyBits);
        if (new_reply_ut == null) {
            continuation.ContinuationPool.free(cont);
            self.reply.* = old_reply_cap;
            self.reply_ut.* = old_reply_ut;
            return SyscallResponse{ .Write = .{ .result = -sos.ENOMEM } };
        }

        const count = requested;

        cont.client = caller;
        cont.reply = old_reply_cap;
        cont.reply_ut = old_reply_ut;
        cont.resume_fn = fileOpResume;
        cont.state = .{
            .FileOp = worker.FileOpState{
                .params = .{ .Write = .{
                    .fd = fd_index,
                    .count = count,
                    .client_buf = user_buf,
                    .client_id = @intCast(client_ctx.id),
                } },
            },
        };

        var file_op_state = &cont.state.FileOp;
        file_op_state.reset();
        file_op_state.vm_handle = vm_handle;
        file_op_state.payload_len = 0;

        continuation.FileOpQueue.enqueue(cont);

        const enqueue_rc: c_int = worker.workerEnqueue(file_op_state);
        if (enqueue_rc < 0) {
            continuation.FileOpQueue.remove(cont);
            self.reply.* = old_reply_cap;
            self.reply_ut.* = old_reply_ut;
            sos.ut_free(new_reply_ut.?);
            cont.cleanup();
            continuation.ContinuationPool.free(cont);
            return SyscallResponse{ .Write = .{ .result = enqueue_rc } };
        }

        self.have_reply.* = false;
        self.reply_ut.* = new_reply_ut.?;
        return null;
    }

    fn startAsyncStat(
        self: *ServerContext,
        caller: *sos.client_t,
        client_ctx: *clients.Client,
        vm_handle: *vm.VmHandle,
        path: []const u8,
        out_addr: usize,
        out_len: usize,
    ) ?SyscallResponse {
        const cont = continuation.ContinuationPool.alloc() orelse {
            return SyscallResponse{ .Stat = .{ .result = -sos.ENOMEM } };
        };

        const old_reply_cap = self.reply.*;
        const old_reply_ut = self.reply_ut.*;
        const new_reply_ut = sos.alloc_retype(self.reply, sel4.seL4_ReplyObject, sel4.seL4_ReplyBits);
        if (new_reply_ut == null) {
            continuation.ContinuationPool.free(cont);
            self.reply.* = old_reply_cap;
            self.reply_ut.* = old_reply_ut;
            return SyscallResponse{ .Stat = .{ .result = -sos.ENOMEM } };
        }

        cont.client = caller;
        cont.reply = old_reply_cap;
        cont.reply_ut = old_reply_ut;
        cont.resume_fn = fileOpResume;
        cont.state = .{
            .FileOp = worker.FileOpState{
                .params = .{ .Stat = .{
                    .path = undefined,
                    .out_buf = out_addr,
                    .out_len = out_len,
                    .client_id = @intCast(client_ctx.id),
                } },
            },
        };

        var file_op_state = &cont.state.FileOp;
        file_op_state.reset();
        file_op_state.vm_handle = vm_handle;

        const normalized_path = Path.initFromSlice(path) catch |err| {
            const errno: c_int = switch (err) {
                error.NameTooLong => sos.ENAMETOOLONG,
                error.InvalidComponent => sos.EPERM,
                error.Empty => sos.EINVAL,
            };
            continuation.FileOpQueue.remove(cont);
            self.reply.* = old_reply_cap;
            self.reply_ut.* = old_reply_ut;
            sos.ut_free(new_reply_ut.?);
            cont.cleanup();
            continuation.ContinuationPool.free(cont);
            return SyscallResponse{ .Stat = .{ .result = -errno } };
        };

        var stat_params = &file_op_state.params.Stat;
        normalized_path.copyTo(stat_params.path[0..]) catch |err| {
            const errno: c_int = switch (err) {
                error.NameTooLong => sos.ENAMETOOLONG,
                error.InvalidComponent => sos.EPERM,
                error.Empty => sos.EINVAL,
            };
            continuation.FileOpQueue.remove(cont);
            self.reply.* = old_reply_cap;
            self.reply_ut.* = old_reply_ut;
            sos.ut_free(new_reply_ut.?);
            cont.cleanup();
            continuation.ContinuationPool.free(cont);
            return SyscallResponse{ .Stat = .{ .result = -errno } };
        };

        continuation.FileOpQueue.enqueue(cont);

        const enqueue_rc: c_int = worker.workerEnqueue(file_op_state);
        if (enqueue_rc < 0) {
            continuation.FileOpQueue.remove(cont);
            self.reply.* = old_reply_cap;
            self.reply_ut.* = old_reply_ut;
            sos.ut_free(new_reply_ut.?);
            cont.cleanup();
            continuation.ContinuationPool.free(cont);
            return SyscallResponse{ .Stat = .{ .result = enqueue_rc } };
        }

        self.have_reply.* = false;
        self.reply_ut.* = new_reply_ut.?;
        return null;
    }

    fn startAsyncClose(
        self: *ServerContext,
        caller: *sos.client_t,
        client_ctx: *clients.Client,
        fd_index: usize,
    ) ?SyscallResponse {
        const table = client_ctx.fileTable();
        _ = table.getHandle(fd_index) catch |err| {
            const errno: c_int = mapFileTableError(err);
            return SyscallResponse{ .Close = .{ .result = -errno } };
        };

        const cont = continuation.ContinuationPool.alloc() orelse {
            return SyscallResponse{ .Close = .{ .result = -sos.ENOMEM } };
        };

        const old_reply_cap = self.reply.*;
        const old_reply_ut = self.reply_ut.*;
        const new_reply_ut = sos.alloc_retype(self.reply, sel4.seL4_ReplyObject, sel4.seL4_ReplyBits);
        if (new_reply_ut == null) {
            continuation.ContinuationPool.free(cont);
            self.reply.* = old_reply_cap;
            self.reply_ut.* = old_reply_ut;
            return SyscallResponse{ .Close = .{ .result = -sos.ENOMEM } };
        }

        cont.client = caller;
        cont.reply = old_reply_cap;
        cont.reply_ut = old_reply_ut;
        cont.resume_fn = fileOpResume;
        cont.state = .{
            .FileOp = worker.FileOpState{
                .params = .{ .Close = .{
                    .fd = fd_index,
                    .client_id = @intCast(client_ctx.id),
                } },
            },
        };

        var file_op_state = &cont.state.FileOp;
        file_op_state.reset();

        continuation.FileOpQueue.enqueue(cont);

        const enqueue_rc: c_int = worker.workerEnqueue(file_op_state);
        if (enqueue_rc < 0) {
            continuation.FileOpQueue.remove(cont);
            self.reply.* = old_reply_cap;
            self.reply_ut.* = old_reply_ut;
            sos.ut_free(new_reply_ut.?);
            cont.cleanup();
            continuation.ContinuationPool.free(cont);
            return SyscallResponse{ .Close = .{ .result = enqueue_rc } };
        }

        self.have_reply.* = false;
        self.reply_ut.* = new_reply_ut.?;
        return null;
    }
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
        .Open => |args| ctx.handleOpen(args),
        .Close => |args| handleClose(ctx, args),
        .Read => |args| handleRead(ctx, args),
        .Write => |args| handleWrite(ctx, args),
        .Stat => |args| handleStat(ctx, args),
        .Usleep => |args| handleUsleep(ctx, args),
        .Timestamp => handleTimestamp(ctx),
        .MyId => handleMyId(ctx),
        .Brk => |args| handleBrk(ctx, args),
        .Mmap => |args| handleMmap(ctx, args),
        .GetDirent => |args| handleGetDirent(ctx, args),
    };
}

fn fileOpResume(
    _: *continuation.Continuation,
    _: ?*anyopaque,
    result: *continuation.ContinuationResult,
) callconv(.c) void {
    result.* = .{ .Error = .{ .errno = sos.ENOSYS } };
}

pub export fn checkCompletedFileOps() callconv(.c) void {
    while (continuation.FileOpQueue.pollCompleted()) |cont| {
        if (!cont.processFileOpCompletion()) {
            continuation.ContinuationPool.free(cont);
        }
    }
}

fn handleGetDirent(ctx: *ServerContext, args: anytype) ?SyscallResponse {
    const caller = ctx.caller orelse return .{ .GetDirent = .{ .result = -sos.EINVAL } };
    const client_id: usize = @intCast(caller.id);
    if (client_id >= MAX_CLIENTS) return .{ .GetDirent = .{ .result = -sos.EINVAL } };

    const client_ctx = clients.get(client_id) orelse return .{ .GetDirent = .{ .result = -sos.EINVAL } };
    _ = client_ctx.ioState();

    const vm_handle = ctx.vm_handle orelse return .{ .GetDirent = .{ .result = -sos.EINVAL } };

    const idx: usize = @intCast(args.index);
    const out_addr: usize = @intCast(args.buf_addr);
    const out_len: usize = @intCast(args.buf_size);

    if (out_len == 0) return .{ .GetDirent = .{ .result = -sos.EINVAL } };

    if (idx == 0) {
        const name = console_name;
        const need: usize = name.len;
        if (out_len < need + 1) {
            return .{ .GetDirent = .{ .result = -sos.ENAMETOOLONG } };
        }
        vm_handle.copyToClient(name, out_addr) catch |err| {
            return .{ .GetDirent = .{ .result = -vm.vmErrorToErrno(err) } };
        };
        const nul: [1]u8 = .{0};
        vm_handle.copyToClient(nul[0..], out_addr + need) catch |err| {
            return .{ .GetDirent = .{ .result = -vm.vmErrorToErrno(err) } };
        };
        return .{ .GetDirent = .{ .result = @intCast(need) } };
    }

    return ctx.startAsyncGetDirent(caller, client_ctx, vm_handle, idx - 1, out_addr, out_len);
}

fn handleClose(ctx: *ServerContext, args: anytype) ?SyscallResponse {
    const caller = ctx.caller orelse {
        return SyscallResponse{ .Close = .{ .result = @as(c_int, (-sos.EINVAL)) } };
    };
    const client_id: usize = @intCast(caller.id);
    const client_id_u16 = @as(@TypeOf(sos.global_console.reader_owner_id), @intCast(client_id));
    if (client_id >= MAX_CLIENTS) {
        return SyscallResponse{ .Close = .{ .result = @as(c_int, (-sos.EINVAL)) } };
    }

    const client_ctx = clients.get(client_id) orelse {
        return SyscallResponse{ .Close = .{ .result = @as(c_int, (-sos.EINVAL)) } };
    };
    var state = client_ctx.ioState();
    ensureStdio(state, client_id_u16);
    if (!state.initialised) {
        return SyscallResponse{ .Close = .{ .result = @as(c_int, (-sos.EBADF)) } };
    }

    const fd_raw: c_int = @intCast(args.arg);
    if (fd_raw < 0 or fd_raw >= SOS_MAX_OPEN_FILES) {
        return SyscallResponse{ .Close = .{ .result = @as(c_int, (-sos.EBADF)) } };
    }

    const fd_index: usize = @intCast(fd_raw);
    const is_console = fd_index < state.fds.len and state.fds[fd_index].used and
        state.fds[fd_index].kind == file.FileKind.dev_console;

    if (is_console) {
        const entry = &state.fds[fd_index];
        if (entry.refcnt > 1) {
            entry.refcnt -= 1;
            return SyscallResponse{ .Close = .{ .result = 0 } };
        }

        console.releaseConsoleAccess(client_id_u16, entry);

        if (entry.ops) |ops_ptr| {
            if (ops_ptr.close) |close_fn| {
                _ = close_fn(entry.dev_id);
            }
        }

        entry.* = empty_fd;
        return SyscallResponse{ .Close = .{ .result = @as(c_int, (0)) } };
    }

    return ctx.startAsyncClose(caller, client_ctx, fd_index);
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

    const ctx_lookup = clients.get(@intCast(cont.client.id)) orelse {
        result.* = .{ .Error = .{ .errno = sos.EINVAL } };
        return;
    };
    // Validate file descriptor is still valid
    var io_state = ctx_lookup.ioState();
    if (!io_state.initialised) {
        result.* = .{ .Error = .{ .errno = sos.EBADF } };
        return;
    }

    const entry = &io_state.fds[state.fd_index];
    if (!entry.used or !entry.readable or entry.ops != state.ops) {
        result.* = .{ .Error = .{ .errno = sos.EBADF } };
        return;
    }

    const read_fn = state.ops.read orelse {
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

    const client_ctx = clients.get(client_id) orelse return .{ .Read = .{ .result = -sos.EINVAL } };
    const client_id_u16 = @as(u16, @intCast(client_ctx.id));
    const state = client_ctx.ioState();
    ensureStdio(state, client_id_u16);
    if (!state.initialised) return .{ .Read = .{ .result = -sos.EBADF } };

    const fd_raw: c_int = @intCast(args.arg);
    if (fd_raw < 0 or fd_raw >= SOS_MAX_OPEN_FILES) return .{ .Read = .{ .result = -sos.EBADF } };

    const fd_index: usize = @intCast(fd_raw);
    const user_buf_addr: usize = @intCast(args.buf_addr);
    const req: usize = @intCast(args.buf_size);
    if (req == 0) return .{ .Read = .{ .result = 0 } };

    const vm_handle = ctx.vm_handle orelse return .{ .Read = .{ .result = -sos.EINVAL } };

    const is_console = fd_index < state.fds.len and state.fds[fd_index].used and
        state.fds[fd_index].kind == file.FileKind.dev_console;

    if (is_console) {
        const entry = &state.fds[fd_index];
        if (!entry.readable) {
            return .{ .Read = .{ .result = -sos.EBADF } };
        }
        const ops_ptr = entry.ops orelse return .{ .Read = .{ .result = -sos.ENOSYS } };
        const read_fn = ops_ptr.read orelse return .{ .Read = .{ .result = -sos.ENOSYS } };

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

        const moved_or_err = vm_handle.withUserSlice(
            user_buf_addr,
            req,
            .writeOnly,
            .{ .ctx = &read_ctx, .func = ReadCtx.op },
        );
        var moved: usize = 0;

        moved = moved_or_err catch |err| {
            if (err == error.DeviceError) {
                return .{ .Read = .{ .result = -read_ctx.errno } };
            }

            const errno: c_int = vm.vmErrorToErrno(err);
            return .{ .Read = .{ .result = -errno } };
        };

        if (moved == 0 and read_ctx.would_block) {
            const cont = continuation.ContinuationPool.alloc() orelse {
                return .{ .Read = .{ .result = -sos.ENOMEM } };
            };

            const old_reply_cap = ctx.reply.*;
            const old_reply_ut = ctx.reply_ut.*;
            const new_reply_ut = sos.alloc_retype(ctx.reply, sel4.seL4_ReplyObject, sel4.seL4_ReplyBits);
            if (new_reply_ut == null) {
                continuation.ContinuationPool.free(cont);
                ctx.reply.* = old_reply_cap;
                ctx.reply_ut.* = old_reply_ut;
                return .{ .Read = .{ .result = -sos.ENOMEM } };
            }

            cont.client = caller;
            cont.reply = old_reply_cap;
            cont.reply_ut = old_reply_ut;
            cont.resume_fn = readResumeFn;
            cont.state = .{
                .Read = .{
                    .fd_index = fd_index,
                    .vm_handle = vm_handle,
                    .user_buf_addr = user_buf_addr,
                    .requested = req,
                    .ops = ops_ptr,
                    .dev_id = entry.dev_id,
                },
            };

            continuation.WaitQueues.waitIO(cont, continuation.CONSOLE_STDIN_FD);

            ctx.have_reply.* = false;
            ctx.reply_ut.* = new_reply_ut.?;
            return null;
        }

        return .{ .Read = .{ .result = @intCast(moved) } };
    }

    return ctx.startAsyncRead(caller, client_ctx, vm_handle, fd_index, user_buf_addr, req);
}

fn handleWrite(ctx: *ServerContext, args: anytype) ?SyscallResponse {
    const caller = ctx.caller orelse return .{ .Write = .{ .result = -sos.EINVAL } };
    const client_id: usize = @intCast(caller.id);
    if (client_id >= MAX_CLIENTS) return .{ .Write = .{ .result = -sos.EINVAL } };

    const client_ctx = clients.get(client_id) orelse return .{ .Write = .{ .result = -sos.EINVAL } };
    const client_id_u16 = @as(u16, @intCast(client_ctx.id));
    const state = client_ctx.ioState();
    ensureStdio(state, client_id_u16);
    if (!state.initialised) return .{ .Write = .{ .result = -sos.EBADF } };

    const fd_raw: c_int = @intCast(args.arg);
    if (fd_raw < 0 or fd_raw >= SOS_MAX_OPEN_FILES) return .{ .Write = .{ .result = -sos.EBADF } };

    const fd_index: usize = @intCast(fd_raw);
    const user_buf_addr: usize = @intCast(args.buf_addr);
    const req: usize = @intCast(args.buf_size);
    if (req == 0) return .{ .Write = .{ .result = 0 } };

    const vm_handle = ctx.vm_handle orelse return .{ .Write = .{ .result = -sos.EINVAL } };

    const is_console = fd_index < state.fds.len and state.fds[fd_index].used and
        state.fds[fd_index].kind == file.FileKind.dev_console;

    if (is_console) {
        const entry = &state.fds[fd_index];
        if (!entry.writable) {
            return .{ .Write = .{ .result = -sos.EBADF } };
        }
        const write_fn = entry.ops.?.write orelse return .{ .Write = .{ .result = -sos.ENOSYS } };

        const WriteCtx = struct {
            dev_id: c_int,
            write_fn: *const fn (c_int, ?*const anyopaque, usize) callconv(.c) isize,
            errno: c_int = 0,
            pub const Self = @This();
            pub fn op(ctx_opaque: *anyopaque, p: [*]u8, n: usize) anyerror!usize {
                const self: *Self = @ptrCast(@alignCast(ctx_opaque));
                const ro: [*]const u8 = p;
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
        const moved_or_err = vm_handle.withUserSlice(user_buf_addr, req, .readOnly, .{ .ctx = &wctx, .func = WriteCtx.op });

        const moved: usize = moved_or_err catch |err| {
            if (err == error.DeviceError) return .{ .Write = .{ .result = -wctx.errno } };
            const errno: c_int = vm.vmErrorToErrno(err);
            return .{ .Write = .{ .result = -errno } };
        };

        return .{ .Write = .{ .result = @intCast(moved) } };
    }

    return ctx.startAsyncWrite(caller, client_ctx, vm_handle, fd_index, user_buf_addr, req);
}

fn handleStat(ctx: *ServerContext, args: anytype) ?SyscallResponse {
    const caller = ctx.caller orelse return .{ .Stat = .{ .result = -sos.EINVAL } };
    const client_id: usize = @intCast(caller.id);
    if (client_id >= MAX_CLIENTS) return .{ .Stat = .{ .result = -sos.EINVAL } };

    const client_ctx = clients.get(client_id) orelse return .{ .Stat = .{ .result = -sos.EINVAL } };
    const client_id_u16 = @as(u16, @intCast(client_ctx.id));
    const state = client_ctx.ioState();
    ensureStdio(state, client_id_u16);

    const path_len = std.math.cast(usize, args.path_len) orelse return .{ .Stat = .{ .result = -sos.EINVAL } };
    const out_len = std.math.cast(usize, args.out_len) orelse return .{ .Stat = .{ .result = -sos.EINVAL } };

    if (path_len == 0 or path_len > worker.OPEN_PATH_CAPACITY) {
        return .{ .Stat = .{ .result = -sos.EINVAL } };
    }

    const stat_size = @sizeOf(sos_types.sos_stat_t);
    if (out_len < stat_size) {
        return .{ .Stat = .{ .result = -sos.ENOMEM } };
    }

    const vm_handle = ctx.vm_handle orelse return .{ .Stat = .{ .result = -sos.EINVAL } };

    var path_buf: [worker.OPEN_PATH_CAPACITY:0]u8 = undefined;
    @memset(path_buf[0..], 0);

    const copied = vm_handle.copyCStringFromClient(@intCast(args.path_addr), path_buf[0..path_buf.len]) catch |err| {
        const errno: c_int = vm.vmErrorToErrno(err);
        return .{ .Stat = .{ .result = -errno } };
    };

    if (copied == 0) {
        return .{ .Stat = .{ .result = -sos.EINVAL } };
    }
    if (copied >= path_buf.len) {
        return .{ .Stat = .{ .result = -sos.ENAMETOOLONG } };
    }

    path_buf[copied] = 0;
    const path_slice = path_buf[0..copied];

    if (path_slice.len == console_name.len and std.mem.eql(u8, path_slice, console_name)) {
        var console_stat = sos_types.sos_stat_t{
            .st_type = sos.ST_SPECIAL,
            .st_fmode = sos.FM_READ | sos.FM_WRITE,
            .st_size = 0,
            .st_ctime = 0,
            .st_atime = 0,
        };
        const stat_bytes = std.mem.asBytes(&console_stat);
        vm_handle.copyToClient(stat_bytes, @intCast(args.out_addr)) catch |err| {
            const errno: c_int = vm.vmErrorToErrno(err);
            return .{ .Stat = .{ .result = -errno } };
        };
        return .{ .Stat = .{ .result = 0 } };
    }

    return ctx.startAsyncStat(caller, client_ctx, vm_handle, path_slice, @intCast(args.out_addr), out_len);
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
const sos_types = cimports.sos_types;

const vm = @import("vm/mod.zig");
pub const worker = @import("worker.zig");
pub const delegation = @import("delegation.zig");
pub const nfs_handler = @import("nfs_handler.zig");
comptime {
    _ = worker;
    _ = delegation;
    _ = nfs_handler;
    _ = continuation;
    _ = &continuation.continuation_bootstrap;
}

pub extern var cspace: sos.cspace_t;

const helpers = @import("helpers.zig");
const resultToCInt = helpers.resultToCInt;

const file = @import("file.zig");
const empty_fd = file.empty_fd;
const SosClientIoState = file.ClientIoState;
const clients = @import("client.zig");

const console = @import("console.zig");
const PendingConsoleRead = console.PendingConsoleRead;
const ensureStdio = console.ensureStdio;
const setupConsoleFd = console.setupConsoleFd;
const console_object_ptr = console.console_object_ptr;

pub const continuation = @import("continuation.zig");
