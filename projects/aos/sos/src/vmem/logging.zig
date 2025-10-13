pub const VmLogger = struct {
    /// Label for the logger
    scope: [*:0]const u8,

    /// Writer for the logs
    fn writer(comptime fmt: [*:0]const u8, args: anytype) void {
        _ = c.printf(fmt, args);
    }

    /// Map capability rights to a printable string representation
    pub inline fn rightsStr(rights: sel4.seL4_CapRights_t) [3:0]u8 {
        const read: u8 = if (sel4.seL4_CapRights_get_capAllowRead(rights) != 0) 'r' else '-';
        const write: u8 = if (sel4.seL4_CapRights_get_capAllowWrite(rights) != 0) 'w' else '-';
        const grant_bit = (sel4.seL4_CapRights_get_capAllowGrant(rights) != 0) or
            (sel4.seL4_CapRights_get_capAllowGrantReply(rights) != 0);
        const grant: u8 = if (grant_bit) 'g' else '-';
        return [3:0]u8{ read, write, grant };
    }

    /// Log an attempt to map a virtual address
    pub inline fn logMapAttempt(
        self: *const VmLogger,
        /// Description of what is being mapped
        what: [*:0]const u8,
        /// Virtual address being mapped
        vaddr: sel4.seL4_Word,
        /// Capability used to perform the operation
        rights: sel4.seL4_CapRights_t,
        /// Virtual memory attributes
        vm_attr: sel4.seL4_ARM_VMAttributes,
    ) void {
        const rights_str = rightsStr(rights);
        const rights_str_c: [*:0]const u8 = @ptrCast(&rights_str);

        self.writer(
            "[map try] %s %s vaddr=0x%lx rights=%s attr=0x%lx\n",
            self.scope,
            what,
            @as(c_ulong, vaddr),
            rights_str_c,
            @as(c_ulong, vm_attr),
        );
    }
    /// Log mapping failure
    pub inline fn logMapFail(
        self: *const VmLogger,
        /// Description of what is being mapped
        what: [*:0]const u8,
        /// Virtual address being mapped
        vaddr: sel4.seL4_Word,
        /// Resulting error
        err: sel4.seL4_Error,
    ) void {
        const level: c_int = sel4.seL4_MappingFailedLookupLevel();
        self.writer("[map failed] %s %s vaddr=%p err=%d missing_level=L%d\n", self.scope, what, @as(c_ulong, vaddr), err, level);
    }
};

const cimports = @import("cimports");
const sel4 = cimports.sel4;
const c = cimports.c;
