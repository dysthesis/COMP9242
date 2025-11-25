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
#include "sys/morecore.h"
#include "vmem_layout.h"

#include <assert.h>
#include <errno.h>
#include <sel4/sel4.h>
#include <sos/gen_config.h>
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
static int pageout_process_one_completion(void);
static int pageout_wait_for_completion(size_t max_iters);
static int pageout_wait_blocking(void);

/* Page-out worker bridge (implemented in Zig). */
extern int pageout_submit(uint32_t slot, size_t frame_ref);
extern int pageout_poll_complete(size_t *frame_ref_out, uint32_t *slot_out);
extern int vm_pageout_finalise(size_t frame_ref, uint32_t slot);
extern int vm_pageout_prepare(size_t frame_ref, uint32_t slot);
extern int vm_pageout_abort(size_t frame_ref, uint32_t slot);

/* Heap management bridge (implemented in Zig and morecore.c). */
extern size_t morecore_free_bytes(void);
extern int heap_reserve_release(void);
extern void heap_reserve_ensure(void);

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

  /* Remove from clock list immediately to prevent duplicate eviction. */
  clock_remove(frame);

  /* Allocate pagefile slot */
  uint32_t slot = pagefile_alloc_slot(victim, 0, 0);
  if (slot == PAGEFILE_INVALID_SLOT) {
    ZF_LOGE("pageout_frame: failed to alloc slot for victim=%zu", victim);
    clock_reconsider(frame);
    return -1;
  }

  /* Unmap and transition metadata to PAGEOUT_PENDING before copying to avoid dirty-after-copy races. */
  int prep_rc = vm_pageout_prepare(victim, slot);
  if (prep_rc != 0) {
    pagefile_free_slot(slot);
    clock_reconsider(frame);
    return prep_rc;
  }

  frame->swap_slot = slot;

  /* Submit; if workers are saturated, poll completions until a slot opens. */
  while (true) {
    int rc = pageout_submit(slot, victim);
    if (rc == 0) {
      return 0;
    }
    if (rc == -SOS_EAGAIN) {
      /* Wait for completions to free worker capacity. */
      (void)pageout_wait_for_completion(16);
      continue;
    }
    frame->swap_slot = 0;
    pagefile_free_slot(slot);
    clock_reconsider(frame);
    return rc;
  }

}

int evict_one_frame(void) {
  frame_ref_t victim = clock_select_victim();
  if (victim == NULL_FRAME) {
    ZF_LOGE("evict_one_frame: no victim (clock_len=%lu free_len=%lu)", frame_table.clock.length,
            frame_table.free.length);
    return -1;
  }
  ZF_LOGE("evict_one_frame: victim=%zu (clock_len=%lu free_len=%lu)", victim,
          frame_table.clock.length, frame_table.free.length);
  ZF_LOGE("evict_one_frame: submitting victim=%zu", victim);
  return pageout_frame(victim);
}

void frame_mark_dirty(frame_ref_t frame_ref) {
  if (frame_ref == NULL_FRAME) {
    return;
  }
  frame_t *frame = frame_from_ref(frame_ref);
  frame->flags |= FRAME_FLAG_DIRTY;
}

void frame_mark_referenced(frame_ref_t frame_ref) {
  if (frame_ref == NULL_FRAME) {
    return;
  }
  frame_t *frame = frame_from_ref(frame_ref);
  frame->flags |= FRAME_FLAG_REFERENCED;
}

void frame_clock_consider(frame_ref_t frame_ref) {
  if (frame_ref == NULL_FRAME) {
    return;
  }
  frame_t *frame = frame_from_ref(frame_ref);
  clock_reconsider(frame);
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

  /* Pre-seed a modest number of frames to avoid early starvation, but do not
   * exhaust the untyped pool or overflow the frame_data region. Under tight
   * SosFrameLimit configs, reserve half the quota for runtime allocations. */
    size_t seed_limit = 4096;
#ifdef CONFIG_SOS_FRAME_LIMIT
  if (CONFIG_SOS_FRAME_LIMIT != 0ul) {
    size_t half = CONFIG_SOS_FRAME_LIMIT / 2;
    if (half == 0) {
      half = 1;
    }
    seed_limit = MIN(seed_limit, half);
  }
#endif
  size_t seeded = 0;
  while (seeded < seed_limit) {
    frame_t *f = alloc_fresh_frame();
    if (f == NULL) {
      break;
    }
    push_front(&frame_table.free, f);
    seeded++;
  }
  ZF_LOGE("frame_table_init: seeded %zu frames (capacity=%lu free_len=%lu)",
          seeded, frame_table.capacity, frame_table.free.length);
}

cspace_t *frame_table_cspace(void) { return frame_table.cspace; }

frame_ref_t alloc_frame(frame_owner_t owner, frame_flags_t flags) {
  /* Proportional reserve: 10% of capacity, minimum 32 frames, maximum 256 frames.
   * This ensures eviction path has sufficient frames for:
   * - NFS PDU allocations (via ut_cspace_alloc_from_object)
   * - Pagefile slot metadata
   * - Worker queue state */
  const size_t min_reserve = 32;
  const size_t max_reserve = 256;
  const size_t proportional = frame_table.capacity / 10;
  const size_t reserve = MAX(min_reserve, MIN(max_reserve, proportional));

  /* Proactive reclamation threshold to avoid entering a no-free-frame state
   * where libnfs cannot allocate encode buffers. */
  const size_t low_watermark = reserve + 96;

  /* Log reserve sizing once during first allocation for diagnostics. */
  static bool reserve_logged = false;
  if (!reserve_logged) {
    ZF_LOGE("alloc_frame: kernel reserve=%zu frames (%zu KiB) for capacity=%lu",
            reserve, (reserve * BIT(seL4_PageBits)) / 1024, frame_table.capacity);
    reserve_logged = true;
  }

  /* Do not consume the reserve for user allocations; kernel may dip into it. */
  frame_t *frame = NULL;
  if (owner == FRAME_OWNER_KERNEL || frame_table.free.length > reserve) {
    frame = pop_front(&frame_table.free);
  }

  /* If we're getting close to the low watermark and paging is available,
   * evict a small batch before we run completely dry. Reserve enforcement
   * occurs at consumption time (below), not during eviction itself. */
  if (frame == NULL && pagefile_is_ready() &&
      frame_table.free.length <= low_watermark && frame_table.clock.length > 0) {
    size_t evict_budget = low_watermark - frame_table.free.length + 1;
    while (evict_budget-- > 0 && frame_table.free.length <= low_watermark) {
      if (evict_one_frame() != 0) {
        break;
      }
      int rc = pageout_wait_blocking();
      if (rc != 0) {
        ZF_LOGE("alloc_frame: proactive pageout rc=%d", rc);
        break;
      }
    }
    /* Enforce reserve at consumption: user allocations respect kernel reserve. */
    if (owner == FRAME_OWNER_KERNEL || frame_table.free.length > reserve) {
      frame = pop_front(&frame_table.free);
    }
  }

  /* Bounded retry budget for eviction-backed allocation in case of transient
   * pagefile I/O failures. */
  const int max_evict_retries = 8;

  /* Pre-flight check: if pagefile is ready but heap is critically low,
   * eviction will likely fail. Release NFS heap reserve proactively and
   * re-check before attempting eviction. */
  const size_t heap_critical_threshold = 96 * 1024;  /* 96 KiB */

  if (frame == NULL && pagefile_is_ready()) {
    size_t heap_free = morecore_free_bytes();
    if (heap_free < heap_critical_threshold) {
      ZF_LOGE("alloc_frame: heap critically low before eviction (free_bytes=%zu, threshold=%zu)",
              heap_free, heap_critical_threshold);
      /* Attempt to release NFS heap reserve to create headroom. */
      if (heap_reserve_release()) {
        heap_free = morecore_free_bytes();
        ZF_LOGE("alloc_frame: released NFS heap reserve, retrying (free_bytes=%zu)", heap_free);
      } else {
        ZF_LOGE("alloc_frame: NFS heap reserve already exhausted; eviction may fail");
      }
    }
  }

  /* Prefer eviction (if available) before minting new frames to avoid ut exhaustion. */
  int evict_attempts = 0;
  while (frame == NULL && pagefile_is_ready() && evict_attempts < max_evict_retries) {
    if (evict_one_frame() == 0) {
      /* Log heap state immediately after eviction submission. */
      ZF_LOGD("alloc_frame: eviction submitted, awaiting completion (heap_free=%zu frames_free=%lu)",
              morecore_free_bytes(), frame_table.free.length);

      int rc = pageout_wait_blocking();
      if (rc != 0) {
        ZF_LOGE("alloc_frame: pageout_wait_blocking rc=%d (heap_free=%zu)", rc, morecore_free_bytes());
        evict_attempts++;
        continue; /* try another victim */
      }
      /* Enforce reserve at consumption: kernel allocations bypass, user respects reserve. */
      if (frame_table.free.length > reserve || owner == FRAME_OWNER_KERNEL) {
        frame = pop_front(&frame_table.free);
      } else {
        /* Successfully freed frame, but reserve protects it for kernel use. */
        ZF_LOGD("alloc_frame: eviction succeeded but frame reserved for kernel (free_len=%lu, reserve=%zu)",
                frame_table.free.length, reserve);
        break;
      }
    } else {
      ZF_LOGE("alloc_frame: eviction attempt failed (clock_len=%lu)", frame_table.clock.length);
      break;
    }
  }

  if (frame == NULL) {
    frame = alloc_fresh_frame();
    if (frame == NULL) {
      ZF_LOGE("alloc_frame: alloc_fresh_frame failed (used=%lu cap=%lu free_len=%lu clock=%lu)",
              frame_table.used, frame_table.capacity, frame_table.free.length,
              frame_table.clock.length);
    }
  }

  if (frame == NULL && pagefile_is_ready()) {
    /* Attempt synchronous eviction to free a frame (bounded retries) */
    evict_attempts = 0;
    while (frame == NULL && pagefile_is_ready() && evict_attempts < max_evict_retries) {
      if (evict_one_frame() == 0) {
        /* Log heap state for final eviction attempt. */
        ZF_LOGD("alloc_frame: final eviction submitted (heap_free=%zu frames_free=%lu)",
                morecore_free_bytes(), frame_table.free.length);

        int rc = pageout_wait_blocking();
        if (rc != 0) {
          ZF_LOGE("alloc_frame: final eviction pageout_wait_blocking rc=%d (heap_free=%zu)",
                  rc, morecore_free_bytes());
          evict_attempts++;
          continue;
        }
        /* Enforce reserve at consumption: kernel allocations bypass, user respects reserve. */
        if (frame_table.free.length > reserve || owner == FRAME_OWNER_KERNEL) {
          frame = pop_front(&frame_table.free);
        } else {
          /* Successfully freed frame, but reserve protects it for kernel use. */
          ZF_LOGD("alloc_frame: final eviction succeeded but frame reserved for kernel (free_len=%lu, reserve=%zu)",
                  frame_table.free.length, reserve);
          break;
        }
      } else {
        ZF_LOGE("alloc_frame: final eviction attempt failed (clock_len=%lu)", frame_table.clock.length);
        break;
      }
    }
  }

  if (frame == NULL) {
    ZF_LOGE("alloc_frame: failed (owner=%d pagefile_ready=%d free_len=%lu clock_len=%lu reserve=%zu)",
            owner, pagefile_is_ready(), frame_table.free.length, frame_table.clock.length, reserve);
  }

  if (frame != NULL) {
    frame->owner = owner;
    frame->flags = flags;
    frame->pin_count = (flags & FRAME_FLAG_PINNED) ? 1 : 0;
    frame->swap_slot = 0;
    /* Ensure stale clock links are cleared before reconsidering eligibility. */
    frame->clock_prev = NULL_FRAME;
    frame->clock_next = NULL_FRAME;
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
    if (frame->list_id == ALLOCATED_LIST) {
      remove_frame(&frame_table.allocated, frame);
    } else {
      ZF_LOGE("free_frame: frame %zu not on allocated list (list_id=%d), skipping double-free",
              frame_ref, frame->list_id);
      return;
    }
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

bool frame_bind_slot(frame_ref_t frame_ref, uint32_t slot) {
  if (frame_ref == NULL_FRAME || slot == PAGEFILE_INVALID_SLOT) {
    return false;
  }
  frame_t *frame = frame_from_ref(frame_ref);
  if (frame->swap_slot != 0 && frame->swap_slot != slot) {
    return false;
  }
  frame->swap_slot = slot;
  return true;
}

void frame_unbind_slot(frame_ref_t frame_ref) {
  if (frame_ref == NULL_FRAME) {
    return;
  }
  frame_t *frame = frame_from_ref(frame_ref);
  frame->swap_slot = 0;
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

/* Process a single page-out completion if available. Returns 0 on success,
 * -SOS_EAGAIN if none available, or -errno on failure. */
static int pageout_process_one_completion(void) {
  size_t frame_ref = 0;
  uint32_t slot = 0;
  int rc = pageout_poll_complete(&frame_ref, &slot);
  if (rc == -SOS_EAGAIN) {
    return rc;
  }
  if (rc != 0) {
    /* Even on failure, release the slot to avoid leaks and attempt rollback. */
    pagefile_free_slot(slot);
    if (rc > 0) {
      int abort_rc = vm_pageout_abort(frame_ref, slot);
      if (abort_rc != 0) {
        ZF_LOGE("pageout completion rollback failed rc=%d frame=%zu slot=%u", abort_rc, frame_ref, slot);
      }
    }
    return rc;
  }

  rc = vm_pageout_finalise(frame_ref, slot);
  if (rc != 0) {
    ZF_LOGE("pageout completion finalise failed rc=%d frame=%zu slot=%u", rc, frame_ref, slot);
    pagefile_free_slot(slot);
    return rc;
  }

  ZF_LOGE("pageout completion success frame=%zu slot=%u", frame_ref, slot);
  return 0;
}

/* Poll for page-out completion up to max_iters times. */
static int pageout_wait_for_completion(size_t max_iters) {
  for (size_t i = 0; i < max_iters; i++) {
    int rc = pageout_process_one_completion();
    if (rc == 0) {
      return 0;
    }
    if (rc != -SOS_EAGAIN) {
      return rc;
    }
    seL4_Yield();
  }
  return -SOS_EAGAIN;
}

/* Block until at least one page-out completion is processed or an error occurs.
 * Bounded retry: if ENOMEM persists for max_enomem_retries consecutive polls,
 * propagate the error to avoid infinite spinning. */
static int pageout_wait_blocking(void) {
  static size_t pwb_log_count = 0;
  const int max_enomem_retries = 128;
  int enomem_count = 0;

  if (pwb_log_count < 32) {
    ZF_LOGE("pageout_wait_blocking: enter (free_bytes=%zu free_frames=%lu clock=%lu)",
            morecore_free_bytes(), frame_table.free.length, frame_table.clock.length);
    pwb_log_count++;
  }

  while (true) {
    int rc = pageout_process_one_completion();
    if (rc == 0) {
      if (pwb_log_count < 64) {
        ZF_LOGE("pageout_wait_blocking: completion rc=0");
        pwb_log_count++;
      }
      return 0;
    }
    if (rc != -SOS_EAGAIN) {
      if (rc == -ENOMEM) {
        enomem_count++;
        if (enomem_count >= max_enomem_retries) {
          /* Disambiguate: ENOMEM from pagefile write indicates kernel heap exhaustion,
           * not backing store failure. Provide actionable diagnostics. */
          ZF_LOGE("pageout_wait_blocking: KERNEL HEAP EXHAUSTED after %d attempts", enomem_count);
          ZF_LOGE("  heap_free=%zu frames_free=%lu clock_len=%lu reserve_status=CHECK_NFS_HANDLER",
                  morecore_free_bytes(), frame_table.free.length, frame_table.clock.length);
          ZF_LOGE("  DIAGNOSIS: NFS pagefile I/O cannot proceed due to insufficient heap for PDU encoding.");
          ZF_LOGE("  REMEDY: Increase NFS_HEAP_MIN_RESERVE or reduce concurrent eviction load.");
          return rc;
        }
      } else if (rc == -EIO || rc == -ENOSPC) {
        /* Backing store failure: distinct from heap exhaustion. */
        ZF_LOGE("pageout_wait_blocking: BACKING STORE ERROR rc=%d (EIO=%d ENOSPC=%d)",
                rc, -EIO, -ENOSPC);
        ZF_LOGE("  DIAGNOSIS: NFS pagefile I/O failed due to network or storage fault.");
        return rc;
      } else {
        /* Other errors: propagate immediately with context. */
        if (pwb_log_count < 64) {
          ZF_LOGE("pageout_wait_blocking: error rc=%d free_bytes=%zu free_len=%lu clock_len=%lu",
                  rc, morecore_free_bytes(), frame_table.free.length, frame_table.clock.length);
          pwb_log_count++;
        }
        return rc;
      }
    }
    seL4_Yield();
  }
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
      ZF_LOGE("alloc_fresh_frame: bump_capacity failed (used=%lu cap=%lu)",
              frame_table.used, frame_table.capacity);
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
    ZF_LOGE("alloc_fresh_frame: alloc_frame_at failed vaddr=0x%lx", (unsigned long)vaddr);
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
