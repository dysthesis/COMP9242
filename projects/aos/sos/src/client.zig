pub const Client = struct {
    id: usize,
    io_state: *file.ClientIoState,
    vm_state: *vm.client.Client,

    pub fn fileTable(self: *Client) *file.FileTable {
        return &self.io_state.file_table;
    }

    pub fn ioState(self: *Client) *file.ClientIoState {
        return self.io_state;
    }

    pub fn vmState(self: *Client) *vm.Client {
        return self.vm_state;
    }
};

var contexts: [sos.MAX_CLIENTS]Client = undefined;
var contexts_initialised = false;

pub fn ensureInitialised() void {
    if (contexts_initialised) return;
    vm.bootstrapVmStates();
    var idx: usize = 0;
    while (idx < contexts.len) : (idx += 1) {
        contexts[idx] = Client{
            .id = idx,
            .io_state = &file.client_io_state[idx],
            .vm_state = &vm.vm_states[idx],
        };
    }
    contexts_initialised = true;
}

pub fn get(id: usize) ?*Client {
    ensureInitialised();
    if (id >= contexts.len) return null;
    return &contexts[id];
}

test "client contexts bootstrap" {
    ensureInitialised();
    try std.testing.expect(contexts_initialised);
    const ctx = get(0).?;
    try std.testing.expectEqual(@as(usize, 0), ctx.id);
    try std.testing.expect(ctx.io_state != null);
    try std.testing.expect(ctx.vm_state != null);
}
const std = @import("std");
const cimports = @import("cimports");
const sos = cimports.sos;

const file = @import("file.zig");
const vm = @import("vm/mod.zig");
