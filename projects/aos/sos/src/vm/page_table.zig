pub const Level = enum { L0, L1, L2, L3 };

pub const PTNode = struct {
    level: Level,
    cap_slot: sel4.seL4_CPtr,
    parent: ?*PTNode = null,
    /// map child index to child node
    children: std.AutoHashMap(u16, *PTNode),
    /// Number of mapped leaf pages in this subtree
    live_leaves: usize = 0,
    refcnt: usize = 0,

    pub fn init(alloc: std.mem.Allocator, level: Level, cap_slot: sel4.seL4_CPtr, parent: ?*PTNode) PTNode {
        return .{
            .level = level,
            .cap_slot = cap_slot,
            .parent = parent,
            .children = std.AutoHashMap(u16, *PTNode).init(alloc),
            .live_leaves = 0,
        };
    }
};

pub const PAGE_SHIFT = 12; // 4 KiB
pub const LVL_BITS = 9; // 512 entries
pub const LVL_COUNT = 4; // 3 or 4
pub const L3_SHIFT = PAGE_SHIFT;
pub const L2_SHIFT = L3_SHIFT + LVL_BITS;
pub const L1_SHIFT = L2_SHIFT + LVL_BITS;
pub const L0_SHIFT = L1_SHIFT + LVL_BITS;
pub const LVL_MASK = (1 << LVL_BITS) - 1;

pub inline fn l0Index(va: usize) u16 {
    return @intCast((va >> L0_SHIFT) & LVL_MASK);
}
pub inline fn l1Index(va: usize) u16 {
    return @intCast((va >> L1_SHIFT) & LVL_MASK);
}
pub inline fn l2Index(va: usize) u16 {
    return @intCast((va >> L2_SHIFT) & LVL_MASK);
}
pub inline fn l3Index(va: usize) u16 {
    return @intCast((va >> L3_SHIFT) & LVL_MASK);
}
pub inline fn pageBase(va: usize) usize {
    return va & ~(@as(usize, (1 << PAGE_SHIFT) - 1));
}

extern var cspace: sos.cspace_t;

pub const RetypeError = error{
    OutOfUntyped, // no UT of the required size
    RetypeFailed, // seL4_Untyped_Retype failed
    BadArgs, // nonsense level, etc.
};

fn ptObjectTypeAndBits() struct { typ: sel4.seL4_Word, bits: sel4.seL4_Word } {
    const typ =
        if (@hasDecl(sel4, "seL4_ARM_PageTableObject"))
            sel4.seL4_ARM_PageTableObject
        else
            @field(sel4, "seL4_PageTableObject");
    const bits =
        if (@hasDecl(sel4, "seL4_PageTableBits"))
            sel4.seL4_PageTableBits
        else
            @field(sel4, "seL4_ARM_PageTableBits");
    return .{ .typ = typ, .bits = bits };
}

/// Retype one page-table object into `slot`.
pub fn retypePageTableObject(slot: sel4.seL4_CPtr, want_level: u8) RetypeError!void {
    if (want_level == 0) return RetypeError.BadArgs;

    const pt = ptObjectTypeAndBits();

    const ut_ptr = sos.ut_alloc(@intCast(pt.bits), &cspace);
    if (ut_ptr == null) {
        return RetypeError.OutOfUntyped;
    }

    // NOTE: Do NOT ut_free() after a successful retype, the memory is now a kernel object.
    const ut_cap: sel4.seL4_CPtr = sos.ut_get_cap(ut_ptr.?);

    const err = sos.cspace_untyped_retype(
        &cspace,
        ut_cap,
        slot,
        pt.typ,
        @intCast(pt.bits),
    );

    if (err != sel4.seL4_NoError) {
        sos.ut_free(ut_ptr.?);
        return RetypeError.RetypeFailed;
    }
}

pub const MapPtError = error{
    InvalidArgs,
    BadLevel,
    MapFailed,
};

inline fn levelShift(lvl: Level) std.math.Log2Int(usize) {
    return switch (lvl) {
        .L0 => L0_SHIFT,
        .L1 => L1_SHIFT,
        .L2 => L2_SHIFT,
        .L3 => L3_SHIFT,
    };
}

// Small shim so this builds across libsel4 versions.
inline fn ptMap(
    pt_cap: sel4.seL4_CPtr,
    root_or_parent: sel4.seL4_CPtr,
    vaddr: sel4.seL4_Word,
    attrs: sel4.seL4_ARM_VMAttributes,
) sel4.seL4_Error {
    if (@hasDecl(sel4, "seL4_ARM_PageTable_Map")) {
        return sel4.seL4_ARM_PageTable_Map(pt_cap, root_or_parent, vaddr, attrs);
    } else {
        // Some headers expose an arch-agnostic alias.
        return @field(sel4, "seL4_PageTable_Map")(pt_cap, root_or_parent, vaddr, attrs);
    }
}

inline fn childLevel(parent: Level) Level {
    return switch (parent) {
        .L0 => .L1,
        .L1 => .L2,
        .L2 => .L3,
        .L3 => unreachable,
    };
}

/// Map a freshly retyped PageTable `pt_cap` under `parent_level` at child index `idx`.
pub fn map_page_table_into_vspace(
    vspace_root: sel4.seL4_CPtr,
    pt_cap: sel4.seL4_CPtr,
    parent_level: Level,
    vaddr: usize,
) MapPtError!void {
    if (parent_level == .L3) return MapPtError.BadLevel;
    const child = childLevel(parent_level);
    const base: usize = vaddr & ~((@as(usize, 1) << levelShift(child)) - 1); // align to child range
    const attrs = sel4.seL4_ARM_Default_VMAttributes;

    const err = ptMap(pt_cap, vspace_root, @intCast(base), attrs);
    if (err != sel4.seL4_NoError) return MapPtError.MapFailed;
}

const std = @import("std");
const cimports = @import("cimports");
const sel4 = cimports.sel4;
const sos = cimports.sos;
