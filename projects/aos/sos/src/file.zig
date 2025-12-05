const std = @import("std");

const cimports = @import("cimports");
const c = cimports.c;
const sos = cimports.sos;
const MAX_CLIENTS: usize = sos.MAX_CLIENTS;

const nfs_handler = @import("nfs_handler.zig");

const SOS_MAX_OPEN_FILES: usize = 32;

const EXTRA_HANDLE_SLOTS: usize = 64;
const HANDLE_POOL_CAPACITY: usize = SOS_MAX_OPEN_FILES + EXTRA_HANDLE_SLOTS;
comptime {
    if (HANDLE_POOL_CAPACITY == 0) {
        @compileError("HANDLE_POOL_CAPACITY must be non-zero");
    }
}

const SpinLock = struct {
    state: u8 = 0,

    fn guard(self: *SpinLock) Guard {
        self.lock();
        return Guard{ .lock = self };
    }

    fn lock(self: *SpinLock) void {
        while (true) {
            if (@cmpxchgStrong(u8, &self.state, 0, 1, .acq_rel, .acquire) == null) {
                return;
            }
        }
    }

    fn unlock(self: *SpinLock) void {
        @atomicStore(u8, &self.state, 0, .release);
    }

    fn reset(self: *SpinLock) void {
        @atomicStore(u8, &self.state, 0, .release);
    }

    const Guard = struct {
        lock: *SpinLock,

        fn release(self: Guard) void {
            self.lock.unlock();
        }
    };
};

pub const FileHandleRef = struct {
    pool_slot: usize = 0,
    raw_handle: ?FileHandle = null,
    fd_hint: c_int = -1,
    refcnt: usize = 0,
};

pub const HandleRelease = union(enum) {
    Active,
    Closed: FileHandle,
};

const HandlePoolError = error{Exhausted};

const HandlePool = struct {
    slots: [HANDLE_POOL_CAPACITY]FileHandleRef = [_]FileHandleRef{FileHandleRef{}} ** HANDLE_POOL_CAPACITY,
    used: [HANDLE_POOL_CAPACITY]bool = [_]bool{false} ** HANDLE_POOL_CAPACITY,
    lock: SpinLock = .{},

    fn reset(self: *HandlePool) void {
        self.used = [_]bool{false} ** HANDLE_POOL_CAPACITY;
        for (&self.slots) |*slot| {
            slot.* = FileHandleRef{};
        }
        self.lock.reset();
    }

    fn alloc(self: *HandlePool, raw_handle: FileHandle) HandlePoolError!*FileHandleRef {
        const guard = self.lock.guard();
        defer guard.release();
        for (&self.slots, 0..) |*slot, idx| {
            if (self.used[idx]) continue;
            self.used[idx] = true;
            slot.* = FileHandleRef{
                .pool_slot = idx,
                .raw_handle = raw_handle,
                .fd_hint = -1,
                .refcnt = 1,
            };
            return slot;
        }
        return HandlePoolError.Exhausted;
    }

    fn retain(self: *HandlePool, slot: *FileHandleRef) void {
        const guard = self.lock.guard();
        defer guard.release();
        if (slot.refcnt == std.math.maxInt(usize)) {
            @panic("file handle refcount overflow");
        }
        slot.refcnt += 1;
    }

    fn release(self: *HandlePool, slot: *FileHandleRef) HandleRelease {
        const guard = self.lock.guard();
        defer guard.release();
        if (slot.refcnt == 0) {
            return HandleRelease.Active;
        }
        slot.refcnt -= 1;
        if (slot.refcnt == 0) {
            const raw = slot.raw_handle;
            const idx = slot.pool_slot;
            slot.* = FileHandleRef{};
            if (idx < self.used.len) {
                self.used[idx] = false;
            }
            if (raw) |handle| {
                return HandleRelease{ .Closed = handle };
            }
            return HandleRelease.Active;
        }
        return HandleRelease.Active;
    }
};

pub const FileHandle = *anyopaque;

pub const FileTableError = error{
    TableFull,
    InvalidFd,
    SlotUnused,
    MissingHandle,
};

const FileTableEntry = struct {
    used: bool = false,
    generation: u32 = 0,
    handle: ?FileHandle = null,
};

pub const FileTable = struct {
    entries: [SOS_MAX_OPEN_FILES]FileTableEntry = [_]FileTableEntry{FileTableEntry{}} ** SOS_MAX_OPEN_FILES,
    next_generation: u32 = 1,

    const Self = @This();

    pub fn init(self: *Self) void {
        self.* = Self{};
        if (self.entries.len > 0) {
            self.entries[0].used = true;
            self.entries[0].handle = null;
        }
    }

    fn bumpGeneration(self: *Self) void {
        self.next_generation +%= 1;
        if (self.next_generation == 0) {
            self.next_generation = 1;
        }
    }

    pub fn allocFd(self: *Self, handle: FileHandle) FileTableError!usize {
        var idx: usize = 0;
        while (idx < self.entries.len) : (idx += 1) {
            const entry = &self.entries[idx];
            if (!entry.used) {
                entry.used = true;
                entry.generation = self.next_generation;
                entry.handle = handle;
                self.bumpGeneration();
                return idx;
            }
        }
        return FileTableError.TableFull;
    }

    pub fn getHandle(self: *const Self, fd: usize) FileTableError!FileHandle {
        if (fd >= self.entries.len) {
            return FileTableError.InvalidFd;
        }
        const entry = self.entries[fd];
        if (!entry.used) {
            return FileTableError.SlotUnused;
        }
        return entry.handle orelse FileTableError.MissingHandle;
    }

    pub fn freeFd(self: *Self, fd: usize) FileTableError!void {
        if (fd >= self.entries.len) {
            return FileTableError.InvalidFd;
        }
        const entry = &self.entries[fd];
        if (!entry.used) {
            return FileTableError.SlotUnused;
        }
        entry.* = FileTableEntry{};
    }
};

pub const FileOps = extern struct {
    open: ?*const fn (name: [*c]const u8, mode: c_int, out_id: ?*c_int) callconv(.c) c_int,
    read: ?*const fn (id: c_int, buf: ?*anyopaque, len: usize) callconv(.c) isize,
    write: ?*const fn (id: c_int, buf: ?*const anyopaque, len: usize) callconv(.c) isize,
    close: ?*const fn (id: c_int) callconv(.c) c_int,
};

pub const FileKind = enum(c_int) {
    none = 0,
    dev_console = 1,
    regular = 2,
};

pub const File = extern struct {
    used: bool,
    readable: bool,
    writable: bool,
    kind: FileKind,
    obj: ?*anyopaque,
    ops: ?*const FileOps,
    dev_id: c_int,
    refcnt: u16,
    offset: usize,
};

pub const ConsoleDev = extern struct {
    reader_in_use: bool,
    reader_owner_id: u16,
    write_refcnt: usize,
};

pub const Devices = extern struct {
    name: [*c]const u8,
    ops: *const FileOps,
};

const ring_capacity: usize = @intCast(sos.CONSOLE_RING_SIZE);

extern fn sos_console_data_ready() callconv(.c) void;

const console_name: [:0]const u8 = "console";
pub const console_name_ptr: [*c]const u8 = @ptrCast(console_name.ptr);

pub const empty_fd: File = File{
    .used = false,
    .readable = false,
    .writable = false,
    .kind = FileKind.none,
    .obj = null,
    .ops = null,
    .dev_id = 0,
    .refcnt = 0,
    .offset = 0,
};
const empty_fd_table = [_]File{empty_fd} ** SOS_MAX_OPEN_FILES;

pub const ClientIoState = struct {
    initialised: bool = false,
    fds: [SOS_MAX_OPEN_FILES]File = empty_fd_table,
    file_table: FileTable = FileTable{},
    handle_pool: HandlePool = HandlePool{},

    pub fn reset(self: *ClientIoState) void {
        self.* = ClientIoState{};
        self.file_table.init();
        self.handle_pool.reset();
    }

    pub fn allocHandleRef(self: *ClientIoState, raw_handle: FileHandle) HandlePoolError!*FileHandleRef {
        return self.handle_pool.alloc(raw_handle);
    }

    pub fn retainHandleRef(self: *ClientIoState, slot: *FileHandleRef) void {
        self.handle_pool.retain(slot);
    }

    pub fn releaseHandleRef(self: *ClientIoState, slot: *FileHandleRef) HandleRelease {
        return self.handle_pool.release(slot);
    }
};

pub inline fn handleRefFromOpaque(ptr: ?*anyopaque) ?*FileHandleRef {
    if (ptr == null) return null;
    return @ptrCast(@alignCast(ptr.?));
}

pub inline fn rawFileHandle(ref: *FileHandleRef) FileHandle {
    return ref.raw_handle orelse @panic("FileHandleRef missing raw handle");
}

pub inline fn setHandleFdHint(ref: *FileHandleRef, fd: c_int) void {
    ref.fd_hint = fd;
}

pub var client_io_state: [MAX_CLIENTS]ClientIoState = [_]ClientIoState{ClientIoState{}} ** MAX_CLIENTS;

pub export var global_console: ConsoleDev = .{
    .reader_in_use = false,
    .reader_owner_id = 0,
    .write_refcnt = 0,
};

/// Circular buffer to store the contents of the network console until it is read.
const ConsoleRing = struct {
    /// The buffer storing the actual data
    buf: [ring_capacity]u8 = [_]u8{0} ** ring_capacity,
    /// Index of the head in `buf`
    head: usize = 0,
    /// Index of the tail in `buf`
    tail: usize = 0,

    fn isEmpty(self: *const ConsoleRing) bool {
        return self.head == self.tail;
    }

    fn next(index: usize) usize {
        return (index + 1) % ring_capacity;
    }

    fn push(self: *ConsoleRing, byte: u8) void {
        const next_head = Self.next(self.head);
        if (next_head == self.tail) {
            return;
        }
        self.buf[self.head] = byte;
        self.head = next_head;
    }

    fn popMany(self: *ConsoleRing, dest: []u8, stop_on_nl: bool) usize {
        if (dest.len == 0) {
            return 0;
        }

        var produced: usize = 0;
        while (produced < dest.len and !self.isEmpty()) {
            const byte = self.buf[self.tail];
            self.tail = Self.next(self.tail);
            dest[produced] = byte;
            produced += 1;
            if (stop_on_nl and byte == '\n') {
                break;
            }
        }

        return produced;
    }

    const Self = @This();
};

/// A driver for the network console.
const ConsoleDevice = struct {
    /// Ring buffer storing the contents of the console until it is read from
    ring: ConsoleRing = .{},
    /// Has it been registered to by the network console?
    input_handler_registered: bool = false,

    /// Lazy registration of the input handler to the network console
    fn ensureInputHandler(self: *ConsoleDevice) void {
        if (self.input_handler_registered) {
            return;
        }

        const netcon = sos.sos_nc;
        if (netcon == null) {
            return;
        }

        _ = sos.network_console_register_handler(netcon, nc_input_handler);
        self.input_handler_registered = true;
    }

    fn badgeFromMode(mode: c_int) u8 {
        const access = mode & c.O_ACCMODE;
        const allow_read = access == c.O_RDONLY or access == c.O_RDWR;
        const allow_write = access == c.O_WRONLY or access == c.O_RDWR;
        return (if (allow_read) @as(u8, 1) else 0) |
            (if (allow_write) @as(u8, 2) else 0);
    }

    /// Push input to ring buffer.
    fn handleInput(self: *ConsoleDevice, ch: u8) void {
        self.ring.push(ch);
        sos_console_data_ready();
    }

    /// Open handler for the console
    fn open(self: *ConsoleDevice, name: [*c]const u8, mode: c_int, out_id: ?*c_int) c_int {
        if (name == null or out_id == null) {
            return -sos.EINVAL;
        }

        if (!ConsoleDevice.nameMatches(name)) {
            return -sos.ENODEV;
        }

        self.ensureInputHandler();
        if (sos.sos_nc == null) {
            return -sos.ENODEV;
        }

        const badge = ConsoleDevice.badgeFromMode(mode);
        if (badge == 0) {
            return -sos.EINVAL;
        }

        out_id.?.* = @as(c_int, badge);
        return 0;
    }

    /// Read data from the ring buffer.
    fn read(self: *ConsoleDevice, buf: ?*anyopaque, len: usize) isize {
        if (buf == null or len == 0) {
            return 0;
        }

        if (self.ring.isEmpty()) {
            return -sos.EWOULDBLOCK;
        }

        const raw_ptr: [*]u8 = @ptrCast(buf.?);
        const out_slice = raw_ptr[0..len];
        const copied = self.ring.popMany(out_slice, false);
        return @as(isize, @intCast(copied));
    }

    /// Write data to the network console.
    fn write(self: *ConsoleDevice, buf: ?*const anyopaque, len: usize) isize {
        if (buf == null or len == 0) {
            return 0;
        }

        _ = self;
        const netcon = sos.sos_nc;
        if (netcon == null) {
            return -sos.ENODEV;
        }

        const max_c_len = @as(usize, @intCast(std.math.maxInt(c_int)));
        const usable_len = @min(len, max_c_len);
        const len_int = std.math.cast(c_int, usable_len) orelse return -sos.EINVAL;
        const data_ptr: [*c]const u8 = @ptrCast(buf.?);
        const sent = sos.network_console_send(netcon, data_ptr, len_int);
        return @as(isize, @intCast(sent));
    }

    /// Close semantics for the console
    fn close(self: *ConsoleDevice, id: c_int) c_int {
        _ = self;
        _ = id;
        return 0;
    }

    fn nameMatches(name_ptr: [*c]const u8) bool {
        if (name_ptr == null) {
            return false;
        }
        const provided = std.mem.sliceTo(name_ptr, 0);
        return std.mem.eql(u8, provided, console_name);
    }
};

var console_device = ConsoleDevice{};

fn nc_input_handler(
    _: ?*sos.struct_network_console,
    ch: c_char,
) callconv(.c) void {
    console_device.handleInput(@bitCast(ch));
}

pub export fn console_open(
    name: [*c]const u8,
    mode: c_int,
    out_id: ?*c_int,
) callconv(.c) c_int {
    return console_device.open(name, mode, out_id);
}

pub export fn console_read(
    _: c_int,
    buf: ?*anyopaque,
    len: usize,
) callconv(.c) isize {
    return console_device.read(buf, len);
}

pub export fn console_close(id: c_int) callconv(.c) c_int {
    return console_device.close(id);
}

pub export fn console_write(
    _: c_int,
    buf: ?*const anyopaque,
    len: usize,
) callconv(.c) isize {
    return console_device.write(buf, len);
}

var console_ops: FileOps = .{
    .open = console_open,
    .read = console_read,
    .write = console_write,
    .close = console_close,
};

/// NFS file backend for regular file operations.
/// This provides FileOps-compatible interface wrapping nfs_handler.zig primitives.
const NfsFileBackend = struct {
    fn open(name: [*c]const u8, mode: c_int, out_id: ?*c_int) callconv(.c) c_int {
        if (name == null or out_id == null) {
            return -sos.EINVAL;
        }

        const path_slice = std.mem.sliceTo(name, 0);
        if (path_slice.len == 0) {
            return -sos.EINVAL;
        }

        // Reject paths containing '/' (no directory support yet per CLAUDE.md)
        for (path_slice) |ch| {
            if (ch == '/') {
                return -sos.EINVAL;
            }
        }

        // Convert mode flags to NFS flags
        const flags: c_int = mode;

        // Attempt to open file via NFS handler
        const fh = nfs_handler.openSync(name, flags) catch |err| {
            _ = c.printf("[nfs_file] Failed to open '%s': error=%d\n", name, @intFromError(err));
            return switch (err) {
                error.NoNFSContext => -sos.EIO,
                error.PoolExhausted => -sos.ENOMEM,
                error.NFSOperationFailed, error.OperationFailed => -sos.EIO,
            };
        };

        // Cast handle to int for storage in File.dev_id
        // We store the raw pointer value as an integer
        const handle_int: c_int = @intCast(@intFromPtr(fh));
        out_id.?.* = handle_int;
        return 0;
    }

    fn read(id: c_int, buf: ?*anyopaque, len: usize) callconv(.c) isize {
        if (buf == null or len == 0) {
            return 0;
        }

        // Reconstruct file handle from dev_id
        const fh: *anyopaque = @ptrFromInt(@as(usize, @intCast(id)));
        const buf_ptr: [*]u8 = @ptrCast(buf.?);

        const bytes_read = nfs_handler.readSync(fh, buf_ptr, len) catch |err| {
            _ = c.printf("[nfs_file] Read failed: error=%d\n", @intFromError(err));
            return -sos.EIO;
        };

        return @intCast(bytes_read);
    }

    fn write(id: c_int, buf: ?*const anyopaque, len: usize) callconv(.c) isize {
        if (buf == null or len == 0) {
            return 0;
        }

        const fh: *anyopaque = @ptrFromInt(@as(usize, @intCast(id)));
        const buf_ptr: [*]const u8 = @ptrCast(buf.?);

        const bytes_written = nfs_handler.writeSync(fh, buf_ptr, len) catch |err| {
            _ = c.printf("[nfs_file] Write failed: error=%d\n", @intFromError(err));
            return -sos.EIO;
        };

        return @intCast(bytes_written);
    }

    fn close(id: c_int) callconv(.c) c_int {
        const fh: *anyopaque = @ptrFromInt(@as(usize, @intCast(id)));

        nfs_handler.closeSync(fh) catch |err| {
            _ = c.printf("[nfs_file] Close failed: error=%d\n", @intFromError(err));
            return -sos.EIO;
        };

        return 0;
    }
};

var nfs_file_ops: FileOps = .{
    .open = NfsFileBackend.open,
    .read = NfsFileBackend.read,
    .write = NfsFileBackend.write,
    .close = NfsFileBackend.close,
};

/// Kernel-internal file handle for subsystems that need direct file access
/// without going through the syscall layer (e.g., pagefile, swap subsystem).
///
/// This provides a simplified interface wrapping NFS operations.
pub const KernelFileHandle = struct {
    nfs_fh: *anyopaque,

    /// Open a file for kernel-internal use.
    ///
    /// Parameters:
    ///   path - Null-terminated file name (must not contain '/')
    ///   flags - Open flags (O_RDONLY, O_WRONLY, O_RDWR, O_CREAT, etc.)
    ///
    /// Returns: KernelFileHandle on success, error otherwise
    pub fn open(path: [*:0]const u8, flags: c_int) !KernelFileHandle {
        // Validate path doesn't contain '/' per VFS limitations
        const path_slice = std.mem.sliceTo(path, 0);
        for (path_slice) |ch| {
            if (ch == '/') {
                _ = c.printf("[kernel_file] Rejected path with '/': %s\n", path);
                return error.InvalidPath;
            }
        }

        const fh = try nfs_handler.openSync(path, flags);
        _ = c.printf("[kernel_file] Opened '%s' successfully (fh=%p)\n", path, fh);

        return KernelFileHandle{ .nfs_fh = fh };
    }

    /// Read from kernel file handle.
    pub fn read(self: KernelFileHandle, buf: []u8) !usize {
        return nfs_handler.readSync(self.nfs_fh, buf.ptr, buf.len);
    }

    /// Write to kernel file handle.
    pub fn write(self: KernelFileHandle, buf: []const u8) !usize {
        return nfs_handler.writeSync(self.nfs_fh, buf.ptr, buf.len);
    }

    /// Positioned read from kernel file handle.
    pub fn pread(self: KernelFileHandle, buf: []u8, offset: usize) !usize {
        return nfs_handler.preadSync(self.nfs_fh, buf.ptr, offset, buf.len);
    }

    /// Positioned write to kernel file handle.
    pub fn pwrite(self: KernelFileHandle, buf: []const u8, offset: usize) !usize {
        return nfs_handler.pwriteSync(self.nfs_fh, buf.ptr, offset, buf.len);
    }

    /// Seek within kernel file handle.
    pub fn lseek(self: KernelFileHandle, offset: i64, whence: c_int) !u64 {
        return nfs_handler.lseekSync(self.nfs_fh, offset, whence);
    }

    /// Close kernel file handle.
    pub fn close(self: KernelFileHandle) void {
        nfs_handler.closeSync(self.nfs_fh) catch |err| {
            _ = c.printf("[kernel_file] Warning: Close failed with error %d\n", @intFromError(err));
        };
        _ = c.printf("[kernel_file] Closed file handle (fh=%p)\n", self.nfs_fh);
    }
};

pub export var devices: [1]Devices = [_]Devices{.{
    .name = console_name_ptr,
    .ops = &console_ops,
}};

pub export var dev_table_len: usize = devices.len;

pub export fn vfs_lookup_ops(name: [*c]const u8) ?*const FileOps {
    if (!ConsoleDevice.nameMatches(name)) {
        return null;
    }
    return devices[0].ops;
}

test "FileTable basic operations" {
    var table = FileTable{};
    table.init();

    var dummy: u32 = 42;
    const handle: FileHandle = @ptrCast(&dummy);

    try std.testing.expectError(FileTableError.MissingHandle, table.getHandle(0));

    const fd1 = try table.allocFd(handle);
    try std.testing.expectEqual(@as(usize, 1), fd1);

    const retrieved = try table.getHandle(fd1);
    try std.testing.expectEqual(handle, retrieved);

    try table.freeFd(fd1);
    try std.testing.expectError(FileTableError.SlotUnused, table.getHandle(fd1));
}
