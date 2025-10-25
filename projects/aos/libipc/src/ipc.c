#include "cspace/cspace.h"
#include "vm/api.h"
#include <ipc.h>
#include <sel4/sel4.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdlib.h>
#include <vmem_layout.h>

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

  c->vm_state = vm_state_acquire(c);
  if (c->vm_state == NULL) {
    free_ids[free_top++] = id;
    free(c);
    return NULL;
  }

  clients[id] = c;

  if (out_badge)
    *out_badge = badge_make(id, gen,
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

  vm_state_release(client);
  client->vm_state = NULL;

  free_ids[free_top++] = id;
  free(client);
}
