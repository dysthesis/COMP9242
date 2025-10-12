/*
 * An enum defining the system call numbers supported by SOS.
 */
#pragma once

#include "cspace/cspace.h"
#include "frame_table.h"
#include "ipc_common.h"
#include "sel4/simple_types.h"

#define MAX_CLIENTS                                                            \
  1024u // how many clients can perform a system call simultaneously

/*
 * We mint one badged endpoint capability per client so the server can identify
 * the caller on every system call via the kernel-supplied badge.
 *
 * Badge layout:
 *   [ FLAGS ... | GEN : g bits | ID : ceil(log2(MAX_CLIENTS)) bits ]
 *
 *  - ID indexes a fixed/segmented client table.
 *  - GEN is a small generation counter for that ID slot.
 *  - Remaining high bits may be reserved for flags (e.g., class/diagnostics).
 *
 * Lifecycle:
 *  - On client creation, we allocate an ID slot, increment its GEN, publish
 *    clients[ID] = <state>, and mint the client’s endpoint cap with
 *    badge = pack(FLAGS, GEN, ID).
 *  - On each system call, the server receives the badge from
 *    seL4_Recv/ReplyRecv, extracts (ID, GEN), and accepts only if clients[ID]
 *    is non-NULL AND gen_tab[ID] == GEN. This rejects stale or forged calls.
 *  - On client teardow, we clear clients[ID], revoke the client’s badged caps,
 *    and return ID to the free list. GEN will be incremented next time the
 *    slot is reused.
 *
 * NOTE: Generation counters DO NOT change after each syscall; they change
 * only when the slot is reused for a different client, preventing ABA (see:
 * https://en.wikipedia.org/wiki/ABA_problem).
 */
#define ID_BITS 10u // log(MAX_CLIENTS)
#define GEN_BITS 8u
#define ID_MASK ((1u << ID_BITS) - 1)
#define GEN_MASK ((seL4_Word)((((seL4_Word)1u << GEN_BITS) - 1u)))
#define GEN_SHIFT (ID_BITS)

static inline seL4_Word badge_make(unsigned id, unsigned gen, seL4_Word flags) {
  // flags don’t touch the low region
  const seL4_Word LOW_MASK = (((seL4_Word)1u << (ID_BITS + GEN_BITS)) - 1u);
  assert((flags & LOW_MASK) == 0);

  // Pack with masking to prevent overflow
  return ((seL4_Word)(id & ID_MASK)) |
         ((seL4_Word)((gen & GEN_MASK) << GEN_SHIFT)) |
         flags; // already confined to high bits
}
static inline unsigned badge_id(seL4_Word b) { return b & ID_MASK; }
static inline unsigned badge_gen(seL4_Word b) {
  return (b >> ID_BITS) & ((1u << GEN_BITS) - 1);
}

typedef struct SharedPage shared_page_t;

/*
 * Allocates a shared page between SOS and the client.
 *
 * On success this returns 0 and initialises `*shared_page` with a descriptor.
 * On failure a negative errno is returned and `*shared_page` is set to NULL.
 */
int sos_alloc_shared_page(cspace_t *sos_cspace, seL4_CPtr client_vspace_root,
                          uintptr_t u_va, uintptr_t k_va,
                          shared_page_t **shared_page);

/*
 * Deallocate and tear down a shared page. On return `*shared_page` will be NULL.
 */
void sos_free_shared_page(cspace_t *sos_cspace, shared_page_t **shared_page);

frame_ref_t sos_shared_page_frame(const shared_page_t *shared_page);
seL4_CPtr sos_shared_page_kernel_cap(const shared_page_t *shared_page);
seL4_CPtr sos_shared_page_client_cap(const shared_page_t *shared_page);
uintptr_t sos_shared_page_kernel_va(const shared_page_t *shared_page);
uintptr_t sos_shared_page_client_va(const shared_page_t *shared_page);

typedef struct client {
  unsigned id;         // slot ID
  uint8_t gen;         // generation
  seL4_CPtr vspace;    // client's VSpace root capability (in SOS's CSpace)
  shared_page_t *shbuf; // the shared page for IPC
} client_t;

extern client_t *clients[MAX_CLIENTS];
extern uint8_t generations[MAX_CLIENTS];

extern uint16_t free_ids[MAX_CLIENTS];
extern size_t free_top;

void client_table_init(void);
client_t *client_create(seL4_CPtr vspace_root, seL4_Word *out_badge,
                        cspace_t *sos_cspace);
client_t *client_lookup(seL4_Word badge);
void client_destroy(client_t *client, cspace_t *sos_cspace);
