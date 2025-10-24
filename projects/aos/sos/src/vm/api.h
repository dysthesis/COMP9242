#pragma once

#include <sel4/sel4.h>
#include <stdbool.h>
#include <stdint.h>

#include "frame_table.h"
#include "ipc.h"

struct vm_handle;

struct vm_handle *vm_state_acquire(client_t *client);
struct vm_handle *vm_state_lookup(client_t *client);
void vm_state_release(client_t *client);

void vm_register_stack_mapping(struct vm_handle *handle, uintptr_t vaddr,
                               frame_ref_t frame_ref, seL4_CPtr cap_slot);
void vm_report_initial_stack(struct vm_handle *handle, uintptr_t mapped_bottom);

int vm_register_elf_mapping(struct vm_handle *handle, uintptr_t vaddr,
                            frame_ref_t frame_ref, seL4_CPtr cap_slot,
                            bool readable, bool writable, bool executable);

uint8_t *vm_get_user_page_data(struct vm_handle *handle, uintptr_t user_vaddr);

void vm_reset_state(struct vm_handle *handle);

bool handle_vm_fault(struct vm_handle *handle, seL4_Word badge,
                     const seL4_MessageInfo_t *message);

uintptr_t sos_metadata_base_runtime(void);
