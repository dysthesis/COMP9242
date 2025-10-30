test "Pool bootstrap initialises correctly" {
    continuation.ContinuationPool.bootstrap();

    const stats = continuation.ContinuationPool.getStats();
    try testing.expectEqual(@as(usize, 0), stats.in_use);
    try testing.expectEqual(continuation.CONT_POOL_SIZE, stats.capacity);
}

test "Pool bootstrap is idempotent" {
    continuation.ContinuationPool.bootstrap();
    const stats1 = continuation.ContinuationPool.getStats();

    continuation.ContinuationPool.bootstrap();
    const stats2 = continuation.ContinuationPool.getStats();

    try testing.expectEqual(stats1.in_use, stats2.in_use);
    try testing.expectEqual(stats1.capacity, stats2.capacity);
}

test "Allocate single continuation" {
    continuation.ContinuationPool.bootstrap();

    const cont = continuation.ContinuationPool.alloc();
    try testing.expect(cont != null);

    const stats = continuation.ContinuationPool.getStats();
    try testing.expectEqual(@as(usize, 1), stats.in_use);
}

test "Allocate all pool entries" {
    continuation.ContinuationPool.bootstrap();

    var allocated: [continuation.CONT_POOL_SIZE]*continuation.Continuation = undefined;
    var i: usize = 0;

    while (i < continuation.CONT_POOL_SIZE) : (i += 1) {
        const cont = continuation.ContinuationPool.alloc();
        try testing.expect(cont != null);
        allocated[i] = cont.?;
    }

    const stats = continuation.ContinuationPool.getStats();
    try testing.expectEqual(continuation.CONT_POOL_SIZE, stats.in_use);

    const overflow = continuation.ContinuationPool.alloc();
    try testing.expect(overflow == null);

    i = 0;
    while (i < continuation.CONT_POOL_SIZE) : (i += 1) {
        continuation.ContinuationPool.free(allocated[i]);
    }
}

test "Free and reallocate" {
    continuation.ContinuationPool.bootstrap();

    const cont1 = continuation.ContinuationPool.alloc();
    try testing.expect(cont1 != null);

    const stats_after_alloc = continuation.ContinuationPool.getStats();
    try testing.expectEqual(@as(usize, 1), stats_after_alloc.in_use);

    continuation.ContinuationPool.free(cont1.?);

    const stats_after_free = continuation.ContinuationPool.getStats();
    try testing.expectEqual(@as(usize, 0), stats_after_free.in_use);

    const cont2 = continuation.ContinuationPool.alloc();
    try testing.expect(cont2 != null);

    const stats_after_realloc = continuation.ContinuationPool.getStats();
    try testing.expectEqual(@as(usize, 1), stats_after_realloc.in_use);

    continuation.ContinuationPool.free(cont2.?);
}

test "Pool exhaustion returns null gracefully" {
    continuation.ContinuationPool.bootstrap();

    var allocated: [continuation.CONT_POOL_SIZE]*continuation.Continuation = undefined;
    var i: usize = 0;

    while (i < continuation.CONT_POOL_SIZE) : (i += 1) {
        allocated[i] = continuation.ContinuationPool.alloc().?;
    }

    const overflow1 = continuation.ContinuationPool.alloc();
    const overflow2 = continuation.ContinuationPool.alloc();
    const overflow3 = continuation.ContinuationPool.alloc();

    try testing.expect(overflow1 == null);
    try testing.expect(overflow2 == null);
    try testing.expect(overflow3 == null);

    continuation.ContinuationPool.free(allocated[0]);

    const cont_after_free = continuation.ContinuationPool.alloc();
    try testing.expect(cont_after_free != null);

    continuation.ContinuationPool.free(cont_after_free.?);
    i = 1;
    while (i < continuation.CONT_POOL_SIZE) : (i += 1) {
        continuation.ContinuationPool.free(allocated[i]);
    }
}

test "Allocated continuation is zero-initialized" {
    continuation.ContinuationPool.bootstrap();

    const cont = continuation.ContinuationPool.alloc();
    try testing.expect(cont != null);

    const c = cont.?;

    try testing.expect(c.client == @ptrFromInt(0));
    try testing.expectEqual(@as(@TypeOf(c.reply), 0), c.reply);
    try testing.expect(c.reply_ut == @ptrFromInt(0));

    continuation.ContinuationPool.free(c);
}

test "Multiple allocations and deallocations" {
    continuation.ContinuationPool.bootstrap();

    const half = continuation.CONT_POOL_SIZE / 2;
    var allocated: [64]*continuation.Continuation = undefined;
    var i: usize = 0;

    while (i < half) : (i += 1) {
        allocated[i] = continuation.ContinuationPool.alloc().?;
    }

    var stats = continuation.ContinuationPool.getStats();
    try testing.expectEqual(half, stats.in_use);

    i = 0;
    while (i < half) : (i += 2) {
        continuation.ContinuationPool.free(allocated[i]);
    }

    stats = continuation.ContinuationPool.getStats();
    try testing.expectEqual(half / 2, stats.in_use);

    i = 0;
    while (i < half / 2) : (i += 1) {
        const cont = continuation.ContinuationPool.alloc();
        try testing.expect(cont != null);
    }

    stats = continuation.ContinuationPool.getStats();
    try testing.expectEqual(half, stats.in_use);

    i = 0;
    while (i < half / 2) : (i += 1) {}

    i = 1;
    while (i < half) : (i += 2) {
        continuation.ContinuationPool.free(allocated[i]);
    }
}

test "Pool statistics are accurate" {
    continuation.ContinuationPool.bootstrap();

    var stats = continuation.ContinuationPool.getStats();
    try testing.expectEqual(@as(usize, 0), stats.in_use);

    const cont1 = continuation.ContinuationPool.alloc().?;
    stats = continuation.ContinuationPool.getStats();
    try testing.expectEqual(@as(usize, 1), stats.in_use);

    const cont2 = continuation.ContinuationPool.alloc().?;
    stats = continuation.ContinuationPool.getStats();
    try testing.expectEqual(@as(usize, 2), stats.in_use);

    const cont3 = continuation.ContinuationPool.alloc().?;
    stats = continuation.ContinuationPool.getStats();
    try testing.expectEqual(@as(usize, 3), stats.in_use);

    continuation.ContinuationPool.free(cont2);
    stats = continuation.ContinuationPool.getStats();
    try testing.expectEqual(@as(usize, 2), stats.in_use);

    continuation.ContinuationPool.free(cont1);
    continuation.ContinuationPool.free(cont3);
    stats = continuation.ContinuationPool.getStats();
    try testing.expectEqual(@as(usize, 0), stats.in_use);
}

const std = @import("std");
const testing = std.testing;
const continuation = @import("continuation.zig");
