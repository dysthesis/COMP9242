pub const MetadataAllocator = struct {
    state: ?*client.Client = null,

    const vtable = std.mem.Allocator.VTable{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };

    pub fn init(self: *MetadataAllocator, state: *client.Client) void {
        self.state = state;
    }

    pub fn allocator(self: *MetadataAllocator) std.mem.Allocator {
        return std.mem.Allocator{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn deinit(self: *MetadataAllocator) void {
        const state_opt = self.state;
        if (state_opt == null) return;
        const state = state_opt.?;
        var idx: usize = 0;
        while (idx < state.metadata_page_count) : (idx += 1) {
            const meta_page = state.metadata_pages[idx];
            _ = sel4.seL4_ARM_Page_Unmap(meta_page.cap_slot);
            _ = sos.cspace_delete(&cspace, meta_page.cap_slot);
            sos.cspace_free_slot(&cspace, meta_page.cap_slot);
            sos.free_frame(meta_page.frame_ref);
        }
        state.metadata_page_count = 0;
        state.metadata_mapped = 0;
        state.metadata_cursor = state.metadata_base;
        self.state = null;
    }

    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self = @as(*MetadataAllocator, @ptrCast(@alignCast(ctx)));
        return self.alloc(len, alignment) catch null;
    }

    fn alloc(self: *MetadataAllocator, len: usize, alignment: std.mem.Alignment) MetadataAllocError![*]u8 {
        const state = self.state orelse return MetadataAllocError.OutOfMemory;
        const align_bytes = alignment.toByteUnits();
        var cursor = state.metadata_cursor;
        cursor = std.mem.alignForward(usize, cursor, align_bytes);
        if (len == 0) {
            return @as([*]u8, @ptrFromInt(cursor));
        }
        const end = cursor + len;
        if (end < cursor) {
            return MetadataAllocError.OutOfMemory;
        }
        try state.ensureMetadataMapped(end);
        state.metadata_cursor = end;
        return @as([*]u8, @ptrFromInt(cursor));
    }

    fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return false;
    }

    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return null;
    }

    fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = ret_addr;
    }
};

pub const MetadataAllocError = error{OutOfMemory};
pub const METADATA_REGION_BYTES: usize = sos.SOS_METADATA_REGION_BYTES;
pub const METADATA_REGION_PAGES: usize = METADATA_REGION_BYTES / sos.PAGE_SIZE_4K;
pub const METADATA_REGION_START: usize = sos.SOS_METADATA_BASE;

const client = @import("client.zig");
const std = @import("std");
const cimports = @import("cimports");
const sel4 = cimports.sel4;
const sos = cimports.sos;
const super = @import("mod.zig");
extern var cspace: sos.cspace_t;
