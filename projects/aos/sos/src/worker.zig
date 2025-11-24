const std = @import("std");
const sel4 = @import("cimports").sel4;
const sos = @import("cimports").sos;
const c = @import("cimports").c;
const sos_types = @import("cimports").sos_types;
const types = @import("worker_types.zig");
const clients = @import("client.zig");
const file = @import("file.zig");
const nfs_handler = @import("nfs_handler.zig");
const vm = @import("vm/mod.zig");
const pagefile = @import("pagefile.zig");
const ROOT_DIR: [:0]const u8 = "/";

const MAX_WORK_QUEUE = 16;
pub const WORKER_COUNT: usize = 4;

pub const WorkType = types.WorkType;
pub const WorkParams = types.WorkParams;
pub const OpenParams = types.OpenParams;
pub const CloseParams = types.CloseParams;
pub const ReadParams = types.ReadParams;
pub const WriteParams = types.WriteParams;
pub const StatParams = types.StatParams;
pub const OpenDirParams = types.OpenDirParams;
pub const ReadDirParams = types.ReadDirParams;
pub const FileOpState = types.FileOpState;
pub const FileOpResult = types.FileOpResult;
pub const OPEN_PATH_CAPACITY = types.OPEN_PATH_CAPACITY;
pub const WRITE_BUFFER_CAPACITY = types.WRITE_BUFFER_CAPACITY;
pub const PageFillSource = types.PageFillSource;

fn mapNfsError(err: anyerror) c_int {
    return switch (err) {
        error.NoNFSContext => sos.ENODEV,
        error.PoolExhausted => sos.EAGAIN,
        error.NotFound => sos.ENOENT,
        error.PermissionDenied => sos.EACCES,
        error.OutOfMemory => sos.ENOMEM,
        error.NetworkUnreachable => sos.ENETUNREACH,
        error.NFSOperationFailed => sos.EIO,
        error.OperationFailed => sos.EIO,
        else => sos.EIO,
    };
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

pub const WorkItem = struct {
    file_op: *FileOpState,

    const Self = @This();

    pub fn process(self: Self, worker: *Worker) void {
        const tag = std.meta.activeTag(self.file_op.params);
        _ = c.printf("[worker] WorkItem.process: tag=%u\n", @as(c_uint, @intFromEnum(tag)));
        switch (tag) {
            .Open => worker.workerOpenFile(self.file_op),
            .Close => worker.workerCloseFile(self.file_op),
            .Read => worker.workerReadFile(self.file_op),
            .Write => worker.workerWriteFile(self.file_op),
            .Stat => worker.workerStatFile(self.file_op),
            .OpenDir => worker.workerOpenDir(self.file_op),
            .ReadDir => worker.workerReadDir(self.file_op),
            .GetDirent => worker.workerGetDirent(self.file_op),
            .PageFill => {
                _ = c.printf("[worker] WorkItem.process: dispatching to workerPageFill\n");
                // Enforce per-slot single inflight: PageFill will EAGAIN if slot busy.
                worker.workerPageFill(self.file_op);
            },
            .PageOut => {
                _ = c.printf("[worker] WorkItem.process: dispatching to workerPageOut\n");
                worker.workerPageOut(self.file_op);
            },
            .Lseek => worker.workerLseek(self.file_op),
            .Unlink => worker.workerUnlink(self.file_op),
        }
    }
};

/// Single-producer single-consumer atomic work queue
pub const WorkQueue = struct {
    items: [MAX_WORK_QUEUE]WorkItem,
    head: u32 align(4),
    tail: u32 align(4),
    notification: sel4.seL4_CPtr,

    pub const Self = @This();

    pub fn init(ntfn: sel4.seL4_CPtr) WorkQueue {
        return WorkQueue{
            .items = undefined,
            .head = 0,
            .tail = 0,
            .notification = ntfn,
        };
    }

    /// Enqueue work item. Returns error.QueueFull if no space available.
    /// WARN: Only main thread should call this
    pub fn enqueue(self: *Self, file_op: *FileOpState) !void {
        const curr_head = @atomicLoad(u32, &self.head, .acquire);
        const next_head = (curr_head + 1) % MAX_WORK_QUEUE;
        const curr_tail = @atomicLoad(u32, &self.tail, .acquire);

        if (next_head == curr_tail) {
            return error.QueueFull;
        }

        self.items[curr_head] = WorkItem{ .file_op = file_op };

        @atomicStore(u32, &self.head, next_head, .release);
        _ = c.printf("[worker] WorkQueue.enqueue: signaling ntfn=%lu head=%u tail=%u\n", self.notification, next_head, curr_tail);
        sel4.seL4_Signal(self.notification);
    }

    /// Dequeue work item
    /// WARN: Only worker thread should call this
    pub fn dequeue(self: *Self) ?WorkItem {
        const curr_tail = @atomicLoad(u32, &self.tail, .acquire);
        const curr_head = @atomicLoad(u32, &self.head, .acquire);

        if (curr_tail == curr_head) {
            return null; // Queue empty
        }

        const item = self.items[curr_tail];
        const next_tail = (curr_tail + 1) % MAX_WORK_QUEUE;
        @atomicStore(u32, &self.tail, next_tail, .release);

        return item;
    }

    pub fn drain(self: *Self, worker: *Worker) void {
        _ = c.printf("[worker] drain: checking queue head=%u tail=%u\n", @atomicLoad(u32, &self.head, .acquire), @atomicLoad(u32, &self.tail, .acquire));
        var count: usize = 0;
        while (self.dequeue()) |item| {
            count += 1;
            _ = c.printf("[worker] drain: processing item %zu\n", count);
            item.process(worker);
        }
        _ = c.printf("[worker] drain: processed %zu items\n", count);
    }
};

pub const Worker = struct {
    queue: WorkQueue,
    delegate_ep: sel4.seL4_CPtr,

    const Self = @This();

    pub fn init(delegate_ep: sel4.seL4_CPtr, work_ntfn: sel4.seL4_CPtr) Worker {
        return Worker{
            .queue = WorkQueue.init(work_ntfn),
            .delegate_ep = delegate_ep,
        };
    }

    /// Enqueue work item
    pub fn enqueue(self: *Self, file_op: *FileOpState) !void {
        try self.queue.enqueue(file_op);
    }

    /// Main worker thread loop
    pub fn run(self: *Self) void {
        _ = c.printf("[worker] Worker thread started (delegate_ep=%lu)\n", self.delegate_ep);

        while (true) {
            // Wait for work notification
            _ = c.printf("[worker] entering seL4_Wait on ntfn=%lu\n", self.queue.notification);
            _ = sel4.seL4_Wait(self.queue.notification, null);
            _ = c.printf("[worker] seL4_Wait returned, draining queue\n");

            self.queue.drain(self);

            self.signalQueueSpaceAvailable();
        }
    }

    /// Signal any waiting continuations that queue has space
    fn signalQueueSpaceAvailable(self: *Self) void {
        _ = self;
        // TODO: Implement continuation integration
    }

    fn workerOpenFile(self: *Self, file_op: *FileOpState) void {
        _ = self;
        const tag = std.meta.activeTag(file_op.params);
        if (tag != .Open) {
            _ = c.printf("[worker] workerOpenFile received mismatched params tag=%u\n", @as(c_uint, @intFromEnum(tag)));
            file_op.completeErrno(sos.EINVAL);
            return;
        }

        var params = &file_op.params.Open;
        const client_idx: usize = @intCast(params.client_id);
        const client_ctx = clients.get(client_idx) orelse {
            _ = c.printf("[worker] workerOpenFile invalid client_id=%u\n", params.client_id);
            file_op.completeErrno(sos.EINVAL);
            return;
        };

        const access = params.flags & c.O_ACCMODE;
        const want_read = access == c.O_RDONLY or access == c.O_RDWR;
        const want_write = access == c.O_WRONLY or access == c.O_RDWR;
        const want_create = (params.flags & c.O_CREAT) != 0;

        const path_ptr: [*:0]const u8 = @ptrCast(&params.path);
        _ = c.printf("[worker] open request client=%u path=\"%s\" flags=0x%x\n", params.client_id, path_ptr, params.flags);

        var stat_buf: sos_types.sos_stat_t = undefined;
        var file_exists = true;
        nfs_handler.statSync(path_ptr, &stat_buf) catch |err| switch (err) {
            error.NotFound => file_exists = false,
            error.PermissionDenied => {
                file_op.completeErrno(sos.EACCES);
                return;
            },
            else => {
                const errno = mapNfsError(err);
                file_op.completeErrno(errno);
                return;
            },
        };

        if (!file_exists and !want_create) {
            file_op.completeErrno(sos.ENOENT);
            return;
        }

        if (file_exists) {
            if (want_read and (stat_buf.st_fmode & sos_types.FM_READ) == 0) {
                file_op.completeErrno(sos.EACCES);
                return;
            }
            if (want_write and (stat_buf.st_fmode & sos_types.FM_WRITE) == 0) {
                file_op.completeErrno(sos.EACCES);
                return;
            }
        }

        const handle = nfs_handler.openSync(path_ptr, params.flags) catch |err| {
            const errno = mapNfsError(err);
            _ = c.printf("[worker] openSync failed errno=%d\n", errno);
            file_op.completeErrno(errno);
            return;
        };

        const io_state = client_ctx.ioState();
        const handle_ref = io_state.allocHandleRef(handle) catch {
            nfs_handler.closeSync(handle) catch {};
            file_op.completeErrno(sos.EMFILE);
            return;
        };

        const table = client_ctx.fileTable();
        const fd = table.allocFd(@ptrCast(handle_ref)) catch |alloc_err| {
            const errno = mapFileTableError(alloc_err);
            _ = c.printf("[worker] allocFd failed errno=%d\n", errno);
            const release = io_state.releaseHandleRef(handle_ref);
            switch (release) {
                .Active => {},
                .Closed => |raw| {
                    nfs_handler.closeSync(raw) catch {};
                },
            }
            file_op.completeErrno(errno);
            return;
        };

        file.setHandleFdHint(handle_ref, @intCast(fd));

        if (fd >= io_state.fds.len) {
            _ = c.printf("[worker] fd index %zu out of range\n", fd);
            const release = io_state.releaseHandleRef(handle_ref);
            switch (release) {
                .Active => {},
                .Closed => |raw| {
                    nfs_handler.closeSync(raw) catch {};
                },
            }
            table.freeFd(fd) catch {};
            file_op.completeErrno(sos.EMFILE);
            return;
        }
        var entry = &io_state.fds[fd];
        entry.* = file.empty_fd;
        entry.used = true;
        entry.readable = want_read;
        entry.writable = want_write;
        entry.kind = file.FileKind.regular;
        entry.obj = @ptrCast(handle_ref);
        entry.offset = 0;
        entry.refcnt = 1;

        file_op.completeFd(fd);
        _ = c.printf("[worker] open completed client=%u fd=%zu\n", params.client_id, fd);
    }

    fn workerReadFile(self: *Self, file_op: *FileOpState) void {
        _ = self;
        const tag = std.meta.activeTag(file_op.params);
        if (tag != .Read) {
            _ = c.printf("[worker] workerReadFile received mismatched params tag=%u\n", @as(c_uint, @intFromEnum(tag)));
            file_op.completeErrno(sos.EINVAL);
            return;
        }
        const params = &file_op.params.Read;
        const client_ctx = clients.get(@intCast(params.client_id)) orelse {
            file_op.completeErrno(sos.EINVAL);
            return;
        };
        const io_state = client_ctx.ioState();
        if (params.fd >= io_state.fds.len) {
            file_op.completeErrno(sos.EBADF);
            return;
        }
        var fd_entry = &io_state.fds[params.fd];
        if (!fd_entry.used or fd_entry.kind != file.FileKind.regular) {
            file_op.completeErrno(sos.EBADF);
            return;
        }
        if (!fd_entry.readable) {
            file_op.completeErrno(sos.EBADF);
            return;
        }

        const table = client_ctx.fileTable();
        const handle_ptr = table.getHandle(params.fd) catch |err| {
            const errno = mapFileTableError(err);
            file_op.completeErrno(errno);
            return;
        };
        const handle_ref = file.handleRefFromOpaque(handle_ptr) orelse {
            file_op.completeErrno(sos.EBADF);
            return;
        };
        const handle = file.rawFileHandle(handle_ref);

        const vm_handle = file_op.vm_handle orelse {
            file_op.completeErrno(sos.EFAULT);
            return;
        };

        var remaining = params.count;
        var total_read: usize = 0;

        while (remaining > 0) {
            const chunk = @min(remaining, WRITE_BUFFER_CAPACITY);
            const buf_ptr: [*]u8 = @as([*]u8, @ptrCast(&file_op.payload[0]));
            const read_bytes = nfs_handler.readSync(handle, buf_ptr, chunk) catch |err| {
                const errno = mapNfsError(err);
                file_op.completeErrno(errno);
                return;
            };

            if (read_bytes == 0) {
                break;
            }

            vm_handle.copyToClient(buf_ptr[0..read_bytes], params.client_buf + total_read) catch |err| {
                const errno = vm.vmErrorToErrno(err);
                file_op.completeErrno(errno);
                return;
            };

            total_read += read_bytes;
            remaining -= read_bytes;
            if (read_bytes < chunk) {
                break;
            }
        }

        fd_entry.offset += total_read;
        file_op.payload_len = 0;
        file_op.completeBytes(total_read);
    }

    fn workerWriteFile(self: *Self, file_op: *FileOpState) void {
        _ = self;
        const tag = std.meta.activeTag(file_op.params);
        if (tag != .Write) {
            _ = c.printf("[worker] workerWriteFile received mismatched params tag=%u\n", @as(c_uint, @intFromEnum(tag)));
            file_op.completeErrno(sos.EINVAL);
            return;
        }

        const params = &file_op.params.Write;
        const client_ctx = clients.get(@intCast(params.client_id)) orelse {
            file_op.completeErrno(sos.EINVAL);
            return;
        };
        const io_state = client_ctx.ioState();
        if (params.fd >= io_state.fds.len) {
            file_op.completeErrno(sos.EBADF);
            return;
        }
        var fd_entry = &io_state.fds[params.fd];
        if (!fd_entry.used or fd_entry.kind != file.FileKind.regular) {
            file_op.completeErrno(sos.EBADF);
            return;
        }
        if (!fd_entry.writable) {
            file_op.completeErrno(sos.EBADF);
            return;
        }

        const table = client_ctx.fileTable();
        const handle_ptr = table.getHandle(params.fd) catch |err| {
            const errno = mapFileTableError(err);
            file_op.completeErrno(errno);
            return;
        };
        const handle_ref = file.handleRefFromOpaque(handle_ptr) orelse {
            file_op.completeErrno(sos.EBADF);
            return;
        };
        const handle = file.rawFileHandle(handle_ref);

        const vm_handle = file_op.vm_handle orelse {
            file_op.completeErrno(sos.EFAULT);
            return;
        };

        var remaining = params.count;
        var total_written: usize = 0;

        while (remaining > 0) {
            const chunk = @min(remaining, WRITE_BUFFER_CAPACITY);
            const buf_slice = file_op.payload[0..chunk];
            vm_handle.copyFromClient(buf_slice, params.client_buf + total_written) catch |err| {
                const errno = vm.vmErrorToErrno(err);
                file_op.completeErrno(errno);
                return;
            };

            const buf_ptr: [*]const u8 = @as([*]const u8, @ptrCast(&buf_slice[0]));
            const written = nfs_handler.writeSync(handle, buf_ptr, chunk) catch |err| {
                const errno = mapNfsError(err);
                file_op.completeErrno(errno);
                return;
            };

            total_written += written;
            remaining -= written;
            if (written < chunk) {
                break;
            }
        }

        fd_entry.offset += total_written;
        file_op.completeBytes(total_written);
    }

    fn workerCloseFile(self: *Self, file_op: *FileOpState) void {
        _ = self;
        const tag = std.meta.activeTag(file_op.params);
        if (tag != .Close) {
            _ = c.printf("[worker] workerCloseFile received mismatched params tag=%u\n", @as(c_uint, @intFromEnum(tag)));
            file_op.completeErrno(sos.EINVAL);
            return;
        }

        const params = &file_op.params.Close;
        const client_ctx = clients.get(@intCast(params.client_id)) orelse {
            file_op.completeErrno(sos.EINVAL);
            return;
        };
        const io_state = client_ctx.ioState();
        const fd_index = params.fd;
        if (fd_index >= io_state.fds.len) {
            file_op.completeErrno(sos.EBADF);
            return;
        }
        const entry = &io_state.fds[fd_index];
        if (!entry.used) {
            file_op.completeErrno(sos.EBADF);
            return;
        }

        const table = client_ctx.fileTable();
        const handle_ptr = table.getHandle(params.fd) catch |err| {
            const errno = mapFileTableError(err);
            file_op.completeErrno(errno);
            return;
        };
        const handle_ref = file.handleRefFromOpaque(handle_ptr) orelse {
            file_op.completeErrno(sos.EBADF);
            return;
        };
        const release = io_state.releaseHandleRef(handle_ref);
        switch (release) {
            .Active => {},
            .Closed => |raw| {
                nfs_handler.closeSync(raw) catch |err| {
                    const errno = mapNfsError(err);
                    file_op.completeErrno(errno);
                    return;
                };
            },
        }

        table.freeFd(params.fd) catch |err| {
            const errno = mapFileTableError(err);
            file_op.completeErrno(errno);
            return;
        };
        entry.* = file.empty_fd;

        file_op.completeStatus(0);
    }

    fn workerLseek(self: *Self, file_op: *FileOpState) void {
        _ = self;
        const tag = std.meta.activeTag(file_op.params);
        if (tag != .Lseek) {
            _ = c.printf("[worker] workerLseek received mismatched params tag=%u\n", @as(c_uint, @intFromEnum(tag)));
            file_op.completeErrno(sos.EINVAL);
            return;
        }

        const params = &file_op.params.Lseek;
        const client_ctx = clients.get(@intCast(params.client_id)) orelse {
            file_op.completeErrno(sos.EINVAL);
            return;
        };
        const io_state = client_ctx.ioState();
        if (params.fd >= io_state.fds.len) {
            file_op.completeErrno(sos.EBADF);
            return;
        }
        var fd_entry = &io_state.fds[params.fd];
        if (!fd_entry.used or fd_entry.kind != file.FileKind.regular) {
            file_op.completeErrno(sos.EBADF);
            return;
        }

        const table = client_ctx.fileTable();
        const handle_ptr = table.getHandle(params.fd) catch |err| {
            const errno = mapFileTableError(err);
            file_op.completeErrno(errno);
            return;
        };
        const handle_ref = file.handleRefFromOpaque(handle_ptr) orelse {
            file_op.completeErrno(sos.EBADF);
            return;
        };
        const handle = file.rawFileHandle(handle_ref);

        if (params.whence != c.SEEK_SET and params.whence != c.SEEK_CUR and params.whence != c.SEEK_END) {
            file_op.completeErrno(sos.EINVAL);
            return;
        }

        const seek_result = nfs_handler.lseekSync(handle, params.offset, params.whence) catch |err| {
            const errno = mapNfsError(err);
            file_op.completeErrno(errno);
            return;
        };

        const signed_offset = std.math.cast(i64, seek_result) orelse {
            file_op.completeErrno(sos.EOVERFLOW);
            return;
        };
        const offset_usize = std.math.cast(usize, seek_result) orelse {
            file_op.completeErrno(sos.EOVERFLOW);
            return;
        };

        fd_entry.offset = offset_usize;
        file_op.completeOffset(signed_offset);
    }

    fn workerUnlink(self: *Self, file_op: *FileOpState) void {
        _ = self;
        const tag = std.meta.activeTag(file_op.params);
        if (tag != .Unlink) {
            _ = c.printf("[worker] workerUnlink received mismatched params tag=%u\n", @as(c_uint, @intFromEnum(tag)));
            file_op.completeErrno(sos.EINVAL);
            return;
        }

        const params = &file_op.params.Unlink;
        const path_ptr: [*:0]const u8 = @ptrCast(&params.path);
        nfs_handler.unlinkSync(path_ptr) catch |err| {
            const errno = mapNfsError(err);
            file_op.completeErrno(errno);
            return;
        };
        file_op.completeStatus(0);
    }

    fn workerStatFile(self: *Self, file_op: *FileOpState) void {
        _ = self;
        const tag = std.meta.activeTag(file_op.params);
        if (tag != .Stat) {
            _ = c.printf("[worker] workerStatFile received mismatched params tag=%u\n", @as(c_uint, @intFromEnum(tag)));
            file_op.completeErrno(sos.EINVAL);
            return;
        }
        const params = &file_op.params.Stat;
        _ = clients.get(@intCast(params.client_id)) orelse {
            file_op.completeErrno(sos.EINVAL);
            return;
        };

        if (params.out_len < @sizeOf(sos_types.sos_stat_t)) {
            file_op.completeErrno(sos.ENOMEM);
            return;
        }

        const path_ptr: [*:0]const u8 = @ptrCast(&params.path);
        nfs_handler.statSync(path_ptr, &file_op.stat_result) catch |err| {
            const errno = mapNfsError(err);
            file_op.completeErrno(errno);
            return;
        };

        file_op.completeStatus(0);
    }

    fn workerOpenDir(self: *Self, file_op: *FileOpState) void {
        _ = self;
        const tag = std.meta.activeTag(file_op.params);
        if (tag != .OpenDir) {
            _ = c.printf("[worker] workerOpenDir received mismatched params tag=%u\n", @as(c_uint, @intFromEnum(tag)));
            return;
        }
        // TODO: Implement this
        _ = c.printf("[worker] workerOpenDir called (not yet implemented)\n");
    }

    fn workerReadDir(self: *Self, file_op: *FileOpState) void {
        _ = self;
        const tag = std.meta.activeTag(file_op.params);
        if (tag != .ReadDir) {
            _ = c.printf("[worker] workerReadDir received mismatched params tag=%u\n", @as(c_uint, @intFromEnum(tag)));
            return;
        }
        // TODO: Implement this
        _ = c.printf("[worker] workerReadDir called (not yet implemented)\n");
    }

    fn workerGetDirent(self: *Self, file_op: *FileOpState) void {
        _ = self;
        const tag = std.meta.activeTag(file_op.params);
        if (tag != .GetDirent) {
            _ = c.printf("[worker] workerGetDirent received mismatched params tag=%u\n", @as(c_uint, @intFromEnum(tag)));
            return;
        }
        const params = &file_op.params.GetDirent;
        if (params.capacity == 0) {
            file_op.completeErrno(sos.ENAMETOOLONG);
            return;
        }

        const dir_handle = nfs_handler.opendirSync(ROOT_DIR.ptr) catch |err| {
            const errno = mapNfsError(err);
            file_op.completeErrno(errno);
            return;
        };
        defer nfs_handler.closeDir(dir_handle);

        var current: usize = 0;
        var found = false;
        var selected_name: []const u8 = &[_]u8{};

        while (true) {
            const name_ptr = nfs_handler.readDirEntry(dir_handle) orelse break;
            const name_slice = std.mem.sliceTo(name_ptr, 0);
            if (name_slice.len == 0) continue;
            if (std.mem.eql(u8, name_slice, ".")) continue;
            if (std.mem.eql(u8, name_slice, "..")) continue;

            if (current == params.index) {
                selected_name = name_slice;
                found = true;
                break;
            }
            current += 1;
        }

        if (!found) {
            file_op.payload_len = 0;
            file_op.completeBytes(0);
            return;
        }

        const copy_len = @min(selected_name.len, params.capacity);
        std.mem.copyForwards(u8, file_op.payload[0..copy_len], selected_name[0..copy_len]);
        file_op.payload[copy_len] = 0;
        file_op.payload_len = copy_len + 1;

        if (selected_name.len > params.capacity) {
            file_op.completeErrno(sos.ERANGE);
            return;
        }

        file_op.completeBytes(copy_len);
    }

    fn workerPageFill(self: *Self, file_op: *FileOpState) void {
        _ = self;
        const tag = std.meta.activeTag(file_op.params);
        if (tag != .PageFill) {
            _ = c.printf("[worker] workerPageFill received mismatched params tag=%u\n", @as(c_uint, @intFromEnum(tag)));
            file_op.completeErrno(sos.EINVAL);
            return;
        }

        const params = &file_op.params.PageFill;
        _ = c.printf("[worker] workerPageFill: entry client=%u page=0x%lx\n", params.client_id, @as(c_ulong, @intCast(params.page_base)));

        const vm_handle = file_op.vm_handle orelse {
            file_op.completeErrno(sos.EFAULT);
            return;
        };
        _ = vm_handle;

        const page_len: usize = vm.PAGE_SIZE_4K;
        @memset(file_op.payload[0..page_len], 0);

        const is_file = params.source == .File;
        const source_str: [*:0]const u8 = if (is_file) "File" else "Anonymous";
        _ = c.printf("[worker] workerPageFill: source=%s\n", source_str);

        switch (params.source) {
            .Anonymous => {
                file_op.payload_len = page_len;
            },
            .File => |backing| {
                _ = c.printf("[worker] workerPageFill: file-backed fd=%d offset=%zu len=%zu\n", backing.fd, backing.file_offset, backing.length);

                const handle_ref = file.handleRefFromOpaque(backing.handle_ref) orelse {
                    _ = c.printf("[worker] workerPageFill: ERROR handle_ref is null\n");
                    file_op.completeErrno(sos.EBADF);
                    return;
                };
                const raw_handle = file.rawFileHandle(handle_ref);
                _ = c.printf("[worker] workerPageFill: calling preadSync handle=%p offset=%zu\n", raw_handle, backing.file_offset);

                const buf_ptr: [*]u8 = @as([*]u8, @ptrCast(&file_op.payload[0]));
                const read_bytes = nfs_handler.preadSync(
                    raw_handle,
                    buf_ptr,
                    backing.file_offset,
                    page_len,
                ) catch |err| {
                    const errno_val = mapNfsError(err);
                    _ = c.printf("[worker] workerPageFill: preadSync failed with error errno=%d\n", errno_val);
                    file_op.completeErrno(mapNfsError(err));
                    return;
                };
                _ = c.printf("[worker] workerPageFill: preadSync returned %zu bytes\n", read_bytes);

                if (read_bytes < page_len) {
                    const rest = buf_ptr[read_bytes..page_len];
                    @memset(rest, 0);
                }
                file_op.payload_len = page_len;
            },
            .Pagefile => |pf| {
                const buf_ptr: [*]u8 = @as([*]u8, @ptrCast(&file_op.payload[0]));
                if (!tryReserveSlot(pf.slot)) {
                    file_op.completeErrno(sos.EAGAIN);
                    return;
                }
                const rc = pagefile.pagefile_read_slot(pf.slot, buf_ptr, page_len);
                releaseSlot(pf.slot);
                if (rc != 0) {
                    _ = c.printf("[worker] workerPageFill: pagefile_read_slot failed rc=%d\n", rc);
                    file_op.completeErrno(-rc);
                    return;
                }
                file_op.payload_len = page_len;
            },
        }

        _ = c.printf("[worker] workerPageFill: completing successfully payload_len=%zu\n", file_op.payload_len);
        file_op.completeStatus(0);
    }

    fn workerPageOut(self: *Self, file_op: *FileOpState) void {
        _ = self;
        const tag = std.meta.activeTag(file_op.params);
        if (tag != .PageOut) {
            _ = c.printf("[worker] workerPageOut received mismatched params tag=%u\n", @as(c_uint, @intFromEnum(tag)));
            file_op.completeErrno(sos.EINVAL);
            return;
        }

        const params = file_op.params.PageOut;
        _ = c.printf("[worker] workerPageOut: slot=%u frame_ref=%lu\n", @as(c_uint, params.slot), @as(c_ulong, @intCast(params.frame_ref)));

        var bounce: [vm.PAGE_SIZE_4K]u8 = undefined;
        const frame_ptr: [*]const u8 = @ptrCast(sos.frame_data(params.frame_ref));
        std.mem.copyForwards(u8, bounce[0..], frame_ptr[0..vm.PAGE_SIZE_4K]);

        const rc = pagefile.pagefile_write_slot(params.slot, &bounce, vm.PAGE_SIZE_4K);
        if (rc != 0) {
            _ = c.printf("[worker] workerPageOut: pagefile_write_slot failed rc=%d\n", rc);
            file_op.completeErrno(-rc);
            return;
        }

        _ = c.printf("[worker] workerPageOut: completed successfully\n");
        file_op.completeStatus(0);
    }
};

var workers: [WORKER_COUNT]Worker = undefined;
var worker_notifications: [WORKER_COUNT]sel4.seL4_CPtr = [_]sel4.seL4_CPtr{sel4.seL4_CapNull} ** WORKER_COUNT;
var worker_notification_ut: [WORKER_COUNT]?*sos.ut_t = [_]?*sos.ut_t{null} ** WORKER_COUNT;
var worker_initialized = false;
var active_worker_count: usize = 0;
var enqueue_rr = std.atomic.Value(usize).init(0);

const PAGEOUT_JOB_CAP: usize = 8;
var pageout_job_states: [PAGEOUT_JOB_CAP]FileOpState = undefined;
var pageout_job_used: [PAGEOUT_JOB_CAP]bool = [_]bool{false} ** PAGEOUT_JOB_CAP;
var pageout_job_done: [PAGEOUT_JOB_CAP]bool = [_]bool{false} ** PAGEOUT_JOB_CAP;
const PageOutMeta = struct { slot: u32, frame_ref: usize };
var pageout_job_meta: [PAGEOUT_JOB_CAP]PageOutMeta = [_]PageOutMeta{.{ .slot = 0, .frame_ref = 0 }} ** PAGEOUT_JOB_CAP;
const MAX_SLOTS: usize = 8192;
const SLOT_BUSY_WORDS: usize = (MAX_SLOTS + 63) / 64;
var pageout_slot_busy: [SLOT_BUSY_WORDS]u64 = [_]u64{0} ** SLOT_BUSY_WORDS;
const SlotLock = struct {
    state: u8 = 0,
    fn lock(self: *SlotLock) void {
        while (@cmpxchgStrong(u8, &self.state, 0, 1, .acq_rel, .acquire) != null) {}
    }
    fn unlock(self: *SlotLock) void {
        @atomicStore(u8, &self.state, 0, .release);
    }
};
var pageout_slot_lock: SlotLock = .{};

fn tryReserveSlot(slot: u32) bool {
    if (slot == 0 or slot >= MAX_SLOTS) return false;
    const word: usize = slot / 64;
    const bit: u6 = @intCast(slot % 64);
    pageout_slot_lock.lock();
    defer pageout_slot_lock.unlock();
    const mask: u64 = (@as(u64, 1) << bit);
    if ((pageout_slot_busy[word] & mask) != 0) {
        return false;
    }
    pageout_slot_busy[word] |= mask;
    return true;
}

fn releaseSlot(slot: u32) void {
    if (slot == 0 or slot >= MAX_SLOTS) return;
    const word: usize = slot / 64;
    const bit: u6 = @intCast(slot % 64);
    pageout_slot_lock.lock();
    defer pageout_slot_lock.unlock();
    pageout_slot_busy[word] &= ~(@as(u64, 1) << bit);
}

/// Thread spawner defined in threads.c
extern fn spawn_worker_thread(
    entry: *const fn (usize) callconv(.c) void,
    arg: usize,
) void;

/// Initialise worker subsystem (C-callable)
pub export fn worker_init(delegate_ep_arg: sel4.seL4_CPtr, work_ntfn: sel4.seL4_CPtr) callconv(.c) void {
    if (worker_initialized) {
        return;
    }

    var idx: usize = 0;
    while (idx < WORKER_COUNT) : (idx += 1) {
        var ntfn = work_ntfn;
        if (idx == 0) {
            worker_notification_ut[idx] = null;
        } else {
            const allocated = sos.alloc_retype(&ntfn, sel4.seL4_NotificationObject, sel4.seL4_NotificationBits);
            if (allocated == null) {
                _ = c.printf("[worker] Failed to allocate notification for worker %u, stopping pool init\n", @as(c_uint, @intCast(idx)));
                break;
            }
            worker_notification_ut[idx] = allocated;
        }

        workers[idx] = Worker.init(delegate_ep_arg, ntfn);
        worker_notifications[idx] = ntfn;
        spawn_worker_thread(worker_main_c, idx);
        _ = c.printf("[worker] Worker thread %u spawned (delegate_ep=%lu, ntfn=%lu)\n", @as(c_uint, @intCast(idx)), delegate_ep_arg, ntfn);
        active_worker_count += 1;
    }

    if (active_worker_count == 0) {
        workers[0] = Worker.init(delegate_ep_arg, work_ntfn);
        worker_notifications[0] = work_ntfn;
        worker_notification_ut[0] = null;
        spawn_worker_thread(worker_main_c, 0);
        active_worker_count = 1;
    }

    worker_initialized = true;
}

/// C wrapper for worker main loop
pub export fn worker_main_c(arg: usize) callconv(.c) void {
    const idx = arg;
    if (!worker_initialized or idx >= active_worker_count) {
        _ = c.printf("[worker] Worker main invoked with invalid index %zu\n", idx);
        return;
    }
    workers[idx].run();
}

/// C-callable enqueue function
pub export fn workerEnqueue(file_op: *FileOpState) callconv(.c) c_int {
    if (!worker_initialized or active_worker_count == 0) {
        return -@as(c_int, @intCast(sos.EINVAL));
    }

    const total = active_worker_count;
    const base = enqueue_rr.fetchAdd(1, .acq_rel);

    var offset: usize = 0;
    while (offset < total) : (offset += 1) {
        const idx = (base + offset) % total;
        workers[idx].enqueue(file_op) catch |err| switch (err) {
            error.QueueFull => continue,
        };
        return 0;
    }

    return -@as(c_int, @intCast(sos.EAGAIN));
}

const PageOutJobSlot = struct {
    index: usize,
    state: *FileOpState,
    slot: u32,
    frame_ref: usize,
};

fn acquirePageOutJobSlot() ?PageOutJobSlot {
    for (&pageout_job_used, 0..) |*used, idx| {
        if (!used.*) {
            used.* = true;
            pageout_job_states[idx].reset();
            pageout_job_done[idx] = false;
            return PageOutJobSlot{ .index = idx, .state = &pageout_job_states[idx], .slot = 0, .frame_ref = 0 };
        }
    }
    return null;
}

fn releasePageOutJobSlot(idx: usize) void {
    if (idx >= pageout_job_used.len) return;
    pageout_job_used[idx] = false;
    pageout_job_done[idx] = false;
    pageout_job_meta[idx] = .{ .slot = 0, .frame_ref = 0 };
}

/// Enqueue page-out job and busy-wait for completion.
/// Returns 0 on success, -errno on failure.
pub export fn pageout_submit(slot: u32, frame_ref: usize) callconv(.c) c_int {
    if (!tryReserveSlot(slot)) {
        return -@as(c_int, @intCast(sos.EAGAIN));
    }
    const job_slot = acquirePageOutJobSlot() orelse return -@as(c_int, @intCast(sos.EAGAIN));
    const idx = job_slot.index;
    var job = job_slot.state;
    job.reset();

    job.params = .{ .PageOut = .{ .slot = slot, .frame_ref = frame_ref } };
    job.vm_handle = null;
    job.payload_len = 0;
    pageout_job_meta[idx] = .{ .slot = slot, .frame_ref = frame_ref };

    const rc = workerEnqueue(job);
    if (rc < 0) {
        releasePageOutJobSlot(idx);
        releaseSlot(slot);
        return rc;
    }

    // mark pending; completion will be polled by pageout_poll_complete
    return 0;
}

/// Poll for completed page-out jobs and return first finished result.
/// Returns 0 on success, -errno on failure, and -EAGAIN if none complete.
/// On success/failure fills out_frame/out_slot with the completed job context.
pub export fn pageout_poll_complete(out_frame: *usize, out_slot: *u32) callconv(.c) c_int {
    for (&pageout_job_used, 0..) |used, idx| {
        if (!used) continue;
        const job = &pageout_job_states[idx];
        if (!job.isCompleted()) continue;

        const meta = pageout_job_meta[idx];
        out_frame.* = meta.frame_ref;
        out_slot.* = meta.slot;

        var errno_val: c_int = sos.EIO;
        switch (job.result) {
            .Status => |value| errno_val = value,
            .Errno => |e| errno_val = e,
            else => errno_val = sos.EIO,
        }

        job.reset();
        releasePageOutJobSlot(idx);
        releaseSlot(meta.slot);
        return errno_val;
    }
    return -@as(c_int, @intCast(sos.EAGAIN));
}
