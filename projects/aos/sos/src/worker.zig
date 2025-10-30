const sel4 = @import("cimports").sel4;
const sos = @import("cimports").sos;
const c = @import("cimports").c;

const MAX_WORK_QUEUE = 16;

pub const WorkType = enum(u8) {
    Open,
    Close,
    Read,
    Write,
    Stat,
    OpenDir,
    ReadDir,
};

pub const WorkItem = struct {
    work_type: WorkType,
    param: *anyopaque,

    const Self = @This();

    pub fn process(self: Self, worker: anytype) void {
        switch (self.work_type) {
            .Open => worker.workerOpenFile(self.param),
            .Read => worker.workerReadFile(self.param),
            .Write => worker.workerWriteFile(self.param),
            .Close => worker.workerCloseFile(self.param),
            .Stat => worker.workerStatFile(self.param),
            .OpenDir => worker.workerOpenDir(self.param),
            .ReadDir => worker.workerReadDir(self.param),
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
    pub fn enqueue(self: *Self, work_type: WorkType, param: *anyopaque) !void {
        const curr_head = @atomicLoad(u32, &self.head, .acquire);
        const next_head = (curr_head + 1) % MAX_WORK_QUEUE;
        const curr_tail = @atomicLoad(u32, &self.tail, .acquire);

        if (next_head == curr_tail) {
            return error.QueueFull;
        }

        self.items[curr_head] = WorkItem{
            .work_type = work_type,
            .param = param,
        };

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
    pub fn enqueue(self: *Self, work_type: WorkType, param: *anyopaque) !void {
        try self.queue.enqueue(work_type, param);
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

    fn workerOpenFile(self: *Self, param: *anyopaque) void {
        _ = self;
        _ = param;
        // TODO: Implement this
        _ = c.printf("[worker] workerOpenFile called (not yet implemented)\n");
    }

    fn workerReadFile(self: *Self, param: *anyopaque) void {
        _ = self;
        _ = param;
        // TODO: Implement this
        _ = c.printf("[worker] workerReadFile called (not yet implemented)\n");
    }

    fn workerWriteFile(self: *Self, param: *anyopaque) void {
        _ = self;
        _ = param;
        // TODO: Implement this
        _ = c.printf("[worker] workerWriteFile called (not yet implemented)\n");
    }

    fn workerCloseFile(self: *Self, param: *anyopaque) void {
        _ = self;
        _ = param;
        // TODO: Implement this
        _ = c.printf("[worker] workerCloseFile called (not yet implemented)\n");
    }

    fn workerStatFile(self: *Self, param: *anyopaque) void {
        _ = self;
        _ = param;
        // TODO: Implement this
        _ = c.printf("[worker] workerStatFile called (not yet implemented)\n");
    }

    fn workerOpenDir(self: *Self, param: *anyopaque) void {
        _ = self;
        _ = param;
        // TODO: Implement this
        _ = c.printf("[worker] workerOpenDir called (not yet implemented)\n");
    }

    fn workerReadDir(self: *Self, param: *anyopaque) void {
        _ = self;
        _ = param;
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
pub export fn workerEnqueue(
    work_type: WorkType,
    param: *anyopaque,
) callconv(.c) c_int {
    global_worker.enqueue(work_type, param) catch return -@as(c_int, @intCast(sos.EAGAIN));
    return 0;
}
