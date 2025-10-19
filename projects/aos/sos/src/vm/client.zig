pub const Client = struct {
    initialised: bool = false,
    heap_break: usize = 0,
    heap_mapped_end: usize = 0,
    mmap_next: usize = 0,
    stack_guard: usize = 0,
    stack_low: usize = 0,
    stack_top: usize = 0,
    mapped_count: usize = 0,
    active_mmaps: usize = 0,

    heap_region: region.Region = .{},
    stack_region: region.Region = .{},

    metadata_allocator: allocator.MetadataAllocator = allocator.MetadataAllocator{},
    metadata_alloc_handle: std.mem.Allocator = undefined,
    metadata_base: usize = 0,
    metadata_cursor: usize = 0,
    metadata_mapped: usize = 0,
    metadata_page_count: usize = 0,
    metadata_pages: [allocator.METADATA_REGION_PAGES]page.MetadataPage = [_]page.MetadataPage{page.MetadataPage{
        .frame_ref = 0,
        .cap_slot = sel4.seL4_CapNull,
        .vaddr = 0,
    }} ** allocator.METADATA_REGION_PAGES,
    page_map: PageMap = undefined,
    mmap_regions: RegionList = .{},

    pub const Self = @This();

    pub fn findPage(self: *Self, vaddr: usize) ?*page.MappedPage {
        return self.page_map.getPtr(vaddr);
    }

    pub fn metadataAllocator(self: *Client) std.mem.Allocator {
        return self.metadata_alloc_handle;
    }

    pub fn init(self: *Self, idx: usize) void {
        self.initialised = true;
        self.heap_break = super.HEAP_BASE;
        self.heap_mapped_end = super.HEAP_BASE;
        self.mmap_next = super.MMAP_BASE;
        self.stack_guard = super.STACK_GUARD_BASE;
        self.stack_low = super.STACK_TOP;
        self.stack_top = super.STACK_TOP;
        self.mapped_count = 0;
        self.active_mmaps = 0;

        self.heap_region.reset(region.RegionKind.Heap);
        self.heap_region.configure(super.HEAP_BASE, region.RegionKind.Heap, super.DEFAULT_HEAP_PROT);

        self.stack_region.reset(region.RegionKind.Stack);
        self.stack_region.configure(super.STACK_TOP, region.RegionKind.Stack, super.DEFAULT_STACK_PROT);

        self.metadata_base = allocator.METADATA_REGION_START + idx * allocator.METADATA_REGION_BYTES;
        self.metadata_cursor = self.metadata_base;
        self.metadata_mapped = 0;
        self.metadata_page_count = 0;
        self.metadata_allocator.init(self);
        self.metadata_alloc_handle = self.metadata_allocator.allocator();
        self.page_map = PageMap.init(self.metadata_alloc_handle);
        self.mmap_regions = RegionList{};
    }

    fn releaseAllPages(self: *Self) void {
        var it = self.page_map.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.release();
        }
        self.page_map.clearRetainingCapacity();
        self.mapped_count = 0;
    }

    pub fn teardown(self: *Self) void {
        if (!self.initialised) {
            self.* = Self{};
            return;
        }
        self.releaseAllPages();
        self.page_map.deinit();
        self.mmap_regions.deinit(self.metadata_alloc_handle);
        self.metadata_allocator.deinit();
        self.* = Self{};
    }

    pub fn ensureMetadataMapped(self: *Client, target: usize) allocator.MetadataAllocError!void {
        while (self.metadata_base + self.metadata_mapped < target) {
            if (self.metadata_page_count >= allocator.METADATA_REGION_PAGES) {
                _ = c.printf("[vm_meta] region exhausted idx=%lu\n", @as(c_ulong, @intCast(self.metadataIndex())));
                return allocator.MetadataAllocError.OutOfMemory;
            }

            const frame_ref = sos.alloc_frame();
            if (frame_ref == 0) {
                _ = c.printf("[vm_meta] alloc_frame failed\n");
                return allocator.MetadataAllocError.OutOfMemory;
            }

            const frame_data_ptr: [*]u8 = @ptrCast(sos.frame_data(frame_ref));
            @memset(frame_data_ptr[0..super.PAGE_SIZE_4K], 0);

            const slot = sos.cspace_alloc_slot(&cspace);
            if (slot == sel4.seL4_CapNull) {
                sos.free_frame(frame_ref);
                _ = c.printf("[vm_meta] cspace_alloc_slot failed\n");
                return allocator.MetadataAllocError.OutOfMemory;
            }

            const src_cspace = sos.frame_table_cspace();
            const frame_cap = sos.frame_page(frame_ref);
            if (sos.cspace_copy(&cspace, slot, src_cspace, frame_cap, super.toSosRights(sel4.seL4_AllRights)) != sel4.seL4_NoError) {
                sos.cspace_free_slot(&cspace, slot);
                sos.free_frame(frame_ref);
                _ = c.printf("[vm_meta] cspace_copy failed\n");
                return allocator.MetadataAllocError.OutOfMemory;
            }

            const rights = super.toSosRights(region.rightsFromBooleans(true, true));
            const attrs = sel4.seL4_ARM_Default_VMAttributes | sel4.seL4_ARM_ExecuteNever;
            const vaddr = self.metadata_base + self.metadata_mapped;
            if (sos.map_frame(&cspace, slot, sel4.seL4_CapInitThreadVSpace, vaddr, rights, attrs) != sel4.seL4_NoError) {
                _ = sos.cspace_delete(&cspace, slot);
                sos.cspace_free_slot(&cspace, slot);
                sos.free_frame(frame_ref);
                _ = c.printf("[vm_meta] map_frame failed\n");
                return allocator.MetadataAllocError.OutOfMemory;
            }

            self.metadata_pages[self.metadata_page_count] = page.MetadataPage{
                .frame_ref = frame_ref,
                .cap_slot = slot,
                .vaddr = vaddr,
            };
            self.metadata_page_count += 1;
            self.metadata_mapped += super.PAGE_SIZE_4K;
        }
    }

    pub fn metadataIndex(self: *Client) usize {
        return (self.metadata_base - allocator.METADATA_REGION_START) / allocator.METADATA_REGION_BYTES;
    }
};

pub const PageMap = std.AutoHashMap(usize, MappedPage);
const MappedPage = page.MappedPage;
pub const RegionList = std.ArrayListUnmanaged(region.Region);

const region = @import("region.zig");
const page = @import("page.zig");
const allocator = @import("allocator.zig");
const super = @import("mod.zig");
const std = @import("std");

const cimports = @import("cimports");
const sel4 = cimports.sel4;
const c = cimports.c;
const sos = cimports.sos;

extern var cspace: sos.cspace_t;
