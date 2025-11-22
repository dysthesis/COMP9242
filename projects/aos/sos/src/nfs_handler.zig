const NFS_POOL_SIZE = 4;
const NFS_TIMEOUT_MS = 10000; // 10 seconds

const O_CREAT: c_int = 0o100;
const DEFAULT_CREATE_MODE: c_int = 0o600; // rw-------
const READ_MODE_MASK: u64 = 0o400 | 0o040 | 0o004;
const WRITE_MODE_MASK: u64 = 0o200 | 0o020 | 0o002;
const EXEC_MODE_MASK: u64 = 0o100 | 0o010 | 0o001;
const ERRNO_MAP = std.StaticStringMap(c_int).initComptime(.{
    .{ "ENOENT", sos.ENOENT },
});

pub const NfsOperation = enum {
    Open,
    Read,
    Write,
    Pread,
    Close,
    Stat,
    OpenDir,
    Unlink,
    Lseek,
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

    seek_value: u64,

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
            .seek_value = 0,
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
        self.seek_value = 0;
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
    /// NOTE: This runs in the worker context, so it MUST NOT block on seL4_Wait.
    /// Instead, it actively polls the network stack until the operation completes.
    pub fn wait(slot: *PoolSlot) i32 {
        _ = c.printf("[nfs_pool] wait: entering active poll loop for slot=%p\n", slot);
        var poll_count: u32 = 0;
        while (!@atomicLoad(bool, &slot.async_finish, .acquire)) {
            const elapsed = getCurrentTimeMs() - slot.start_time;
            if (elapsed > slot.timeout_ms) {
                _ = c.printf("[nfs_pool] TIMEOUT after %lums\n", elapsed);
                return -@as(i32, @intCast(sos.EIO));
            }

            // Actively service the network stack to process NFS responses
            // without blocking the syscall loop
            nfsServicePoll(c.POLLIN | c.POLLOUT);

            poll_count += 1;
            if (poll_count % 10000 == 0) {
                _ = c.printf("[nfs_pool] wait: still polling slot=%p count=%u elapsed=%lums\n", slot, poll_count, elapsed);
            }
        }

        _ = c.printf("[nfs_pool] wait: completed slot=%p status=%d after %u polls\n", slot, slot.status, poll_count);
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
                        const bytes_read: usize = @intCast(err);
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
            .Pread => {
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
                    if (slot.stat_out) |out_ptr| {
                        const nfs_stat: *const nfs_stat_64 = @ptrCast(@alignCast(stat_data));
                        assignStat(out_ptr, nfs_stat);
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
            .Unlink => {
                slot.status = 0;
            },
            .Lseek => {
                if (data) |seek_ptr| {
                    const value_ptr: *const u64 = @ptrCast(@alignCast(seek_ptr));
                    slot.seek_value = value_ptr.*;
                    slot.status = 0;
                } else {
                    _ = c.printf("[nfs_callback] Lseek succeeded but data is null\n");
                    slot.status = -@as(i32, @intCast(sos.EIO));
                }
            },
        }
    }

    // Signal completion to worker thread via atomic flag
    // The wait loop actively polls this flag instead of blocking on a notification
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

pub fn preadSync(fh: *anyopaque, buf: [*]u8, offset: usize, count: usize) !usize {
    const nfs_ctx = get_nfs_context() orelse return error.NoNFSContext;
    const slot = nfs_pool.acquire() orelse return error.PoolExhausted;
    defer nfs_pool.release(slot);

    slot.operation = .Pread;
    slot.read_buf = buf;
    slot.stat_out = null;

    const fh_typed: *nfsfh = @ptrCast(@alignCast(fh));
    const rc = nfs_pread_async(
        nfs_ctx,
        fh_typed,
        @intCast(offset),
        count,
        nfs_callback_c_bridge,
        @as(?*anyopaque, @ptrCast(slot)),
    );
    if (rc < 0) {
        _ = c.printf("[nfs] nfs_pread_async failed: %d\n", rc);
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

pub fn lseekSync(fh: *anyopaque, offset: i64, whence: c_int) !u64 {
    const nfs_ctx = get_nfs_context() orelse return error.NoNFSContext;
    const slot = nfs_pool.acquire() orelse return error.PoolExhausted;
    defer nfs_pool.release(slot);

    slot.operation = .Lseek;
    slot.read_buf = null;
    slot.stat_out = null;
    slot.seek_value = 0;

    const fh_typed: *nfsfh = @ptrCast(@alignCast(fh));
    const rc = nfs_lseek_async(
        nfs_ctx,
        fh_typed,
        offset,
        whence,
        nfs_callback_c_bridge,
        @as(?*anyopaque, @ptrCast(slot)),
    );
    if (rc < 0) {
        _ = c.printf("[nfs] nfs_lseek_async failed: %d\n", rc);
        return error.NFSOperationFailed;
    }

    const status = NfsPool.wait(slot);
    if (status < 0) {
        return errnoToError(-status);
    }

    return slot.seek_value;
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

pub fn unlinkSync(path: [*:0]const u8) !void {
    const nfs_ctx = get_nfs_context() orelse return error.NoNFSContext;
    const slot = nfs_pool.acquire() orelse return error.PoolExhausted;
    defer nfs_pool.release(slot);

    slot.operation = .Unlink;
    slot.read_buf = null;
    slot.stat_out = null;

    const rc = nfs_unlink_async(
        nfs_ctx,
        path,
        nfs_callback_c_bridge,
        @as(?*anyopaque, @ptrCast(slot)),
    );
    if (rc < 0) {
        _ = c.printf("[nfs] nfs_unlink_async failed: %d\n", rc);
        return error.NFSOperationFailed;
    }

    const status = NfsPool.wait(slot);
    if (status < 0) {
        return errnoToError(-status);
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

    const rc = nfs_stat64_async(
        nfs_ctx,
        path,
        nfs_callback_c_bridge,
        @as(?*anyopaque, @ptrCast(slot)),
    );
    if (rc < 0) {
        _ = c.printf("[nfs] nfs_stat64_async failed: %d\n", rc);
        return error.NFSOperationFailed;
    }

    const status = NfsPool.wait(slot);
    if (status < 0) {
        return errnoToError(-status);
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

pub fn readDirEntry(dir: *anyopaque) ?[*:0]const u8 {
    const nfs_ctx = get_nfs_context() orelse return null;
    const entry = nfs_readdir(nfs_ctx, @ptrCast(dir));
    if (entry == null) return null;
    return entry.?.name;
}

pub fn closeDir(dir: *anyopaque) void {
    const nfs_ctx = get_nfs_context() orelse return;
    nfs_closedir(nfs_ctx, @ptrCast(dir));
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
const nfsdirent = extern struct {
    next: ?*nfsdirent,
    name: [*:0]const u8,
};

const nfs_cb = *const fn (c_int, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void;

extern fn get_nfs_context() ?*nfs_context;
extern fn nfs_is_mounted() bool;

extern fn nfs_open2_async(nfs_ctx: ?*nfs_context, path: [*:0]const u8, flags: c_int, mode: c_int, cb: nfs_cb, private_data: ?*anyopaque) c_int;
extern fn nfs_read_async(nfs_ctx: ?*nfs_context, fh: ?*nfsfh, count: u64, cb: nfs_cb, private_data: ?*anyopaque) c_int;
extern fn nfs_pread_async(nfs_ctx: ?*nfs_context, fh: ?*nfsfh, offset: u64, count: u64, cb: nfs_cb, private_data: ?*anyopaque) c_int;
extern fn nfs_write_async(nfs_ctx: ?*nfs_context, fh: ?*nfsfh, count: u64, buf: [*]const u8, cb: nfs_cb, private_data: ?*anyopaque) c_int;
extern fn nfs_close_async(nfs_ctx: ?*nfs_context, fh: ?*nfsfh, cb: nfs_cb, private_data: ?*anyopaque) c_int;
extern fn nfs_lseek_async(nfs_ctx: ?*nfs_context, fh: ?*nfsfh, offset: i64, whence: c_int, cb: nfs_cb, private_data: ?*anyopaque) c_int;
extern fn nfs_stat64_async(nfs_ctx: ?*nfs_context, path: [*:0]const u8, cb: nfs_cb, private_data: ?*anyopaque) c_int;
extern fn nfs_opendir_async(nfs_ctx: ?*nfs_context, path: [*:0]const u8, cb: nfs_cb, private_data: ?*anyopaque) c_int;
extern fn nfs_readdir(nfs_ctx: ?*nfs_context, dir: ?*nfsdir) ?*nfsdirent;
extern fn nfs_closedir(nfs_ctx: ?*nfs_context, dir: ?*nfsdir) void;
extern fn nfs_service(nfs_ctx: ?*nfs_context, revents: c_int) c_int;
extern fn nfs_unlink_async(nfs_ctx: ?*nfs_context, path: [*:0]const u8, cb: nfs_cb, private_data: ?*anyopaque) c_int;
extern fn nfs_get_error(nfs_ctx: ?*nfs_context) [*:0]const u8;

const nfs_stat_64 = extern struct {
    nfs_dev: u64,
    nfs_ino: u64,
    nfs_mode: u64,
    nfs_nlink: u64,
    nfs_uid: u64,
    nfs_gid: u64,
    nfs_rdev: u64,
    nfs_size: u64,
    nfs_blksize: u64,
    nfs_blocks: u64,
    nfs_atime: u64,
    nfs_mtime: u64,
    nfs_ctime: u64,
    nfs_atime_nsec: u64,
    nfs_mtime_nsec: u64,
    nfs_ctime_nsec: u64,
    nfs_used: u64,
};

fn assignStat(out: *sos_types.sos_stat_t, src: *const nfs_stat_64) void {
    out.st_type = sos_types.ST_FILE;
    const fmode_type = @TypeOf(out.st_fmode);
    out.st_fmode = @as(fmode_type, @intCast(modeToFmode(src.nfs_mode)));

    const size_type = @TypeOf(out.st_size);
    const size_max = std.math.maxInt(size_type);
    const clamped_size = if (src.nfs_size > size_max) size_max else src.nfs_size;
    out.st_size = @intCast(clamped_size);

    out.st_ctime = clampToType(@TypeOf(out.st_ctime), convertTimeMs(src.nfs_ctime, src.nfs_ctime_nsec));
    out.st_atime = clampToType(@TypeOf(out.st_atime), convertTimeMs(src.nfs_atime, src.nfs_atime_nsec));
}

fn convertTimeMs(seconds: u64, nanos: u64) i128 {
    const sec_ms: i128 = @intCast(seconds);
    const ns_part: i128 = @intCast(nanos);
    return sec_ms * 1000 + @divTrunc(ns_part, 1_000_000);
}

fn clampToType(comptime T: type, value: i128) T {
    const min_val: i128 = @intCast(std.math.minInt(T));
    const max_val: i128 = @intCast(std.math.maxInt(T));
    const clamped = std.math.clamp(value, min_val, max_val);
    return @intCast(clamped);
}

fn modeToFmode(mode: u64) c_int {
    var fmode: c_int = 0;
    if ((mode & READ_MODE_MASK) != 0) fmode |= sos_types.FM_READ;
    if ((mode & WRITE_MODE_MASK) != 0) fmode |= sos_types.FM_WRITE;
    if ((mode & EXEC_MODE_MASK) != 0) fmode |= sos_types.FM_EXEC;
    return fmode;
}

fn errnoToError(errno: i32) anyerror {
    return switch (errno) {
        sos.ENOENT => error.NotFound,
        sos.EACCES => error.PermissionDenied,
        sos.ENOMEM => error.OutOfMemory,
        sos.ENETUNREACH => error.NetworkUnreachable,
        else => error.OperationFailed,
    };
}

// C-callable wrappers for pagefile subsystem

/// Open file synchronously (C-callable wrapper)
/// Returns file handle on success, null on failure
pub export fn nfs_open_sync_c(path: [*:0]const u8, flags: c_int) callconv(.c) ?*anyopaque {
    return openSync(path, flags) catch |err| {
        _ = c.printf("[nfs] nfs_open_sync_c failed: %d\n", @intFromError(err));
        return null;
    };
}

/// Close file synchronously (C-callable wrapper)
/// Returns 0 on success, -1 on failure
pub export fn nfs_close_sync_c(fh: ?*anyopaque) callconv(.c) c_int {
    if (fh == null) return -1;
    closeSync(fh.?) catch {
        return -1;
    };
    return 0;
}

/// Callback type for async pagefile operations
pub const PagefileAsyncCallback = *const fn (status: c_int, fh: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) void;

/// Queue async NFS open for pagefile
///
/// This function queues an async NFS open operation and returns immediately
/// without blocking. The callback will be invoked when the operation completes.
///
/// WARN: This function must be used instead of nfs_open_sync_c for pagefile
/// initialisation to avoid deadlock when called before the syscall loop begins.
pub export fn nfs_open_async_c(
    path: [*:0]const u8,
    flags: c_int,
    callback: PagefileAsyncCallback,
    userdata: ?*anyopaque,
) callconv(.c) c_int {
    const nfs_ctx = get_nfs_context() orelse {
        _ = c.printf("[nfs] nfs_open_async_c: no NFS context\n");
        return -1;
    };

    const mode: c_int = if ((flags & O_CREAT) != 0)
        DEFAULT_CREATE_MODE
    else
        0;

    // Static storage for callback data (only used for pagefile init, one-time use)
    const CallbackData = struct {
        callback: PagefileAsyncCallback,
        userdata: ?*anyopaque,
    };

    const Static = struct {
        var cb_data: CallbackData = undefined;
        var initialised: bool = false;
    };

    if (Static.initialised) {
        _ = c.printf("[nfs] nfs_open_async_c: only one async open supported at a time\n");
        return -1;
    }

    Static.cb_data = .{
        .callback = callback,
        .userdata = userdata,
    };
    Static.initialised = true;

    // Create wrapper callback that adapts libnfs callback to our C callback
    const CallbackWrapper = struct {
        fn wrapper(status: c_int, _: ?*anyopaque, data: ?*anyopaque, _private: ?*anyopaque) callconv(.c) void {
            _ = _private;

            // Invoke the user's callback with adapted parameters
            Static.cb_data.callback(status, data, Static.cb_data.userdata);

            // Mark as available for reuse
            Static.initialised = false;
        }
    };

    const rc = nfs_open2_async(nfs_ctx, path, flags, mode, CallbackWrapper.wrapper, null);
    if (rc < 0) {
        _ = c.printf("[nfs] nfs_open2_async failed: %d\n", rc);
        Static.initialised = false;
        return -1;
    }

    return 0;
}
