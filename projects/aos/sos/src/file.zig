const std = @import("std");

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("file.h");
    @cInclude("networkconsole/networkconsole.h");
});

const ring_capacity: usize = @intCast(c.CONSOLE_RING_SIZE);

extern fn sos_console_data_ready() callconv(.c) void;

const console_name: [:0]const u8 = "console";
const console_name_ptr: [*c]const u8 = @ptrCast(console_name.ptr);

pub export var global_console: c.console_dev_t = .{
    .reader_in_use = false,
    .reader_owner_id = 0,
    .write_refcnt = 0,
};

const ConsoleRing = struct {
    buf: [ring_capacity]u8 = [_]u8{0} ** ring_capacity,
    head: usize = 0,
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

const ConsoleDevice = struct {
    ring: ConsoleRing = .{},
    input_handler_registered: bool = false,

    fn ensureInputHandler(self: *ConsoleDevice) void {
        if (self.input_handler_registered) {
            return;
        }

        const netcon = c.sos_nc;
        if (netcon == null) {
            return;
        }

        _ = c.network_console_register_handler(netcon, nc_input_handler);
        self.input_handler_registered = true;
    }

    fn badgeFromMode(mode: c_int) u8 {
        const access = mode & c.O_ACCMODE;
        const allow_read = access == c.O_RDONLY or access == c.O_RDWR;
        const allow_write = access == c.O_WRONLY or access == c.O_RDWR;
        return (if (allow_read) @as(u8, 1) else 0) |
            (if (allow_write) @as(u8, 2) else 0);
    }

    fn handleInput(self: *ConsoleDevice, ch: u8) void {
        self.ring.push(ch);
        sos_console_data_ready();
    }

    fn open(self: *ConsoleDevice, name: [*c]const u8, mode: c_int, out_id: ?*c_int) c_int {
        if (name == null or out_id == null) {
            return -c.EINVAL;
        }

        if (!ConsoleDevice.nameMatches(name)) {
            return -c.ENODEV;
        }

        self.ensureInputHandler();
        if (c.sos_nc == null) {
            return -c.ENODEV;
        }

        const badge = ConsoleDevice.badgeFromMode(mode);
        if (badge == 0) {
            return -c.EINVAL;
        }

        out_id.?.* = @as(c_int, badge);
        return 0;
    }

    fn read(self: *ConsoleDevice, buf: ?*anyopaque, len: usize) isize {
        if (buf == null or len == 0) {
            return 0;
        }

        if (self.ring.isEmpty()) {
            return -c.EWOULDBLOCK;
        }

        const raw_ptr: [*]u8 = @ptrCast(buf.?);
        const out_slice = raw_ptr[0..len];
        const copied = self.ring.popMany(out_slice, false);
        return @as(isize, @intCast(copied));
    }

    fn write(self: *ConsoleDevice, buf: ?*anyopaque, len: usize) isize {
        if (buf == null or len == 0) {
            return 0;
        }

        _ = self;
        const netcon = c.sos_nc;
        if (netcon == null) {
            return -c.ENODEV;
        }

        const max_c_len = @as(usize, @intCast(std.math.maxInt(c_int)));
        const usable_len = @min(len, max_c_len);
        const len_int = std.math.cast(c_int, usable_len) orelse return -c.EINVAL;
        const data_ptr: [*c]u8 = @ptrCast(buf.?);
        const sent = c.network_console_send(netcon, data_ptr, len_int);
        return @as(isize, @intCast(sent));
    }

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
    _: ?*c.struct_network_console,
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
    buf: ?*anyopaque,
    len: usize,
) callconv(.c) isize {
    return console_device.write(buf, len);
}

var console_ops = c.file_ops_t{
    .open = console_open,
    .read = console_read,
    .write = console_write,
    .close = console_close,
};

pub export var devices: [1]c.dev_reg_t = [_]c.dev_reg_t{.{
    .name = console_name_ptr,
    .ops = &console_ops,
}};

pub export var dev_table_len: usize = devices.len;

pub export fn vfs_lookup_ops(name: [*c]const u8) ?*const c.file_ops_t {
    if (!ConsoleDevice.nameMatches(name)) {
        return null;
    }
    return devices[0].ops;
}
