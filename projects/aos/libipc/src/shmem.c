#include "mapping.h"
#include "sel4/arch/types.h"
#include "sel4/bootinfo_types.h"
#include "sel4/shared_types.h"
#include "sel4/simple_types.h"
#include "utils/zf_log.h"
#include <cspace/cspace.h>
#include <errno.h>
#include <frame_table.h>
#include <ipc.h>
#include <string.h>

int sos_alloc_shared_page(cspace_t *sos_cspace, seL4_CPtr client_vspace_root,
                          uintptr_t u_va, uintptr_t k_va,
                          shared_page_t *shared_page) {
  memset(shared_page, 0, sizeof(shared_page_t));

  // Allocate a new physical frame...
  frame_ref_t frame = alloc_frame();
  if (frame == NULL_FRAME) {
    ZF_LOGE("[ipc] out of memory for shared frame!");
    return -ENOMEM;
  }
  // ...and get the capability that holds the rights to it.
  seL4_CPtr frame_cap = frame_page(frame);

  // Map the allocated frame to the kernel's virtual address space.
  seL4_CPtr k_cap = cspace_alloc_slot(sos_cspace);
  if (k_cap == seL4_CapNull) {
    ZF_LOGE("[ipc] no more space left in SOS' capability space!");
    free_frame(frame);
    return -ENOSPC;
  }
  int err =
      cspace_copy(sos_cspace, k_cap, sos_cspace, frame_cap, seL4_AllRights);
  if (err) {
    ZF_LOGE("[ipc] failed to copy frame capability to SOS' capability space!");
    cspace_free_slot(sos_cspace, k_cap);
    free_frame(frame);
    return -EIO;
  }
  err = map_frame(sos_cspace, k_cap, seL4_CapInitThreadVSpace, k_va,
                  seL4_AllRights, seL4_ARM_Default_VMAttributes);
  if (err) {
    ZF_LOGE("[ipc] failed to map the frame to SOS' virtual address space!");
    cspace_delete(sos_cspace, k_cap);
    cspace_free_slot(sos_cspace, k_cap);
    free_frame(frame);
    return -EFAULT;
  }
  // Zero the page to avoid leaking data.
  memset((void *)k_va, 0, PAGE_SIZE_4K);

  seL4_CPtr u_cap = cspace_alloc_slot(sos_cspace);
  if (u_cap == seL4_CapNull) {
    ZF_LOGE("[ipc] no more space left in SOS' capability space for client!");
    seL4_ARM_Page_Unmap(k_cap);
    cspace_delete(sos_cspace, k_cap);
    cspace_free_slot(sos_cspace, k_cap);
    free_frame(frame);
    return -ENOSPC;
  }
  err =
      cspace_copy(sos_cspace, u_cap, sos_cspace, frame_cap, seL4_AllRights);
  if (err) {
    ZF_LOGE("[ipc] failed to copy frame capability to client slot!");
    seL4_ARM_Page_Unmap(k_cap);
    cspace_delete(sos_cspace, k_cap);
    cspace_free_slot(sos_cspace, k_cap);
    cspace_free_slot(sos_cspace, u_cap);
    free_frame(frame);
    return -EIO;
  }

  // Map the allocated frame into the client's virtual address space.
  err = map_frame(sos_cspace, u_cap, client_vspace_root, u_va,
                  seL4_ReadWrite, seL4_ARM_Default_VMAttributes);
  if (err) {
    ZF_LOGE(
        "[ipc] failed to map the frame to the client's virtual address space!");
    seL4_ARM_Page_Unmap(k_cap);
    cspace_delete(sos_cspace, k_cap);
    cspace_free_slot(sos_cspace, k_cap);
    cspace_delete(sos_cspace, u_cap);
    cspace_free_slot(sos_cspace, u_cap);
    free_frame(frame);
    return -EFAULT;
  }

  shared_page->frame = frame;
  shared_page->k_cap = k_cap;
  shared_page->u_cap = u_cap;
  shared_page->k_va = k_va;
  shared_page->u_va = u_va;

  return 0;
}

void sos_free_shared_page(cspace_t *sos_cspace, shared_page_t *shared_page) {
  if (!shared_page || shared_page->frame == NULL_FRAME) {
    return;
  }

  // Unmap shared frame from SOS
  if (shared_page->k_cap) {
    seL4_ARM_Page_Unmap(shared_page->k_cap);
    cspace_delete(sos_cspace, shared_page->k_cap);
    cspace_free_slot(sos_cspace, shared_page->k_cap);
  }

  // Unmap shared frame from the client
  if (shared_page->u_cap) {
    seL4_ARM_Page_Unmap(shared_page->u_cap);
    cspace_delete(sos_cspace, shared_page->u_cap);
    cspace_free_slot(sos_cspace, shared_page->u_cap);
  }

  // Return frame to frame table
  free_frame(shared_page->frame);

  memset(shared_page, 0, sizeof(shared_page_t));
}
