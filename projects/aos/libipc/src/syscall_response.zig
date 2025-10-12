const lib = @import("lib.zig");
const sel4 = lib.sel4;

fn wordToU64(word: sel4.seL4_Word) u64 {
    return switch (@bitSizeOf(sel4.seL4_Word)) {
        64 => @bitCast(word),
        32 => @intCast(word),
        else => @compileError("Unsupported seL4_Word size"),
    };
}

fn wordToI64(word: sel4.seL4_Word) i64 {
    return @bitCast(wordToU64(word));
}

fn wordToCInt(word: sel4.seL4_Word) c_int {
    return @intCast(wordToI64(word));
}

fn i64ToWord(value: i64) sel4.seL4_Word {
    return switch (@bitSizeOf(sel4.seL4_Word)) {
        64 => blk: {
            const unsigned: u64 = @bitCast(value);
            break :blk @as(sel4.seL4_Word, @bitCast(unsigned));
        },
        32 => blk: {
            const trunc: i32 = @truncate(value);
            const unsigned: u32 = @bitCast(trunc);
            break :blk @as(sel4.seL4_Word, @bitCast(unsigned));
        },
        else => @compileError("Unsupported seL4_Word size"),
    };
}

fn cIntToWord(value: c_int) sel4.seL4_Word {
    return i64ToWord(@as(i64, value));
}

pub const SyscallResponse = union(lib.SyscallNum) {
    Open: struct { result: c_int },
    Close: struct { result: c_int },
    Read: struct { result: c_int },
    Write: struct { result: c_int },
    Usleep: struct { result: c_int },
    Timestamp: struct { timestamp: i64 },
    MyId: struct { pid: c_int },

    pub fn deserialise(tag: lib.SyscallNum, msg: sel4.seL4_MessageInfo_t) lib.SyscallCallError!SyscallResponse {
        const len = sel4.seL4_MessageInfo_get_length(msg);
        if (len < 1) {
            return lib.SyscallCallError.EmptyReply;
        }
        if (sel4.seL4_MessageInfo_get_extraCaps(msg) != 0) {
            return lib.SyscallCallError.HasExtraCaps;
        }

        const mr0 = sel4.seL4_GetMR(0);
        return switch (tag) {
            .Open => SyscallResponse{ .Open = .{ .result = wordToCInt(mr0) } },
            .Close => SyscallResponse{ .Close = .{ .result = wordToCInt(mr0) } },
            .Read => SyscallResponse{ .Read = .{ .result = wordToCInt(mr0) } },
            .Write => SyscallResponse{ .Write = .{ .result = wordToCInt(mr0) } },
            .Usleep => SyscallResponse{ .Usleep = .{ .result = wordToCInt(mr0) } },
            .Timestamp => SyscallResponse{ .Timestamp = .{ .timestamp = wordToI64(mr0) } },
            .MyId => SyscallResponse{ .MyId = .{ .pid = wordToCInt(mr0) } },
        };
    }

    pub fn serialise(self: SyscallResponse) sel4.seL4_MessageInfo_t {
        sel4.seL4_SetMR(1, 0);
        sel4.seL4_SetMR(2, 0);
        sel4.seL4_SetMR(3, 0);
        const word = switch (self) {
            .Open => |payload| cIntToWord(payload.result),
            .Close => |payload| cIntToWord(payload.result),
            .Read => |payload| cIntToWord(payload.result),
            .Write => |payload| cIntToWord(payload.result),
            .Usleep => |payload| cIntToWord(payload.result),
            .Timestamp => |payload| i64ToWord(payload.timestamp),
            .MyId => |payload| cIntToWord(payload.pid),
        };
        sel4.seL4_SetMR(0, word);
        return sel4.seL4_MessageInfo_new(0, 0, 0, 1);
    }
};
