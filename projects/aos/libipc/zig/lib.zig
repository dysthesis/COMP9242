pub const SyscallNum = enum(u8) {
    Open = 1,
    Close = 2,
    Read = 3,
    Write = 4,
    Usleep = 5,
    Timestamp = 6,
    MyId = 7,
};

const SysallDeserialisationError = error{ NoMessageRegisters, HasExtraCaps, InvalidSyscallNumber };

pub const Syscall = union(SyscallNum) {
    Open: struct { arg: sel4.seL4_Word, buf_addr: sel4.seL4_Word, buf_size: sel4.seL4_Word },
    Close: struct { arg: sel4.seL4_Word },
    Read: struct { arg: sel4.seL4_Word, buf_addr: sel4.seL4_Word, buf_size: sel4.seL4_Word },
    Write: struct { arg: sel4.seL4_Word, buf_addr: sel4.seL4_Word, buf_size: sel4.seL4_Word },
    Usleep: struct { arg: sel4.seL4_Word },
    Timestamp: struct {},
    MyId: struct {},

    /// Serialise a system call into a seL4 IPC message
    fn serialise(self: Syscall) sel4.seL4_MessageInfo_t {
        return switch (self) {
            .Open => |args| blk: {
                sel4.seL4_SetMR(0, @as(sel4.seL4_Word, @intFromEnum(SyscallNum.Open)));
                sel4.seL4_SetMR(1, args.arg);
                sel4.seL4_SetMR(2, args.buf_addr);
                sel4.seL4_SetMR(3, args.buf_size);
                break :blk sel4.seL4_MessageInfo_new(0, 0, 0, 4);
            },
            .Close => |args| blk: {
                sel4.seL4_SetMR(0, @as(sel4.seL4_Word, @intFromEnum(SyscallNum.Close)));
                sel4.seL4_SetMR(1, args.arg);
                sel4.seL4_SetMR(2, 0);
                sel4.seL4_SetMR(3, 0);
                break :blk sel4.seL4_MessageInfo_new(0, 0, 0, 2);
            },
            .Read => |args| blk: {
                sel4.seL4_SetMR(0, @as(sel4.seL4_Word, @intFromEnum(SyscallNum.Read)));
                sel4.seL4_SetMR(1, args.arg);
                sel4.seL4_SetMR(2, args.buf_addr);
                sel4.seL4_SetMR(3, args.buf_size);
                break :blk sel4.seL4_MessageInfo_new(0, 0, 0, 4);
            },
            .Write => |args| blk: {
                sel4.seL4_SetMR(0, @as(sel4.seL4_Word, @intFromEnum(SyscallNum.Write)));
                sel4.seL4_SetMR(1, args.arg);
                sel4.seL4_SetMR(2, args.buf_addr);
                sel4.seL4_SetMR(3, args.buf_size);
                break :blk sel4.seL4_MessageInfo_new(0, 0, 0, 4);
            },
            .Usleep => |args| blk: {
                sel4.seL4_SetMR(0, @as(sel4.seL4_Word, @intFromEnum(SyscallNum.Usleep)));
                sel4.seL4_SetMR(1, args.arg);
                sel4.seL4_SetMR(2, 0);
                sel4.seL4_SetMR(3, 0);
                break :blk sel4.seL4_MessageInfo_new(0, 0, 0, 2);
            },
            .Timestamp => blk: {
                sel4.seL4_SetMR(0, @as(sel4.seL4_Word, @intFromEnum(SyscallNum.Timestamp)));
                sel4.seL4_SetMR(1, 0);
                sel4.seL4_SetMR(2, 0);
                sel4.seL4_SetMR(3, 0);
                break :blk sel4.seL4_MessageInfo_new(0, 0, 0, 1);
            },
            .MyId => blk: {
                sel4.seL4_SetMR(0, @as(sel4.seL4_Word, @intFromEnum(SyscallNum.MyId)));
                sel4.seL4_SetMR(1, 0);
                sel4.seL4_SetMR(2, 0);
                sel4.seL4_SetMR(3, 0);
                break :blk sel4.seL4_MessageInfo_new(0, 0, 0, 1);
            },
        };
    }
    /// Deserialise a seL4 IPC message into a system call
    fn deserialise(msg: sel4.seL4_MessageInfo_t) Syscall!SysallDeserialisationError {
        // A message must contain at least one register
        const len = sel4.seL4_MessageInfo_get_length(msg);
        if (len < 1) {
            return SysallDeserialisationError.NoMessageRegisters;
        }

        // A message shouldn't contain a capability
        const extra_capabilities = sel4.seL4_MessageInfo_get_extraCaps(msg);
        if (extra_capabilities != 0) {
            return SysallDeserialisationError.HasExtraCaps;
        }

        const raw_syscall_num = sel4.seL4_GetMR(0);
        const syscall_num = std.meta.intToEnum(SyscallNum, raw_syscall_num) orelse return SysallDeserialisationError.InvalidSyscallNumber;

        const syscall = switch (syscall_num) {
            .Open => if (len < 4) return SysallDeserialisationError.NoMessageRegisters else Syscall{
                .Open = .{
                    .arg = sel4.seL4_GetMR(1),
                    .buf_addr = sel4.seL4_GetMR(2),
                    .buf_size = sel4.seL4_GetMR(3),
                },
            },
            .Close => if (len < 2) return SysallDeserialisationError.NoMessageRegisters else Syscall{
                .Close = .{ .arg = sel4.seL4_GetMR(1) },
            },
            .Read => if (len < 4) return SysallDeserialisationError.NoMessageRegisters else Syscall{
                .Read = .{
                    .arg = sel4.seL4_GetMR(1),
                    .buf_addr = sel4.seL4_GetMR(2),
                    .buf_size = sel4.seL4_GetMR(3),
                },
            },
            .Write => if (len < 4) return SysallDeserialisationError.NoMessageRegisters else Syscall{
                .Write = .{
                    .arg = sel4.seL4_GetMR(1),
                    .buf_addr = sel4.seL4_GetMR(2),
                    .buf_size = sel4.seL4_GetMR(3),
                },
            },
            .Usleep => if (len < 2) return SysallDeserialisationError.NoMessageRegisters else Syscall{
                .Usleep = .{ .arg = sel4.seL4_GetMR(1) },
            },
            .Timestamp => Syscall{ .Timestamp = .{} },
            .MyId => Syscall{ .MyId = .{} },
        };
        return syscall;
    }
};
const c = @cImport({
    @cInclude("stdio.h");
});
const sel4 = @cImport({
    @cInclude("sel4/sel4.h");
});

const std = @import("std");
