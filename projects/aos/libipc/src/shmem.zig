const std = @import("std");

const c = @cImport({
    @cInclude("sel4/sel4.h");
    @cInclude("sel4/shared_types.h");
    @cInclude("mapping.h");
    @cInclude("cspace/cspace.h");
    @cInclude("frame_table.h");
    @cInclude("ipc.h");
    @cInclude("utils/zf_log.h");
});

pub const C = c;

const errno = struct {
    pub const EINVAL: c_int = 22;
    pub const ENOMEM: c_int = 12;
    pub const ENOSPC: c_int = 28;
    pub const EIO: c_int = 5;
    pub const EFAULT: c_int = 14;
};

pub const AllocError = error{
    NullDescriptor,
    OutOfMemory,
    KernelSlotExhausted,
    KernelCapCopyFailed,
    KernelMapFailed,
    ClientSlotExhausted,
    ClientCapCopyFailed,
    ClientMapFailed,
};

inline fn logError(comptime message: []const u8) void {
    const c_message = comptime std.fmt.comptimePrint("{s}\x00", .{message});
    const c_ptr: [*c]const u8 = @ptrCast(c_message.ptr);
    c._zf_log_write(
        c.ZF_LOG_ERROR,
        null,
        c_ptr,
    );
}

fn zeroKernelPage(k_va: usize) void {
    const addr: usize = k_va;
    const len: usize = @intCast(c.PAGE_SIZE_4K);
    const bytes = @as([*]u8, @ptrFromInt(addr));
    @memset(bytes[0..len], 0);
}

const invalid_slot = std.math.maxInt(usize);
const pool_slack: usize = 16;
const max_clients: usize = std.math.cast(usize, c.MAX_CLIENTS) orelse @compileError("MAX_CLIENTS does not fit in usize");
const pool_capacity: usize = max_clients + pool_slack;

pub const SharedPage = extern struct {
    frame: c.frame_ref_t = c.NULL_FRAME,
    k_cap: c.seL4_CPtr = c.seL4_CapNull,
    u_cap: c.seL4_CPtr = c.seL4_CapNull,
    k_va: c.seL4_Word = 0,
    u_va: c.seL4_Word = 0,
    pool_slot: usize = invalid_slot,

    pub fn init(
        self: *SharedPage,
        sos_cspace: *c.cspace_t,
        client_vspace_root: c.seL4_CPtr,
        u_va: usize,
        k_va: usize,
    ) AllocError!void {
        self.frame = c.NULL_FRAME;
        self.k_cap = c.seL4_CapNull;
        self.u_cap = c.seL4_CapNull;
        self.k_va = 0;
        self.u_va = 0;

        const frame = c.alloc_frame();
        if (frame == c.NULL_FRAME) {
            logError("[ipc] out of memory for shared frame!");
            return AllocError.OutOfMemory;
        }
        errdefer c.free_frame(frame);

        const frame_cap = c.frame_page(frame);

        const k_cap = c.cspace_alloc_slot(sos_cspace);
        if (k_cap == c.seL4_CapNull) {
            logError("[ipc] no more space left in SOS' capability space!");
            return AllocError.KernelSlotExhausted;
        }
        errdefer c.cspace_free_slot(sos_cspace, k_cap);

        var have_kernel_cap = false;
        errdefer if (have_kernel_cap) {
            _ = c.cspace_delete(sos_cspace, k_cap);
        };

        if (c.cspace_copy(sos_cspace, k_cap, sos_cspace, frame_cap, c.seL4_AllRights) != 0) {
            logError("[ipc] failed to copy frame capability to SOS' capability space!");
            return AllocError.KernelCapCopyFailed;
        }
        have_kernel_cap = true;

        var kernel_mapped = false;
        errdefer if (kernel_mapped) {
            _ = c.seL4_ARM_Page_Unmap(k_cap);
        };

        const k_target: c.seL4_Word = @intCast(k_va);
        if (c.map_frame(
            sos_cspace,
            k_cap,
            c.seL4_CapInitThreadVSpace,
            k_target,
            c.seL4_AllRights,
            c.seL4_ARM_Default_VMAttributes,
        ) != 0) {
            logError("[ipc] failed to map the frame to SOS' virtual address space!");
            return AllocError.KernelMapFailed;
        }
        kernel_mapped = true;

        zeroKernelPage(k_va);

        const u_cap = c.cspace_alloc_slot(sos_cspace);
        if (u_cap == c.seL4_CapNull) {
            logError("[ipc] no more space left in SOS' capability space for client!");
            return AllocError.ClientSlotExhausted;
        }
        errdefer c.cspace_free_slot(sos_cspace, u_cap);

        var have_client_cap = false;
        errdefer if (have_client_cap) {
            _ = c.cspace_delete(sos_cspace, u_cap);
        };

        if (c.cspace_copy(sos_cspace, u_cap, sos_cspace, frame_cap, c.seL4_AllRights) != 0) {
            logError("[ipc] failed to copy frame capability to client slot!");
            return AllocError.ClientCapCopyFailed;
        }
        have_client_cap = true;

        var client_mapped = false;
        errdefer if (client_mapped) {
            _ = c.seL4_ARM_Page_Unmap(u_cap);
        };

        const u_target: c.seL4_Word = @intCast(u_va);
        if (c.map_frame(
            sos_cspace,
            u_cap,
            client_vspace_root,
            u_target,
            c.seL4_ReadWrite,
            c.seL4_ARM_Default_VMAttributes,
        ) != 0) {
            logError("[ipc] failed to map the frame to the client's virtual address space!");
            return AllocError.ClientMapFailed;
        }
        client_mapped = true;

        self.frame = frame;
        self.k_cap = k_cap;
        self.u_cap = u_cap;
        self.k_va = @intCast(k_va);
        self.u_va = @intCast(u_va);
    }

    pub fn deinit(self: *SharedPage, sos_cspace: *c.cspace_t) void {
        if (self.k_cap != c.seL4_CapNull) {
            _ = c.seL4_ARM_Page_Unmap(self.k_cap);
            _ = c.cspace_delete(sos_cspace, self.k_cap);
            c.cspace_free_slot(sos_cspace, self.k_cap);
        }

        if (self.u_cap != c.seL4_CapNull) {
            _ = c.seL4_ARM_Page_Unmap(self.u_cap);
            _ = c.cspace_delete(sos_cspace, self.u_cap);
            c.cspace_free_slot(sos_cspace, self.u_cap);
        }

        if (self.frame != c.NULL_FRAME) {
            c.free_frame(self.frame);
        }

        self.frame = c.NULL_FRAME;
        self.k_cap = c.seL4_CapNull;
        self.u_cap = c.seL4_CapNull;
        self.k_va = 0;
        self.u_va = 0;
    }

    pub fn release(self: *SharedPage, sos_cspace: *c.cspace_t) void {
        self.deinit(sos_cspace);
        poolRelease(self);
    }

    pub fn create(
        sos_cspace: *c.cspace_t,
        client_vspace_root: c.seL4_CPtr,
        u_va: usize,
        k_va: usize,
    ) AllocError!*SharedPage {
        const page = try poolAlloc();
        errdefer poolRelease(page);

        page.init(sos_cspace, client_vspace_root, u_va, k_va) catch |err| {
            return err;
        };

        return page;
    }

};

var pool_storage: [pool_capacity]SharedPage = [_]SharedPage{.{}} ** pool_capacity;
var pool_freelist: [pool_capacity]usize = undefined;
var pool_top: usize = 0;
var pool_initialised: bool = false;

fn poolInit() void {
    if (pool_initialised) {
        return;
    }

    var i: usize = 0;
    while (i < pool_capacity) : (i += 1) {
        pool_freelist[i] = pool_capacity - 1 - i;
    }
    pool_top = pool_capacity;
    pool_initialised = true;
}

fn poolAlloc() AllocError!*SharedPage {
    poolInit();
    if (pool_top == 0) {
        logError("[ipc] shared page descriptor pool exhausted!");
        return AllocError.OutOfMemory;
    }

    pool_top -= 1;
    std.debug.assert(pool_top < pool_capacity);
    const slot = pool_freelist[pool_top];
    var page = &pool_storage[slot];
    page.frame = c.NULL_FRAME;
    page.k_cap = c.seL4_CapNull;
    page.u_cap = c.seL4_CapNull;
    page.k_va = 0;
    page.u_va = 0;
    page.pool_slot = slot;
    return page;
}

fn poolRelease(page: *SharedPage) void {
    poolInit();
    const slot = page.pool_slot;
    if (slot == invalid_slot) {
        return;
    }
    std.debug.assert(pool_top < pool_capacity);
    pool_freelist[pool_top] = slot;
    pool_top += 1;
    page.frame = c.NULL_FRAME;
    page.k_cap = c.seL4_CapNull;
    page.u_cap = c.seL4_CapNull;
    page.k_va = 0;
    page.u_va = 0;
    page.pool_slot = invalid_slot;
}

pub fn allocErrorToErrno(err: AllocError) c_int {
    return switch (err) {
        error.NullDescriptor => -errno.EINVAL,
        error.OutOfMemory => -errno.ENOMEM,
        error.KernelSlotExhausted => -errno.ENOSPC,
        error.KernelCapCopyFailed => -errno.EIO,
        error.KernelMapFailed => -errno.EFAULT,
        error.ClientSlotExhausted => -errno.ENOSPC,
        error.ClientCapCopyFailed => -errno.EIO,
        error.ClientMapFailed => -errno.EFAULT,
    };
}
