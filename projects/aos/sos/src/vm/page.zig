/// A virtual memory page
pub const Page = struct {
    used: bool = false,
    vaddr: usize = 0,
    frame_ref: usize = 0,
    cap_slot: sel4.seL4_CPtr = 0,
};

const cimports = @import("cimports");
const sel4 = cimports.sel4;
