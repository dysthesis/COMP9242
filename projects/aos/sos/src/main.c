/*
 * Copyright 2019, Data61
 * Commonwealth Scientific and Industrial Research Organisation (CSIRO)
 * ABN 41 687 119 230.
 *
 * This software may be distributed and modified according to the terms of
 * the GNU General Public License version 2. Note that NO WARRANTY is provided.
 * See "LICENSE_GPLv2.txt" for details.
 *
 * @TAG(DATA61_GPL)
 */
#include <assert.h>
#include <autoconf.h>
#include <errno.h>
#include <fcntl.h>
#include <ipc.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <utils/util.h>

#include <aos/debug.h>
#include <aos/sel4_zf_logif.h>
#include <cspace/cspace.h>

#include <clock/clock.h>
#include <cpio/cpio.h>
#include <elf/elf.h>
#include <networkconsole/networkconsole.h>

#include <sel4runtime.h>
#include <sel4runtime/auxv.h>

#include "bootstrap.h"
#include "continuation.h"
#include "drivers/uart.h"
#include "elfload.h"
#include "file.h"
#include "frame_table.h"
#include "ipc_common.h"
#include "irq.h"
#include "mapping.h"
#include "network.h"
#include "pagefile.h"
#include "sel4/bootinfo_types.h"
#include "sel4/simple_types.h"
#include "syscalls.h"
#include "tests.h"
#include "threads.h"
#include "ut.h"
#include "utils.h"
#include "vm/api.h"
#include "vmem_layout.h"
#include <sos/gen_config.h>
#ifdef CONFIG_SOS_GDB_ENABLED
#include "debugger.h"
#endif /* CONFIG_SOS_GDB_ENABLED */

#include <aos/vsyscall.h>

/* Import Zig delegation handler */
extern seL4_MessageInfo_t delegationHandleRequest(seL4_Word badge,
                                                  seL4_MessageInfo_t message);

/* Import Zig worker init */
extern void worker_init(seL4_CPtr delegate_ep, seL4_CPtr work_ntfn);

/* Import Zig NFS handler init */
extern void nfs_handler_init(void);

/* Poll asynchronous file operations */
extern void checkCompletedFileOps(void);
/*
 * To differentiate between signals from notification objects and and IPC
 * messages, we assign a badge to the notification object. The badge that we
 * receive will be the bitwise 'OR' of the notification object badge and the
 * badges of all pending IPC messages.
 *
 * All badged IRQs set high bit, then we use unique bits to
 * distinguish interrupt sources.
 * Delegation IPC uses second-highest bit.
 */
#define IRQ_EP_BADGE BIT(seL4_BadgeBits - 1ul)
#define IRQ_IDENT_BADGE_BITS MASK(seL4_BadgeBits - 1ul)
#define DELEGATE_EP_BADGE (1UL << 30)

#define APP_NAME "vm_test"
#define APP_PRIORITY (0)
#define APP_EP_BADGE (101)

/* The number of additional stack pages to provide to the initial
 * process */
#define INITIAL_PROCESS_EXTRA_STACK_PAGES 4

/* Network console handle for SOS console output */
struct network_console *sos_nc;

/*
 * A dummy starting syscall
 */
#define SOS_SYSCALL0 0

/* The linker will link this symbol to the start address  *
 * of an archive of attached applications.                */
extern char _cpio_archive[];
extern char _cpio_archive_end[];
extern char __eh_frame_start[];
/* provided by gcc */
extern void(__register_frame)(void *);

/* root tasks cspace */
cspace_t cspace;

static seL4_CPtr sched_ctrl_start;
static seL4_CPtr sched_ctrl_end;

client_t *clients[MAX_CLIENTS];   // client bookkeeping for IPC
uint8_t generations[MAX_CLIENTS]; // keep track of the current generation
                                  // number for each client ID to prevent
                                  // UAF of old, deallocated badges
uint16_t free_ids[MAX_CLIENTS];   // free IDs for new clients
size_t free_top;

/* the one process we start */
static struct {
  ut_t *tcb_ut;
  seL4_CPtr tcb;
  ut_t *vspace_ut;
  seL4_CPtr vspace;
  client_t *client;
  seL4_Word badge;

  frame_ref_t ipc_buffer_frame;
  seL4_CPtr ipc_buffer;
  bool ipc_buffer_vm_owned;

  ut_t *sched_context_ut;
  seL4_CPtr sched_context;

  cspace_t cspace;

  frame_ref_t stack_frames[INITIAL_PROCESS_EXTRA_STACK_PAGES + 1];
  seL4_CPtr stack_slots[INITIAL_PROCESS_EXTRA_STACK_PAGES + 1];
  size_t stack_frame_count;
  seL4_CPtr fault_ep_slot;
} user_process;

/* Temporary helpers until a general VM subsystem is in place. */
seL4_CPtr client_get_vspace(client_t *client) {
  printf("[client_get_vspace] client=%p user_client=%p id=%d/%d gen=%u/%u "
         "vspace=%#lx\n",
         (void *)client, (void *)user_process.client, client ? client->id : -1,
         user_process.client ? user_process.client->id : -1,
         client ? client->gen : 0,
         user_process.client ? user_process.client->gen : 0,
         (unsigned long)user_process.vspace);

  if (client && user_process.client && client->id == user_process.client->id &&
      client->gen == user_process.client->gen) {
    return user_process.vspace;
  }
  return seL4_CapNull;
}

cspace_t *client_get_cspace(client_t *client) {
  if (client && user_process.client && client->id == user_process.client->id &&
      client->gen == user_process.client->gen) {
    return &user_process.cspace;
  }
  return NULL;
}

// ZIG FUNCTION STUBS

seL4_MessageInfo_t handle_syscall(seL4_Word badge,
                                  const seL4_MessageInfo_t *message,
                                  bool *have_reply, client_t *caller,
                                  seL4_CPtr *reply, ut_t **reply_ut);

// END OF ZIG FUNCTION STUBS

NORETURN void syscall_loop(seL4_CPtr ep) {
  seL4_CPtr reply;

  /* Create reply object */
  ut_t *reply_ut = alloc_retype(&reply, seL4_ReplyObject, seL4_ReplyBits);
  if (reply_ut == NULL) {
    ZF_LOGF("Failed to alloc reply object ut");
  }

  bool have_reply = false;
  seL4_MessageInfo_t reply_msg = seL4_MessageInfo_new(0, 0, 0, 0);

  while (1) {
    // Flush pending operations
    checkCompletedFileOps();

    seL4_Word badge = 0;
    seL4_MessageInfo_t message;

    /* Reply (if there is a reply) and block on ep, waiting for an IPC
     * sent over ep, or a notification from our bound notification object */
    if (have_reply) {
      message = seL4_ReplyRecv(ep, reply_msg, &badge, reply);
    } else {
      message = seL4_Recv(ep, &badge, reply);
    }

    /* Awake! We got a message - check the label and badge to
     * see what the message is about */
    seL4_Word label = seL4_MessageInfo_get_label(message);
    // printf("[sos] msg label=%lu len=%lu badge=0x%lx\n", label,
    // seL4_MessageInfo_get_length(message), badge);

    if (badge & IRQ_EP_BADGE) {
      /* It's a notification from our bound notification
       * object! */
      sos_handle_irq_notification(&badge, &have_reply);
    } else if (badge & DELEGATE_EP_BADGE) {
      /* Delegation IPC from worker thread */
      reply_msg = delegationHandleRequest(badge, message);
      have_reply = true;
    } else if (label == seL4_Fault_NullFault ||
               label == seL4_Fault_UnknownSyscall) {
      client_t *caller = client_lookup(badge);
      if (!caller) {
        ZF_LOGE("Unknown/stale caller badge=0x%lx", (unsigned long)badge);
        have_reply = false;
        continue;
      }

      /* It's not a fault or an interrupt, it must be an IPC
       * message from console_test! */
      reply_msg = handle_syscall(badge, &message, &have_reply, caller, &reply,
                                 &reply_ut);
    } else if (label == seL4_Fault_VMFault) {
      client_t *caller = client_lookup(badge);
      if (!caller) {
        ZF_LOGE("Unknown/stale caller badge=0x%lx", (unsigned long)badge);
        have_reply = false;
        continue;
      }

      struct vm_handle *vm = caller->vm_state;
      if (vm == NULL) {
        vm = vm_state_lookup(caller);
        if (vm == NULL) {
          ZF_LOGE("VM state missing for caller badge=0x%lx",
                  (unsigned long)badge);
          have_reply = false;
          continue;
        }
        caller->vm_state = vm;
      }

      vm_fault_result_t fault_result =
          handle_vm_fault(vm, badge, &message, &have_reply, &reply, &reply_ut);

      switch (fault_result) {
      case VM_FAULT_HANDLED:
        reply_msg = seL4_MessageInfo_new(0, 0, 0, 0);
        have_reply = true;
        continue;

      case VM_FAULT_DEFERRED:
        ZF_LOGD("Deferred VM fault for badge=0x%lx (reply=%#lx ut=%p)",
                (unsigned long)badge, (unsigned long)reply, (void *)reply_ut);
        assert(!have_reply);
        assert(reply_ut != NULL);
        continue;

      case VM_FAULT_FATAL:
      default:
        break;
      }

      goto fault_log;
    } else {
    fault_log:;
      sos_ipc_msg_t ipc_msg;
      if (sos_deserialise_ipc_msg(&message, &ipc_msg) == 0) {
        // inspect the IPC message received if we can
        printf("[sos] syscall_loop(fault): badge -> %lu\n",
               (unsigned long)badge);
        printf("[sos] syscall_loop(fault): sysno -> %lu\n",
               (unsigned long)(sos_sysno_t)ipc_msg.sysno);
        printf("[sos] syscall_loop(fault): arg -> %lu\n",
               (unsigned long)ipc_msg.arg);
        printf("[sos] syscall_loop(fault): buf_addr -> %lx\n",
               (unsigned long)ipc_msg.buf_addr);
        printf("[sos] syscall_loop(fault): buf_size -> %lu\n",
               (unsigned long)ipc_msg.buf_size);
      }
      /* some kind of fault */
      debug_print_fault(message, APP_NAME);
      /* dump registers too */
      debug_dump_registers(user_process.tcb);
      /* Don't reply and recv on nothing */
      have_reply = false;

      ZF_LOGF("The SOS skeleton does not know how to handle faults!");
    }
  }
}

static int stack_write(seL4_Word *mapped_stack, int index, uintptr_t val) {
  mapped_stack[index] = val;
  return index - 1;
}

static void cleanup_stack_frames(void) {
  bool use_vm_reset =
      user_process.client != NULL && user_process.client->vm_state != NULL;

  if (use_vm_reset) {
    vm_reset_state(user_process.client->vm_state);
  } else {
    while (user_process.stack_frame_count > 0) {
      user_process.stack_frame_count--;
      frame_ref_t frame =
          user_process.stack_frames[user_process.stack_frame_count];
      seL4_CPtr slot = user_process.stack_slots[user_process.stack_frame_count];

      if (slot != seL4_CapNull) {
        seL4_Error err = seL4_ARM_Page_Unmap(slot);
        if (err != seL4_NoError) {
          ZF_LOGW("Failed to unmap stack slot %zu (err=%d)",
                  user_process.stack_frame_count, err);
        }
        err = cspace_delete(&cspace, slot);
        if (err != seL4_NoError) {
          ZF_LOGW("Failed to delete stack slot %zu (err=%d)",
                  user_process.stack_frame_count, err);
        }
        cspace_free_slot(&cspace, slot);
      }

      if (frame != NULL_FRAME) {
        free_frame(frame);
      }
    }
  }

  user_process.stack_frame_count = 0;
  for (size_t i = 0; i < ARRAY_SIZE(user_process.stack_frames); i++) {
    user_process.stack_frames[i] = NULL_FRAME;
    user_process.stack_slots[i] = seL4_CapNull;
  }
}

static void release_ipc_buffer_manual(void) {
  if (user_process.ipc_buffer != seL4_CapNull) {
    seL4_Error err = cspace_delete(&cspace, user_process.ipc_buffer);
    if (err != seL4_NoError) {
      ZF_LOGW("Failed to delete IPC buffer slot (err=%d)", err);
    }
    cspace_free_slot(&cspace, user_process.ipc_buffer);
    user_process.ipc_buffer = seL4_CapNull;
  }
  if (user_process.ipc_buffer_frame != NULL_FRAME) {
    free_frame(user_process.ipc_buffer_frame);
    user_process.ipc_buffer_frame = NULL_FRAME;
  }
  user_process.ipc_buffer_vm_owned = false;
}

static int map_process_stack_page(uintptr_t vaddr) {
  if (user_process.stack_frame_count >= ARRAY_SIZE(user_process.stack_frames)) {
    ZF_LOGE("Stack frame tracking overflow");
    return -1;
  }

  frame_ref_t frame = alloc_frame(FRAME_OWNER_USER, FRAME_FLAG_EVICTABLE);
  if (frame == NULL_FRAME) {
    ZF_LOGE("Failed to allocate stack frame");
    return -1;
  }

  unsigned char *bytes = frame_data(frame);
  memset(bytes, 0, PAGE_SIZE_4K);

  seL4_CPtr slot = cspace_alloc_slot(&cspace);
  if (slot == seL4_CapNull) {
    free_frame(frame);
    ZF_LOGE("Failed to allocate slot for stack frame");
    return -1;
  }

  seL4_Error err = cspace_copy(&cspace, slot, frame_table_cspace(),
                               frame_page(frame), seL4_AllRights);
  if (err != seL4_NoError) {
    cspace_free_slot(&cspace, slot);
    free_frame(frame);
    ZF_LOGE("Failed to copy stack frame cap");
    return -1;
  }

  struct vm_handle *vm_handle =
      (user_process.client && user_process.client->vm_state)
          ? user_process.client->vm_state
          : NULL;
  if (vm_handle != NULL) {
    int vm_err = vm_map_owned_frame(vm_handle, vaddr, frame, slot, true, true,
                                    false, true, true);
    if (vm_err < 0) {
      if (vm_err == -EEXIST) {
        ZF_LOGE("Stack frame already mapped at %p", (void *)vaddr);
      } else {
        ZF_LOGE("VM stack map failed for %p errno=%d", (void *)vaddr, -vm_err);
      }
      cspace_delete(&cspace, slot);
      cspace_free_slot(&cspace, slot);
      free_frame(frame);
      return -1;
    }
  } else {
    seL4_CapRights_t rights = seL4_CapRights_new(0, 0, 1, 1);
    err = map_frame(&cspace, slot, user_process.vspace, vaddr, rights,
                    seL4_ARM_Default_VMAttributes);
    if (err != seL4_NoError) {
      cspace_delete(&cspace, slot);
      cspace_free_slot(&cspace, slot);
      free_frame(frame);
      ZF_LOGE("Unable to map stack frame for user app");
      return -1;
    }
  }

  if (user_process.client == NULL || user_process.client->vm_state == NULL) {
    ZF_LOGE("Missing VM handle while recording stack mapping");
  } else {
    vm_register_stack_mapping(user_process.client->vm_state, vaddr, frame,
                              slot);
  }

  user_process.stack_frames[user_process.stack_frame_count] = frame;
  user_process.stack_slots[user_process.stack_frame_count] = slot;
  user_process.stack_frame_count++;
  return 0;
}

/* set up System V ABI compliant stack, so that the process can
 * start up and initialise the C library */
static uintptr_t init_process_stack(cspace_t *cspace, seL4_CPtr local_vspace,
                                    elf_t *elf_file) {
  user_process.stack_frame_count = 0;
  for (size_t i = 0; i < ARRAY_SIZE(user_process.stack_frames); i++) {
    user_process.stack_frames[i] = NULL_FRAME;
    user_process.stack_slots[i] = seL4_CapNull;
  }

  /* virtual addresses in the target process' address space */
  uintptr_t stack_top = PROCESS_STACK_TOP & ~((uintptr_t)PAGE_SIZE_4K - 1);
  uintptr_t stack_bottom = stack_top - PAGE_SIZE_4K;
  /* virtual addresses in the SOS's address space */
  void *local_stack_top = (seL4_Word *)SOS_SCRATCH;
  uintptr_t local_stack_bottom = SOS_SCRATCH - PAGE_SIZE_4K;

  /* find the vsyscall table */
  uintptr_t *sysinfo =
      (uintptr_t *)elf_getSectionNamed(elf_file, "__vsyscall", NULL);
  if (!sysinfo || !*sysinfo) {
    ZF_LOGE("could not find syscall table for c library");
    return 0;
  }

  seL4_Error err;
  seL4_CPtr local_stack_cptr = seL4_CapNull;
  seL4_CapRights_t stack_rights = seL4_CapRights_new(0, 0, 1, 1);

  if (map_process_stack_page(stack_bottom) != 0) {
    cleanup_stack_frames();
    return 0;
  }

  local_stack_cptr = cspace_alloc_slot(cspace);
  if (local_stack_cptr == seL4_CapNull) {
    ZF_LOGE("Failed to alloc slot for stack");
    cleanup_stack_frames();
    return 0;
  }

  err = cspace_copy(cspace, local_stack_cptr, frame_table_cspace(),
                    frame_page(user_process.stack_frames[0]), seL4_AllRights);
  if (err != seL4_NoError) {
    cspace_free_slot(cspace, local_stack_cptr);
    ZF_LOGE("Failed to copy cap for local stack mapping");
    cleanup_stack_frames();
    return 0;
  }

  err = map_frame(cspace, local_stack_cptr, local_vspace, local_stack_bottom,
                  stack_rights, seL4_ARM_Default_VMAttributes);
  if (err != seL4_NoError) {
    cspace_delete(cspace, local_stack_cptr);
    cspace_free_slot(cspace, local_stack_cptr);
    ZF_LOGE("Failed to map stack into SOS");
    cleanup_stack_frames();
    return 0;
  }

  int index = -2;

  /* null terminate the aux vectors */
  index = stack_write(local_stack_top, index, 0);
  index = stack_write(local_stack_top, index, 0);

  /* write the aux vectors */
  index = stack_write(local_stack_top, index, PAGE_SIZE_4K);
  index = stack_write(local_stack_top, index, AT_PAGESZ);

  index = stack_write(local_stack_top, index, *sysinfo);
  index = stack_write(local_stack_top, index, AT_SYSINFO);

  index = stack_write(local_stack_top, index, PROCESS_IPC_BUFFER);
  index = stack_write(local_stack_top, index, AT_SEL4_IPC_BUFFER_PTR);

  /* null terminate the environment pointers */
  index = stack_write(local_stack_top, index, 0);

  /* we don't have any env pointers - skip */

  /* null terminate the argument pointers */
  index = stack_write(local_stack_top, index, 0);

  /* no argpointers - skip */

  /* set argc to 0 */
  stack_write(local_stack_top, index, 0);

  /* adjust the initial stack top */
  stack_top += (index * sizeof(seL4_Word));

  /* the stack *must* remain aligned to a double word boundary,
   * as GCC assumes this, and horrible bugs occur if this is wrong */
  assert(index % 2 == 0);
  assert(stack_top % (sizeof(seL4_Word) * 2) == 0);

  /* unmap our copy of the stack */
  err = seL4_ARM_Page_Unmap(local_stack_cptr);
  assert(err == seL4_NoError);

  /* delete the copy of the stack frame cap */
  err = cspace_delete(cspace, local_stack_cptr);
  assert(err == seL4_NoError);

  /* mark the slot as free */
  cspace_free_slot(cspace, local_stack_cptr);
  local_stack_cptr = seL4_CapNull;

  /* Exend the stack with extra pages */
  for (int page = 0; page < INITIAL_PROCESS_EXTRA_STACK_PAGES; page++) {
    stack_bottom -= PAGE_SIZE_4K;
    if (map_process_stack_page(stack_bottom) != 0) {
      cleanup_stack_frames();
      return 0;
    }
  }

  if (user_process.client != NULL && user_process.client->vm_state != NULL) {
    vm_report_initial_stack(user_process.client->vm_state, stack_bottom);
  }

  return stack_top;
}

/* Start the first process, and return true if successful
 *
 * This function will leak memory if the process does not start successfully.
 * TODO: avoid leaking memory once you implement real processes, otherwise a
 * user can force your OS to run out of memory by creating lots of failed
 * processes.
 */
bool start_first_process(char *app_name, seL4_CPtr ep) {
  bool success = false;
  client_t *client = NULL;
  seL4_Word client_badge = 0;
  user_process.client = NULL;
  user_process.badge = 0;
  user_process.fault_ep_slot = seL4_CapNull;
  /* Create a VSpace */
  user_process.vspace_ut = alloc_retype(
      &user_process.vspace, seL4_ARM_PageGlobalDirectoryObject, seL4_PGDBits);
  if (user_process.vspace_ut == NULL) {
    goto out;
  }

  /* assign the vspace to an asid pool */
  seL4_Word err =
      seL4_ARM_ASIDPool_Assign(seL4_CapInitThreadASIDPool, user_process.vspace);
  if (err != seL4_NoError) {
    ZF_LOGE("Failed to assign asid pool");
    goto out;
  }

  client = client_create(user_process.vspace, &client_badge, &cspace);
  if (!client) {
    ZF_LOGE("client_create failed");
    goto out;
  }
  user_process.client = client;
  user_process.badge = client_badge;
  client->vm_state = vm_state_acquire(client);

  /* Create a simple 1 level CSpace */
  err = cspace_create_one_level(&cspace, &user_process.cspace);
  if (err != CSPACE_NOERROR) {
    ZF_LOGE("Failed to create cspace");
    goto out;
  }

  /* Create an IPC buffer backing frame */
  user_process.ipc_buffer_frame =
      alloc_frame(FRAME_OWNER_USER, FRAME_FLAG_EVICTABLE);
  if (user_process.ipc_buffer_frame == NULL_FRAME) {
    ZF_LOGE("Failed to allocate IPC buffer frame");
    goto out;
  }
  unsigned char *ipc_bytes = frame_data(user_process.ipc_buffer_frame);
  memset(ipc_bytes, 0, PAGE_SIZE_4K);

  user_process.ipc_buffer = cspace_alloc_slot(&cspace);
  if (user_process.ipc_buffer == seL4_CapNull) {
    ZF_LOGE("Failed to alloc slot for IPC buffer");
    free_frame(user_process.ipc_buffer_frame);
    user_process.ipc_buffer_frame = NULL_FRAME;
    goto out;
  }

  err = cspace_copy(&cspace, user_process.ipc_buffer, frame_table_cspace(),
                    frame_page(user_process.ipc_buffer_frame), seL4_AllRights);
  if (err != seL4_NoError) {
    cspace_free_slot(&cspace, user_process.ipc_buffer);
    user_process.ipc_buffer = seL4_CapNull;
    free_frame(user_process.ipc_buffer_frame);
    user_process.ipc_buffer_frame = NULL_FRAME;
    ZF_LOGE("Failed to copy IPC buffer cap");
    goto out;
  }
  user_process.ipc_buffer_vm_owned = false;

  /* allocate a new slot in the target cspace which we will mint a badged
   * endpoint cap into -- the badge is used to identify the process, which
   * will come in handy when you have multiple processes. */
  seL4_CPtr user_ep = cspace_alloc_slot(&user_process.cspace);
  if (user_ep == seL4_CapNull) {
    ZF_LOGE("Failed to alloc user ep slot");
    goto out;
  }

  /* now mutate the cap, thereby setting the badge */
  err = cspace_mint(&user_process.cspace, user_ep, &cspace, ep, seL4_AllRights,
                    client_badge);
  if (err) {
    ZF_LOGE("Failed to mint user ep");
    goto out;
  }

  user_process.fault_ep_slot = cspace_alloc_slot(&cspace);
  if (user_process.fault_ep_slot == seL4_CapNull) {
    ZF_LOGE("Failed to alloc slot for fault endpoint");
    goto out;
  }

  err = cspace_mint(&cspace, user_process.fault_ep_slot, &cspace, ep,
                    seL4_AllRights, client_badge);
  if (err) {
    ZF_LOGE("Failed to mint fault endpoint");
    goto out;
  }

  /* Create a new TCB object */
  user_process.tcb_ut =
      alloc_retype(&user_process.tcb, seL4_TCBObject, seL4_TCBBits);
  if (user_process.tcb_ut == NULL) {
    ZF_LOGE("Failed to alloc tcb ut");
    goto out;
  }

  /* Configure the TCB */
  err = seL4_TCB_Configure(user_process.tcb, user_process.cspace.root_cnode,
                           seL4_NilData, user_process.vspace, seL4_NilData,
                           PROCESS_IPC_BUFFER, user_process.ipc_buffer);
  if (err != seL4_NoError) {
    ZF_LOGE("Unable to configure new TCB");
    goto out;
  }

  /* Create scheduling context */
  user_process.sched_context_ut =
      alloc_retype(&user_process.sched_context, seL4_SchedContextObject,
                   seL4_MinSchedContextBits);
  if (user_process.sched_context_ut == NULL) {
    ZF_LOGE("Failed to alloc sched context ut");
    goto out;
  }

  /* Configure the scheduling context to use the first core with budget equal
   * to period */
  err = seL4_SchedControl_Configure(
      sched_ctrl_start, user_process.sched_context, US_IN_MS, US_IN_MS, 0, 0);
  if (err != seL4_NoError) {
    ZF_LOGE("Unable to configure scheduling context");
    goto out;
  }

  /* bind sched context, set fault endpoint and priority
   * In MCS, fault end point needed here should be in current thread's cspace.
   * NOTE this will use the unbadged ep unlike above, you might want to mint
   * it with a badge so you can identify which thread faulted in your fault
   * handler
   */
  err = seL4_TCB_SetSchedParams(
      user_process.tcb, seL4_CapInitThreadTCB, seL4_MinPrio, APP_PRIORITY,
      user_process.sched_context, user_process.fault_ep_slot);
  if (err != seL4_NoError) {
    ZF_LOGE("Unable to set scheduling params");
    goto out;
  }

  /* Provide a name for the thread -- Helpful for debugging */
  NAME_THREAD(user_process.tcb, app_name);

  /* parse the cpio image */
  ZF_LOGI("\nStarting \"%s\"...\n", app_name);
  elf_t elf_file = {};
  unsigned long elf_size;
  size_t cpio_len = _cpio_archive_end - _cpio_archive;
  const char *elf_base =
      cpio_get_file(_cpio_archive, cpio_len, app_name, &elf_size);
  if (elf_base == NULL) {
    ZF_LOGE("Unable to locate cpio header for %s", app_name);
    goto out;
  }
  /* Ensure that the file is an elf file. */
  if (elf_newFile(elf_base, elf_size, &elf_file)) {
    ZF_LOGE("Invalid elf file");
    goto out;
  }

  /* set up the stack */
  seL4_Word sp =
      init_process_stack(&cspace, seL4_CapInitThreadVSpace, &elf_file);
  if (sp == 0) {
    ZF_LOGE("Failed to initialise process stack");
    goto out;
  }

  /* load the elf image from the cpio file */
  err = elf_load(&cspace, user_process.vspace, &elf_file, client->vm_state);
  if (err) {
    ZF_LOGE("Failed to load elf image");
    goto out;
  }

  /* Map in the IPC buffer for the thread */
  if (client->vm_state != NULL) {
    int vm_err = vm_map_owned_frame(
        client->vm_state, PROCESS_IPC_BUFFER, user_process.ipc_buffer_frame,
        user_process.ipc_buffer, true, true, false, true, true);
    if (vm_err < 0) {
      ZF_LOGE("VM map failed for IPC buffer errno=%d", -vm_err);
      release_ipc_buffer_manual();
      goto out;
    }
    user_process.ipc_buffer_vm_owned = true;
  } else {
    err = map_frame(&cspace, user_process.ipc_buffer, user_process.vspace,
                    PROCESS_IPC_BUFFER, seL4_AllRights,
                    seL4_ARM_Default_VMAttributes);
    if (err != 0) {
      ZF_LOGE("Unable to map IPC buffer for user app");
      release_ipc_buffer_manual();
      goto out;
    }
  }

  /* Start the new process */
  seL4_UserContext context = {
      .pc = elf_getEntryPoint(&elf_file),
      .sp = sp,
  };
  printf("Starting %s at %p\n", APP_NAME, (void *)context.pc);
  err = seL4_TCB_WriteRegisters(user_process.tcb, 1, 0, 2, &context);
  ZF_LOGE_IF(err, "Failed to write registers");
  success = (err == seL4_NoError);

out:
  if (!success && client) {
    if (client->vm_state != NULL) {
      vm_reset_state(client->vm_state);
    }
    client_destroy(client, &cspace);
    user_process.client = NULL;
    user_process.badge = 0;
  }
  if (!success && user_process.fault_ep_slot != seL4_CapNull) {
    cspace_delete(&cspace, user_process.fault_ep_slot);
    cspace_free_slot(&cspace, user_process.fault_ep_slot);
    user_process.fault_ep_slot = seL4_CapNull;
  }
  if (!success) {
    cleanup_stack_frames();
    if (!user_process.ipc_buffer_vm_owned) {
      release_ipc_buffer_manual();
    }
  }
  return success;
}

/* Allocate an endpoint and a notification object for sos.
 * Note that these objects will never be freed, so we do not
 * track the allocated ut objects anywhere
 */
static void sos_ipc_init(seL4_CPtr *ipc_ep, seL4_CPtr *ntfn) {
  /* Create an notification object for interrupts */
  ut_t *ut = alloc_retype(ntfn, seL4_NotificationObject, seL4_NotificationBits);
  ZF_LOGF_IF(!ut, "No memory for notification object");

  /* Bind the notification object to our TCB */
  seL4_Error err = seL4_TCB_BindNotification(seL4_CapInitThreadTCB, *ntfn);
  ZF_LOGF_IFERR(err, "Failed to bind notification object to TCB");

  /* Create an endpoint for user application IPC */
  ut = alloc_retype(ipc_ep, seL4_EndpointObject, seL4_EndpointBits);
  ZF_LOGF_IF(!ut, "No memory for endpoint");
}

/* called by crt */
seL4_CPtr get_seL4_CapInitThreadTCB(void) { return seL4_CapInitThreadTCB; }

/* tell muslc about our "syscalls", which will be called by muslc on invocations
 * to the c library */
void init_muslc(void) {
  setbuf(stdout, NULL);

  muslcsys_install_syscall(__NR_set_tid_address, sys_set_tid_address);
  muslcsys_install_syscall(__NR_writev, sys_writev);
  muslcsys_install_syscall(__NR_exit, sys_exit);
  muslcsys_install_syscall(__NR_rt_sigprocmask, sys_rt_sigprocmask);
  muslcsys_install_syscall(__NR_gettid, sys_gettid);
  muslcsys_install_syscall(__NR_getpid, sys_getpid);
  muslcsys_install_syscall(__NR_tgkill, sys_tgkill);
  muslcsys_install_syscall(__NR_tkill, sys_tkill);
  muslcsys_install_syscall(__NR_exit_group, sys_exit_group);
  muslcsys_install_syscall(__NR_ioctl, sys_ioctl);
  muslcsys_install_syscall(__NR_mmap, sys_mmap);
  muslcsys_install_syscall(__NR_brk, sys_brk);
  muslcsys_install_syscall(__NR_clock_gettime, sys_clock_gettime);
  muslcsys_install_syscall(__NR_nanosleep, sys_nanosleep);
  muslcsys_install_syscall(__NR_getuid, sys_getuid);
  muslcsys_install_syscall(__NR_getgid, sys_getgid);
  muslcsys_install_syscall(__NR_openat, sys_openat);
  muslcsys_install_syscall(__NR_close, sys_close);
  muslcsys_install_syscall(__NR_socket, sys_socket);
  muslcsys_install_syscall(__NR_bind, sys_bind);
  muslcsys_install_syscall(__NR_listen, sys_listen);
  muslcsys_install_syscall(__NR_connect, sys_connect);
  muslcsys_install_syscall(__NR_accept, sys_accept);
  muslcsys_install_syscall(__NR_sendto, sys_sendto);
  muslcsys_install_syscall(__NR_recvfrom, sys_recvfrom);
  muslcsys_install_syscall(__NR_readv, sys_readv);
  muslcsys_install_syscall(__NR_getsockname, sys_getsockname);
  muslcsys_install_syscall(__NR_getpeername, sys_getpeername);
  muslcsys_install_syscall(__NR_fcntl, sys_fcntl);
  muslcsys_install_syscall(__NR_setsockopt, sys_setsockopt);
  muslcsys_install_syscall(__NR_getsockopt, sys_getsockopt);
  muslcsys_install_syscall(__NR_ppoll, sys_ppoll);
  muslcsys_install_syscall(__NR_madvise, sys_madvise);
}

static seL4_CPtr mint_badged_ep(cspace_t *cspace, seL4_CPtr ep,
                                seL4_Word badge) {
  seL4_CPtr slot = cspace_alloc_slot(cspace);
  ZF_LOGF_IF(slot == seL4_CapNull, "no free cspace slot");

  seL4_Error err = cspace_mint(cspace, slot, cspace, ep, seL4_AllRights,
                               seL4_CapData_Badge_new(badge));

  if (err) {
    cspace_free_slot(cspace, slot);
    return seL4_CapNull;
  }
  return slot;
}

NORETURN void *main_continued(UNUSED void *arg) {
  /* Initialise other system compenents here */
  seL4_CPtr ipc_ep, ntfn;
  sos_ipc_init(&ipc_ep, &ntfn);
  sos_init_irq_dispatch(&cspace, seL4_CapIRQControl, ntfn, IRQ_EP_BADGE,
                        IRQ_IDENT_BADGE_BITS);

  /* Initialize threads library */
#ifdef CONFIG_SOS_GDB_ENABLED
  /* Create an endpoint that the GDB threads listens to */
  seL4_CPtr gdb_recv_ep;
  ut_t *ep_ut =
      alloc_retype(&gdb_recv_ep, seL4_EndpointObject, seL4_EndpointBits);
  ZF_LOGF_IF(ep_ut == NULL, "Failed to create GDB endpoint");

  init_threads(ipc_ep, gdb_recv_ep, sched_ctrl_start, sched_ctrl_end);
#else
  init_threads(ipc_ep, ipc_ep, sched_ctrl_start, sched_ctrl_end);
#endif /* CONFIG_SOS_GDB_ENABLED */

  frame_table_init(&cspace, seL4_CapInitThreadVSpace);

  /* Map the timer device (NOTE: this is the same mapping you will use for
   * your timer driver - sos uses the watchdog timers on this page to
   * implement reset infrastructure & network ticks, so touching the watchdog
   * timers here is not recommended!) */
  void *timer_vaddr =
      sos_map_device(&cspace, PAGE_ALIGN_4K(TIMER_MAP_BASE), PAGE_SIZE_4K);

  /* Initialise the network hardware. */
  printf("Network init\n");
  network_init(&cspace, timer_vaddr, ntfn);
  sos_nc = network_console_init();

  /* Initialise NFS handler pool */
  printf("NFS handler init\n");
  nfs_handler_init();

  /* Initialise worker thread infrastructure */
  printf("Worker init\n");

  /* Allocate delegation endpoint */
  seL4_CPtr delegate_ep;
  ut_t *delegate_ep_ut =
      alloc_retype(&delegate_ep, seL4_EndpointObject, seL4_EndpointBits);
  ZF_LOGF_IF(delegate_ep_ut == NULL, "Failed to alloc delegation endpoint");

  /* Mint badged delegation endpoint */
  seL4_CPtr delegate_ep_badged =
      mint_badged_ep(&cspace, delegate_ep, DELEGATE_EP_BADGE);

  ZF_LOGF_IF(delegate_ep_badged == seL4_CapNull,
             "Failed to mint badged delegation endpoint");

  /* Allocate work queue notification */
  seL4_CPtr work_ntfn;
  ut_t *work_ntfn_ut =
      alloc_retype(&work_ntfn, seL4_NotificationObject, seL4_NotificationBits);
  ZF_LOGF_IF(work_ntfn_ut == NULL, "Failed to alloc work notification");

  /* Initialize worker subsystem */
  worker_init(delegate_ep_badged, work_ntfn);

#ifdef CONFIG_SOS_GDB_ENABLED
  /* Initialize the debugger */
  seL4_Error err = debugger_init(&cspace, seL4_CapIRQControl, gdb_recv_ep);
  ZF_LOGF_IF(err, "Failed to initialize debugger %d", err);
  char secret_string[15] = "Welcome to AOS!";
#endif /* CONFIG_SOS_GDB_ENABLED */

  /* Initialises the timer (must be started before pagefile init) */
  printf("Timer init\n");
  start_timer(timer_vaddr);

  /* Wait for NFS mount to complete before initializing pagefile */
  printf("Waiting for NFS mount...\n");
  while (!nfs_is_mounted()) {
    seL4_Word badge = 0;
    seL4_Wait(ntfn, &badge);
    bool have_reply = false;
    sos_handle_irq_notification(&badge, &have_reply);
  }
  printf("NFS mounted\n");

  /* Initialise pagefile subsystem now that NFS is available and timer is running */
  printf("Pagefile init\n");
  int pagefile_ret = pagefile_init();
  if (pagefile_ret < 0) {
    printf("Pagefile initialisation failed; eviction disabled\n");
  }

  /* run sos initialisation tests */
  run_tests(&cspace);

  client_table_init();

  /* You will need to register an IRQ handler for the timer here.
   * See "irq.h". */
  seL4_IRQHandler timeout_irq_handler = 0;
  // use edge triggered since we only want to handle the interrupt once
  // after it is handled, we will re-config the timer
  int init_irq_err =
      sos_register_irq_handler(meson_timeout_irq(MESON_TIMER_A), true,
                               timer_irq, NULL, &timeout_irq_handler);
  ZF_LOGF_IF(init_irq_err != 0, "Failed to initialise timeout IRQ");
  seL4_IRQHandler_Ack(timeout_irq_handler);

  /* Start the user application */
  printf("Start first process\n");
  bool success = start_first_process(APP_NAME, ipc_ep);
  ZF_LOGF_IF(!success, "Failed to start first process");

  /* Initialise continuation pool allocator */
  continuation_bootstrap();

  printf("\nSOS entering syscall loop\n");
  syscall_loop(ipc_ep);
}
/*
 * Main entry point - called by crt.
 */
int main(void) {
  init_muslc();

  /* register the location of the unwind_tables -- this is required for
   * backtrace() to work */
  __register_frame(&__eh_frame_start);

  seL4_BootInfo *boot_info = sel4runtime_bootinfo();

  debug_print_bootinfo(boot_info);

  printf("\nSOS Starting...\n");

  NAME_THREAD(seL4_CapInitThreadTCB, "SOS:root");

  sched_ctrl_start = boot_info->schedcontrol.start;
  sched_ctrl_end = boot_info->schedcontrol.end;

  /* Initialise the cspace manager, ut manager and dma */
  sos_bootstrap(&cspace, boot_info);

  /* switch to the real uart to output (rather than seL4_DebugPutChar, which
   * only works if the kernel is built with support for printing, and is much
   * slower, as each character print goes via the kernel)
   *
   * NOTE we share this uart with the kernel when the kernel is in debug mode.
   */
  uart_init(&cspace);
  update_vputchar(uart_putchar);

  /* test print */
  printf("SOS Started!\n");

  /* allocate a bigger stack and switch to it -- we'll also have a guard page,
   * which makes it much easier to detect stack overruns */
  seL4_Word vaddr = SOS_STACK;
  for (int i = 0; i < SOS_STACK_PAGES; i++) {
    seL4_CPtr frame_cap;
    ut_t *frame =
        alloc_retype(&frame_cap, seL4_ARM_SmallPageObject, seL4_PageBits);
    ZF_LOGF_IF(frame == NULL, "Failed to allocate stack page");
    seL4_Error err =
        map_frame(&cspace, frame_cap, seL4_CapInitThreadVSpace, vaddr,
                  seL4_AllRights, seL4_ARM_Default_VMAttributes);
    ZF_LOGF_IFERR(err, "Failed to map stack");
    vaddr += PAGE_SIZE_4K;
  }

  utils_run_on_stack((void *)vaddr, main_continued, NULL);

  UNREACHABLE();
}
