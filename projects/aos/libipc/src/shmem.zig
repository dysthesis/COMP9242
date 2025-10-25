const std = @import("std");

const cimports = @import("cimports");
const c = cimports.c;
const sos = cimports.sos;
const sel4 = cimports.sel4;

pub const C = sos;

const errno = struct {
    pub const EINVAL: c_int = 22;
    pub const ENOMEM: c_int = 12;
    pub const ENOSPC: c_int = 28;
    pub const EIO: c_int = 5;
    pub const EFAULT: c_int = 14;
};

inline fn toSosRights(rights: sel4.seL4_CapRights_t) sos.seL4_CapRights_t {
    var converted: sos.seL4_CapRights_t = undefined;
    converted.words[0] = rights.words[0];
    return converted;
}

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
    sos._zf_log_write(
        sos.ZF_LOG_ERROR,
        null,
        c_ptr,
    );
}

fn zeroKernelPage(k_va: usize) void {
    const addr: usize = k_va;
    const len: usize = @intCast(sos.PAGE_SIZE_4K);
    const bytes = @as([*]u8, @ptrFromInt(addr));
    @memset(bytes[0..len], 0);
}

const invalid_slot = std.math.maxInt(usize);
const pool_slack: usize = 16;
const max_clients: usize = std.math.cast(usize, sos.MAX_CLIENTS) orelse @compileError("MAX_CLIENTS does not fit in usize");
const pool_capacity: usize = max_clients + pool_slack;

pub const SharedPage = extern struct {
    frame: sos.frame_ref_t = sos.NULL_FRAME,
    k_cap: sel4.seL4_CPtr = sel4.seL4_CapNull,
    u_cap: sel4.seL4_CPtr = sel4.seL4_CapNull,
    k_va: sel4.seL4_Word = 0,
    u_va: sel4.seL4_Word = 0,
    pool_slot: usize = invalid_slot,

    pub fn init(
        self: *SharedPage,
        sos_cspace: *sos.cspace_t,
        client_vspace_root: sel4.seL4_CPtr,
        u_va: usize,
        k_va: usize,
    ) AllocError!void {
        self.frame = sos.NULL_FRAME;
        self.k_cap = sel4.seL4_CapNull;
        self.u_cap = sel4.seL4_CapNull;
        self.k_va = 0;
        self.u_va = 0;

        const frame = sos.alloc_frame();
        if (frame == sos.NULL_FRAME) {
            logError("[ipc] out of memory for shared frame!");
            return AllocError.OutOfMemory;
        }
        errdefer sos.free_frame(frame);

        const frame_cap = sos.frame_page(frame);

        const k_cap = sos.cspace_alloc_slot(sos_cspace);
        if (k_cap == sel4.seL4_CapNull) {
            logError("[ipc] no more space left in SOS' capability space!");
            return AllocError.KernelSlotExhausted;
        }
        errdefer sos.cspace_free_slot(sos_cspace, k_cap);

        var have_kernel_cap = false;
        errdefer if (have_kernel_cap) {
            _ = sos.cspace_delete(sos_cspace, k_cap);
        };

        if (sos.cspace_copy(sos_cspace, k_cap, sos_cspace, frame_cap, toSosRights(sel4.seL4_AllRights)) != 0) {
            logError("[ipc] failed to copy frame capability to SOS' capability space!");
            return AllocError.KernelCapCopyFailed;
        }
        have_kernel_cap = true;

        var kernel_mapped = false;
        errdefer if (kernel_mapped) {
            _ = sel4.seL4_ARM_Page_Unmap(k_cap);
        };

        const k_target: sel4.seL4_Word = @intCast(k_va);
        // NOTE: This maps into SOS for bookkeeping only. VM tracking is handled separately when the page is exposed to clients.
        if (sos.map_frame(
            sos_cspace,
            k_cap,
            sel4.seL4_CapInitThreadVSpace,
            k_target,
            toSosRights(sel4.seL4_AllRights),
            sel4.seL4_ARM_Default_VMAttributes,
        ) != 0) {
            logError("[ipc] failed to map the frame to SOS' virtual address space!");
            return AllocError.KernelMapFailed;
        }
        kernel_mapped = true;

        zeroKernelPage(k_va);

        const u_cap = sos.cspace_alloc_slot(sos_cspace);
        if (u_cap == sel4.seL4_CapNull) {
            logError("[ipc] no more space left in SOS' capability space for client!");
            return AllocError.ClientSlotExhausted;
        }
        errdefer sos.cspace_free_slot(sos_cspace, u_cap);

        var have_client_cap = false;
        errdefer if (have_client_cap) {
            _ = sos.cspace_delete(sos_cspace, u_cap);
        };

        if (sos.cspace_copy(sos_cspace, u_cap, sos_cspace, frame_cap, toSosRights(sel4.seL4_AllRights)) != 0) {
            logError("[ipc] failed to copy frame capability to client slot!");
            return AllocError.ClientCapCopyFailed;
        }
        have_client_cap = true;

        var client_mapped = false;
        errdefer if (client_mapped) {
            _ = sel4.seL4_ARM_Page_Unmap(u_cap);
        };

        const u_target: sel4.seL4_Word = @intCast(u_va);
        // TODO: once vm_handle plumbing is available here, switch to
        // vm_map_owned_frame so the client-side mapping participates in the
        // unified VM accounting.
        if (sos.map_frame(
            sos_cspace,
            u_cap,
            client_vspace_root,
            u_target,
            toSosRights(sel4.seL4_ReadWrite),
            sel4.seL4_ARM_Default_VMAttributes,
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

    pub fn deinit(self: *SharedPage, sos_cspace: *sos.cspace_t) void {
        if (self.k_cap != sel4.seL4_CapNull) {
            _ = sel4.seL4_ARM_Page_Unmap(self.k_cap);
            _ = sos.cspace_delete(sos_cspace, self.k_cap);
            sos.cspace_free_slot(sos_cspace, self.k_cap);
        }

        if (self.u_cap != sel4.seL4_CapNull) {
            _ = sel4.seL4_ARM_Page_Unmap(self.u_cap);
            _ = sos.cspace_delete(sos_cspace, self.u_cap);
            sos.cspace_free_slot(sos_cspace, self.u_cap);
        }

        if (self.frame != sos.NULL_FRAME) {
            sos.free_frame(self.frame);
        }

        self.frame = sos.NULL_FRAME;
        self.k_cap = sel4.seL4_CapNull;
        self.u_cap = sel4.seL4_CapNull;
        self.k_va = 0;
        self.u_va = 0;
    }

    pub fn release(self: *SharedPage, sos_cspace: *sos.cspace_t) void {
        self.deinit(sos_cspace);
        poolRelease(self);
    }

    pub fn create(
        sos_cspace: *sos.cspace_t,
        client_vspace_root: sel4.seL4_CPtr,
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
    page.frame = sos.NULL_FRAME;
    page.k_cap = sel4.seL4_CapNull;
    page.u_cap = sel4.seL4_CapNull;
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
    page.frame = sos.NULL_FRAME;
    page.k_cap = sel4.seL4_CapNull;
    page.u_cap = sel4.seL4_CapNull;
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
