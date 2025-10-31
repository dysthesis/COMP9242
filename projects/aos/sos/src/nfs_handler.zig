const NFS_POOL_SIZE = 4;
const NFS_TIMEOUT_MS = 10000; // 10 seconds

const O_CREAT: c_int = 0o100;
const DEFAULT_CREATE_MODE: c_int = 0o600; // rw-------

pub const NfsOperation = enum {
    Open,
    Read,
    Write,
    Close,
    Stat,
    OpenDir,
};

/// Pool slot for async/sync conversion
pub const PoolSlot = struct {
    used: bool,
    async_finish: bool align(4),
    status: i32,

    result: union {
        fh: *anyopaque,
        dir: *anyopaque,
        data: *anyopaque,
    },

    operation: NfsOperation,
    read_buf: ?[*]u8,
    stat_out: ?*sos_types.sos_stat_t,

    // Timeout tracking
    start_time: u64,
    timeout_ms: u32,

    pub fn init() PoolSlot {
        return PoolSlot{
            .used = false,
            .async_finish = false,
            .status = 0,
            .result = .{ .data = undefined },
            .operation = .Open,
            .read_buf = null,
            .stat_out = null,
            .start_time = 0,
            .timeout_ms = NFS_TIMEOUT_MS,
        };
    }

    pub fn reset(self: *PoolSlot) void {
        self.used = false;
        self.async_finish = false;
        self.status = 0;
        self.read_buf = null;
        self.stat_out = null;
    }

    pub fn checkTimeout(self: *PoolSlot, current_time: u64) bool {
        if (!self.used) return false;
        if (@atomicLoad(bool, &self.async_finish, .acquire)) return false;

        const elapsed = current_time - self.start_time;
        return elapsed > self.timeout_ms;
    }
};

pub const NfsPool = struct {
    slots: [NFS_POOL_SIZE]PoolSlot,
    clock_hand: usize,

    pub fn init() NfsPool {
        var pool = NfsPool{
            .slots = undefined,
            .clock_hand = 0,
        };

        for (&pool.slots) |*slot| {
            slot.* = PoolSlot.init();
        }

        return pool;
    }

    /// Acquire a pool slot
    pub fn acquire(self: *NfsPool) ?*PoolSlot {
        var attempts: usize = 0;
        while (attempts < NFS_POOL_SIZE) : (attempts += 1) {
            const idx = self.clock_hand;
            self.clock_hand = (self.clock_hand + 1) % NFS_POOL_SIZE;

            if (!self.slots[idx].used) {
                self.slots[idx].used = true;
                self.slots[idx].reset();
                self.slots[idx].start_time = getCurrentTimeMs();
                return &self.slots[idx];
            }
        }

        _ = c.printf("[nfs_pool] ERROR: Pool exhausted (%u slots)\n", @as(c_uint, NFS_POOL_SIZE));
        return null;
    }

    /// Release a pool slot
    pub fn release(self: *NfsPool, slot: *PoolSlot) void {
        _ = self;
        slot.reset();
    }

    /// Wait for async operation to complete
    pub fn wait(slot: *PoolSlot) i32 {
        const max_spin_iterations = 1000;
        var spin_count: u32 = 0;
        var backoff: u32 = 1;

        while (!@atomicLoad(bool, &slot.async_finish, .acquire)) {
            // Check timeout
            const elapsed = getCurrentTimeMs() - slot.start_time;
            if (elapsed > slot.timeout_ms) {
                _ = c.printf("[nfs_pool] TIMEOUT after %lums\n", elapsed);
                return -@as(i32, @intCast(sos.EIO));
            }

            // Busy-wait with exponential backoff
            if (spin_count < max_spin_iterations) {
                std.atomic.spinLoopHint();
                spin_count += 1;
            } else {
                // After initial spin, yield to scheduler
                var i: u32 = 0;
                while (i < backoff) : (i += 1) {
                    std.atomic.spinLoopHint();
                }
                backoff = @min(backoff * 2, 1000);
            }
        }

        return slot.status;
    }
};

var nfs_pool: NfsPool = undefined;
var pool_initialised: bool = false;

pub fn init() void {
    if (pool_initialised) return;

    const nfs_ctx = get_nfs_context();
    if (nfs_ctx == null) {
        @panic("NFS context not initialised by network.c");
    }

    if (!nfs_is_mounted()) {
        _ = c.printf("[nfs_handler] WARNING: NFS not yet mounted\n");
    }

    nfs_pool = NfsPool.init();
    pool_initialised = true;

    _ = c.printf("[nfs_handler] Pool initialised with %u slots\n", @as(c_uint, NFS_POOL_SIZE));
}

/// C-callable init
pub export fn nfs_handler_init() callconv(.c) void {
    init();
}

extern fn ts_get_timestamp() sel4.seL4_Word;

/// Get current time in milliseconds
fn getCurrentTimeMs() u64 {
    return ts_get_timestamp();
}

/// Timeout watchdog
pub export fn nfsTimeoutWatchdog() callconv(.c) void {
    if (!pool_initialised) return;

    const current_time = getCurrentTimeMs();

    for (&nfs_pool.slots) |*slot| {
        if (!slot.used) continue;
        if (@atomicLoad(bool, &slot.async_finish, .acquire)) continue;

        const elapsed = current_time - slot.start_time;
        if (elapsed > slot.timeout_ms) {
            _ = c.printf("[nfs_watchdog] Slot %p timed out after %lums\n", slot, elapsed);

            slot.status = -@as(i32, @intCast(sos.EIO));
            @atomicStore(bool, &slot.async_finish, true, .release);
            // NOTE: Callback param memory leak acceptable
        }
    }
}

/// Callback parameter passed to libnfs via private_data
/// Generic NFS callback
pub export fn nfsGenericCallbackZig(
    err: c_int,
    nfs_ctx: ?*anyopaque,
    data: ?*anyopaque,
    private_data: ?*anyopaque,
) callconv(.c) void {
    _ = nfs_ctx;

    if (private_data == null) {
        _ = c.printf("[nfs_callback] ERROR: private_data is null\n");
        return;
    }

    const slot: *PoolSlot = @ptrCast(@alignCast(private_data));

    if (err < 0) {
        // Operation failed
        _ = c.printf("[nfs_callback] Operation %u failed with error %d\n", @as(c_uint, @intFromEnum(slot.operation)), err);
        slot.status = err;
    } else {
        // Operation succeeded
        switch (slot.operation) {
            .Open => {
                if (data) |fh_ptr| {
                    slot.result.fh = fh_ptr;
                    slot.status = 0;
                } else {
                    _ = c.printf("[nfs_callback] Open succeeded but fh is null\n");
                    slot.status = -@as(i32, @intCast(sos.EIO));
                }
            },
            .Read => {
                if (data) |read_data| {
                    if (slot.read_buf) |buf| {
                        // libnfs provides data buffer in callback for reads
                        // Copy from libnfs buffer to our buffer
                        const bytes_read: usize = @intCast(err); // For read, err contains bytes read
                        @memcpy(buf[0..bytes_read], @as([*]u8, @ptrCast(read_data))[0..bytes_read]);
                        slot.status = @intCast(bytes_read);
                    } else {
                        _ = c.printf("[nfs_callback] Read succeeded but read_buf is null\n");
                        slot.status = -@as(i32, @intCast(sos.EIO));
                    }
                } else {
                    _ = c.printf("[nfs_callback] Read succeeded but data is null\n");
                    slot.status = -@as(i32, @intCast(sos.EIO));
                }
            },
            .Write => {
                // For write, success means data was written
                // err contains bytes written on success
                slot.status = err;
            },
            .Close => {
                // Close has no return value
                slot.status = 0;
            },
            .Stat => {
                if (data) |stat_data| {
                    if (slot.stat_out) |_| {
                        // Copy stat structure from libnfs to our stat_out
                        // NOTE: libnfs uses struct stat, we use sos_stat_t
                        const nfs_stat: *anyopaque = @ptrCast(stat_data);
                        _ = nfs_stat; // TODO: Convert
                        slot.status = 0;
                    } else {
                        _ = c.printf("[nfs_callback] Stat succeeded but stat_out is null\n");
                        slot.status = -@as(i32, @intCast(sos.EIO));
                    }
                } else {
                    _ = c.printf("[nfs_callback] Stat succeeded but data is null\n");
                    slot.status = -@as(i32, @intCast(sos.EIO));
                }
            },
            .OpenDir => {
                if (data) |dir_ptr| {
                    slot.result.dir = dir_ptr;
                    slot.status = 0;
                } else {
                    _ = c.printf("[nfs_callback] OpenDir succeeded but dir is null\n");
                    slot.status = -@as(i32, @intCast(sos.EIO));
                }
            },
        }
    }

    // Signal completion to worker thread
    @atomicStore(bool, &slot.async_finish, true, .release);
}

extern fn nfs_callback_c_bridge(err: c_int, nfs_ctx: ?*anyopaque, data: ?*anyopaque, private_data: ?*anyopaque) void;

/// Open file synchronously
pub fn openSync(path: [*:0]const u8, flags: c_int) !*anyopaque {
    const nfs_ctx = get_nfs_context() orelse return error.NoNFSContext;
    const slot = nfs_pool.acquire() orelse return error.PoolExhausted;
    defer nfs_pool.release(slot);

    slot.operation = .Open;
    slot.read_buf = null;
    slot.stat_out = null;

    const private_data: ?*anyopaque = @as(?*anyopaque, @ptrCast(slot));
    const mode: c_int = if ((flags & O_CREAT) != 0)
        DEFAULT_CREATE_MODE
    else
        0;

    const rc = nfs_open2_async(nfs_ctx, path, flags, mode, nfs_callback_c_bridge, private_data);
    if (rc < 0) {
        _ = c.printf("[nfs] nfs_open_async failed: %d\n", rc);
        return error.NFSOperationFailed;
    }

    const status = NfsPool.wait(slot);
    if (status < 0) {
        return error.OperationFailed;
    }

    return slot.result.fh;
}

/// Read from file synchronously
pub fn readSync(fh: *anyopaque, buf: [*]u8, count: usize) !usize {
    const nfs_ctx = get_nfs_context() orelse return error.NoNFSContext;
    const slot = nfs_pool.acquire() orelse return error.PoolExhausted;
    defer nfs_pool.release(slot);

    slot.operation = .Read;
    slot.read_buf = buf;
    slot.stat_out = null;

    const fh_typed: *nfsfh = @ptrCast(@alignCast(fh));
    const rc = nfs_read_async(
        nfs_ctx,
        fh_typed,
        count,
        nfs_callback_c_bridge,
        @as(?*anyopaque, @ptrCast(slot)),
    );
    if (rc < 0) {
        _ = c.printf("[nfs] nfs_read_async failed: %d\n", rc);
        return error.NFSOperationFailed;
    }

    const status = NfsPool.wait(slot);
    if (status < 0) {
        return error.OperationFailed;
    }

    return @intCast(status);
}

/// Write to file synchronously
pub fn writeSync(fh: *anyopaque, buf: [*]const u8, count: usize) !usize {
    const nfs_ctx = get_nfs_context() orelse return error.NoNFSContext;
    const slot = nfs_pool.acquire() orelse return error.PoolExhausted;
    defer nfs_pool.release(slot);

    slot.operation = .Write;
    slot.read_buf = null;
    slot.stat_out = null;

    const fh_typed: *nfsfh = @ptrCast(@alignCast(fh));
    const rc = nfs_write_async(
        nfs_ctx,
        fh_typed,
        count,
        buf,
        nfs_callback_c_bridge,
        @as(?*anyopaque, @ptrCast(slot)),
    );
    if (rc < 0) {
        _ = c.printf("[nfs] nfs_write_async failed: %d\n", rc);
        return error.NFSOperationFailed;
    }

    const status = NfsPool.wait(slot);
    if (status < 0) {
        return error.OperationFailed;
    }

    return @intCast(status);
}

/// Close file synchronously
pub fn closeSync(fh: *anyopaque) !void {
    const nfs_ctx = get_nfs_context() orelse return error.NoNFSContext;
    const slot = nfs_pool.acquire() orelse return error.PoolExhausted;
    defer nfs_pool.release(slot);

    slot.operation = .Close;
    slot.read_buf = null;
    slot.stat_out = null;

    const fh_typed: *nfsfh = @ptrCast(@alignCast(fh));
    const rc = nfs_close_async(
        nfs_ctx,
        fh_typed,
        nfs_callback_c_bridge,
        @as(?*anyopaque, @ptrCast(slot)),
    );
    if (rc < 0) {
        _ = c.printf("[nfs] nfs_close_async failed: %d\n", rc);
        return error.NFSOperationFailed;
    }

    const status = NfsPool.wait(slot);
    if (status < 0) {
        return error.OperationFailed;
    }
}

/// Stat file synchronously
pub fn statSync(path: [*:0]const u8, stat_out: *sos_types.sos_stat_t) !void {
    const nfs_ctx = get_nfs_context() orelse return error.NoNFSContext;
    const slot = nfs_pool.acquire() orelse return error.PoolExhausted;
    defer nfs_pool.release(slot);

    slot.operation = .Stat;
    slot.stat_out = stat_out;
    slot.read_buf = null;

    const rc = nfs_stat_async(
        nfs_ctx,
        path,
        nfs_callback_c_bridge,
        @as(?*anyopaque, @ptrCast(slot)),
    );
    if (rc < 0) {
        _ = c.printf("[nfs] nfs_stat_async failed: %d\n", rc);
        return error.NFSOperationFailed;
    }

    const status = NfsPool.wait(slot);
    if (status < 0) {
        return error.OperationFailed;
    }
}

/// Open directory synchronously
pub fn opendirSync(path: [*:0]const u8) !*anyopaque {
    const nfs_ctx = get_nfs_context() orelse return error.NoNFSContext;
    const slot = nfs_pool.acquire() orelse return error.PoolExhausted;
    defer nfs_pool.release(slot);

    slot.operation = .OpenDir;
    slot.read_buf = null;
    slot.stat_out = null;

    const rc = nfs_opendir_async(
        nfs_ctx,
        path,
        nfs_callback_c_bridge,
        @as(?*anyopaque, @ptrCast(slot)),
    );
    if (rc < 0) {
        _ = c.printf("[nfs] nfs_opendir_async failed: %d\n", rc);
        return error.NFSOperationFailed;
    }

    const status = NfsPool.wait(slot);
    if (status < 0) {
        return error.OperationFailed;
    }

    return slot.result.dir;
}

/// Service NFS events
pub export fn nfsServicePoll(revents: c_int) callconv(.c) void {
    const nfs_ctx = get_nfs_context() orelse return;
    _ = nfs_service(nfs_ctx, revents);
}

const cimports = @import("cimports");
const sel4 = cimports.sel4;
const c = cimports.c;
const sos = cimports.sos;
const sos_types = cimports.sos_types;
const std = @import("std");

const nfs_context = opaque {};
const nfsfh = opaque {};
const nfsdir = opaque {};

const nfs_cb = *const fn (c_int, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void;

extern fn get_nfs_context() ?*nfs_context;
extern fn nfs_is_mounted() bool;

extern fn nfs_open2_async(nfs_ctx: ?*nfs_context, path: [*:0]const u8, flags: c_int, mode: c_int, cb: nfs_cb, private_data: ?*anyopaque) c_int;
extern fn nfs_read_async(nfs_ctx: ?*nfs_context, fh: ?*nfsfh, count: u64, cb: nfs_cb, private_data: ?*anyopaque) c_int;
extern fn nfs_write_async(nfs_ctx: ?*nfs_context, fh: ?*nfsfh, count: u64, buf: [*]const u8, cb: nfs_cb, private_data: ?*anyopaque) c_int;
extern fn nfs_close_async(nfs_ctx: ?*nfs_context, fh: ?*nfsfh, cb: nfs_cb, private_data: ?*anyopaque) c_int;
extern fn nfs_stat_async(nfs_ctx: ?*nfs_context, path: [*:0]const u8, cb: nfs_cb, private_data: ?*anyopaque) c_int;
extern fn nfs_opendir_async(nfs_ctx: ?*nfs_context, path: [*:0]const u8, cb: nfs_cb, private_data: ?*anyopaque) c_int;
extern fn nfs_readdir(nfs_ctx: ?*nfs_context, dir: ?*nfsdir) ?*anyopaque;
extern fn nfs_closedir(nfs_ctx: ?*nfs_context, dir: ?*nfsdir) void;
extern fn nfs_service(nfs_ctx: ?*nfs_context, revents: c_int) c_int;
extern fn nfs_get_error(nfs_ctx: ?*nfs_context) [*:0]const u8;
