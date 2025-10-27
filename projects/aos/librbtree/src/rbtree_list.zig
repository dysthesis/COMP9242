pub const RbListNode = struct {
    prev: ?*RbListNode,
    next: ?*RbListNode,
    rb_node: rb.Node,
};

pub fn RbList(
    K: type,
    key: fn (*RbListNode) callconv(.@"inline") K,
    cmp: fn (K, K) callconv(.@"inline") std.math.Order,
) type {
    return struct {
        inner: rb.Rb(K, rb_key, cmp),
        len: usize,

        pub fn init() Self {
            return .{ .inner = .init(), .len = 0 };
        }

        pub fn find(self: *const Self, k: K) ?*RbListNode {
            const rb_node = self.inner.find(k) orelse return null;
            return @fieldParentPtr("rb_node", rb_node);
        }
        pub fn lowerBound(self: *const Self, k: K) ?*RbListNode {
            const rb_node = self.inner.lowerBound(k) orelse return null;
            return @fieldParentPtr("rb_node", rb_node);
        }
        pub fn add(self: *Self, x: *RbListNode) void {
            if (self.inner.findOrAdd(&x.rb_node)) |head_rb_node| {
                const head: *RbListNode = @fieldParentPtr("rb_node", head_rb_node);
                std.debug.assert(head.prev == null);
                x.prev = head;
                x.next = head.next;
                if (head.next != null) head.next.?.prev = x;
                head.next = x;
            } else {
                x.prev = null;
                x.next = null;
            }
            self.len += 1;
        }
        pub fn erase(self: *Self, x: *RbListNode) void {
            if (x.prev == null) {
                _ = self.inner.erase(&x.rb_node);
                if (x.next) |next| {
                    next.prev = null;
                    self.inner.add(&next.rb_node);
                }
            } else {
                const prev = x.prev;
                const next = x.next;
                prev.?.next = next;
                if (next != null) next.?.prev = prev;
            }
            self.len -= 1;
        }

        inline fn rb_key(rb_node: *rb.Node) K {
            const node: *RbListNode = @fieldParentPtr("rb_node", rb_node);
            return key(node);
        }

        const Self = @This();
    };
}

test "rb_list" {
    const Item = struct {
        num: usize,
        node: RbListNode = undefined,
        pub inline fn key(x: *RbListNode) usize {
            const ptr: *@This() = @fieldParentPtr("node", x);
            return ptr.num;
        }
        pub inline fn cmp(a: usize, b: usize) std.math.Order {
            return std.math.order(a, b);
        }
    };

    var rb_list = RbList(usize, Item.key, Item.cmp).init();
    var n = [_]Item{
        .{ .num = 1 },
        .{ .num = 1 },
        .{ .num = 2 },
        .{ .num = 1 },
    };
    var i: usize = 0;

    rb_list.add(&n[i].node);
    try ex(rb_list.len == 1);
    try ex(rb_list.inner.len == 1);
    i += 1;

    rb_list.add(&n[i].node);
    try ex(rb_list.len == 2);
    try ex(rb_list.inner.len == 1);
    i += 1;

    rb_list.add(&n[i].node);
    try ex(rb_list.len == 3);
    try ex(rb_list.inner.len == 2);
    i += 1;

    rb_list.erase(&n[0].node); // remove head
    try ex(rb_list.len == 2);
    try ex(rb_list.inner.len == 2);

    rb_list.add(&n[i].node);
    try ex(rb_list.len == 3);
    try ex(rb_list.inner.len == 2);
    i += 1;

    try ex(Item.key(rb_list.lowerBound(0).?) == 1);
    try ex(Item.key(rb_list.find(1).?) == 1);
    try ex(Item.key(rb_list.lowerBound(1).?) == 1);
    try ex(Item.key(rb_list.find(2).?) == 2);
    try ex(rb_list.find(3) == null);
    try ex(rb_list.lowerBound(3) == null);

    rb_list.erase(&n[1].node); // remove nonhead
    try ex(rb_list.len == 2);
    try ex(rb_list.inner.len == 2);

    try ex(Item.key(rb_list.lowerBound(0).?) == 1);
    try ex(Item.key(rb_list.find(1).?) == 1);
    try ex(Item.key(rb_list.lowerBound(1).?) == 1);
    try ex(Item.key(rb_list.find(2).?) == 2);
    try ex(rb_list.find(3) == null);
    try ex(rb_list.lowerBound(3) == null);

    rb_list.erase(&n[2].node); // remove single
    try ex(rb_list.len == 1);
    try ex(rb_list.inner.len == 1);

    try ex(rb_list.find(2) == null);
}

const rb = @import("rbtree.zig");
const builtin = @import("builtin");
const ex = std.testing.expect;
const std = @import("std");
