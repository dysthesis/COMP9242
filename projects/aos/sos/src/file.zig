const std = @import("std");

const cimports = @import("cimports");
const c = cimports.c;
const sos = cimports.sos;
const MAX_CLIENTS: usize = sos.MAX_CLIENTS;

const super = @import("main.zig");
const SOS_MAX_OPEN_FILES = super.SOS_MAX_OPEN_FILES;

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
};

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
        if ((id & 1) != 0) {
            global_console.reader_in_use = false;
        }
        if ((id & 2) != 0 and global_console.write_refcnt > 0) {
            global_console.write_refcnt -= 1;
        }
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
