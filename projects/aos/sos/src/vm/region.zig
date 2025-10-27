const std = @import("std");
const cimports = @import("cimports");
const sel4 = cimports.sel4;
const sos = cimports.sos;

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
    start: usize = 0,
    /// The end address of this region
    end: usize = 0,
    /// The attributes of this region, including what kind it is
    attr: RegionAttr = .{ .kind = RegionKind.Normal, .data = 0 },
    /// The permissions to this region
    perm: sos.seL4_CapRights_t = std.mem.zeroes(sos.seL4_CapRights_t),
    /// Whether the region slot is in use
    used: bool = false,
    /// Whether any mappings have been recorded yet
    mapped: bool = false,

    /// Initialise a region with the provided range, kind, and protection flags
    pub fn configure(self: *Region, start: usize, kind: RegionKind, prot_flags: c_int) void {
        self.start = start;
        self.end = start;
        self.attr = .{ .kind = kind, .data = protToData(prot_flags) };
        self.perm = rightsFromBooleans(
            (prot_flags & sos.PROT_READ) != 0,
            (prot_flags & sos.PROT_WRITE) != 0,
        );
        self.used = true;
        self.mapped = false;
    }

    /// Reset the region to an unused state with the provided kind.
    pub fn reset(self: *Region, kind: RegionKind) void {
        self.start = 0;
        self.end = 0;
        self.attr = .{ .kind = kind, .data = 0 };
        self.perm = std.mem.zeroes(sos.seL4_CapRights_t);
        self.used = false;
        self.mapped = false;
    }

    /// Update the recorded access rights for the region.
    pub fn updateAccess(self: *Region, readable: bool, writable: bool, executable: bool) void {
        const prot_flags = encodeProtFlags(readable, writable, executable);
        if (!self.mapped) {
            self.attr.data = protToData(prot_flags);
            self.perm = rightsFromBooleans(readable, writable);
        } else {
            const merged = dataToProt(self.attr.data) | prot_flags;
            self.attr.data = protToData(merged);
            self.perm = mergeCapRights(self.perm, rightsFromBooleans(readable, writable));
        }
    }

    /// Expand the recorded virtual address range to include the provided mapping.
    pub fn recordMapping(self: *Region, addr: usize, page_size: usize) void {
        const base = std.mem.alignBackward(usize, addr, page_size);
        const end_addr = base + page_size;
        if (!self.mapped) {
            self.start = base;
            self.end = end_addr;
            self.mapped = true;
        } else {
            if (base < self.start) self.start = base;
            if (end_addr > self.end) self.end = end_addr;
        }
    }

    /// Determine whether an address falls within the region.
    pub fn contains(self: *const Region, addr: usize) bool {
        if (!self.used or !self.mapped) return false;
        return addr >= self.start and addr < self.end;
    }

    /// Return the stored protection flags for the region.
    pub fn prot(self: *const Region) c_int {
        return dataToProt(self.attr.data);
    }
};

/// Convert protection booleans into a POSIX-style mask.
pub fn encodeProtFlags(readable: bool, writable: bool, executable: bool) c_int {
    var prot: c_int = 0;
    if (readable) prot |= sos.PROT_READ;
    if (writable) prot |= sos.PROT_WRITE;
    if (executable) prot |= sos.PROT_EXEC;
    return prot;
}

/// Convert protection booleans to seL4 cap rights.
pub fn rightsFromBooleans(readable: bool, writable: bool) sos.seL4_CapRights_t {
    return sos.seL4_CapRights_new(
        0,
        0,
        if (readable) 1 else 0,
        if (writable) 1 else 0,
    );
}

/// Merge two sets of seL4 cap rights.
pub fn mergeCapRights(a: sos.seL4_CapRights_t, b: sos.seL4_CapRights_t) sos.seL4_CapRights_t {
    var merged = a;
    merged.words[0] = merged.words[0] | b.words[0];
    return merged;
}

/// Convert POSIX-style protection flags to the packed data representation.
pub fn protToData(prot: c_int) u60 {
    const masked: u64 = @as(u64, @intCast(prot)) & ((@as(u64, 1) << 60) - 1);
    return @intCast(masked);
}

/// Convert the packed data representation back to POSIX-style flags.
pub fn dataToProt(data: u60) c_int {
    return @intCast(@as(u64, data));
}
