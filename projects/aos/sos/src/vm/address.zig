const std = @import("std");

/// A virtual address
pub const Address = struct {
    value: usize,
    const Self = @This();

    /// Construct a new instance of `Address`.
    pub fn init(value: usize) Address {
        return .{ .value = value };
    }

    /// Get the address as a raw `usize`.
    pub fn raw(self: Self) usize {
        return self.value;
    }

    /// True when `value` is aligned to the provided power-of-two boundary.
    pub fn isAligned(self: Self, alignment: usize) bool {
        return alignment == 0 or self.value % alignment == 0;
    }

    /// Drop the low bits so the address lands on the previous alignment boundary.
    pub fn alignDown(self: Self, alignment: usize) Address {
        if (alignment == 0) return self;
        const aligned = self.value - (self.value % alignment);
        return .{ .value = aligned };
    }

    /// Round the address up to the next alignment boundary.
    pub fn alignUp(self: Self, alignment: usize) Address {
        if (alignment == 0) return self;
        const remainder = self.value % alignment;
        if (remainder == 0) return self;
        const delta = alignment - remainder;
        const aligned = std.math.add(usize, self.value, delta) catch unreachable;
        return .{ .value = aligned };
    }

    /// Convenience wrapper for `PAGE_SIZE`-aligned down similar to `pageBase`.
    pub fn pageBase(self: Self, page_size: usize) Address {
        return self.alignDown(page_size);
    }

    /// Return the offset of this address within an alignment-sized region.
    pub fn offsetWithin(self: Self, alignment: usize) usize {
        return if (alignment == 0) 0 else self.value % alignment;
    }

    /// Add `delta` bytes to the address (panics on overflow).
    pub fn add(self: Self, delta: usize) Address {
        const result = std.math.add(usize, self.value, delta) catch unreachable;
        return .{ .value = result };
    }
};
