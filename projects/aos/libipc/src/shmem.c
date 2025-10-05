#include "sel4/shared_types.h"
#include <cspace/cspace.h>
#include <frame_table.h>
#include <ipc.h>

void sos_alloc_shared_frame(cspace_t *target) {
  /* Allocate a frame and get its data and capability */
  frame_ref_t frame = alloc_frame();
  unsigned char *local = frame_data(frame);
  seL4_CPtr page_cap = frame_page(frame);

  /* Copy over the allocated page capability to the target cspace */
  seL4_CPtr client_slot = cspace_alloc_slot(target);
  cspace_copy(target, client_slot, frame_table_cspace(), page_cap,
              seL4_ReadWrite);

  map_frame(target, client_slot, client_vspace, client_vaddr,
            seL4_CapRights_new(false, false, true, true),
            seL4_ARM_Default_VMAttributes);
}
