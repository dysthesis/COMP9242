const std = @import("std");
const sel4 = @import("cimports").sel4;
const sos = @import("cimports").sos;
const c = @import("cimports").c;
const types = @import("worker_types.zig");
const clients = @import("client.zig");
const file = @import("file.zig");
const nfs_handler = @import("nfs_handler.zig");

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

    pub fn process(self: Self, worker: anytype) void {
        switch (std.meta.activeTag(self.file_op.params)) {
            .Open => worker.workerOpenFile(self.file_op),
            .Close => worker.workerCloseFile(self.file_op),
            .Read => worker.workerReadFile(self.file_op),
            .Write => worker.workerWriteFile(self.file_op),
            .Stat => worker.workerStatFile(self.file_op),
            .OpenDir => worker.workerOpenDir(self.file_op),
            .ReadDir => worker.workerReadDir(self.file_op),
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

        const path_ptr: [*:0]const u8 = @ptrCast(&params.path);
        _ = c.printf("[worker] open request client=%u path=\"%s\" flags=0x%x\n", params.client_id, path_ptr, params.flags);

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

        const table = client_ctx.fileTable();
        const handle = table.getHandle(params.fd) catch |err| {
            const errno = mapFileTableError(err);
            file_op.completeErrno(errno);
            return;
        };

        const to_read = @min(params.count, WRITE_BUFFER_CAPACITY);
        if (to_read == 0) {
            file_op.payload_len = 0;
            file_op.completeBytes(0);
            return;
        }

        const buf_ptr: [*]u8 = @as([*]u8, @ptrCast(&file_op.payload[0]));
        const read_bytes = nfs_handler.readSync(handle, buf_ptr, to_read) catch |err| {
            const errno = mapNfsError(err);
            file_op.completeErrno(errno);
            return;
        };

        file_op.payload_len = read_bytes;
        file_op.completeBytes(read_bytes);
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

        const table = client_ctx.fileTable();
        const handle = table.getHandle(params.fd) catch |err| {
            const errno = mapFileTableError(err);
            file_op.completeErrno(errno);
            return;
        };

        const to_write = @min(params.count, file_op.payload_len);
        if (to_write == 0) {
            file_op.completeBytes(0);
            return;
        }

        const buf_ptr: [*]const u8 = @as([*]const u8, @ptrCast(&file_op.payload[0]));
        const written = nfs_handler.writeSync(handle, buf_ptr, to_write) catch |err| {
            const errno = mapNfsError(err);
            file_op.completeErrno(errno);
            return;
        };

        file_op.completeBytes(written);
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
        // TODO: Implement this
        _ = c.printf("[worker] workerStatFile called (not yet implemented)\n");
        file_op.completeErrno(sos.ENOSYS);
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
