const lib = @import("lib.zig");
const std = @import("std");
const sel4 = lib.sel4;

pub const Syscall = union(lib.SyscallNum) {
    Open: struct { arg: sel4.seL4_Word, buf_addr: sel4.seL4_Word, buf_size: sel4.seL4_Word },
    Close: struct { arg: sel4.seL4_Word },
    Read: struct { arg: sel4.seL4_Word, buf_addr: sel4.seL4_Word, buf_size: sel4.seL4_Word },
    Write: struct { arg: sel4.seL4_Word, buf_addr: sel4.seL4_Word, buf_size: sel4.seL4_Word },
    Usleep: struct { arg: sel4.seL4_Word },
    Timestamp: struct {},
    MyId: struct {},
    Brk: struct { new_break: sel4.seL4_Word },
    Mmap: struct {
        addr: sel4.seL4_Word,
        length: sel4.seL4_Word,
        prot: sel4.seL4_Word,
        flags: sel4.seL4_Word,
        fd: sel4.seL4_Word,
        offset: sel4.seL4_Word,
    },
    // TODO: see if we can trim this down to 4 MRs
    Stat: struct { path_addr: sel4.seL4_Word, path_len: sel4.seL4_Word, out_addr: sel4.seL4_Word, out_len: sel4.seL4_Word },
    GetDirent: struct {
        index: usize, // which directory entry
        buf_addr: usize,
        buf_size: usize,
    },
    PagerStats: struct {},

    fn serialise(self: Syscall) sel4.seL4_MessageInfo_t {
        return switch (self) {
            .Open => |args| blk: {
                sel4.seL4_SetMR(0, @as(sel4.seL4_Word, @intFromEnum(lib.SyscallNum.Open)));
                sel4.seL4_SetMR(1, args.arg);
                sel4.seL4_SetMR(2, args.buf_addr);
                sel4.seL4_SetMR(3, args.buf_size);
                break :blk sel4.seL4_MessageInfo_new(0, 0, 0, 4);
            },
            .Close => |args| blk: {
                sel4.seL4_SetMR(0, @as(sel4.seL4_Word, @intFromEnum(lib.SyscallNum.Close)));
                sel4.seL4_SetMR(1, args.arg);
                sel4.seL4_SetMR(2, 0);
                sel4.seL4_SetMR(3, 0);
                break :blk sel4.seL4_MessageInfo_new(0, 0, 0, 4);
            },
            .Read => |args| blk: {
                sel4.seL4_SetMR(0, @as(sel4.seL4_Word, @intFromEnum(lib.SyscallNum.Read)));
                sel4.seL4_SetMR(1, args.arg);
                sel4.seL4_SetMR(2, args.buf_addr);
                sel4.seL4_SetMR(3, args.buf_size);
                break :blk sel4.seL4_MessageInfo_new(0, 0, 0, 4);
            },
            .Write => |args| blk: {
                sel4.seL4_SetMR(0, @as(sel4.seL4_Word, @intFromEnum(lib.SyscallNum.Write)));
                sel4.seL4_SetMR(1, args.arg);
                sel4.seL4_SetMR(2, args.buf_addr);
                sel4.seL4_SetMR(3, args.buf_size);
                break :blk sel4.seL4_MessageInfo_new(0, 0, 0, 4);
            },
            .Stat => |args| blk: {
                sel4.seL4_SetMR(0, @as(sel4.seL4_Word, @intFromEnum(lib.SyscallNum.Stat)));
                sel4.seL4_SetMR(1, args.path_addr);
                sel4.seL4_SetMR(2, args.path_len);
                sel4.seL4_SetMR(3, args.out_addr);
                sel4.seL4_SetMR(4, args.out_len);
                break :blk sel4.seL4_MessageInfo_new(0, 0, 0, 5);
            },
            .GetDirent => |args| blk: {
                sel4.seL4_SetMR(0, @as(sel4.seL4_Word, @intFromEnum(lib.SyscallNum.GetDirent)));
                sel4.seL4_SetMR(1, args.index);
                sel4.seL4_SetMR(2, args.buf_addr);
                sel4.seL4_SetMR(3, args.buf_size);
                break :blk sel4.seL4_MessageInfo_new(0, 0, 0, 4);
            },
            .Usleep => |args| blk: {
                sel4.seL4_SetMR(0, @as(sel4.seL4_Word, @intFromEnum(lib.SyscallNum.Usleep)));
                sel4.seL4_SetMR(1, args.arg);
                sel4.seL4_SetMR(2, 0);
                sel4.seL4_SetMR(3, 0);
                break :blk sel4.seL4_MessageInfo_new(0, 0, 0, 4);
            },
            .Timestamp => blk: {
                sel4.seL4_SetMR(0, @as(sel4.seL4_Word, @intFromEnum(lib.SyscallNum.Timestamp)));
                sel4.seL4_SetMR(1, 0);
                sel4.seL4_SetMR(2, 0);
                sel4.seL4_SetMR(3, 0);
                break :blk sel4.seL4_MessageInfo_new(0, 0, 0, 4);
            },
            .MyId => blk: {
                sel4.seL4_SetMR(0, @as(sel4.seL4_Word, @intFromEnum(lib.SyscallNum.MyId)));
                sel4.seL4_SetMR(1, 0);
                sel4.seL4_SetMR(2, 0);
                sel4.seL4_SetMR(3, 0);
                break :blk sel4.seL4_MessageInfo_new(0, 0, 0, 4);
            },
            .Brk => |args| blk: {
                sel4.seL4_SetMR(0, @as(sel4.seL4_Word, @intFromEnum(lib.SyscallNum.Brk)));
                sel4.seL4_SetMR(1, args.new_break);
                sel4.seL4_SetMR(2, 0);
                sel4.seL4_SetMR(3, 0);
                break :blk sel4.seL4_MessageInfo_new(0, 0, 0, 4);
            },
            .Mmap => |args| blk: {
                sel4.seL4_SetMR(0, @as(sel4.seL4_Word, @intFromEnum(lib.SyscallNum.Mmap)));
                sel4.seL4_SetMR(1, args.addr);
                sel4.seL4_SetMR(2, args.length);
                sel4.seL4_SetMR(3, args.prot);
                sel4.seL4_SetMR(4, args.flags);
                sel4.seL4_SetMR(5, args.fd);
                sel4.seL4_SetMR(6, args.offset);
                break :blk sel4.seL4_MessageInfo_new(0, 0, 0, 7);
            },
            .PagerStats => blk: {
                sel4.seL4_SetMR(0, @as(sel4.seL4_Word, @intFromEnum(lib.SyscallNum.PagerStats)));
                sel4.seL4_SetMR(1, 0);
                sel4.seL4_SetMR(2, 0);
                sel4.seL4_SetMR(3, 0);
                break :blk sel4.seL4_MessageInfo_new(0, 0, 0, 4);
            },
        };
    }

    fn tag(self: Syscall) lib.SyscallNum {
        return switch (self) {
            .Open => .Open,
            .Close => .Close,
            .Read => .Read,
            .Write => .Write,
            .Usleep => .Usleep,
            .Timestamp => .Timestamp,
            .MyId => .MyId,
            .Brk => .Brk,
            .Mmap => .Mmap,
            .Stat => .Stat,
            .GetDirent => .GetDirent,
            .PagerStats => .PagerStats,
        };
    }

    pub fn call(self: Syscall, endpoint: sel4.seL4_CPtr) lib.SyscallCallError!lib.SyscallResponse {
        const request = self.serialise();
        const reply = sel4.seL4_Call(endpoint, request);
        return lib.SyscallResponse.deserialise(self.tag(), reply);
    }

    pub fn deserialise(msg: sel4.seL4_MessageInfo_t) lib.SyscallDeserialisationError!Syscall {
        const len = sel4.seL4_MessageInfo_get_length(msg);
        if (len < 1) {
            return lib.SyscallDeserialisationError.NoMessageRegisters;
        }
        if (sel4.seL4_MessageInfo_get_extraCaps(msg) != 0) {
            return lib.SyscallDeserialisationError.HasExtraCaps;
        }

        const raw_syscall = sel4.seL4_GetMR(0);
        const syscall_num = std.meta.intToEnum(lib.SyscallNum, raw_syscall) catch {
            return lib.SyscallDeserialisationError.InvalidSyscallNumber;
        };

        return switch (syscall_num) {
            .Open => if (len < 4) lib.SyscallDeserialisationError.NoMessageRegisters else Syscall{
                .Open = .{
                    .arg = sel4.seL4_GetMR(1),
                    .buf_addr = sel4.seL4_GetMR(2),
                    .buf_size = sel4.seL4_GetMR(3),
                },
            },
            .Close => if (len < 2) lib.SyscallDeserialisationError.NoMessageRegisters else Syscall{
                .Close = .{ .arg = sel4.seL4_GetMR(1) },
            },
            .Read => if (len < 4) lib.SyscallDeserialisationError.NoMessageRegisters else Syscall{
                .Read = .{
                    .arg = sel4.seL4_GetMR(1),
                    .buf_addr = sel4.seL4_GetMR(2),
                    .buf_size = sel4.seL4_GetMR(3),
                },
            },
            .Write => if (len < 4) lib.SyscallDeserialisationError.NoMessageRegisters else Syscall{
                .Write = .{
                    .arg = sel4.seL4_GetMR(1),
                    .buf_addr = sel4.seL4_GetMR(2),
                    .buf_size = sel4.seL4_GetMR(3),
                },
            },
            .Stat => if (len < 5) lib.SyscallDeserialisationError.NoMessageRegisters else Syscall{
                .Stat = .{
                    .path_addr = sel4.seL4_GetMR(1),
                    .path_len = sel4.seL4_GetMR(2),
                    .out_addr = sel4.seL4_GetMR(3),
                    .out_len = sel4.seL4_GetMR(4),
                },
            },
            .Usleep => if (len < 2) lib.SyscallDeserialisationError.NoMessageRegisters else Syscall{
                .Usleep = .{ .arg = sel4.seL4_GetMR(1) },
            },
            .Timestamp => Syscall{ .Timestamp = .{} },
            .MyId => Syscall{ .MyId = .{} },
            .Brk => if (len < 2) lib.SyscallDeserialisationError.NoMessageRegisters else Syscall{
                .Brk = .{ .new_break = sel4.seL4_GetMR(1) },
            },
            .Mmap => if (len < 7) lib.SyscallDeserialisationError.NoMessageRegisters else Syscall{
                .Mmap = .{
                    .addr = sel4.seL4_GetMR(1),
                    .length = sel4.seL4_GetMR(2),
                    .prot = sel4.seL4_GetMR(3),
                    .flags = sel4.seL4_GetMR(4),
                    .fd = sel4.seL4_GetMR(5),
                    .offset = sel4.seL4_GetMR(6),
                },
            },
            .GetDirent => if (len < 4) lib.SyscallDeserialisationError.NoMessageRegisters else Syscall{
                .GetDirent = .{
                    .index = sel4.seL4_GetMR(1),
                    .buf_addr = sel4.seL4_GetMR(2),
                    .buf_size = sel4.seL4_GetMR(3),
                },
            },
            .PagerStats => Syscall{ .PagerStats = .{} },
        };
    }
};
