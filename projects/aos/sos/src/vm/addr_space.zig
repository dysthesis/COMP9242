/// Per-process address space
pub const AddrSpace = struct {
    regions: RegionMap,
    pages: PageMap,
    alloc: std.mem.Allocator,
    vspace: sel4.seL4_CPtr = sel4.seL4_CapInitThreadVSpace,
    cspace: *sos.cspace_t,
    root: *page_table.PTNode,

    pub const Self = @This();

    /// Initialise a new address space
    pub fn init(
        alloc: std.mem.Allocator,
        cspace_ptr: *sos.cspace_t,
        vspace_root_cap: sel4.seL4_CPtr,
    ) !Self {
        _ = c.printf("[addr_space] entered AddrSpace.init...\n");
        _ = c.printf("[addr_space] initialising page table...\n");
        const root = try alloc.create(page_table.PTNode);
        root.* = page_table.PTNode.init(alloc, .L0, vspace_root_cap, null);
        _ = c.printf("[addr_space] page table initialised!\n");
        return .{
            .regions = RegionMap.init(),
            .pages = PageMap.init(alloc),
            .alloc = alloc,
            .vspace = vspace_root_cap,
            .cspace = cspace_ptr,
            .root = root,
        };
    }

    /// Destroy the address space
    pub fn deinit(self: *Self) void {
        self.pages.deinit();
    }

    pub inline fn getPtr(self: *Self, vaddr: usize) ?*page.MappedPage {
        return self.pages.getPtr(vaddr);
    }

    pub inline fn put(self: *Self, vaddr: usize, mapped_page: page.MappedPage) !void {
        try self.pages.put(vaddr, mapped_page);
    }

    pub inline fn num_mapped(self: *const Self) usize {
        return self.pages.count();
    }

    pub inline fn iterator(self: *Self) @TypeOf(self.pages.iterator()) {
        return self.pages.iterator();
    }

    pub inline fn clearRetainingCapacity(self: *Self) void {
        self.pages.clearRetainingCapacity();
    }

    pub inline fn insertRegion(self: *Self, node: *RegionNode, coalesce: bool) !void {
        try self.regions.insert(node, coalesce);
    }

    pub inline fn removeRegion(self: *Self, node: *RegionNode) void {
        self.regions.erase(node);
    }

    pub inline fn findRegion(self: *const Self, addr: usize) ?*RegionNode {
        return self.regions.find(addr);
    }

    pub inline fn findFreeGap(self: *const Self, size: usize, bottom: usize, top: usize) ?usize {
        return self.regions.findFree(size, bottom, top);
    }

    fn ensureChild(
        self: *Self,
        parent: *page_table.PTNode,
        idx: u16,
        want_level: page_table.Level,
        vaddr: usize,
    ) !*page_table.PTNode {
        if (parent.children.get(idx)) |node| return node;

        const slot = sos.cspace_alloc_slot(self.cspace);
        if (slot == sel4.seL4_CapNull) return error.OutOfSlots;

        try page_table.retypePageTableObject(slot, want_level);

        // Map this page table at the address implied by vaddr (helper aligns internally)
        try page_table.mapChildToVSpace(self.vspace, slot, parent.level, vaddr);

        const child = try self.alloc.create(page_table.PTNode);
        child.* = page_table.PTNode.init(self.alloc, want_level, slot, parent);
        try parent.children.put(idx, child);
        parent.refcnt += 1;
        return child;
    }

    pub fn ensurePath(self: *Self, vaddr: usize) !*page_table.PTNode {
        var n = self.root;
        n = try self.ensureChild(n, page_table.l0Index(vaddr), .L1, vaddr);
        n = try self.ensureChild(n, page_table.l1Index(vaddr), .L2, vaddr);
        n = try self.ensureChild(n, page_table.l2Index(vaddr), .L3, vaddr);
        return n;
    }

    pub fn walkPath(self: *Self, vaddr: usize) ?[4]*page_table.PTNode {
        var path: [4]*page_table.PTNode = undefined;
        var n = self.root;
        path[0] = n;

        const l0_idx = page_table.l0Index(vaddr);
        const l1_idx = page_table.l1Index(vaddr);
        const l2_idx = page_table.l2Index(vaddr);
        // const l3_idx = page_table.l3Index(vaddr);

        if (n.children.get(l0_idx)) |l1| {
            path[1] = l1;
            if (l1.children.get(l1_idx)) |l2| {
                path[2] = l2;
                if (l2.children.get(l2_idx)) |l3| {
                    path[3] = l3;
                    return path;
                }
            }
        }
        return null;
    }

    fn bumpLiveLeaves(node: *page_table.PTNode) void {
        var cur: ?*page_table.PTNode = node;
        while (cur) |n| {
            n.live_leaves += 1;
            cur = n.parent;
        }
    }

    fn decLiveLeaves(node: *page_table.PTNode) void {
        var cur: ?*page_table.PTNode = node;
        while (cur) |n| {
            if (n.live_leaves > 0) n.live_leaves -= 1;
            cur = n.parent;
        }
    }

    /// Remove empty page-table nodes bottom-up along the path to `vaddr`.
    fn pruneEmpty(self: *Self, vaddr: usize, path: *const [4]*page_table.PTNode) void {
        const idx: [4]u16 = .{
            page_table.l0Index(vaddr),
            page_table.l1Index(vaddr),
            page_table.l2Index(vaddr),
            page_table.l3Index(vaddr),
        };

        var level: usize = 3;
        while (level > 0) : (level -= 1) {
            const child = path.*[level];
            if (child.live_leaves != 0) break;
            if (child.children.count() != 0) break;

            const parent = path.*[level - 1];

            _ = sos.cspace_delete(self.cspace, child.cap_slot);
            sos.cspace_free_slot(self.cspace, child.cap_slot);
            _ = parent.children.remove(idx[level - 1]);
            self.alloc.destroy(child);
        }
    }

    /// Call after a successful leaf mapping at `vaddr`.
    pub fn recordLeafMap(self: *AddrSpace, vaddr: usize) void {
        if (self.walkPath(vaddr)) |path| {
            var i: usize = 3;
            while (true) {
                path[i].live_leaves += 1;
                if (i == 0) break;
                i -= 1;
            }
        }
    }

    /// Call when unmapping a leaf at `vaddr` (e.g., teardown).
    pub fn recordLeafUnmap(self: *Self, vaddr: usize) void {
        const p = self.walkPath(vaddr) orelse return;
        const l3: *page_table.PTNode = p[3];
        decLiveLeaves(l3);
        self.pruneEmpty(vaddr, &p);
    }

    pub fn mapFrame(
        self: *Self,
        page_cap: sel4.seL4_CPtr,
        vaddr: usize,
        rights: sos.seL4_CapRights_t,
        attrs: sel4.seL4_ARM_VMAttributes,
    ) super.VmError!void {
        var tries: u32 = 0;

        while (true) {
            _ = c.printf("[vm_map] attempting to map frame, cap=%lu vaddr=0x%lx rights=%s attr=0x%lx", page_cap, @as(c_ulong, vaddr), &logging.rightsStr(rights), @as(c_ulong, attrs));

            const err = pageMap(page_cap, self.vspace, vaddr, rights, attrs);
            if (err == sel4.seL4_NoError) break;

            if (err != sel4.seL4_FailedLookup or tries >= 3) {
                const lvl: c_ulong = sel4.seL4_MappingFailedLookupLevel();
                _ = c.printf("[map failed] vaddr=0x%lx err=%d missing_level=L%lu\n", @as(c_ulong, vaddr), @as(c_int, @intCast(err)), lvl);
                return super.VmError.MapFailed;
            }

            tries += 1;

            const lvl_word = sel4.seL4_MappingFailedLookupLevel();
            const missing_child = page_table.missingChildLevel(lvl_word) orelse {
                _ = c.printf("[vm_map] unknown missing level code=%lu\n", @as(c_ulong, lvl_word));
                return super.VmError.MapFailed;
            };
            const parent = page_table.parentLevel(missing_child);

            // Allocate a cslot for the new child page table
            const slot = sos.cspace_alloc_slot(self.cspace);
            if (slot == sel4.seL4_CapNull) return super.VmError.OutOfSlots;

            // Retype the object for the child level
            page_table.retypePageTableObject(slot, missing_child) catch |e| {
                sos.cspace_free_slot(self.cspace, slot);
                return mapAddrSpaceErr(e);
            };

            // Map the child at the correctly aligned base that covers vaddr.
            page_table.mapChildToVSpace(self.vspace, slot, parent, vaddr) catch |e| {
                _ = sos.cspace_delete(self.cspace, slot);
                sos.cspace_free_slot(self.cspace, slot);
                return mapAddrSpaceErr(e);
            };

            // retry the leaf map now that the missing level exists
        }

        self.recordLeafMap(vaddr);
    }
};

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

inline fn mapAddrSpaceErr(e: anyerror) super.VmError {
    return switch (e) {
        error.OutOfMemory => super.VmError.Capacity,

        error.OutOfSlots => super.VmError.OutOfSlots,

        error.OutOfUntyped => super.VmError.Capacity,
        error.RetypeFailed => super.VmError.MapFailed,
        error.BadArgs => super.VmError.InvalidArgs,

        error.MapFailed => super.VmError.MapFailed,

        else => super.VmError.MapFailed,
    };
}

pub const PageMap = std.AutoHashMap(usize, page.MappedPage);

/// A node for the RbTree containing individual regions
pub const RegionNode = struct {
    rb: RbNode,
    reg: Region,
    pub const Self = @This();
    inline fn fromRb(node: *RbNode) *Self {
        return @fieldParentPtr("rb", node);
    }
    fn key(n: *RbNode) usize {
        return Self.fromRb(n).reg.start;
    }
    fn cmp(a: usize, b: usize) std.math.Order {
        return std.math.order(a, b);
    }
};

/// A map of the regions in an address space
const RegionMap = struct {
    map: RbTree(usize, RegionNode.key, RegionNode.cmp),
    len: usize,
    pub const Self = @This();

    const CapRights = @FieldType(Region, "perm");

    const Iterator = struct {
        next_node: ?*RbNode,

        inline fn toOptional(node: *RbNode) ?*RbNode {
            return if (node != RbNodeNil) node else null;
        }

        pub inline fn init(node: ?*RbNode) Iterator {
            return .{ .next_node = node };
        }

        pub inline fn empty() Iterator {
            return .{ .next_node = null };
        }

        pub inline fn next(self: *Iterator) ?*RegionNode {
            const current = self.next_node orelse return null;
            const succ = current.succ();
            self.next_node = toOptional(succ);
            return RegionNode.fromRb(current);
        }
    };

    inline fn rightsEqual(a: CapRights, b: CapRights) bool {
        return a.words[0] == b.words[0];
    }

    pub fn init() Self {
        return .{
            .map = RbTree(usize, RegionNode.key, RegionNode.cmp).init(),
            .len = 0,
        };
    }

    pub fn iter(self: *const Self) Iterator {
        return Iterator.init(self.map.min());
    }

    pub fn iterFrom(self: *const Self, addr: usize) Iterator {
        if (self.len == 0) return Iterator.empty();

        if (self.map.lowerBound(addr)) |node| {
            const pred = node.pred();
            if (pred != RbNodeNil) {
                const pred_node = RegionNode.fromRb(pred);
                if (pred_node.reg.end > addr) {
                    return Iterator.init(pred);
                }
            }
            return Iterator.init(node);
        }

        const max = self.map.max() orelse return Iterator.empty();
        if (RegionNode.fromRb(max).reg.end > addr) {
            return Iterator.init(max);
        }
        return Iterator.empty();
    }

    /// Find the region containing a given address, if any
    pub fn find(self: *const Self, addr: usize) ?*RegionNode {
        const lb = self.map.lowerBound(addr) orelse {
            // no region with start >= v, candidate is the max by start
            const max = self.map.max() orelse return null;
            const candidate = RegionNode.fromRb(max);
            return if (addr < candidate.reg.end) candidate else null;
        };
        const n = RegionNode.fromRb(lb);
        if (n.reg.start == addr and addr < n.reg.end) return n;
        const p = lb.pred();
        if (p != RbNodeNil) {
            const cand = RegionNode.fromRb(p);
            if (addr < cand.reg.end) return cand;
        }
        return null;
    }

    /// Insert a new region, and optionally coalesce any neighbour that touch and match attributes or permissions
    pub fn insert(self: *Self, node: *RegionNode, coalesce: bool) !void {
        // ordered insertion point by start
        if (self.map.findOrAdd(&node.rb)) |existing| {
            // existing region with identical start; forbidden in non-overlap model
            _ = existing;
            return error.OverlapOrDuplicateStart;
        }

        // check left neighbour for overlap and maybe merge
        if (node.rb.pred() != RbNodeNil) {
            const left = RegionNode.fromRb(node.rb.pred());
            if (left.reg.end > node.reg.start) {
                // overlaps
                self.removeInternal(node);
                return error.OverlapOrDuplicateStart;
            }
            if (coalesce and left.reg.end == node.reg.start and
                left.reg.attr.kind == node.reg.attr.kind and
                left.reg.attr.data == node.reg.attr.data and
                rightsEqual(left.reg.perm, node.reg.perm))
            {
                // Extend left, drop current node
                left.reg.end = node.reg.end;
                self.removeInternal(node);
                // Merging may now touch/merge the right neighbours
                self.mergeForward(left, coalesce);
                return;
            }
        }

        // check right neighbour for overlap and maybe merge
        const right = node.rb.succ();
        if (right != RbNodeNil) {
            const r = RegionNode.fromRb(right);
            if (node.reg.end > r.reg.start) {
                // overlaps
                self.removeInternal(node);
                return error.OverlapOrDuplicateStart;
            }
            if (coalesce and node.reg.end == r.reg.start and
                r.reg.attr.kind == node.reg.attr.kind and
                r.reg.attr.data == node.reg.attr.data and
                rightsEqual(node.reg.perm, r.reg.perm))
            {
                // swallow right, extend new node, then unlink right
                node.reg.end = r.reg.end;
                _ = self.map.erase(&r.rb);
                self.len -= 1;
                // keep merging forward if a cascade of abutting regions follows
                self.mergeForward(node, coalesce);
            }
        }

        self.len += 1;
    }
    pub fn erase(self: *Self, node: *RegionNode) void {
        _ = self.map.erase(&node.rb);
        self.len -= 1;
    }

    pub fn findFree(self: *const Self, size: usize, bottom: usize, top: usize) ?usize {
        if (size == 0 or bottom > top or top - bottom < size) return null;

        var cursor_start = bottom;
        var it = self.iterFrom(bottom);
        while (it.next()) |n| {
            // Stop when region starts beyond top
            if (n.reg.start >= top) break;
            if (n.reg.start >= cursor_start and n.reg.start - cursor_start >= size) {
                return cursor_start;
            }
            // Advance past this region if it blocks us
            if (n.reg.end > cursor_start) cursor_start = n.reg.end;
            if (cursor_start > top - size) return null;
        }
        // Tail gap
        return if (top - cursor_start >= size) cursor_start else null;
    }

    fn removeInternal(self: *RegionMap, node: *RegionNode) void {
        _ = self.map.erase(&node.rb);
    }
    fn mergeForward(self: *RegionMap, base: *RegionNode, coalesce: bool) void {
        if (!coalesce) return;
        var cur = base;
        while (cur.rb.succ() != RbNodeNil) {
            const nxt = RegionNode.fromRb(cur.rb.succ());
            if (cur.reg.end != nxt.reg.start) break;
            if (!(cur.reg.attr.kind == nxt.reg.attr.kind and
                cur.reg.attr.data == nxt.reg.attr.data and
                rightsEqual(cur.reg.perm, nxt.reg.perm))) break;
            cur.reg.end = nxt.reg.end;
            _ = self.map.erase(&nxt.rb);
            self.len -= 1;
        }
    }
};

const super = @import("mod.zig");
const Region = super.region.Region;
const rbtree = @import("rbtree");
const RbNode = rbtree.tree.RbNode;
const RbTree = rbtree.tree.RbTree;
const RbNodeNil = rbtree.tree.nil;

const std = @import("std");
const page = @import("page.zig");
const page_table = @import("page_table.zig");
const logging = @import("logging.zig");

const cimports = @import("cimports");
const sel4 = cimports.sel4;
const sos = cimports.sos;
const c = cimports.c;
