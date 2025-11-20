pub const Level = enum { L0, L1, L2, L3 };

pub const PTNode = struct {
    level: Level,
    cap_slot: sel4.seL4_CPtr,
    parent: ?*PTNode = null,
    ut: ?*sos.ut_t = null,
    /// map child index to child node
    children: std.AutoHashMap(u16, *PTNode),
    /// Number of mapped leaf pages in this subtree
    live_leaves: usize = 0,
    refcnt: usize = 0,

    pub fn init(
        alloc: std.mem.Allocator,
        level: Level,
        cap_slot: sel4.seL4_CPtr,
        parent: ?*PTNode,
        ut_ptr: ?*sos.ut_t,
    ) PTNode {
        return .{
            .level = level,
            .cap_slot = cap_slot,
            .parent = parent,
            .ut = ut_ptr,
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

fn ptObjectTypeAndBits(level: Level) struct { typ: sel4.seL4_Word, bits: sel4.seL4_Word } {
    // I sure love C FFI (and C in general)! /s

    // Check if the libsel4 we're using has the stuff we need
    const hasPUD = @hasDecl(sel4, "seL4_ARM_PageUpperDirectoryObject");
    const hasPD = @hasDecl(sel4, "seL4_ARM_PageDirectoryObject");

    if (!hasPUD and !hasPD) {
        // What do we call the page table bits?
        const bits =
            if (@hasDecl(sel4, "seL4_ARM_PageTableBits"))
            sel4.seL4_ARM_PageTableBits
        else
            sel4.seL4_PageTableBits;
        return .{
            .typ = sel4.seL4_ARM_PageTableObject,
            .bits = bits,
        };
    } else if (!hasPUD and hasPD) {
        return switch (level) {
            .L0 => @panic("L0 has no child!"),
            .L1 => .{
                .typ = sel4.seL4_ARM_PageDirectoryObject,
                .bits = if (@hasDecl(sel4, "seL4_PDBits"))
                    sel4.seL4_PDBits
                else if (@hasDecl(sel4, "seL4_ARM_PageTableBits"))
                    sel4.seL4_PageTableBits
                else
                    sel4.seL4_PageTableBits,
            },
            .L2, .L3 => .{
                .typ = sel4.seL4_ARM_PageTableObject,
                .bits = if (@hasDecl(sel4, "seL4_ARM_PageTableBits"))
                    sel4.seL4_ARM_PageTableBits
                else
                    sel4.seL4_PageTableBits,
            },
        };
    } else if (hasPUD and !hasPD) {
        return switch (level) {
            .L0 => @panic("L0 has no child"),
            .L1 => .{ .typ = sel4.seL4_ARM_PageUpperDirectoryObject, .bits = sel4.seL4_PUDBits },
            .L2, .L3 => .{ .typ = sel4.seL4_ARM_PageTableObject, .bits = if (@hasDecl(sel4, "seL4_ARM_PageTableBits"))
                sel4.seL4_ARM_PageTableBits
            else
                sel4.seL4_PageTableBits },
        };
    } else {
        return switch (level) {
            .L0 => @panic("L0 has no child"),
            .L1 => .{ .typ = sel4.seL4_ARM_PageUpperDirectoryObject, .bits = sel4.seL4_PUDBits },
            .L2 => .{ .typ = sel4.seL4_ARM_PageDirectoryObject, .bits = if (@hasDecl(sel4, "seL4_PDBits")) sel4.seL4_PDBits else (if (@hasDecl(sel4, "seL4_ARM_PageTableBits")) sel4.seL4_ARM_PageTableBits else sel4.seL4_PageTableBits) },
            .L3 => .{ .typ = sel4.seL4_ARM_PageTableObject, .bits = if (@hasDecl(sel4, "seL4_ARM_PageTableBits")) sel4.seL4_ARM_PageTableBits else sel4.seL4_PageTableBits },
        };
    }
}

/// Retype one page-table object into `slot`.
pub fn retypePageTableObject(slot: sel4.seL4_CPtr, level: Level) RetypeError!*sos.ut_t {
    if (level == .L0) return RetypeError.BadArgs;

    const pt = ptObjectTypeAndBits(level);

    const ut_ptr = sos.ut_alloc(@intCast(pt.bits), &cspace) orelse
        return RetypeError.OutOfUntyped;

    const ut_cap: sel4.seL4_CPtr = sos.ut_get_cap(ut_ptr);

    const err = sos.cspace_untyped_retype(
        &cspace,
        ut_cap,
        slot,
        pt.typ,
        @intCast(pt.bits),
    );

    if (err != sel4.seL4_NoError) {
        sos.ut_free(ut_ptr);
        return RetypeError.RetypeFailed;
    }

    return ut_ptr;
}

pub fn mapChildToVSpace(
    vspace_root: sel4.seL4_CPtr,
    child_cap: sel4.seL4_CPtr,
    parent_level: Level,
    vaddr: usize,
) MapPtError!void {
    if (parent_level == .L3) return MapPtError.BadLevel;

    const child = childLevel(parent_level);
    const span_shift = levelShift(child);
    const span = (@as(usize, 1) << span_shift) * 512; // span covered by the child table
    const base = vaddr & ~(span - 1);

    const attrs = sel4.seL4_ARM_Default_VMAttributes;
    const err = ptMap(child, child_cap, vspace_root, @intCast(base), attrs);
    if (err != sel4.seL4_NoError) {
        const level = sel4.seL4_MappingFailedLookupLevel();
        _ = c.printf("[ptMap] from mapChildToVSpace -> failed with parent=%d vaddr=0x%lx base=0x%lx missing_level=L%lu err=%d", @as(c_int, @intFromEnum(parent_level)), @as(c_ulong, @intCast(vaddr)), @as(c_ulong, base), level, @as(c_int, @intCast(err)));
        return MapPtError.MapFailed;
    }
}

pub fn unmapPagingObject(level: Level, cap: sel4.seL4_CPtr) void {
    _ = level;
    if (@hasDecl(sel4, "seL4_ARM_PageTable_Unmap")) {
        const err = sel4.seL4_ARM_PageTable_Unmap(cap);
        if (err != sel4.seL4_NoError) {
            _ = c.printf("[pt_unmap] PageTable_Unmap failed cap=%lu err=%d\n", @as(c_ulong, @intCast(cap)), @as(c_int, @intCast(err)));
        }
    } else {
        const err = @field(sel4, "seL4_PageTable_Unmap")(cap);
        if (err != sel4.seL4_NoError) {
            _ = c.printf("[pt_unmap] PageTable_Unmap failed cap=%lu err=%d\n", @as(c_ulong, @intCast(cap)), @as(c_int, @intCast(err)));
        }
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
    child_level: Level,
    pt_cap: sel4.seL4_CPtr,
    vspace_root: sel4.seL4_CPtr,
    vaddr: sel4.seL4_Word,
    attrs: sel4.seL4_ARM_VMAttributes,
) sel4.seL4_Error {
    switch (child_level) {
        .L0 => unreachable, // L0 is the vspace root
        .L1 => if (@hasDecl(sel4, "seL4_ARM_PageUpperDirectory_Map"))
            return sel4.seL4_ARM_PageUpperDirectory_Map(pt_cap, vspace_root, vaddr, attrs),

        .L2 => if (@hasDecl(sel4, "seL4_ARM_PageDirectory_Map"))
            return sel4.seL4_ARM_PageDirectory_Map(pt_cap, vspace_root, vaddr, attrs),
        .L3 => {
            if (@hasDecl(sel4, "seL4_ARM_PageTable_Map")) {
                return sel4.seL4_ARM_PageTable_Map(pt_cap, vspace_root, vaddr, attrs);
            } else {
                // Some headers expose an arch-agnostic alias.
                return @field(sel4, "seL4_PageTable_Map")(pt_cap, vspace_root, vaddr, attrs);
            }
        },
    }

    return @field(sel4, "seL4_PageTable_Map")(pt_cap, vspace_root, vaddr, attrs);
}

pub inline fn childLevel(parent: Level) Level {
    return switch (parent) {
        .L0 => .L1,
        .L1 => .L2,
        .L2 => .L3,
        .L3 => unreachable,
    };
}

pub inline fn parentLevel(child: Level) Level {
    return switch (child) {
        .L1 => .L0,
        .L2 => .L1,
        .L3 => .L2,
        .L0 => unreachable,
    };
}

/// Convert the value returned by seL4_MappingFailedLookupLevel() into the child table to create.
pub fn missingChildLevel(lvl: sel4.seL4_Word) ?Level {
    // Newer libsel4 returns the level index (1..3).
    if (lvl == 1 or lvl == 2 or lvl == 3) {
        return @enumFromInt(lvl);
    }
    // Older libsel4 returns "number of unresolved bits" constants per arch.
    if (@hasDecl(sel4, "SEL4_MAPPING_LOOKUP_NO_PUD") and lvl == sel4.SEL4_MAPPING_LOOKUP_NO_PUD) return .L1;
    if (@hasDecl(sel4, "SEL4_MAPPING_LOOKUP_NO_PD") and lvl == sel4.SEL4_MAPPING_LOOKUP_NO_PD) return .L2;
    if (@hasDecl(sel4, "SEL4_MAPPING_LOOKUP_NO_PT") and lvl == sel4.SEL4_MAPPING_LOOKUP_NO_PT) return .L3;
    return null;
}

const std = @import("std");
const cimports = @import("cimports");
const sel4 = cimports.sel4;
const sos = cimports.sos;
const c = cimports.c;
