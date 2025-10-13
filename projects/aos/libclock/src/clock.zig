const INITIAL_TIMEOUTS: usize = 10;

/// A timer timeout
const Timeout = struct {
    /// A unique identifier for the timer
    id: u32,
    /// The absolute time when this timeout will be triggered
    deadline: u64,
    /// The function to call back to when the timeout expires
    callback: c.timer_callback_t,
    /// Data to feed in to the callback
    data: ?*anyopaque,
    /// Is this timeout active
    active: bool,
};

fn compareTimeout(_: void, a: *Timeout, b: *Timeout) math.Order {
    return math.order(a.deadline, b.deadline);
}

/// Priority queue of timeouts to sort by earliest due timeouts.
const TimeoutQueue = std.PriorityQueue(*Timeout, void, compareTimeout);
/// Global list of timeouts to keep track of free timeout IDs.
const TimeoutSlots = std.ArrayList(?*Timeout);

/// A counter-timebase pair representing a delay
const Delay = struct {
    count: u16,
    base: c.timeout_timebase_t,

    /// Construct a new delay from raw microseconds.
    fn from(us: u64) Delay {
        const max16: u64 = math.maxInt(u16);
        if (us <= max16) {
            return .{
                .count = @intCast(us),
                .base = c.TIMEOUT_TIMEBASE_1_US,
            };
        }
        if (us <= max16 * 10) {
            return .{
                .count = @intCast(us / 10),
                .base = c.TIMEOUT_TIMEBASE_10_US,
            };
        }
        if (us <= max16 * 100) {
            return .{
                .count = @intCast(us / 100),
                .base = c.TIMEOUT_TIMEBASE_100_US,
            };
        }
        if (us <= max16 * 1000) {
            return .{
                .count = @intCast(us / 1000),
                .base = c.TIMEOUT_TIMEBASE_1_MS,
            };
        }
        return .{
            .count = math.maxInt(u16),
            .base = c.TIMEOUT_TIMEBASE_1_MS,
        };
    }
};

inline fn logError(comptime fmt: []const u8, args: anytype) void {
    _ = fmt;
    _ = args;
}

fn destroyTimeout(timeout: *Timeout) void {
    free(@as(?*anyopaque, @ptrCast(timeout)));
}

/// Global clock
const Clock = struct {
    /// Hardware clock registers
    regs: ?*volatile c.meson_timer_reg_t,
    /// Is the clock running?
    running: bool,
    /// Queue of timeouts sorted by earliest due
    queue: TimeoutQueue,
    /// List of timeouts by ID
    slots: TimeoutSlots,
    /// How many timeouts are active
    active_count: usize,

    fn init() Clock {
        return .{
            .regs = null,
            .running = false,
            .queue = TimeoutQueue.init(heap_allocator, {}),
            .slots = TimeoutSlots{},
            .active_count = 0,
        };
    }

    /// Disable the clock hardware
    fn disableHardware(self: *Clock) void {
        if (self.regs) |regs| {
            c.configure_timeout(
                regs,
                c.MESON_TIMER_A,
                false,
                false,
                c.TIMEOUT_TIMEBASE_1_MS,
                0,
            );
        }
    }

    /// Get the current time if the clock is running
    fn currentTime(self: *const Clock) ?u64 {
        if (!self.running or self.regs == null) {
            return null;
        }
        return c.read_timestamp(self.regs.?);
    }

    /// Get rid of the head if it is inactive.
    fn pruneInactiveHead(self: *Clock) void {
        while (true) {
            const maybe_head = self.queue.peek();
            if (maybe_head) |head| {
                if (head.active) {
                    return;
                }
                _ = self.queue.remove();
                destroyTimeout(head);
            } else {
                return;
            }
        }
    }

    /// Configure the hardware timer to trigger an interrupt for the earliest due timeout.
    fn scheduleEarliest(self: *Clock, now_hint: ?u64) void {
        if (!self.running or self.regs == null) {
            return;
        }

        self.pruneInactiveHead();

        if (self.active_count == 0) {
            self.disableHardware();
            return;
        }

        const head = self.queue.peek() orelse {
            self.disableHardware();
            return;
        };
        if (!head.active) unreachable;

        const now = now_hint orelse self.currentTime() orelse 0;
        const diff: u64 = if (head.deadline > now) head.deadline - now else 0;
        const delay = Delay.from(diff);

        c.configure_timeout(
            self.regs.?,
            c.MESON_TIMER_A,
            true,
            false,
            delay.base,
            delay.count,
        );
    }

    /// Reset the clock state
    fn resetState(self: *Clock) void {
        while (self.queue.removeOrNull()) |timeout| {
            destroyTimeout(timeout);
        }
        self.queue.deinit();
        self.queue = TimeoutQueue.init(heap_allocator, {});

        self.slots.deinit(heap_allocator);
        self.slots = TimeoutSlots{};

        self.active_count = 0;
    }

    fn allocateTimeoutSlot(self: *Clock, timeout: *Timeout) Allocator.Error!u32 {
        var index: usize = 0;
        while (index < self.slots.items.len) : (index += 1) {
            if (self.slots.items[index] == null) {
                self.slots.items[index] = timeout;
                const id: u32 = @intCast(index + 1);
                return id;
            }
        }

        try self.slots.append(heap_allocator, timeout);
        const id: u32 = @intCast(self.slots.items.len);
        return id;
    }

    fn releaseTimeoutSlot(self: *Clock, id: u32) void {
        if (id == 0) return;
        const index: usize = @intCast(id - 1);
        if (index < self.slots.items.len) {
            self.slots.items[index] = null;
        }
    }

    fn getTimeoutById(self: *Clock, id: u32) ?*Timeout {
        if (id == 0) return null;
        const index: usize = @intCast(id - 1);
        if (index >= self.slots.items.len) return null;
        return self.slots.items[index];
    }

    /// Start the clock
    fn start(self: *Clock, timer_vaddr: [*c]u8) c_int {
        if (timer_vaddr == null) {
            return c.CLOCK_R_FAIL;
        }

        if (self.running) {
            const stopped = self.stop();
            if (stopped != c.CLOCK_R_OK) {
                return stopped;
            }
        } else {
            self.resetState();
        }

        const base_addr = @intFromPtr(timer_vaddr) + c.TIMER_REG_START;
        self.regs = @as(*volatile c.meson_timer_reg_t, @ptrFromInt(base_addr));

        c.configure_timestamp(self.regs.?, c.TIMESTAMP_TIMEBASE_1_US);
        self.regs.?.timer_e = 0;

        if (self.queue.ensureTotalCapacityPrecise(INITIAL_TIMEOUTS)) |_| {} else |err| {
            logError("start_timer: failed to reserve queue capacity: {s}", .{@errorName(err)});
            _ = self.stop();
            return c.CLOCK_R_FAIL;
        }

        if (self.slots.ensureTotalCapacityPrecise(heap_allocator, INITIAL_TIMEOUTS)) |_| {} else |err| {
            logError("start_timer: failed to reserve slot capacity: {s}", .{@errorName(err)});
            _ = self.stop();
            return c.CLOCK_R_FAIL;
        }

        self.active_count = 0;
        self.running = true;
        return c.CLOCK_R_OK;
    }

    /// Get the current time as a `timestamp_t`
    fn getTime(self: *Clock) c.timestamp_t {
        return self.currentTime() orelse 0;
    }

    /// Register a new timeout, returning the resulting ID for that timeout
    fn registerTimer(self: *Clock, delay: u64, callback: c.timer_callback_t, data: ?*anyopaque) u32 {
        if (!self.running) {
            logError("register_timer: driver not initialised", .{});
            return 0;
        }
        if (self.regs == null or callback == null) {
            return 0;
        }

        const new_timeout_ptr = malloc(@sizeOf(Timeout)) orelse {
            logError("register_timer: allocation failed", .{});
            return 0;
        };
        const new_timeout = @as(*Timeout, @ptrFromInt(@intFromPtr(new_timeout_ptr)));
        new_timeout.* = Timeout{
            .id = 0,
            .deadline = 0,
            .callback = callback,
            .data = data,
            .active = false,
        };

        const now = self.currentTime() orelse {
            logError("register_timer: current time unavailable", .{});
            destroyTimeout(new_timeout);
            return 0;
        };
        const deadline = math.add(u64, now, delay) catch {
            logError("register_timer: deadline overflow", .{});
            destroyTimeout(new_timeout);
            return 0;
        };

        const id = self.allocateTimeoutSlot(new_timeout) catch |err| {
            logError("register_timer: failed to allocate slot: {s}", .{@errorName(err)});
            destroyTimeout(new_timeout);
            return 0;
        };

        new_timeout.deadline = deadline;
        new_timeout.id = id;
        new_timeout.active = true;

        if (self.queue.add(new_timeout)) |_| {} else |err| {
            logError("register_timer: queue insertion failed: {s}", .{@errorName(err)});
            self.releaseTimeoutSlot(id);
            destroyTimeout(new_timeout);
            return 0;
        }

        self.active_count += 1;

        self.pruneInactiveHead();
        if (self.queue.peek()) |head| {
            if (head == new_timeout) {
                self.scheduleEarliest(null);
            }
        }

        return id;
    }

    /// Remove a timoeut by ID.
    fn removeTimer(self: *Clock, id: u32) c_int {
        if (!self.running) {
            return c.CLOCK_R_UINT;
        }
        if (id == 0) {
            return c.CLOCK_R_FAIL;
        }

        const timeout = self.getTimeoutById(id) orelse {
            return c.CLOCK_R_FAIL;
        };

        if (!timeout.active) {
            return c.CLOCK_R_FAIL;
        }

        timeout.active = false;
        self.releaseTimeoutSlot(id);
        if (self.active_count == 0) unreachable;
        self.active_count -= 1;

        const now = self.currentTime();
        self.scheduleEarliest(now);
        return c.CLOCK_R_OK;
    }

    fn handleIrq(self: *Clock, data: ?*anyopaque, irq: c.seL4_Word, irq_handler: c.seL4_IRQHandler) c_int {
        _ = data;
        _ = irq;

        if (!self.running or self.regs == null) {
            return c.CLOCK_R_UINT;
        }

        var now_opt = self.currentTime();
        if (now_opt == null) {
            self.scheduleEarliest(null);
            _ = c.seL4_IRQHandler_Ack(irq_handler);
            return c.CLOCK_R_UINT;
        }
        var now = now_opt.?;

        while (true) {
            const maybe_head = self.queue.peek();
            if (maybe_head == null) break;

            const head = maybe_head.?;
            if (!head.active) {
                _ = self.queue.remove();
                destroyTimeout(head);
                continue;
            }

            if (head.deadline > now) {
                break;
            }

            _ = self.queue.remove();
            self.releaseTimeoutSlot(head.id);
            head.active = false;
            if (self.active_count == 0) unreachable;
            self.active_count -= 1;

            if (head.callback) |cb| {
                cb(head.id, head.data);
            }

            destroyTimeout(head);
            now_opt = self.currentTime();
            if (now_opt) |value| {
                now = value;
            }
        }

        self.scheduleEarliest(now_opt);
        _ = c.seL4_IRQHandler_Ack(irq_handler);
        return c.CLOCK_R_OK;
    }

    fn stop(self: *Clock) c_int {
        if (!self.running) {
            return c.CLOCK_R_OK;
        }

        self.disableHardware();

        self.resetState();

        self.regs = null;
        self.running = false;

        return c.CLOCK_R_OK;
    }
};

var default_clock = Clock.init();

// NOTE: This exports functions for C as required by `clock.h`
pub export fn is_timer_running() callconv(.c) bool {
    return default_clock.running;
}

pub export fn start_timer(timer_vaddr: [*c]u8) callconv(.c) c_int {
    return default_clock.start(timer_vaddr);
}

pub export fn get_time() callconv(.c) c.timestamp_t {
    return default_clock.getTime();
}

pub export fn register_timer(delay: u64, callback: c.timer_callback_t, data: ?*anyopaque) callconv(.c) u32 {
    return default_clock.registerTimer(delay, callback, data);
}

pub export fn remove_timer(id: u32) callconv(.c) c_int {
    return default_clock.removeTimer(id);
}

pub export fn timer_irq(data: ?*anyopaque, irq: c.seL4_Word, irq_handler: c.seL4_IRQHandler) callconv(.c) c_int {
    return default_clock.handleIrq(data, irq, irq_handler);
}

pub export fn stop_timer() callconv(.c) c_int {
    return default_clock.stop();
}

// NOTE: this imports functions from C
extern fn malloc(size: usize) ?*anyopaque;
extern fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque;
extern fn free(ptr: ?*anyopaque) void;

const max_supported_alignment: usize = 16;

/// Rely on musl's malloc to use the preallocated memory since we haven't implemented virtual memory
/// and proper allocation yet.
const MallocAllocator = struct {
    const vtable = Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = freeFn,
    };

    fn alloc(
        _: *anyopaque,
        len: usize,
        alignment: Alignment,
        _: usize,
    ) ?[*]u8 {
        if (len == 0) return null;
        if (alignment.toByteUnits() > max_supported_alignment) return null;
        const raw = malloc(len) orelse return null;
        return @as([*]u8, @ptrCast(raw));
    }

    fn resize(
        _: *anyopaque,
        _: []u8,
        _: Alignment,
        _: usize,
        _: usize,
    ) bool {
        return false;
    }

    fn remap(
        _: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        _: usize,
    ) ?[*]u8 {
        if (alignment.toByteUnits() > max_supported_alignment) return null;
        if (memory.len == 0 or new_len == 0) return null;
        const new_ptr = realloc(@as(?*anyopaque, @ptrCast(memory.ptr)), new_len) orelse return null;
        return @as([*]u8, @ptrCast(new_ptr));
    }

    fn freeFn(
        _: *anyopaque,
        memory: []u8,
        _: Alignment,
        _: usize,
    ) void {
        if (memory.len == 0) return;
        free(@as(?*anyopaque, @ptrCast(memory.ptr)));
    }
};

const heap_allocator: Allocator = .{
    .ptr = undefined,
    .vtable = &MallocAllocator.vtable,
};

const std = @import("std");

const cimports = @import("cimports");
const c = cimports.c;

const math = std.math;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
