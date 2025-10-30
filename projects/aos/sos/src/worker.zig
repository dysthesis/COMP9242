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

    pub fn process(self: Self, ep: sel4.seL4_CPtr) void {
        switch (self.work_type) {
            .Open => workerOpenFile(ep, self.param),
            .Read => workerReadFile(ep, self.param),
            .Write => workerWriteFile(ep, self.param),
            .Close => workerCloseFile(ep, self.param),
            .Stat => workerStatFile(ep, self.param),
            .OpenDir => workerOpenDir(ep, self.param),
            .ReadDir => workerReadDir(ep, self.param),
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

    pub fn drain(self: *Self, ep: sel4.seL4_CPtr) void {
        while (self.dequeue()) |item| {
            item.process(ep);
        }
    }
};

var work_queue: WorkQueue = undefined;
var delegate_ep: sel4.seL4_CPtr = undefined;
/// Thread spawner defined in
extern fn spawn_worker_thread(
    entry: *const fn (usize) callconv(.c) void,
    arg: usize,
) void;

/// Initialise worker subsystem
pub fn init(delegate_ep_arg: sel4.seL4_CPtr, work_ntfn: sel4.seL4_CPtr) void {
    work_queue = WorkQueue.init(work_ntfn);
    delegate_ep = delegate_ep_arg;

    spawn_worker_thread(worker_main_c, delegate_ep_arg);
    _ = c.printf("[worker] Worker thread spawned with delegate_ep=%lu\n", delegate_ep_arg);
}

/// C wrapper for workerMain
pub export fn worker_main_c(arg: usize) callconv(.c) void {
    const ep: sel4.seL4_CPtr = @intCast(arg);
    workerMain(ep);
}

/// Worker thread main loop
fn workerMain(ep: sel4.seL4_CPtr) void {
    _ = c.printf("[worker] Worker thread started (delegate_ep=%lu)\n", ep);

    while (true) {
        // Wait for work notification
        _ = sel4.seL4_Wait(work_queue.notification, null);

        work_queue.drain(ep);

        signalQueueSpaceAvailable();
    }
}

/// Signal any waiting continuations that queue has space
fn signalQueueSpaceAvailable() void {
    // TODO: Implement this.
}

fn workerOpenFile(ep: sel4.seL4_CPtr, param: *anyopaque) void {
    _ = ep;
    _ = param;
    // TODO: Implement this
    _ = c.printf("[worker] workerOpenFile called (not yet implemented)\n");
}

fn workerReadFile(ep: sel4.seL4_CPtr, param: *anyopaque) void {
    _ = ep;
    _ = param;
    // TODO: Implement this
    _ = c.printf("[worker] workerReadFile called (not yet implemented)\n");
}

fn workerWriteFile(ep: sel4.seL4_CPtr, param: *anyopaque) void {
    _ = ep;
    _ = param;
    // TODO: Implement this
    _ = c.printf("[worker] workerWriteFile called (not yet implemented)\n");
}

fn workerCloseFile(ep: sel4.seL4_CPtr, param: *anyopaque) void {
    _ = ep;
    _ = param;
    // TODO: Implement this
    _ = c.printf("[worker] workerCloseFile called (not yet implemented)\n");
}

fn workerStatFile(ep: sel4.seL4_CPtr, param: *anyopaque) void {
    _ = ep;
    _ = param;
    // TODO: Implement this
    _ = c.printf("[worker] workerStatFile called (not yet implemented)\n");
}

fn workerOpenDir(ep: sel4.seL4_CPtr, param: *anyopaque) void {
    _ = ep;
    _ = param;
    // TODO: Implement thi
    _ = c.printf("[worker] workerOpenDir called (not yet implemented)\n");
}

fn workerReadDir(ep: sel4.seL4_CPtr, param: *anyopaque) void {
    _ = ep;
    _ = param;
    // TODO: Implement this
    _ = c.printf("[worker] workerReadDir called (not yet implemented)\n");
}

pub export fn workerEnqueue(
    work_type: WorkType,
    param: *anyopaque,
) callconv(.c) c_int {
    work_queue.enqueue(work_type, param) catch return -@as(c_int, @intCast(sos.EAGAIN));
    return 0;
}
