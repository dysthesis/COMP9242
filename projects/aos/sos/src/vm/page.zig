/// Bookkeeping for a page mapped into a client address space.
pub const MappedPage = struct {
    frame_ref: usize,
    cap_slot: sel4.seL4_CPtr,
    cap_owner: ?*sos.cspace_t,
    owns_frame: bool,
    owns_cap: bool,

    pub const Self = @This();

    pub fn release(self: *Self) void {
        if (self.cap_owner) |owner| {
            if (self.cap_slot != sel4.seL4_CapNull and self.owns_cap) {
                const unmap_err = sel4.seL4_ARM_Page_Unmap(self.cap_slot);
                if (unmap_err != sel4.seL4_NoError) {
                    const unmap_err_i32: c_int = @intCast(unmap_err);
                    _ = c.printf("[vm_release] Page_Unmap err=%d slot=%lu\n", unmap_err_i32, @as(c_ulong, @intCast(self.cap_slot)));
                }
                const delete_err = sos.cspace_delete(owner, self.cap_slot);
                if (delete_err != sel4.seL4_NoError) {
                    const delete_err_i32: c_int = @intCast(delete_err);
                    _ = c.printf("[vm_release] cspace_delete err=%d slot=%lu\n", delete_err_i32, @as(c_ulong, @intCast(self.cap_slot)));
                }
                sos.cspace_free_slot(owner, self.cap_slot);
            }
        }
        if (self.owns_frame and self.frame_ref != 0) {
            sos.free_frame(self.frame_ref);
        }
    }
};

/// Bookkeeping for kernel metadata pages backing VM state.
pub const MetadataPage = struct {
    frame_ref: usize,
    cap_slot: sel4.seL4_CPtr,
    vaddr: usize,
};

const cimports = @import("cimports");
const c = cimports.c;
const sel4 = cimports.sel4;
const sos = cimports.sos;
