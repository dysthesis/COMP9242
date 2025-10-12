const shmem = @import("shmem.zig");

const c = shmem.C;

const errno = struct {
    pub const EINVAL: c_int = 22;
};

pub const SharedPage = shmem.SharedPage;
pub const SharedPageAllocError = shmem.AllocError;

pub export fn sos_alloc_shared_page(
    sos_cspace: *c.cspace_t,
    client_vspace_root: c.seL4_CPtr,
    u_va: usize,
    k_va: usize,
    out_shared_page: ?*?*SharedPage,
) callconv(.c) c_int {
    const out_ptr = out_shared_page orelse return -errno.EINVAL;
    out_ptr.* = null;

    const page = SharedPage.create(sos_cspace, client_vspace_root, u_va, k_va) catch |err| {
        return shmem.allocErrorToErrno(err);
    };

    out_ptr.* = page;
    return 0;
}

pub export fn sos_free_shared_page(
    sos_cspace: *c.cspace_t,
    shared_page_ptr: ?*?*SharedPage,
) callconv(.c) void {
    const handle = shared_page_ptr orelse return;
    const page_opt = handle.*;
    const page = page_opt orelse return;

    page.release(sos_cspace);
    handle.* = null;
}

pub export fn sos_shared_page_frame(shared_page: ?*const SharedPage) callconv(.c) c.frame_ref_t {
    const page = shared_page orelse return c.NULL_FRAME;
    return page.frame;
}

pub export fn sos_shared_page_kernel_cap(shared_page: ?*const SharedPage) callconv(.c) c.seL4_CPtr {
    const page = shared_page orelse return c.seL4_CapNull;
    return page.k_cap;
}

pub export fn sos_shared_page_client_cap(shared_page: ?*const SharedPage) callconv(.c) c.seL4_CPtr {
    const page = shared_page orelse return c.seL4_CapNull;
    return page.u_cap;
}

pub export fn sos_shared_page_kernel_va(shared_page: ?*const SharedPage) callconv(.c) c.seL4_Word {
    const page = shared_page orelse return 0;
    return page.k_va;
}

pub export fn sos_shared_page_client_va(shared_page: ?*const SharedPage) callconv(.c) c.seL4_Word {
    const page = shared_page orelse return 0;
    return page.u_va;
}
