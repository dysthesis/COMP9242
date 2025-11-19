const cimports = @import("cimports");
pub const sel4 = cimports.sel4;

pub const std = @import("std");

pub const SyscallNum = enum(u8) {
    Open = 1,
    Close = 2,
    Read = 3,
    Write = 4,
    Usleep = 5,
    Timestamp = 6,
    MyId = 7,
    Brk = 8,
    Mmap = 9,
    Stat = 10,
    GetDirent = 11,
    PagerStats = 12,
    Lseek = 13,
    Unlink = 14,
};

pub const SyscallDeserialisationError = error{
    NoMessageRegisters,
    HasExtraCaps,
    InvalidSyscallNumber,
};

pub const SyscallCallError = error{
    EmptyReply,
    HasExtraCaps,
};

pub const Syscall = @import("syscall.zig").Syscall;
pub const SyscallResponse = @import("syscall_response.zig").SyscallResponse;
