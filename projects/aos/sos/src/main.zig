const c = @cImport({
    @cInclude("stdio.h");
});

// import zig's standard library
// OS dependent features won't be functional (without extra work)
// but there are still useful items like `std.debug.assert` and `std.math.maxInt`
const std = @import("std");

// `export` makes this function available to other objects at link time
// `callconv(.c)` makes it follow c calling convention
export fn hiFromZig() callconv(.c) void {
    // you can access c functions like this
    _ = c.printf("hi from zig!\n");
}
