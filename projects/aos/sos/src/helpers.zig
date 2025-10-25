pub fn resultToCInt(value: isize) c_int {
    return std.math.cast(c_int, value) orelse {
        return if (value < 0) @as(c_int, (-sos.EIO)) else std.math.maxInt(c_int);
    };
}

pub fn sharedBufPtr(comptime T: type, caller: *sos.client_t) [*]T {
    const shbuf = caller.shbuf orelse {
        std.debug.panic("caller missing shared buffer", .{});
    };
    const addr_value = sos.sos_shared_page_kernel_va(shbuf);
    if (addr_value == 0) {
        std.debug.panic("shared buffer has no kernel mapping", .{});
    }
    const addr: usize = @intCast(addr_value);
    return @ptrFromInt(addr);
}

const std = @import("std");
const cimports = @import("cimports");
const sos = cimports.sos;
