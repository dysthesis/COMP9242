#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <sel4/sel4.h>

#include "frame_table.h"
#include "ipc.h"

struct vm_handle;

struct vm_handle *vm_state_acquire(client_t *client);
struct vm_handle *vm_state_lookup(client_t *client);
void vm_state_release(client_t *client);

void vm_register_stack_mapping(struct vm_handle *handle, uintptr_t vaddr,
                               frame_ref_t frame_ref, seL4_CPtr cap_slot);
void vm_report_initial_stack(struct vm_handle *handle, uintptr_t mapped_bottom);
void vm_reset_state(struct vm_handle *handle);

bool handle_vm_fault(struct vm_handle *handle, seL4_Word badge,
                     const seL4_MessageInfo_t *message);
