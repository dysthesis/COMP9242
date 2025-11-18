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
const ROOT_DIR: [:0]const u8 = "/";

const MAX_WORK_QUEUE = 16;

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
        switch (std.meta.activeTag(self.file_op.params)) {
            .Open => worker.workerOpenFile(self.file_op),
            .Close => worker.workerCloseFile(self.file_op),
            .Read => worker.workerReadFile(self.file_op),
            .Write => worker.workerWriteFile(self.file_op),
            .Stat => worker.workerStatFile(self.file_op),
            .OpenDir => worker.workerOpenDir(self.file_op),
            .ReadDir => worker.workerReadDir(self.file_op),
            .GetDirent => worker.workerGetDirent(self.file_op),
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
        while (self.dequeue()) |item| {
            item.process(worker);
        }
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
            _ = sel4.seL4_Wait(self.queue.notification, null);

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

        const table = client_ctx.fileTable();
        const fd = table.allocFd(handle) catch |alloc_err| {
            const errno = mapFileTableError(alloc_err);
            _ = c.printf("[worker] allocFd failed errno=%d\n", errno);
            nfs_handler.closeSync(handle) catch {};
            file_op.completeErrno(errno);
            return;
        };

        const io_state = client_ctx.ioState();
        if (fd >= io_state.fds.len) {
            _ = c.printf("[worker] fd index %zu out of range\n", fd);
            nfs_handler.closeSync(handle) catch {};
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
        entry.obj = handle;
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
        const handle = table.getHandle(params.fd) catch |err| {
            const errno = mapFileTableError(err);
            file_op.completeErrno(errno);
            return;
        };

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
        const handle = table.getHandle(params.fd) catch |err| {
            const errno = mapFileTableError(err);
            file_op.completeErrno(errno);
            return;
        };

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
        const handle = table.getHandle(params.fd) catch |err| {
            const errno = mapFileTableError(err);
            file_op.completeErrno(errno);
            return;
        };

        const close_result = nfs_handler.closeSync(handle) catch |err| {
            const errno = mapNfsError(err);
            file_op.completeErrno(errno);
            return;
        };
        _ = close_result;

        table.freeFd(params.fd) catch |err| {
            const errno = mapFileTableError(err);
            file_op.completeErrno(errno);
            return;
        };
        entry.* = file.empty_fd;

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
            file_op.completeErrno(sos.ENOENT);
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
};

// Global worker instance
var global_worker: Worker = undefined;

/// Thread spawner defined in threads.c
extern fn spawn_worker_thread(
    entry: *const fn (usize) callconv(.c) void,
    arg: usize,
) void;

/// Initialise worker subsystem (C-callable)
pub export fn worker_init(delegate_ep_arg: sel4.seL4_CPtr, work_ntfn: sel4.seL4_CPtr) callconv(.c) void {
    global_worker = Worker.init(delegate_ep_arg, work_ntfn);

    spawn_worker_thread(worker_main_c, delegate_ep_arg);
    _ = c.printf("[worker] Worker thread spawned with delegate_ep=%lu\n", delegate_ep_arg);
}

/// C wrapper for worker main loop
pub export fn worker_main_c(arg: usize) callconv(.c) void {
    _ = arg; // delegate_ep already stored in global_worker
    global_worker.run();
}

/// C-callable enqueue function
pub export fn workerEnqueue(file_op: *FileOpState) callconv(.c) c_int {
    global_worker.enqueue(file_op) catch return -@as(c_int, @intCast(sos.EAGAIN));
    return 0;
}
