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
#include "frame_table.h"
#include "mapping.h"
#include "pagefile.h"
#include "vmem_layout.h"

#include <assert.h>
#include <sos/gen_config.h>
#include <sel4/sel4.h>
#include <stdbool.h>
#include <string.h>
#include <utils/util.h>

/* Debugging macro to get the human-readable name of a particular list. */
#define LIST_NAME(list) LIST_ID_NAME(list->list_id)

/* Names of each of the lists. */
#define LIST_NAME_ENTRY(list) [list] = #list
char *frame_table_list_names[] = {
    LIST_NAME_ENTRY(NO_LIST),
    LIST_NAME_ENTRY(FREE_LIST),
    LIST_NAME_ENTRY(ALLOCATED_LIST),
};

/*
 * An entire page of data.
 */
typedef unsigned char frame_data_t[BIT(seL4_PageBits)];
compile_time_assert("Frame data size correct",
                    sizeof(frame_data_t) == BIT(seL4_PageBits));

/* Memory-efficient doubly linked list of frames
 *
 * As all frame objects will live in effectively an array, we only need
 * to be able to index into that array.
 */
typedef struct {
  list_id_t list_id;
  /* Index of first element in list */
  frame_ref_t first;
  /* Index in last element of list */
  frame_ref_t last;
  /* Size of list (useful for debugging) */
  size_t length;
} frame_list_t;

typedef struct {
  /* Hand points to the next candidate frame. */
  frame_ref_t hand;
  /* Number of frames currently enqueued on the clock list. */
  size_t length;
} clock_list_t;

/* This global variable tracks the frame table */
static struct {
  /* The array of all frames in memory. */
  frame_t *frames;
  /* The data region of the frame table. */
  frame_data_t *frame_data;
  /* The current capacity of the frame table. */
  size_t capacity;
  /* The current number of frames resident in the table. */
  size_t used;
  /* The current size of the frame table in bytes. */
  size_t byte_length;
  /* The free frames. */
  frame_list_t free;
  /* The allocated frames. */
  frame_list_t allocated;
  /* Circular list of evictable frames. */
  clock_list_t clock;
  /* cspace used to make allocations of capabilities. */
  cspace_t *cspace;
  /* vspace used to map pages into SOS. */
  seL4_ARM_PageGlobalDirectory vspace;
} frame_table = {
    .frames = (void *)SOS_FRAME_TABLE,
    .frame_data = (void *)SOS_FRAME_DATA,
    .free = {.list_id = FREE_LIST},
    .allocated = {.list_id = ALLOCATED_LIST},
    .clock = {.hand = NULL_FRAME, .length = 0},
};

/* Management of frame nodes */
static frame_ref_t ref_from_frame(frame_t *frame);

/* Management of frame list */
static void push_front(frame_list_t *list, frame_t *frame);
static void push_back(frame_list_t *list, frame_t *frame);
static frame_t *pop_front(frame_list_t *list);
static void remove_frame(frame_list_t *list, frame_t *frame);

/* Management of clock list */
static bool clock_is_member(const frame_t *frame);
static bool clock_is_eligible(const frame_t *frame);
static void clock_add(frame_t *frame);
static void clock_remove(frame_t *frame);
static void clock_reconsider(frame_t *frame);
static void clock_validate(void);
static void clock_advance_hand(frame_ref_t next);

/* Page-out worker bridge (implemented in Zig). */
extern int pageout_submit(uint32_t slot, size_t frame_ref);
extern int pageout_poll_complete(size_t *frame_ref_out, uint32_t *slot_out);
extern int vm_pageout_finalise(size_t frame_ref, uint32_t slot);

#define SOS_EAGAIN 11
/*
 * Allocate a frame at a particular address in SOS.
 *
 * @param(in)  vaddr  Address in SOS at which to map the frame.
 * @return            Page used to map frame into SOS.
 */
static seL4_ARM_Page alloc_frame_at(uintptr_t vaddr);

/*
 * Initiate page-out of a victim frame.
 * NOTE: This implementation does not yet unmap the frame or update VM metadata;
 * it only writes the current contents to the pagefile and records the slot.
 * The caller must ensure state transitions and unmapping are handled elsewhere.
 */
int pageout_frame(frame_ref_t victim) {
  if (victim == NULL_FRAME) {
    return -1;
  }

  frame_t *frame = frame_from_ref(victim);

  /* Allocate pagefile slot */
  uint32_t slot = pagefile_alloc_slot(victim, 0, 0);
  if (slot == PAGEFILE_INVALID_SLOT) {
    return -1;
  }

  int rc = pageout_submit(slot, victim);
  if (rc != 0) {
    pagefile_free_slot(slot);
    return rc;
  }

  size_t completed_frame = 0;
  uint32_t completed_slot = 0;
  int polls = 0;
  while (true) {
    rc = pageout_poll_complete(&completed_frame, &completed_slot);
    if (rc != -SOS_EAGAIN) {
      break;
    }
    if (polls++ > 1000) {
      /* Give caller a chance to progress other work. */
      rc = -SOS_EAGAIN;
      break;
    }
    seL4_Yield();
  }

  if (rc != 0) {
    pagefile_free_slot(slot);
    return rc;
  }

  assert(completed_frame == victim);
  assert(completed_slot == slot);

  rc = vm_pageout_finalise(victim, slot);
  if (rc != 0) {
    pagefile_free_slot(slot);
    return rc;
  }

  frame->swap_slot = slot;
  free_frame(victim);
  return 0;
}

int evict_one_frame(void) {
  frame_ref_t victim = clock_select_victim();
  if (victim == NULL_FRAME) {
    return -1;
  }

  return pageout_frame(victim);
}

void frame_mark_dirty(frame_ref_t frame_ref) {
  if (frame_ref == NULL_FRAME) {
    return;
  }
  frame_t *frame = frame_from_ref(frame_ref);
  frame->flags |= FRAME_FLAG_DIRTY;
}

/* Allocate a new frame. */
static frame_t *alloc_fresh_frame(void);

/* Increase the capacity of the frame table.
 *
 * @return  0 on succuss, -ve on failure. */
static int bump_capacity(void);

void frame_table_init(cspace_t *cspace, seL4_CPtr vspace) {
  frame_table.cspace = cspace;
  frame_table.vspace = vspace;
  frame_table.clock.hand = NULL_FRAME;
  frame_table.clock.length = 0;
}

cspace_t *frame_table_cspace(void) { return frame_table.cspace; }

frame_ref_t alloc_frame(frame_owner_t owner, frame_flags_t flags) {
  frame_t *frame = pop_front(&frame_table.free);

  if (frame == NULL) {
    frame = alloc_fresh_frame();
  }

  if (frame == NULL && pagefile_is_ready()) {
    /* Attempt synchronous eviction to free a frame */
    if (evict_one_frame() == 0) {
      frame = pop_front(&frame_table.free);
    }
  }

  if (frame != NULL) {
    frame->owner = owner;
    frame->flags = flags;
    frame->pin_count = (flags & FRAME_FLAG_PINNED) ? 1 : 0;
    frame->swap_slot = 0;
    /* Ensure stale clock links are cleared before reconsidering eligibility. */
    frame->clock_prev = NULL_FRAME;
    frame->clock_next = NULL_FRAME;
    clock_reconsider(frame);
    push_back(&frame_table.allocated, frame);
  } else {
    return NULL_FRAME;
  }

  return ref_from_frame(frame);
}

void free_frame(frame_ref_t frame_ref) {
  if (frame_ref != NULL_FRAME) {
    frame_t *frame = frame_from_ref(frame_ref);

    clock_remove(frame);
    remove_frame(&frame_table.allocated, frame);
    frame->owner = FRAME_OWNER_KERNEL;
    frame->flags = 0;
    frame->pin_count = 0;
    frame->swap_slot = 0;
    frame->clock_prev = NULL_FRAME;
    frame->clock_next = NULL_FRAME;
    push_front(&frame_table.free, frame);
  }
}

seL4_ARM_Page frame_page(frame_ref_t frame_ref) {
  frame_t *frame = frame_from_ref(frame_ref);
  return frame->sos_page;
}

unsigned char *frame_data(frame_ref_t frame_ref) {
  assert(frame_ref != NULL_FRAME);
  assert(frame_ref < frame_table.capacity);
  return frame_table.frame_data[frame_ref];
}

frame_t *frame_from_ref(frame_ref_t frame_ref) {
  assert(frame_ref != NULL_FRAME);
  assert(frame_ref < frame_table.capacity);
  return &frame_table.frames[frame_ref];
}

static frame_ref_t ref_from_frame(frame_t *frame) {
  assert(frame >= frame_table.frames);
  assert(frame < frame_table.frames + frame_table.used);
  return frame - frame_table.frames;
}

static void push_front(frame_list_t *list, frame_t *frame) {
  assert(frame != NULL);
  assert(frame->list_id == NO_LIST);
  assert(frame->next == NULL_FRAME);
  assert(frame->prev == NULL_FRAME);

  frame_ref_t frame_ref = ref_from_frame(frame);

  if (list->last == NULL_FRAME) {
    list->last = frame_ref;
  }

  frame->next = list->first;
  if (frame->next != NULL_FRAME) {
    frame_t *next = frame_from_ref(frame->next);
    next->prev = frame_ref;
  }

  list->first = frame_ref;
  list->length += 1;
  frame->list_id = list->list_id;

  ZF_LOGD("%s.length = %lu", LIST_NAME(list), list->length);
}

static void push_back(frame_list_t *list, frame_t *frame) {
  assert(frame != NULL);
  assert(frame->list_id == NO_LIST);
  assert(frame->next == NULL_FRAME);
  assert(frame->prev == NULL_FRAME);

  frame_ref_t frame_ref = ref_from_frame(frame);

  if (list->last != NULL_FRAME) {
    frame_t *last = frame_from_ref(list->last);
    last->next = frame_ref;

    frame->prev = list->last;
    list->last = frame_ref;

    frame->list_id = list->list_id;
    list->length += 1;
    ZF_LOGD("%s.length = %lu", LIST_NAME(list), list->length);
  } else {
    /* Empty list */
    push_front(list, frame);
  }
}

static frame_t *pop_front(frame_list_t *list) {
  if (list->first != NULL_FRAME) {
    frame_t *head = frame_from_ref(list->first);
    if (list->last == list->first) {
      /* Was last in list */
      list->last = NULL_FRAME;
      assert(head->next == NULL_FRAME);
    } else {
      frame_t *next = frame_from_ref(head->next);
      next->prev = NULL_FRAME;
    }

    list->first = head->next;

    assert(head->prev == NULL_FRAME);
    head->next = NULL_FRAME;
    head->list_id = NO_LIST;
    head->prev = NULL_FRAME;
    head->next = NULL_FRAME;
    list->length -= 1;
    ZF_LOGD("%s.length = %lu", LIST_NAME(list), list->length);
    return head;
  } else {
    return NULL;
  }
}

static void remove_frame(frame_list_t *list, frame_t *frame) {
  assert(frame != NULL);
  assert(frame->list_id == list->list_id);

  if (frame->prev != NULL_FRAME) {
    frame_t *prev = frame_from_ref(frame->prev);
    prev->next = frame->next;
  } else {
    list->first = frame->next;
  }

  if (frame->next != NULL_FRAME) {
    frame_t *next = frame_from_ref(frame->next);
    next->prev = frame->prev;
  } else {
    list->last = frame->prev;
  }

  list->length -= 1;
  frame->list_id = NO_LIST;
  frame->prev = NULL_FRAME;
  frame->next = NULL_FRAME;
  ZF_LOGD("%s.length = %lu", LIST_NAME(list), list->length);
}

static bool clock_is_member(const frame_t *frame) {
  return frame->clock_next != NULL_FRAME;
}

static bool clock_is_eligible(const frame_t *frame) {
  if (frame->owner != FRAME_OWNER_USER) {
    return false;
  }
  if ((frame->flags & FRAME_FLAG_EVICTABLE) == 0) {
    return false;
  }
  if ((frame->flags & FRAME_FLAG_PINNED) != 0) {
    return false;
  }
  return true;
}

static void clock_validate(void) {
#ifndef NDEBUG
  size_t count = 0;
  frame_ref_t cursor = frame_table.clock.hand;

  if (frame_table.clock.length == 0) {
    assert(cursor == NULL_FRAME);
    return;
  }

  assert(cursor != NULL_FRAME);
  do {
    frame_t *f = frame_from_ref(cursor);
    assert(clock_is_member(f));
    count += 1;
    cursor = f->clock_next;
    /* Safety net against accidental cycles. */
    assert(count <= frame_table.clock.length + 1);
  } while (cursor != frame_table.clock.hand);

  assert(count == frame_table.clock.length);
#endif
}

static void clock_advance_hand(frame_ref_t next) {
  frame_table.clock.hand = next;
}

static void clock_add(frame_t *frame) {
  assert(frame != NULL);
  assert(!clock_is_member(frame));
  assert(clock_is_eligible(frame));

  frame_ref_t ref = ref_from_frame(frame);

  if (frame_table.clock.length == 0) {
    frame->clock_prev = ref;
    frame->clock_next = ref;
    frame_table.clock.hand = ref;
  } else {
    frame_t *hand = frame_from_ref(frame_table.clock.hand);
    frame_t *tail = frame_from_ref(hand->clock_prev);

    frame->clock_prev = ref_from_frame(tail);
    frame->clock_next = frame_table.clock.hand;

    tail->clock_next = ref;
    hand->clock_prev = ref;
  }

  frame_table.clock.length += 1;
  clock_validate();
}

static void clock_remove(frame_t *frame) {
  if (!clock_is_member(frame)) {
    return;
  }

  frame_ref_t ref = ref_from_frame(frame);

  if (frame_table.clock.length == 1) {
    assert(frame->clock_next == ref);
    assert(frame->clock_prev == ref);
    frame_table.clock.hand = NULL_FRAME;
  } else {
    frame_t *prev = frame_from_ref(frame->clock_prev);
    frame_t *next = frame_from_ref(frame->clock_next);

    prev->clock_next = frame->clock_next;
    next->clock_prev = frame->clock_prev;

    if (frame_table.clock.hand == ref) {
      clock_advance_hand(ref_from_frame(next));
    }
  }

  frame_table.clock.length -= 1;
  frame->clock_prev = NULL_FRAME;
  frame->clock_next = NULL_FRAME;
  clock_validate();
}

static void clock_reconsider(frame_t *frame) {
  if (clock_is_member(frame)) {
    if (!clock_is_eligible(frame)) {
      clock_remove(frame);
    }
    return;
  }

  if (clock_is_eligible(frame)) {
    clock_add(frame);
  }
}

frame_ref_t clock_select_victim(void) {
  if (frame_table.clock.length == 0) {
    return NULL_FRAME;
  }

  assert(frame_table.clock.hand != NULL_FRAME);

  /* Two full rotations budget to find an unreferenced clean frame. */
  size_t budget = frame_table.clock.length * 2;
  frame_ref_t dirty_candidate = NULL_FRAME;

  while (frame_table.clock.length > 0 && budget-- > 0) {
    frame_t *cur = frame_from_ref(frame_table.clock.hand);

    if (!clock_is_eligible(cur)) {
      /* Defensive cleanup if eligibility changed without notification. */
      clock_remove(cur);
      if (frame_table.clock.length == 0) {
        return NULL_FRAME;
      }
      continue;
    }

    bool referenced = (cur->flags & FRAME_FLAG_REFERENCED) != 0;
    bool dirty = (cur->flags & FRAME_FLAG_DIRTY) != 0;

    if (referenced) {
      cur->flags &= ~FRAME_FLAG_REFERENCED;
      clock_advance_hand(cur->clock_next);
      continue;
    }

    if (!dirty) {
      frame_ref_t victim = ref_from_frame(cur);
      clock_advance_hand(cur->clock_next);
      return victim;
    }

    if (dirty_candidate == NULL_FRAME) {
      dirty_candidate = ref_from_frame(cur);
    }

    clock_advance_hand(cur->clock_next);
  }

  if (dirty_candidate != NULL_FRAME) {
    frame_t *chosen = frame_from_ref(dirty_candidate);
    clock_advance_hand(chosen->clock_next);
    return dirty_candidate;
  }

  return NULL_FRAME;
}

static frame_t *alloc_fresh_frame(void) {
  assert(frame_table.used <= frame_table.capacity);
#ifdef CONFIG_SOS_FRAME_LIMIT
  if (CONFIG_SOS_FRAME_LIMIT != 0ul) {
    assert(frame_table.capacity <= CONFIG_SOS_FRAME_LIMIT);
  }
#endif

  if (frame_table.used == frame_table.capacity) {
    if (bump_capacity() != 0) {
      /* Could not increase capacity. */
      return NULL;
    }
  }

  assert(frame_table.used < frame_table.capacity);

  if (frame_table.used == 0) {
    /* The first frame is a sentinel NULL frame. */
    frame_table.used += 1;
  }

  frame_t *frame = &frame_table.frames[frame_table.used];
  frame_table.used += 1;

  uintptr_t vaddr = (uintptr_t)frame_data(ref_from_frame(frame));
  seL4_ARM_Page sos_page = alloc_frame_at(vaddr);
  if (sos_page == seL4_CapNull) {
    frame_table.used -= 1;
    return NULL;
  }

  *frame = (frame_t){
      .sos_page = sos_page,
      .prev = NULL_FRAME,
      .next = NULL_FRAME,
      .list_id = NO_LIST,
      .owner = FRAME_OWNER_KERNEL,
      .flags = 0,
      .pin_count = 0,
      .reserved16 = 0,
      .swap_slot = 0,
      .clock_prev = NULL_FRAME,
      .clock_next = NULL_FRAME,
  };

  ZF_LOGD("Frame table contains %lu/%lu frames", frame_table.used,
          frame_table.capacity);
  return frame;
}

static int bump_capacity(void) {
#ifdef CONFIG_SOS_FRAME_LIMIT
  if (CONFIG_SOS_FRAME_LIMIT != 0ul &&
      frame_table.capacity == CONFIG_SOS_FRAME_LIMIT) {
    /* Reached maximum capacity. */
    return -1;
  }
#endif

  uintptr_t vaddr = (uintptr_t)frame_table.frames + frame_table.byte_length;

  seL4_ARM_Page cptr = alloc_frame_at(vaddr);
  if (cptr == seL4_CapNull) {
    return -1;
  }

  frame_table.byte_length += BIT(seL4_PageBits);
  frame_table.capacity = frame_table.byte_length / sizeof(frame_t);

#ifdef CONFIG_SOS_FRAME_LIMIT
  if (CONFIG_SOS_FRAME_LIMIT != 0ul) {
    frame_table.capacity = MIN(CONFIG_SOS_FRAME_LIMIT, frame_table.capacity);
  }
#endif

  ZF_LOGD("Frame table contains %lu/%lu frames", frame_table.used,
          frame_table.capacity);
  return 0;
}

static seL4_ARM_Page alloc_frame_at(uintptr_t vaddr) {
  /* Allocate an untyped for the frame. */
  ut_t *ut = ut_alloc_4k_untyped(NULL);
  if (ut == NULL) {
    return seL4_CapNull;
  }

  /* Allocate a slot for the page capability. */
  seL4_ARM_Page cptr = cspace_alloc_slot(frame_table.cspace);
  if (cptr == seL4_CapNull) {
    ut_free(ut);
    return seL4_CapNull;
  }

  /* Retype the untyped into a page. */
  int err = cspace_untyped_retype(frame_table.cspace, ut->cap, cptr,
                                  seL4_ARM_SmallPageObject, seL4_PageBits);
  if (err != 0) {
    cspace_free_slot(frame_table.cspace, cptr);
    ut_free(ut);
    return seL4_CapNull;
  }

  /* Map the frame into SOS. */
  seL4_ARM_VMAttributes attrs =
      seL4_ARM_Default_VMAttributes | seL4_ARM_ExecuteNever;
  err = map_frame(frame_table.cspace, cptr, frame_table.vspace, vaddr,
                  seL4_ReadWrite, attrs);
  if (err != 0) {
    cspace_delete(frame_table.cspace, cptr);
    cspace_free_slot(frame_table.cspace, cptr);
    ut_free(ut);
    return seL4_CapNull;
  }

  return cptr;
}
