const cimports = @import("cimports");
const sel4 = cimports.sel4;
const sos = cimports.sos;
const c = cimports.c;

const vm = @import("vm/mod.zig");

const VmFaultResult = vm.VmFaultResult;

pub export fn handle_vm_fault(
    vm_handle: *vm.VmHandle,
    badge: sel4.seL4_Word,
    message: [*c]const sel4.seL4_MessageInfo_t,
    have_reply: [*c]bool,
    reply: [*c]sel4.seL4_CPtr,
    reply_ut: [*c]*sos.ut_t,
) callconv(.c) VmFaultResult {
    _ = badge;
    _ = have_reply;
    _ = reply;
    _ = reply_ut;

    vm_handle.validate();

    const info = message.*;
    if (sel4.seL4_MessageInfo_get_label(info) != sel4.seL4_Fault_VMFault) {
        return .fatal;
    }

    if (sel4.seL4_MessageInfo_get_length(info) < 2) {
        _ = c.printf(
            "[vm_fault] unexpected length=%lu\n",
            @as(c_ulong, sel4.seL4_MessageInfo_get_length(info)),
        );
        return .fatal;
    }

    const fault_addr_word = sel4.seL4_GetMR(sel4.seL4_VMFault_Addr);
    const fsr = sel4.seL4_GetMR(sel4.seL4_VMFault_FSR);
    const prefetch = sel4.seL4_GetMR(sel4.seL4_VMFault_PrefetchFault) != 0;
    const fault_addr: usize = @intCast(fault_addr_word);
    const want_write = (fsr & (1 << 6)) != 0;

    const addr_raw: c_ulong = @intCast(fault_addr);
    const fsr_raw: c_ulong = @intCast(fsr);
    _ = c.printf(
        "[vm_fault] addr=0x%lx fsr=0x%lx write=%d fetch=%d\n",
        @as(c_ulong, addr_raw),
        @as(c_ulong, fsr_raw),
        @as(c_int, if (want_write) 1 else 0),
        @as(c_int, if (prefetch) 1 else 0),
    );

    vm_handle.handleFault(fault_addr, want_write, prefetch) catch |err| {
        _ = c.printf("[vm_fault] handler error=%d\n", vm.vmErrorToErrno(err));
        return .fatal;
    };

    return .handled;
}
