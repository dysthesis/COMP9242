pub const DelegateOp = enum(u64) {
    NfsOpenAsync,
    NfsReadAsync,
    NfsWriteAsync,
    NfsCloseAsync,
    NfsStatAsync,
    NfsOpenDirAsync,
    NfsReadDirSync,
    MapUserBuffer,
    UnmapUserBuffer,
    const Self = @This();
    pub fn call(self: Self, delegate_ep: sel4.seL4_CPtr, args: anytype) !i64 {
        const tag = switch (self) {
            .MapUserBuffer => blk: {
                const t = sel4.seL4_MessageInfo_new(0, 0, 0, 3);
                sel4.seL4_SetMR(0, @intFromEnum(self));
                sel4.seL4_SetMR(1, @intFromPtr(args.vm_handle));
                sel4.seL4_SetMR(2, args.user_vaddr);
                break :blk t;
            },

            .UnmapUserBuffer => blk: {
                const t = sel4.seL4_MessageInfo_new(0, 0, 0, 2);
                sel4.seL4_SetMR(0, @intFromEnum(self));
                sel4.seL4_SetMR(1, @intFromPtr(args.sos_vaddr));
                break :blk t;
            },

            .NfsOpenAsync => blk: {
                const t = sel4.seL4_MessageInfo_new(0, 0, 0, 5);
                sel4.seL4_SetMR(0, @intFromEnum(self));
                sel4.seL4_SetMR(1, @intFromPtr(args.filename));
                sel4.seL4_SetMR(2, @as(u64, @intCast(args.mode)));
                sel4.seL4_SetMR(3, @intFromPtr(args.callback));
                sel4.seL4_SetMR(4, @intFromPtr(args.cb_data));
                break :blk t;
            },

            .NfsReadAsync => blk: {
                const t = sel4.seL4_MessageInfo_new(0, 0, 0, 6);
                sel4.seL4_SetMR(0, @intFromEnum(self));
                sel4.seL4_SetMR(1, @intFromPtr(args.fh));
                sel4.seL4_SetMR(2, args.offset);
                sel4.seL4_SetMR(3, args.count);
                sel4.seL4_SetMR(4, @intFromPtr(args.callback));
                sel4.seL4_SetMR(5, @intFromPtr(args.cb_data));
                break :blk t;
            },

            .NfsWriteAsync => blk: {
                const t = sel4.seL4_MessageInfo_new(0, 0, 0, 6);
                sel4.seL4_SetMR(0, @intFromEnum(self));
                sel4.seL4_SetMR(1, @intFromPtr(args.fh));
                sel4.seL4_SetMR(2, args.offset);
                sel4.seL4_SetMR(3, @intFromPtr(args.buf));
                sel4.seL4_SetMR(4, args.count);
                sel4.seL4_SetMR(5, @intFromPtr(args.callback));
                break :blk t;
            },

            .NfsCloseAsync => blk: {
                const t = sel4.seL4_MessageInfo_new(0, 0, 0, 4);
                sel4.seL4_SetMR(0, @intFromEnum(self));
                sel4.seL4_SetMR(1, @intFromPtr(args.fh));
                sel4.seL4_SetMR(2, @intFromPtr(args.callback));
                sel4.seL4_SetMR(3, @intFromPtr(args.cb_data));
                break :blk t;
            },

            .NfsStatAsync => blk: {
                const t = sel4.seL4_MessageInfo_new(0, 0, 0, 4);
                sel4.seL4_SetMR(0, @intFromEnum(self));
                sel4.seL4_SetMR(1, @intFromPtr(args.filename));
                sel4.seL4_SetMR(2, @intFromPtr(args.callback));
                sel4.seL4_SetMR(3, @intFromPtr(args.cb_data));
                break :blk t;
            },

            .NfsOpenDirAsync => blk: {
                const t = sel4.seL4_MessageInfo_new(0, 0, 0, 4);
                sel4.seL4_SetMR(0, @intFromEnum(self));
                sel4.seL4_SetMR(1, @intFromPtr(args.path));
                sel4.seL4_SetMR(2, @intFromPtr(args.callback));
                sel4.seL4_SetMR(3, @intFromPtr(args.cb_data));
                break :blk t;
            },

            .NfsReadDirSync => blk: {
                const t = sel4.seL4_MessageInfo_new(0, 0, 0, 2);
                sel4.seL4_SetMR(0, @intFromEnum(self));
                sel4.seL4_SetMR(1, @intFromPtr(args.dir));
                break :blk t;
            },
        };

        const reply = sel4.seL4_Call(delegate_ep, tag);
        _ = reply;
        const result: i64 = @bitCast(sel4.seL4_GetMR(0));

        return result;
    }
};

pub export fn delegationHandleRequest(
    badge: sel4.seL4_Word,
    message: sel4.seL4_MessageInfo_t,
) callconv(.c) sel4.seL4_MessageInfo_t {
    _ = badge;
    _ = message;

    const op_raw = sel4.seL4_GetMR(0);
    const op: DelegateOp = @enumFromInt(op_raw);

    const result: i64 = switch (op) {
        .MapUserBuffer => handleMapUserBuffer(),
        .UnmapUserBuffer => handleUnmapUserBuffer(),
        .NfsOpenAsync => handleNfsOpenAsync(),
        .NfsReadAsync => handleNfsReadAsync(),
        .NfsWriteAsync => handleNfsWriteAsync(),
        .NfsCloseAsync => handleNfsCloseAsync(),
        .NfsStatAsync => handleNfsStatAsync(),
        .NfsOpenDirAsync => handleNfsOpenDirAsync(),
        .NfsReadDirSync => handleNfsReadDirSync(),
    };

    sel4.seL4_SetMR(0, @bitCast(result));
    return sel4.seL4_MessageInfo_new(0, 0, 0, 1);
}

fn handleMapUserBuffer() i64 {
    const vm_handle: *vm.VmHandle = @ptrFromInt(sel4.seL4_GetMR(1));
    const user_vaddr: usize = @intCast(sel4.seL4_GetMR(2));

    // Get SOS VA of user page
    const page_data = vm_handle.getUserPageData(user_vaddr) orelse {
        _ = c.printf("[delegation] EFAULT: user_vaddr=0x%lx not mapped\n", user_vaddr);
        return -@as(i64, sos.EFAULT);
    };

    // page_data points to base of page, add offset within page
    const page_offset = user_vaddr & (sos.PAGE_SIZE_4K - 1);
    const sos_vaddr = @intFromPtr(page_data) + page_offset;
    return @intCast(sos_vaddr);
}

fn handleUnmapUserBuffer() i64 {
    // No-op (frame_data provides persistent mappings).
    // TODO: Could implement reference counting if needed later.
    return 0;
}

fn handleNfsOpenAsync() i64 {
    // TODO: Implement this
    _ = c.printf("[delegation] handleNfsOpenAsync called (not yet implemented)\n");
    return -@as(i64, sos.ENOSYS);
}

fn handleNfsReadAsync() i64 {
    // TODO: Implement this
    _ = c.printf("[delegation] handleNfsReadAsync called (not yet implemented)\n");
    return -@as(i64, sos.ENOSYS);
}

fn handleNfsWriteAsync() i64 {
    // TODO: Implement this
    _ = c.printf("[delegation] handleNfsWriteAsync called (not yet implemented)\n");
    return -@as(i64, sos.ENOSYS);
}

fn handleNfsCloseAsync() i64 {
    // TODO: Implement this
    _ = c.printf("[delegation] handleNfsCloseAsync called (not yet implemented)\n");
    return -@as(i64, sos.ENOSYS);
}

fn handleNfsStatAsync() i64 {
    // TODO: Implement this
    _ = c.printf("[delegation] handleNfsStatAsync called (not yet implemented)\n");
    return -@as(i64, sos.ENOSYS);
}

fn handleNfsOpenDirAsync() i64 {
    // TODO: Implement this
    _ = c.printf("[delegation] handleNfsOpenDirAsync called (not yet implemented)\n");
    return -@as(i64, sos.ENOSYS);
}

fn handleNfsReadDirSync() i64 {
    // TODO: Implement this
    _ = c.printf("[delegation] handleNfsReadDirSync called (not yet implemented)\n");
    return -@as(i64, sos.ENOSYS);
}

const vm = @import("vm/mod.zig");
const sel4 = @import("cimports").sel4;
const sos = @import("cimports").sos;
const c = @import("cimports").c;
const std = @import("std");
