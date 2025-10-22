/// Map capability rights to a printable string representation
pub inline fn rightsStr(rights: sos.seL4_CapRights_t) [3:0]u8 {
    const read: u8 = if (sos.seL4_CapRights_get_capAllowRead(rights) != 0) 'r' else '-';
    const write: u8 = if (sos.seL4_CapRights_get_capAllowWrite(rights) != 0) 'w' else '-';
    const grant_bit = (sos.seL4_CapRights_get_capAllowGrant(rights) != 0) or
        (sos.seL4_CapRights_get_capAllowGrantReply(rights) != 0);
    const grant: u8 = if (grant_bit) 'g' else '-';
    return [3:0]u8{ read, write, grant };
}

const cimports = @import("cimports");
const sos = cimports.sos;
const c = cimports.c;
