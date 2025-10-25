inline fn pageMap(
    page_cap: sel4.seL4_CPtr,
    root: sel4.seL4_CPtr,
    vaddr: usize,
    rights: sos.seL4_CapRights_t,
    attrs: sel4.seL4_ARM_VMAttributes,
) sel4.seL4_Error {
    if (@hasDecl(sel4, "seL4_ARM_Page_Map")) {
        return sos.seL4_ARM_Page_Map(page_cap, root, vaddr, rights, attrs);
    } else {
        return @field(sel4, "seL4_Page_Map")(page_cap, root, vaddr, rights, attrs);
    }
}

/// Map a frame into `as` at `vaddr`, creating any missing paging structures, then record the leaf for later pruning.
pub fn map_owned_frame(
    as: *AddrSpace,
    page_cap: sel4.seL4_CPtr,
    vaddr: usize,
    rights: sos.seL4_CapRights_t,
    attrs: sel4.seL4_ARM_VMAttributes,
) super.VmError!void {
    // Ensure intermediate PTs exist for this VA
    _ = as.ensurePath(vaddr) catch |e| {
        return switch (e) {
            error.OutOfMemory, error.OutOfUntyped => super.VmError.Capacity,
            error.OutOfSlots => super.VmError.OutOfSlots,
            error.RetypeFailed, error.MapFailed => super.VmError.MapFailed,
            error.BadArgs => super.VmError.InvalidArgs,
            else => super.VmError.MapFailed,
        };
    };

    const err = pageMap(page_cap, as.vspace, vaddr, rights, attrs);
    if (err == sel4.seL4_DeleteFirst) {
        return super.VmError.AlreadyMapped;
    }
    if (err != sel4.seL4_NoError) {
        const lvl: c_ulong = sel4.seL4_MappingFailedLookupLevel();
        _ = c.printf("[map failed] vaddr=0x%lx err=%d missing_level=L%lu\n", @as(c_ulong, vaddr), @as(c_int, @intCast(err)), lvl);
        return super.VmError.MapFailed;
    }

    // Track the new live leaf so teardown can prune PTs
    as.recordLeafMap(vaddr);
    // catch |e| {
    //     // Keep kernel/shadow state consistent on accounting failure
    //     _ = sel4.seL4_ARM_Page_Unmap(page_cap);
    //     return switch (e) {
    //         error.OutOfMemory => super.VmError.Capacity,
    //         error.OutOfSlots => super.VmError.OutOfSlots,
    //         else => super.VmError.MapFailed,
    //     };
    // };
}

const cimports = @import("cimports");
const sel4 = cimports.sel4;
const sos = cimports.sos;
const c = cimports.c;

const super = @import("mod.zig");
const AddrSpace = @import("addr_space.zig").AddrSpace;
