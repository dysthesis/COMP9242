const std = @import("std");
const cimports = @import("cimports");
const c = cimports.c;

pub const WorkType = enum(u8) {
    Open,
    Close,
    Read,
    Write,
    Stat,
    OpenDir,
    ReadDir,
};

pub const OpenParams = struct {
    path: [256:0]u8,
    flags: c_int,
    client_id: u32,
};

pub const ReadParams = struct {
    fd: usize,
    count: usize,
    client_buf: usize,
    client_id: u32,
};

pub const WriteParams = struct {
    fd: usize,
    data: [4096]u8,
    count: usize,
    client_id: u32,
};

pub const CloseParams = struct {
    fd: usize,
    client_id: u32,
};

pub const StatParams = struct {
    path: [256:0]u8,
    client_id: u32,
};

pub const OpenDirParams = struct {
    path: [256:0]u8,
    client_id: u32,
};

pub const ReadDirParams = struct {
    fd: usize,
    client_id: u32,
};

pub const WorkParams = union(WorkType) {
    Open: OpenParams,
    Close: CloseParams,
    Read: ReadParams,
    Write: WriteParams,
    Stat: StatParams,
    OpenDir: OpenDirParams,
    ReadDir: ReadDirParams,
};

pub const FileOpResult = union(enum) {
    Fd: usize,
    Bytes: usize,
    Errno: i32,

    pub fn okFd(fd: usize) FileOpResult {
        return .{ .Fd = fd };
    }

    pub fn okBytes(count: usize) FileOpResult {
        return .{ .Bytes = count };
    }

    pub fn err(errno: i32) FileOpResult {
        return .{ .Errno = errno };
    }
};

pub const FileOpState = struct {
    params: WorkParams,
    result: FileOpResult = FileOpResult.err(0),
    completed: bool align(4) = false,

    pub fn reset(self: *FileOpState) void {
        self.result = FileOpResult.err(0);
        @atomicStore(bool, &self.completed, false, .release);
    }

    fn finish(self: *FileOpState, value: FileOpResult) void {
        self.result = value;
        @atomicStore(bool, &self.completed, true, .release);
    }

    pub fn completeFd(self: *FileOpState, fd: usize) void {
        self.finish(FileOpResult.okFd(fd));
    }

    pub fn completeBytes(self: *FileOpState, count: usize) void {
        self.finish(FileOpResult.okBytes(count));
    }

    pub fn completeErrno(self: *FileOpState, errno: i32) void {
        self.finish(FileOpResult.err(errno));
    }

    pub fn isCompleted(self: *const FileOpState) bool {
        return @atomicLoad(bool, &self.completed, .acquire);
    }
};

test "FileOpResult helpers" {
    var res = FileOpResult.okFd(5);
    try std.testing.expect(res == .Fd);
    res = FileOpResult.okBytes(10);
    try std.testing.expect(res == .Bytes);
    res = FileOpResult.err(-1);
    try std.testing.expect(res == .Errno);
}
