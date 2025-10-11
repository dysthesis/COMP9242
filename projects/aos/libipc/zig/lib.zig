const c = @cImport({
    @cInclude("stdio.h");
});

pub export fn hiFromLibIpc() callconv(.c) void {
    // you can access c functions like this
    _ = c.printf("hi from libipc!\n");
}
