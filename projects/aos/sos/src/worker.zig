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

pub const OpenParams = struct {
    path: [256:0]u8,
    flags: c_int,
    client_id: u32,
};

pub const ReadParams = struct {
    fd: usize,
    count: usize,
    client_buf: usize,
    client_id: u32,
};

pub const WriteParams = struct {
    fd: usize,
    data: [4096]u8,
    count: usize,
    client_id: u32,
};

pub const CloseParams = struct {
    fd: usize,
    client_id: u32,
};

pub const StatParams = struct {
    path: [256:0]u8,
    client_id: u32,
};

pub const OpenDirParams = struct {
    path: [256:0]u8,
    client_id: u32,
};

pub const ReadDirParams = struct {
    fd: usize,
    client_id: u32,
};

pub const WorkParams = union(WorkType) {
    Open: OpenParams,
    Close: CloseParams,
    Read: ReadParams,
    Write: WriteParams,
    Stat: StatParams,
    OpenDir: OpenDirParams,
    ReadDir: ReadDirParams,
};

pub const WorkItem = struct {
    params: *WorkParams,

    const Self = @This();

    pub fn process(self: Self, worker: anytype) void {
        switch (self.params.*) {
            .Open => worker.workerOpenFile(self.params),
            .Read => worker.workerReadFile(self.params),
            .Write => worker.workerWriteFile(self.params),
            .Close => worker.workerCloseFile(self.params),
            .Stat => worker.workerStatFile(self.params),
            .OpenDir => worker.workerOpenDir(self.params),
            .ReadDir => worker.workerReadDir(self.params),
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
    pub fn enqueue(self: *Self, params: *WorkParams) !void {
        const curr_head = @atomicLoad(u32, &self.head, .acquire);
        const next_head = (curr_head + 1) % MAX_WORK_QUEUE;
        const curr_tail = @atomicLoad(u32, &self.tail, .acquire);

        if (next_head == curr_tail) {
            return error.QueueFull;
        }

        self.items[curr_head] = WorkItem{ .params = params };

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
    pub fn enqueue(self: *Self, params: *WorkParams) !void {
        try self.queue.enqueue(params);
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

    fn workerOpenFile(self: *Self, params: *WorkParams) void {
        _ = self;
        switch (params.*) {
            .Open => {},
            else => {
                _ = c.printf("[worker] workerOpenFile received mismatched params tag=%u\n", @as(c_uint, @intFromEnum(params.*)));
                return;
            },
        }
        // TODO: Implement this
        _ = c.printf("[worker] workerOpenFile called (not yet implemented)\n");
    }

    fn workerReadFile(self: *Self, params: *WorkParams) void {
        _ = self;
        switch (params.*) {
            .Read => {},
            else => {
                _ = c.printf("[worker] workerReadFile received mismatched params tag=%u\n", @as(c_uint, @intFromEnum(params.*)));
                return;
            },
        }
        // TODO: Implement this
        _ = c.printf("[worker] workerReadFile called (not yet implemented)\n");
    }

    fn workerWriteFile(self: *Self, params: *WorkParams) void {
        _ = self;
        switch (params.*) {
            .Write => {},
            else => {
                _ = c.printf("[worker] workerWriteFile received mismatched params tag=%u\n", @as(c_uint, @intFromEnum(params.*)));
                return;
            },
        }
        // TODO: Implement this
        _ = c.printf("[worker] workerWriteFile called (not yet implemented)\n");
    }

    fn workerCloseFile(self: *Self, params: *WorkParams) void {
        _ = self;
        switch (params.*) {
            .Close => {},
            else => {
                _ = c.printf("[worker] workerCloseFile received mismatched params tag=%u\n", @as(c_uint, @intFromEnum(params.*)));
                return;
            },
        }
        // TODO: Implement this
        _ = c.printf("[worker] workerCloseFile called (not yet implemented)\n");
    }

    fn workerStatFile(self: *Self, params: *WorkParams) void {
        _ = self;
        switch (params.*) {
            .Stat => {},
            else => {
                _ = c.printf("[worker] workerStatFile received mismatched params tag=%u\n", @as(c_uint, @intFromEnum(params.*)));
                return;
            },
        }
        // TODO: Implement this
        _ = c.printf("[worker] workerStatFile called (not yet implemented)\n");
    }

    fn workerOpenDir(self: *Self, params: *WorkParams) void {
        _ = self;
        switch (params.*) {
            .OpenDir => {},
            else => {
                _ = c.printf("[worker] workerOpenDir received mismatched params tag=%u\n", @as(c_uint, @intFromEnum(params.*)));
                return;
            },
        }
        // TODO: Implement this
        _ = c.printf("[worker] workerOpenDir called (not yet implemented)\n");
    }

    fn workerReadDir(self: *Self, params: *WorkParams) void {
        _ = self;
        switch (params.*) {
            .ReadDir => {},
            else => {
                _ = c.printf("[worker] workerReadDir received mismatched params tag=%u\n", @as(c_uint, @intFromEnum(params.*)));
                return;
            },
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
pub export fn workerEnqueue(
    params: *WorkParams,
) callconv(.c) c_int {
    global_worker.enqueue(params) catch return -@as(c_int, @intCast(sos.EAGAIN));
    return 0;
}
