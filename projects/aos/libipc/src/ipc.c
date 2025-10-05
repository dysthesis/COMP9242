#include "cspace/cspace.h"
#include <ipc.h>
#include <sel4/sel4.h>
#include <stdbool.h>
#include <stddef.h>
#include <vmem_layout.h>

_Static_assert(SOS_IPC_MSG_WORDS <= seL4_FastMessageRegisters,
               "Too many message registers for fast path");

seL4_MessageInfo_t sos_serialise_ipc_msg(const sos_ipc_msg_t *msg) {
  if (!msg) {
    return seL4_MessageInfo_new(/*label*/ 0,
                                /*capsUnwrapped*/ 0,
                                /*extraCaps*/ 0,
                                /*length*/ 0);
  }

  seL4_SetMR(0, (seL4_Word)msg->sysno);
  seL4_SetMR(1, (seL4_Word)msg->arg);
  seL4_SetMR(2, (seL4_Word)msg->buf_addr);
  seL4_SetMR(3, (seL4_Word)msg->buf_size);

  return seL4_MessageInfo_new(/*label*/ 0,
                              /*capsUnwrapped*/ 0,
                              /*extraCaps*/ 0,
                              /*length*/ SOS_IPC_MSG_WORDS);
}

int sos_deserialise_ipc_msg(const seL4_MessageInfo_t *msg_info,
                            sos_ipc_msg_t *out) {
  if (!msg_info || !out)
    return -1;

  const seL4_Word len = seL4_MessageInfo_get_length(*msg_info);
  const seL4_Word xcaps = seL4_MessageInfo_get_extraCaps(*msg_info);

  if (len < SOS_IPC_MSG_WORDS || xcaps != 0) {
    /* Normalise output to a safe default */
    out->sysno = 0;
    out->arg = 0;
    out->buf_addr = 0;
    out->buf_size = 0;
    return -1;
  }

  out->sysno = (sos_sysno_t)seL4_GetMR(0);
  out->arg = seL4_GetMR(1);
  out->buf_addr = seL4_GetMR(2);
  out->buf_size = seL4_GetMR(3);
  return 0;
}

void client_table_init(void) {
  for (unsigned i = 0; i < MAX_CLIENTS; i++)
    free_ids[i] = (uint16_t)i;
  free_top = MAX_CLIENTS;
  memset(clients, 0, sizeof clients);
  memset(generations, 0, sizeof generations);
}

/* Create and register a client. Returns badge to mint into the client's
 * endpoint cap. */
client_t *client_create(seL4_CPtr vspace_root, seL4_Word *out_badge,
                        cspace_t *sos_cspace) {
  if (free_top == 0)
    return NULL; // out of slots
  unsigned id = free_ids[--free_top];
  unsigned gen = ++generations[id]; // bump generation on reuse

  client_t *c = calloc(1, sizeof *c);
  if (!c) {
    free_ids[free_top++] = id;
    return NULL;
  }

  c->id = id;
  c->gen = (uint8_t)gen;
  c->vspace = vspace_root;

  uintptr_t kva = SOS_SHBUF_BASE + (uintptr_t)id * PAGE_SIZE_4K;
  if (sos_alloc_shared_page(sos_cspace, vspace_root, PROCESS_SHBUF_UVA, kva,
                            &c->shbuf) != 0) {
    free_ids[free_top++] = id;
    free(c);
    return NULL;
  }

  clients[id] = c;

  if (out_badge)
    *out_badge = badge_make(
        gen, id,
        /* we're not using flags for now, but this might be
                           handy to differentiate IPC messages later on */
        0);
  return c;
}

client_t *client_lookup(seL4_Word badge) {
  unsigned id = badge_id(badge);
  unsigned gen = badge_gen(badge);
  client_t *c = (id < MAX_CLIENTS) ? clients[id] : NULL;
  return (c && generations[id] == gen) ? c : NULL; // reject stale/forged
}

/* Destroy client */

void client_destroy(client_t *client, cspace_t *sos_cspace) {
  if (!client)
    return;
  unsigned id = client->id;
  clients[id] = NULL;

  sos_free_shared_page(sos_cspace, &client->shbuf);

  free_ids[free_top++] = id;
  free(client);
}
