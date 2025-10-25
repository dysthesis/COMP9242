pub fn resultToCInt(value: isize) c_int {
    return std.math.cast(c_int, value) orelse {
        return if (value < 0) @as(c_int, (-sos.EIO)) else std.math.maxInt(c_int);
    };
}

const std = @import("std");
const cimports = @import("cimports");
const sos = cimports.sos;
