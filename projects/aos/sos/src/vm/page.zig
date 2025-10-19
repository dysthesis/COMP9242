const cimports = @import("cimports");
const sel4 = cimports.sel4;
const sos = cimports.sos;

/// Bookkeeping for a page mapped into a client address space.
pub const MappedPage = struct {
    frame_ref: usize,
    cap_slot: sel4.seL4_CPtr,
    cap_owner: ?*sos.cspace_t,
    owns_frame: bool,
    owns_cap: bool,
};

/// Bookkeeping for kernel metadata pages backing VM state.
pub const MetadataPage = struct {
    frame_ref: usize,
    cap_slot: sel4.seL4_CPtr,
    vaddr: usize,
};
