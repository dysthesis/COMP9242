/// A node of a red-black tree
pub const RbNode = packed struct {
    left: *Self,
    right: *Self,
    parent_int: std.meta.Int(.unsigned, @bitSizeOf(usize) - 1),
    col: enum(u1) { black, red },

    /// Get the parent of the current node
    pub inline fn parent(self: *const RbNode) *Self {
        return @ptrFromInt(self.parent_int << 1);
    }
    /// Set the parent of the current node
    pub inline fn setParent(self: *Self, p: *Self) void {
        self.parent_int = @intCast(@intFromPtr(p) >> 1);
    }

    /// Minimum child of this node by iteratively going left
    pub inline fn minChild(self: *Self) *Self {
        var x = self;
        while (x.left != nil) x = x.left;
        return x;
    }

    /// Maximum child of this node by iteratively going right
    pub inline fn maxChild(self: *Self) *Self {
        var x = self;
        while (x.right != nil) x = x.right;
        return x;
    }

    /// Get the successor of the current node; that is, get the node with the smallest key strictly
    /// greater than the current one.
    pub inline fn succ(self: *Self) *Self {
        var x = self;
        if (x.right != nil) return minChild(x.right);
        var y = x.parent();
        while (y != nil and x == y.right) {
            x = y;
            y = y.parent();
        }
        return y;
    }

    /// Verify if self is a nil node
    pub inline fn nilChecked(self: *Self) ?*Self {
        if (self != nil) return self;
        return null;
    }

    const Self = @This();

    comptime {
        std.debug.assert(@bitSizeOf(RbNode) == @bitSizeOf(usize) * 3);
    }
};

var nil_val: RbNode = undefined;
var nil_init = false;
const nil: *RbNode = &nil_val;

/// Constrct a red-black tree
pub fn RbTree(
    K: type,
    key: fn (*RbNode) callconv(.@"inline") K,
    cmp: fn (K, K) callconv(.@"inline") std.math.Order,
) type {
    return struct {
        root: *RbNode,
        len: usize,

        pub fn init() Self {
            if (!nil_init) {
                @branchHint(.unlikely);
                nil_init = true;
                nil_val = .{
                    .left = nil,
                    .right = nil,
                    .parent_int = @intCast(@intFromPtr(nil) >> 1),
                    .col = .black,
                };
            }

            return .{ .root = nil, .len = 0 };
        }

        pub inline fn lowerBound(self: *const Self, k: K) ?*RbNode {
            var p = nil;
            var x = self.root;
            while (x != nil) switch (cmp(key(x), k)) {
                .lt => x = x.right,
                .eq, .gt => {
                    p = x;
                    x = x.left;
                },
            };
            return p.nilChecked();
        }
        pub inline fn find(self: *const Self, k: K) ?*RbNode {
            var x = self.root;
            while (x != nil) switch (cmp(key(x), k)) {
                .lt => x = x.right,
                .eq => return x,
                .gt => x = x.left,
            };
            return null;
        }
        pub inline fn add(self: *Self, z: *RbNode) void {
            var y = nil;
            var x = self.root;
            while (x != nil) {
                y = x;
                switch (cmp(key(x), key(z))) {
                    .lt => x = x.right,
                    .eq => x = x.right,
                    .gt => x = x.left,
                }
            }
            z.left = nil;
            z.right = nil;
            z.setParent(y);
            z.col = .red;
            if (y == nil) {
                self.root = z;
            } else switch (cmp(key(y), key(z))) {
                .lt => y.right = z,
                .eq => y.right = z,
                .gt => y.left = z,
            }
            self.insertFixup(z);
            self.len += 1;
        }
        pub inline fn findOrAdd(self: *Self, z: *RbNode) ?*RbNode {
            var y = nil;
            var x = self.root;
            while (x != nil) {
                y = x;
                switch (cmp(key(x), key(z))) {
                    .lt => x = x.right,
                    .eq => return x,
                    .gt => x = x.left,
                }
            }
            z.left = nil;
            z.right = nil;
            z.setParent(y);
            z.col = .red;
            if (y == nil) {
                self.root = z;
            } else switch (cmp(key(y), key(z))) {
                .lt => y.right = z,
                .eq => unreachable,
                .gt => y.left = z,
            }
            self.insertFixup(z);
            self.len += 1;
            return null;
        }
        pub inline fn erase(self: *Self, z: *RbNode) ?*RbNode {
            var y = z;
            var x: *RbNode = undefined;
            var y_origin_col = y.col;
            const next = z.succ();

            if (z.left == nil) {
                x = z.right;
                self.transplant(z, z.right);
            } else if (z.right == nil) {
                x = z.left;
                self.transplant(z, z.left);
            } else {
                y = z.right.minChild();
                y_origin_col = y.col;
                x = y.right;
                if (y.parent() == z) {
                    x.setParent(y);
                } else {
                    self.transplant(y, y.right);
                    y.right = z.right;
                    y.right.setParent(y);
                }
                self.transplant(z, y);
                y.left = z.left;
                y.left.setParent(y);
                if (z.col == .red) {
                    y.col = .red;
                } else {
                    y.col = .black;
                }
            }

            if (y_origin_col == .black) self.eraseFixup(x);
            self.len -= 1;
            return next.nilChecked();
        }

        pub inline fn min(self: *const Self) ?*RbNode {
            return self.root.minChild().nilChecked();
        }
        pub inline fn max(self: *const Self) ?*RbNode {
            return self.root.maxChild().nilChecked();
        }
        pub inline fn iter(self: *const Self) Iterator {
            return .{ .cur = self.root.minChild() };
        }

        inline fn leftRotate(self: *Self, x: *RbNode) void {
            var y = x.right;
            x.right = y.left;
            if (y.left != nil) y.left.setParent(x);
            y.setParent(x.parent());
            if (x.parent() == nil) {
                self.root = y;
            } else if (x == x.parent().left) {
                x.parent().left = y;
            } else {
                x.parent().right = y;
            }
            y.left = x;
            x.setParent(y);
        }
        inline fn rightRotate(self: *Self, x: *RbNode) void {
            var y = x.left;
            x.left = y.right;
            if (y.right != nil) y.right.setParent(x);
            y.setParent(x.parent());
            if (x.parent() == nil) {
                self.root = y;
            } else if (x == x.parent().right) {
                x.parent().right = y;
            } else {
                x.parent().left = y;
            }
            y.right = x;
            x.setParent(y);
        }
        inline fn insertFixup(self: *Self, node: *RbNode) void {
            var z = node;
            while (z.parent().col == .red) {
                var p = z.parent();
                var g = p.parent();
                if (p == g.left) {
                    var u = g.right;
                    if (u.col == .red) {
                        p.col = .black;
                        u.col = .black;
                        g.col = .red;
                        z = g;
                    } else {
                        if (z == p.right) {
                            z = p;
                            self.leftRotate(z);
                            p = z.parent();
                            g = p.parent();
                        }
                        p.col = .black;
                        g.col = .red;
                        self.rightRotate(g);
                    }
                } else {
                    var u = g.left;
                    if (u.col == .red) {
                        p.col = .black;
                        u.col = .black;
                        g.col = .red;
                        z = g;
                    } else {
                        if (z == p.left) {
                            z = p;
                            self.rightRotate(z);
                            p = z.parent();
                            g = p.parent();
                        }
                        p.col = .black;
                        g.col = .red;
                        self.leftRotate(g);
                    }
                }
            }
            self.root.col = .black;
        }
        inline fn eraseFixup(self: *Self, node: *RbNode) void {
            var x = node;
            while (x != self.root and x.col == .black) {
                if (x == x.parent().left) {
                    var w = x.parent().right;
                    if (w.col == .red) {
                        w.col = .black;
                        x.parent().col = .red;
                        self.leftRotate(x.parent());
                        w = x.parent().right;
                    }
                    if (w.left.col == .black and w.right.col == .black) {
                        w.col = .red;
                        x = x.parent();
                    } else {
                        if (w.right.col == .black) {
                            w.left.col = .black;
                            w.col = .red;
                            self.rightRotate(w);
                            w = x.parent().right;
                        }
                        if (x.parent().col == .red) {
                            w.col = .red;
                        } else {
                            w.col = .black;
                        }
                        x.parent().col = .black;
                        w.right.col = .black;
                        self.leftRotate(x.parent());
                        x = self.root;
                    }
                } else {
                    var w = x.parent().left;
                    if (w.col == .red) {
                        w.col = .black;
                        w.parent().col = .red;
                        self.rightRotate(x.parent());
                        w = x.parent().left;
                    }
                    if (w.right.col == .black and w.left.col == .black) {
                        w.col = .red;
                        x = x.parent();
                    } else {
                        if (w.left.col == .black) {
                            w.right.col = .black;
                            w.col = .red;
                            self.leftRotate(w);
                            w = x.parent().left;
                        }
                        if (x.parent().col == .red) {
                            w.col = .red;
                        } else {
                            w.col = .black;
                        }
                        x.parent().col = .black;
                        w.left.col = .black;
                        self.rightRotate(x.parent());
                        x = self.root;
                    }
                }
            }
            self.root.col = .black;
        }
        inline fn transplant(self: *Self, u: *RbNode, v: *RbNode) void {
            if (u.parent() == nil) {
                self.root = v;
            } else if (u == u.parent().left) {
                u.parent().left = v;
            } else {
                u.parent().right = v;
            }
            v.setParent(u.parent());
        }

        const Self = @This();
    };
}

const Iterator = struct {
    cur: *RbNode,

    pub inline fn next(self: *Self) ?*RbNode {
        defer self.cur = self.cur.succ();
        return self.cur.nilChecked();
    }

    const Self = @This();
};

test "rb" {
    const ex = std.testing.expect;

    const Item = struct {
        num: usize,
        node: RbNode,
        pub inline fn key(x: *RbNode) usize {
            const ptr: *@This() = @fieldParentPtr("node", x);
            return ptr.num;
        }
        pub inline fn cmp(a: usize, b: usize) std.math.Order {
            return std.math.order(a, b);
        }
    };

    var rb = RbTree(usize, Item.key, Item.cmp).init();
    try ex(rb.find(5) == null);
    var n0: Item = .{ .num = 5, .node = undefined };
    rb.add(&n0.node);
    try ex(rb.len == 1);
    try ex(rb.find(5) == &n0.node);
    try ex(rb.lowerBound(4) == &n0.node);
    try ex(rb.lowerBound(5) == &n0.node);
    try ex(rb.lowerBound(6) == null);
    var n1: Item = .{ .num = 10, .node = undefined };
    rb.add(&n1.node);
    try ex(rb.erase(&n0.node) == &n1.node);
    try ex(rb.len == 1);
}

test "duplicate" {
    const ex = std.testing.expect;

    const Item = struct {
        num: usize,
        node: RbNode,
        pub inline fn key(x: *RbNode) usize {
            const ptr: *@This() = @fieldParentPtr("node", x);
            return ptr.num;
        }
        pub inline fn cmp(a: usize, b: usize) std.math.Order {
            return std.math.order(a, b);
        }
    };

    var rb = RbTree(usize, Item.key, Item.cmp).init();
    var n0: Item = .{ .num = 2, .node = undefined };
    var n1: Item = .{ .num = 2, .node = undefined };
    rb.add(&n0.node);
    rb.add(&n1.node);
    try ex(rb.len == 2);
}

test "min max" {
    const ex = std.testing.expect;

    const Item = struct {
        num: usize,
        node: RbNode,
        pub inline fn key(x: *RbNode) usize {
            const ptr: *@This() = @fieldParentPtr("node", x);
            return ptr.num;
        }
        pub inline fn cmp(a: usize, b: usize) std.math.Order {
            return std.math.order(a, b);
        }
    };

    var rb = RbTree(usize, Item.key, Item.cmp).init();
    var items = [_]Item{
        .{ .num = 555, .node = undefined },
        .{ .num = 2, .node = undefined },
        .{ .num = 10, .node = undefined },
        .{ .num = 3, .node = undefined },
    };
    for (&items) |*item| rb.add(&item.node);
    try ex(rb.len == 4);
    try ex(Item.key(rb.min().?) == 2);
    try ex(Item.key(rb.max().?) == 555);
}

test "iter" {
    const ex = std.testing.expect;

    const Item = struct {
        num: usize,
        node: RbNode,
        pub inline fn key(x: *RbNode) usize {
            const ptr: *@This() = @fieldParentPtr("node", x);
            return ptr.num;
        }
        pub inline fn cmp(a: usize, b: usize) std.math.Order {
            return std.math.order(a, b);
        }
    };
    var rb = RbTree(usize, Item.key, Item.cmp).init();
    var items = [_]Item{
        .{ .num = 555, .node = undefined },
        .{ .num = 2, .node = undefined },
        .{ .num = 10, .node = undefined },
        .{ .num = 10, .node = undefined },
        .{ .num = 3, .node = undefined },
    };
    for (&items) |*item| rb.add(&item.node);

    var it = rb.iter();
    try ex(Item.key(it.next().?) == 2);
    try ex(Item.key(it.next().?) == 3);
    try ex(Item.key(it.next().?) == 10);
    try ex(Item.key(it.next().?) == 10);
    try ex(Item.key(it.next().?) == 555);
    try ex(it.next() == null);
}

const std = @import("std");
