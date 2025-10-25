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
    addr_space: AddrSpace = undefined,

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

    pub const Self = @This();

    pub fn findPage(self: *Self, vaddr: usize) ?*page.MappedPage {
        return self.addr_space.getPtr(vaddr);
    }

    pub fn insertPage(
        self: *Self,
        vaddr: usize,
        frame_ref: usize,
        cap_slot: sel4.seL4_CPtr,
        cap_owner: ?*sos.cspace_t,
        owns_frame: bool,
        owns_cap: bool,
    ) super.VmError!*page.MappedPage {
        if (owns_cap and cap_owner == null) {
            _ = c.printf("[vm_map] insertPage missing cap_owner for vaddr=0x%lx\n", @as(c_ulong, @intCast(vaddr)));
            return super.VmError.InvalidArgs;
        }
        if (self.addr_space.getPtr(vaddr)) |entry| {
            entry.frame_ref = frame_ref;
            entry.cap_slot = cap_slot;
            entry.cap_owner = cap_owner;
            entry.owns_frame = owns_frame;
            entry.owns_cap = owns_cap;
            return entry;
        }

        self.addr_space.put(vaddr, page.MappedPage{
            .frame_ref = frame_ref,
            .cap_slot = cap_slot,
            .cap_owner = cap_owner,
            .owns_frame = owns_frame,
            .owns_cap = owns_cap,
        }) catch {
            return super.VmError.Capacity;
        };
        self.mapped_count = self.addr_space.num_mapped();
        return self.addr_space.getPtr(vaddr).?;
    }

    fn isLegalUserMapping(self: *Client, base: usize) bool {
        // inside configured heap band and below the current break.
        if (base >= super.HEAP_BASE and base < self.heap_break) return true;

        // strictly between guard and top (guard page itself is illegal).
        const min_stack = self.stack_guard + super.PAGE_SIZE_4K;
        if (base >= min_stack and base < self.stack_top) return true;

        // any address covered by a declared RegionKind.Mmap.
        if (self.findMmapRegion(base) != null) return true;

        // everything else is out of policy.
        return false;
    }

    pub fn mapAnonymousPage(self: *Self, handle: *super.VmHandle, vaddr: usize, tracker: *region.Region) super.VmError!void {
        if (!tracker.used) {
            return super.VmError.InvalidArgs;
        }

        if (!self.isLegalUserMapping(super.pageBase(vaddr))) {
            return super.VmError.Bounds;
        }

        const caller = handle.getClient();

        const prot_flags = tracker.prot();
        const readable = (prot_flags & sos.PROT_READ) != 0;
        const writable = (prot_flags & sos.PROT_WRITE) != 0;
        const executable = (prot_flags & sos.PROT_EXEC) != 0;

        _ = c.printf("[vm_map] enter caller=0x%lx vaddr=0x%lx read=%d write=%d exec=%d mapped_count=%lu\n", @as(c_ulong, @intCast(@intFromPtr(caller))), @as(c_ulong, @intCast(vaddr)), @as(c_int, if (readable) 1 else 0), @as(c_int, if (writable) 1 else 0), @as(c_int, if (executable) 1 else 0), @as(c_ulong, @intCast(self.mapped_count)));

        if (self.findPage(vaddr) != null) {
            _ = c.printf("[vm_map] already mapped vaddr=0x%lx\n", @as(c_ulong, @intCast(vaddr)));
            return;
        }

        const proc_vspace = sos.client_get_vspace(caller);
        if (proc_vspace == 0) {
            return super.VmError.ClientContext;
        }

        const frame_ref = sos.alloc_frame();
        if (frame_ref == 0) {
            _ = c.printf("[vm_map] alloc_frame failed caller=0x%lx\n", @as(c_ulong, @intCast(@intFromPtr(caller))));
            return super.VmError.OutOfFrames;
        }
        _ = c.printf("[vm_map] alloc_frame ok frame_ref=%lu\n", @as(c_ulong, @intCast(frame_ref)));

        const frame_raw = sos.frame_data(frame_ref);
        const frame_bytes = @as([*]u8, @ptrCast(frame_raw));
        @memset(frame_bytes[0..super.PAGE_SIZE_4K], 0);
        _ = c.printf("[vm_map] cleared frame_data addr=0x%lx size=%lu\n", @as(c_ulong, @intCast(@intFromPtr(frame_raw))), @as(c_ulong, @intCast(super.PAGE_SIZE_4K)));

        const slot = sos.cspace_alloc_slot(&cspace);
        if (slot == sel4.seL4_CapNull) {
            sos.free_frame(frame_ref);
            _ = c.printf("[vm_map] cspace_alloc_slot failed frame_ref=%lu\n", @as(c_ulong, @intCast(frame_ref)));
            return super.VmError.OutOfSlots;
        }
        _ = c.printf("[vm_map] allocated slot=%lu owner_cspace=0x%lx\n", @as(c_ulong, @intCast(slot)), @as(c_ulong, @intCast(@intFromPtr(&cspace))));
        _ = c.printf("[vm_map] allocated slot=%lu for frame_ref=%lu\n", @as(c_ulong, @intCast(slot)), @as(c_ulong, @intCast(frame_ref)));

        const src_cspace = sos.frame_table_cspace();
        const frame_cap = sos.frame_page(frame_ref);
        const copy_err = sos.cspace_copy(&cspace, slot, src_cspace, frame_cap, sos.seL4_AllRights);
        if (copy_err != sel4.seL4_NoError) {
            _ = sos.cspace_free_slot(&cspace, slot);
            sos.free_frame(frame_ref);
            const copy_err_i32: c_int = @intCast(copy_err);
            _ = c.printf("[vm_map] cspace_copy failed err=%d slot=%lu frame_ref=%lu\n", copy_err_i32, @as(c_ulong, @intCast(slot)), @as(c_ulong, @intCast(frame_ref)));
            return super.VmError.MapFailed;
        }
        _ = c.printf("[vm_map] copied frame cap slot=%lu frame_ref=%lu\n", @as(c_ulong, @intCast(slot)), @as(c_ulong, @intCast(frame_ref)));

        const rights = region.rightsFromBooleans(readable, writable);
        var attrs = sel4.seL4_ARM_Default_VMAttributes;
        if (!executable) {
            attrs = attrs | sel4.seL4_ARM_ExecuteNever;
        }

        self.addr_space.mapFrame(slot, vaddr, rights, attrs) catch |err| {
            _ = sos.cspace_delete(&cspace, slot);
            _ = sos.cspace_free_slot(&cspace, slot);
            sos.free_frame(frame_ref);
            _ = c.printf("[vm_map] map_frame failed err=%d slot=%lu frame_ref=%lu vaddr=0x%lx\n", super.vmErrorToErrno(err), @as(c_ulong, @intCast(slot)), @as(c_ulong, @intCast(frame_ref)), @as(c_ulong, @intCast(vaddr)));
            return super.VmError.MapFailed;
        };
        _ = c.printf("[vm_map] map_frame success slot=%lu frame_ref=%lu vaddr=0x%lx\n", @as(c_ulong, @intCast(slot)), @as(c_ulong, @intCast(frame_ref)), @as(c_ulong, @intCast(vaddr)));

        _ = self.insertPage(vaddr, frame_ref, slot, &cspace, true, true) catch |err| {
            if (err == super.VmError.Capacity) {
                const meta_used = self.metadata_cursor - self.metadata_base;
                _ = c.printf("[vm_meta] capacity hit vaddr=0x%lx mapped_count=%lu used_bytes=%lu limit_bytes=%lu pages=%lu\n", @as(c_ulong, @intCast(vaddr)), @as(c_ulong, @intCast(self.mapped_count)), @as(c_ulong, @intCast(meta_used)), @as(c_ulong, @intCast(allocator.METADATA_REGION_BYTES)), @as(c_ulong, @intCast(self.metadata_page_count)));
            }
            _ = sos.cspace_delete(&cspace, slot);
            _ = sos.cspace_free_slot(&cspace, slot);
            sos.free_frame(frame_ref);
            return err;
        };
        self.mapped_count = self.addr_space.num_mapped();
        // self.addr_space.recordLeafMap(vaddr);

        _ = c.printf("[vm_map] recorded mapping vaddr=0x%lx frame_ref=%lu slot=%lu new_mapped_count=%lu\n", @as(c_ulong, @intCast(vaddr)), @as(c_ulong, @intCast(frame_ref)), @as(c_ulong, @intCast(slot)), @as(c_ulong, @intCast(self.mapped_count)));

        tracker.updateAccess(readable, writable, executable);
        tracker.recordMapping(vaddr, super.PAGE_SIZE_4K);

        switch (tracker.attr.kind) {
            .Stack => {
                if (tracker.start < self.stack_low) {
                    self.stack_low = tracker.start;
                }
            },
            .Heap => {
                if (tracker.end > self.heap_mapped_end) {
                    self.heap_mapped_end = tracker.end;
                }
            },
            else => {},
        }
    }

    pub fn mapOwnedFrame(
        self: *Self,
        vaddr: usize,
        frame_ref: usize,
        cap_slot: sel4.seL4_CPtr,
        readable: bool,
        writable: bool,
        executable: bool,
        owns_frame: bool,
        owns_cap: bool,
    ) super.VmError!void {
        const rights = region.rightsFromBooleans(readable, writable);
        var attrs = sel4.seL4_ARM_Default_VMAttributes;
        if (!executable) {
            attrs |= sel4.seL4_ARM_ExecuteNever;
        }

        try mapping.map_owned_frame(&self.addr_space, cap_slot, vaddr, rights, attrs);

        _ = self.insertPage(vaddr, frame_ref, cap_slot, &super.cspace, owns_frame, owns_cap) catch |err| {
            self.addr_space.recordLeafUnmap(vaddr);
            const unmap_err = sel4.seL4_ARM_Page_Unmap(cap_slot);
            if (unmap_err != sel4.seL4_NoError) {
                _ = c.printf("[vm_map_owned] rollback Page_Unmap err=%d slot=%lu\n", @as(c_int, @intCast(unmap_err)), @as(c_ulong, @intCast(cap_slot)));
            }
            if (owns_cap) {
                _ = sos.cspace_delete(&cspace, cap_slot);
                sos.cspace_free_slot(&cspace, cap_slot);
            }
            if (owns_frame and frame_ref != 0) {
                sos.free_frame(frame_ref);
            }
            return err;
        };

        self.mapped_count = self.addr_space.num_mapped();
    }

    pub fn metadataAllocator(self: *Client) std.mem.Allocator {
        return self.metadata_alloc_handle;
    }

    pub fn init(self: *Self, idx: usize, cl: *sos.client_t) !void {
        _ = c.printf("[vm_client] entered Client.init...\n");
        self.initialised = true;
        self.heap_break = super.HEAP_BASE;
        self.heap_mapped_end = super.HEAP_BASE;
        self.mmap_next = super.MMAP_BASE;
        self.stack_guard = super.STACK_GUARD_BASE;
        self.stack_low = super.STACK_TOP;
        self.stack_top = super.STACK_TOP;
        self.mapped_count = 0;
        self.active_mmaps = 0;

        _ = c.printf("[vm_client] setting up heap...\n");
        self.heap_region.reset(region.RegionKind.Heap);
        self.heap_region.configure(super.HEAP_BASE, region.RegionKind.Heap, super.DEFAULT_HEAP_PROT);
        _ = c.printf("[vm_client] heap ready!\n");

        _ = c.printf("[vm_client] setting up stack...\n");
        self.stack_region.reset(region.RegionKind.Stack);
        self.stack_region.configure(super.STACK_TOP, region.RegionKind.Stack, super.DEFAULT_STACK_PROT);
        _ = c.printf("[vm_client] stack ready!\n");

        self.metadata_base = allocator.METADATA_REGION_START + idx * allocator.METADATA_REGION_BYTES;
        self.metadata_cursor = self.metadata_base;
        self.metadata_mapped = 0;
        self.metadata_page_count = 0;
        self.metadata_allocator.init(self);
        _ = c.printf("[vm_client] setting up allocator...\n");
        self.metadata_alloc_handle = self.metadata_allocator.allocator();
        _ = c.printf("[vm_client] allocator ready!\n");

        _ = c.printf("[vm_client] setting up process vspace...\n");
        const proc_vspace: sel4.seL4_CPtr = sos.client_get_vspace(cl);
        if (proc_vspace == 0) {
            _ = c.printf("[vm_client] error: client_get_vspace for client with ID %d and generation %d returned %d\n", cl.id, cl.gen, proc_vspace);
            return error.ClientContext;
        }
        _ = c.printf("[vm_client] process vspace ready!\n");

        _ = c.printf("[vm_client] initialising client address space...\n");
        self.addr_space = try AddrSpace.init(self.metadataAllocator(), &cspace, proc_vspace);
        _ = c.printf("[vm_client] address space ready!\n");
    }

    fn releaseAllPages(self: *Self) void {
        var it = self.addr_space.iterator();
        while (it.next()) |kv| {
            const vaddr = kv.key_ptr.*;
            self.addr_space.recordLeafUnmap(vaddr);
            kv.value_ptr.release(); // unmap frame cap and free frame
        }
        self.addr_space.clearRetainingCapacity();
        self.mapped_count = 0;
        if (self.addr_space.hasLivePagingNodes()) {
            _ = c.printf("[vm_teardown] warning: paging nodes remain after release\n");
        }
    }

    pub fn teardown(self: *Self) void {
        if (!self.initialised) {
            self.* = Self{};
            return;
        }
        self.releaseAllPages();
        self.addr_space.deinit();
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
            if (sos.cspace_copy(&cspace, slot, src_cspace, frame_cap, sos.seL4_AllRights) != sel4.seL4_NoError) {
                sos.cspace_free_slot(&cspace, slot);
                sos.free_frame(frame_ref);
                _ = c.printf("[vm_meta] cspace_copy failed\n");
                return allocator.MetadataAllocError.OutOfMemory;
            }

            const rights = region.rightsFromBooleans(true, true);
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

    pub fn leaseMmapRegion(self: *Self, base: usize, prot: c_int) super.VmError!*region.Region {
        if (self.active_mmaps >= super.MAX_MMAP_REGIONS) {
            _ = c.printf("[vm_mmap] no free region slots (active=%lu, max=%lu)\n", @as(c_ulong, @intCast(self.active_mmaps)), @as(c_ulong, @intCast(super.MAX_MMAP_REGIONS)));
            return super.VmError.Capacity;
        }

        const A = self.addr_space.alloc;
        var node = A.create(RegionNode) catch {
            _ = c.printf("[vm_mmap] alloc RegionNode failed\n");
            return super.VmError.Capacity;
        };
        errdefer A.destroy(node);

        node.* = .{ .rb = undefined, .reg = .{} };
        node.reg.reset(region.RegionKind.Mmap);
        node.reg.configure(base, region.RegionKind.Mmap, prot);

        if (self.addr_space.findRegion(base)) |exist| {
            if (exist.reg.contains(base)) {
                _ = c.printf("[vm_mmap] base 0x%lx lies inside an existing region [0x%lx, 0x%lx)\n", @as(c_ulong, @intCast(base)), @as(c_ulong, @intCast(exist.reg.start)), @as(c_ulong, @intCast(exist.reg.end)));
                return super.VmError.InvalidArgs;
            }
        }

        self.addr_space.insertRegion(node, false) catch |e| {
            const name = @errorName(e); // []const u8
            _ = c.printf("[vm_mmap] insertRegion failed (%.*s) base=0x%lx\n", @as(c_int, @intCast(name.len)), name.ptr, @as(c_ulong, @intCast(base)));
            return super.VmError.InvalidArgs;
        };

        self.active_mmaps += 1;
        return &node.reg;
    }

    pub fn releaseMmapRegion(self: *Self, tracker: *region.Region) void {
        if (!tracker.used) return;

        const node: *RegionNode = @alignCast(@fieldParentPtr("reg", tracker));

        self.addr_space.removeRegion(node);
        self.addr_space.alloc.destroy(node);
        if (self.active_mmaps > 0) self.active_mmaps -= 1;
    }

    pub fn findMmapRegion(self: *Self, addr: usize) ?*region.Region {
        const node = self.addr_space.findRegion(addr) orelse return null;
        const reg = &node.reg;

        if (reg.attr.kind == region.RegionKind.Mmap and reg.contains(addr)) {
            return reg;
        }
        return null;
    }
};

pub const AddrSpace = @import("addr_space.zig").AddrSpace;
pub const RegionNode = @import("addr_space.zig").RegionNode;

const region = @import("region.zig");
const page = @import("page.zig");
const allocator = @import("allocator.zig");
const super = @import("mod.zig");
const std = @import("std");
const mapping = @import("mapping.zig");

const cimports = @import("cimports");
const sel4 = cimports.sel4;
const c = cimports.c;
const sos = cimports.sos;

extern fn sos_metadata_base_runtime() usize;

extern var cspace: sos.cspace_t;
