const std = @import("std");
const cimports = @import("cimports");
const c = cimports.c;
const sos_types = cimports.sos_types;
const vm = @import("vm/mod.zig");
const file = @import("file.zig");

pub const WorkType = enum(u8) {
    Open,
    Close,
    Read,
    Write,
    Stat,
    OpenDir,
    ReadDir,
    GetDirent,
    PageFill,
};

pub const OPEN_PATH_CAPACITY: usize = 256;
pub const WRITE_BUFFER_CAPACITY: usize = 4096;

pub const OpenParams = struct {
    path: [OPEN_PATH_CAPACITY:0]u8,
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
    count: usize,
    client_buf: usize,
    client_id: u32,
};

pub const CloseParams = struct {
    fd: usize,
    client_id: u32,
};

pub const StatParams = struct {
    path: [OPEN_PATH_CAPACITY:0]u8,
    out_buf: usize,
    out_len: usize,
    client_id: u32,
};

pub const OpenDirParams = struct {
    path: [OPEN_PATH_CAPACITY:0]u8,
    client_id: u32,
};

pub const ReadDirParams = struct {
    fd: usize,
    client_id: u32,
};

pub const GetDirentParams = struct {
    index: usize,
    capacity: usize,
    client_id: u16,
    out_buf: usize,
    out_len: usize,
};

pub const PageFillSource = union(enum) {
    /// Anonymous memory requiring zero-initialised contents
    Anonymous,

    /// File-backed mapping requiring data fetched from a file descriptor
    File: struct {
        fd: c_int,
        file_offset: usize,
        length: usize = vm.PAGE_SIZE_4K,
        handle_ref: file.FileHandle = null,
    },
};

pub const PageFillParams = struct {
    client_id: u32,
    page_base: usize,
    prot: c_int,
    region_kind: vm.region.RegionKind,
    want_write: bool,
    prefetch: bool,
    source: PageFillSource,
};

pub const WorkParams = union(WorkType) {
    Open: OpenParams,
    Close: CloseParams,
    Read: ReadParams,
    Write: WriteParams,
    Stat: StatParams,
    OpenDir: OpenDirParams,
    ReadDir: ReadDirParams,
    GetDirent: GetDirentParams,
    PageFill: PageFillParams,
};

pub const FileOpResult = union(enum) {
    Fd: usize,
    Bytes: usize,
    Errno: i32,
    Status: i32,

    pub fn okFd(fd: usize) FileOpResult {
        return .{ .Fd = fd };
    }

    pub fn okBytes(count: usize) FileOpResult {
        return .{ .Bytes = count };
    }

    pub fn err(errno: i32) FileOpResult {
        return .{ .Errno = errno };
    }

    pub fn status(value: i32) FileOpResult {
        return .{ .Status = value };
    }
};

pub const FileOpState = struct {
    params: WorkParams,
    payload: [WRITE_BUFFER_CAPACITY]u8 = [_]u8{0} ** WRITE_BUFFER_CAPACITY,
    payload_len: usize = 0,
    stat_result: sos_types.sos_stat_t = std.mem.zeroes(sos_types.sos_stat_t),
    vm_handle: ?*vm.VmHandle = null,
    result: FileOpResult = FileOpResult.err(0),
    completed: bool align(4) = false,

    pub fn reset(self: *FileOpState) void {
        self.result = FileOpResult.err(0);
        self.payload_len = 0;
        self.stat_result = std.mem.zeroes(sos_types.sos_stat_t);
        self.vm_handle = null;
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

    pub fn completeStatus(self: *FileOpState, value: i32) void {
        self.finish(FileOpResult.status(value));
    }

    pub fn isCompleted(self: *const FileOpState) bool {
        return @atomicLoad(bool, &self.completed, .acquire);
    }

    pub fn payloadSlice(self: *FileOpState) []u8 {
        return self.payload[0..self.payload_len];
    }

    pub fn payloadSliceMut(self: *FileOpState) []u8 {
        return self.payload[0..];
    }
};

comptime {
    if (WRITE_BUFFER_CAPACITY < vm.PAGE_SIZE_4K) {
        @compileError("WRITE_BUFFER_CAPACITY must be at least one page for pager jobs");
    }
}

test "FileOpResult helpers" {
    var res = FileOpResult.okFd(5);
    try std.testing.expect(res == .Fd);
    res = FileOpResult.okBytes(10);
    try std.testing.expect(res == .Bytes);
    res = FileOpResult.err(-1);
    try std.testing.expect(res == .Errno);
}
