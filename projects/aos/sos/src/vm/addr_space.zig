/// Per-process address space
pub const AddrSpace = struct {
    regions: RegionMap,
};

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

    const CapRights = std.meta.FieldType(Region, "perm");

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

pub const super = @import("mod.zig");
pub const Region = super.region.Region;
pub const rbtree = @import("rbtree");
pub const RbNode = rbtree.tree.RbNode;
pub const RbTree = rbtree.tree.RbTree;
pub const RbNodeNil = rbtree.tree.nil;
pub const std = @import("std");
