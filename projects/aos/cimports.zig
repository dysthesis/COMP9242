pub const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdint.h");
    @cInclude("stddef.h");
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("string.h");
    @cInclude("file.h");
    @cInclude("networkconsole/networkconsole.h");
    @cInclude("clock/clock.h");
    @cInclude("clock/device.h");
    @cInclude("device.h");
    @cInclude("sys/mman.h");
    @cInclude("sel4/sel4.h");
    @cInclude("sel4/shared_types.h");
    @cInclude("sel4/sel4_arch/mapping.h");
    @cInclude("mapping.h");
    @cInclude("cspace/cspace.h");
    @cInclude("frame_table.h");
    @cInclude("ipc.h");
    @cInclude("utils/zf_log.h");
    @cInclude("utils/page.h");
});

pub const sel4 = @cImport({
    @cInclude("sel4/sel4.h");
    @cInclude("sel4/sel4_arch/mapping.h");
    @cInclude("sel4/shared_types.h");
});

pub const sos = @cImport({
    @cInclude("ipc.h");
    @cInclude("file.h");
    @cInclude("sos_time.h");
    @cInclude("vmem_layout.h");
    @cInclude("utils/page.h");
    @cInclude("ut.h");
    @cInclude("utils.h");
});

pub const sos_types = @cImport({
    @cInclude("sos.h");
});
