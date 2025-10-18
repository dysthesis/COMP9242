/// Indicator for region type
pub const RegionKind = enum(u4) {
    /// Default kind for normal memory mapping, e.g. ELF segments and IPC buffers
    Normal,
    /// Process heap, created using `brk()`
    Heap,
    /// Growable process stack
    Stack,
    /// Memory-mapped regions
    Mmap,
};

/// An efficient packed struct that contains the region kind and any additional flags
pub const RegionAttr = packed struct(u64) {
    kind: RegionKind,
    data: u60,
};

/// An address space region
pub const Region = struct {
    /// The start address of this region
    start: usize,
    /// The end address of this region
    end: usize,
    /// The attributes of this region, including what kind it is
    attr: RegionAttr,
    /// The permissions to this region
    perm: sel4.seL4_CapRights,
};

const cimports = @import("cimports");
const c = cimports.c;
const sel4 = cimports.sel4;
