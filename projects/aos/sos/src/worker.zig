const std = @import("std");
const sel4 = @import("cimports").sel4;
const sos = @import("cimports").sos;
const c = @import("cimports").c;
const types = @import("worker_types.zig");

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
            return;
        }
        // TODO: Implement this
        _ = c.printf("[worker] workerOpenFile called (not yet implemented)\n");
    }

    fn workerReadFile(self: *Self, file_op: *FileOpState) void {
        _ = self;
        const tag = std.meta.activeTag(file_op.params);
        if (tag != .Read) {
            _ = c.printf("[worker] workerReadFile received mismatched params tag=%u\n", @as(c_uint, @intFromEnum(tag)));
            return;
        }
        // TODO: Implement this
        _ = c.printf("[worker] workerReadFile called (not yet implemented)\n");
    }

    fn workerWriteFile(self: *Self, file_op: *FileOpState) void {
        _ = self;
        const tag = std.meta.activeTag(file_op.params);
        if (tag != .Write) {
            _ = c.printf("[worker] workerWriteFile received mismatched params tag=%u\n", @as(c_uint, @intFromEnum(tag)));
            return;
        }
        // TODO: Implement this
        _ = c.printf("[worker] workerWriteFile called (not yet implemented)\n");
    }

    fn workerCloseFile(self: *Self, file_op: *FileOpState) void {
        _ = self;
        const tag = std.meta.activeTag(file_op.params);
        if (tag != .Close) {
            _ = c.printf("[worker] workerCloseFile received mismatched params tag=%u\n", @as(c_uint, @intFromEnum(tag)));
            return;
        }
        // TODO: Implement this
        _ = c.printf("[worker] workerCloseFile called (not yet implemented)\n");
    }

    fn workerStatFile(self: *Self, file_op: *FileOpState) void {
        _ = self;
        const tag = std.meta.activeTag(file_op.params);
        if (tag != .Stat) {
            _ = c.printf("[worker] workerStatFile received mismatched params tag=%u\n", @as(c_uint, @intFromEnum(tag)));
            return;
        }
        // TODO: Implement this
        _ = c.printf("[worker] workerStatFile called (not yet implemented)\n");
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
