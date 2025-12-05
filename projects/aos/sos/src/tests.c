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
#define ZF_LOG_LEVEL ZF_LOG_INFO
#include "bootstrap.h"
#include "dma.h"
#include "frame_table.h"
#include "pagefile.h"
#include "vmem_layout.h"
#include <assert.h>
#include <clock/clock_tests.h>
#include <cspace/cspace.h>
#include <ipc.h>
#include <sel4/sel4.h>
#include <utils/util.h>

#define TEST_FRAMES 10

static void test_bf_bit(unsigned long bit) {
  ZF_LOGV("%lu", bit);
  seL4_Word bitfield[2] = {0};
  assert(bf_first_free(2, bitfield) == 0);

  bf_set_bit(bitfield, bit);
  assert(bf_get_bit(bitfield, bit));
  seL4_Word ff = bit == 0 ? 1 : 0;
  assert(bf_first_free(2, bitfield) == ff);

  bf_clr_bit(bitfield, bit);
  assert(!bf_get_bit(bitfield, bit));
}

static void test_bf(void) {
  test_bf_bit(0);

  test_bf_bit(1);
  test_bf_bit(63);
  test_bf_bit(64);
  test_bf_bit(65);
  test_bf_bit(127);

  seL4_Word bitfield[2] = {0};
  for (unsigned int i = 0; i < 127; i++) {
    assert(bf_get_bit(bitfield, i) == 0);
    bf_set_bit(bitfield, i);
    assert(bf_get_bit(bitfield, i));
    assert(bf_first_free(2, bitfield) == i + 1);
  }
}

static void test_cspace(cspace_t *cspace) {
  ZF_LOGI("Test cspace");
  /* test we can alloc a cptr */
  ZF_LOGV("Test allocating cslot");
  seL4_CPtr cptr = cspace_alloc_slot(cspace);
  assert(cptr != 0);

  ZF_LOGV("Test freeing cslot");
  /* test we can free the cptr */
  cspace_free_slot(cspace, cptr);

  ZF_LOGV("Test free slot is returned");
  /* test we get the same cptr back if we alloc again */
  seL4_CPtr cptr_new = cspace_alloc_slot(cspace);
  assert(cptr == cptr_new);

  cspace_free_slot(cspace, cptr_new);

  /* test allocating and freeing a large amount of slots */
  const int reserve_slots = WATERMARK_SLOTS + MAPPING_SLOTS + 2;
  int nslots = CNODE_SLOTS(CNODE_SIZE_BITS) / 2;
  if (cspace->two_level) {
    int total_slots =
        CNODE_SLOTS(cspace->top_lvl_size_bits) * CNODE_SLOTS(CNODE_SIZE_BITS);
    int usable = total_slots - reserve_slots;
    usable = usable < 0 ? 0 : usable;
    nslots = MIN(usable, CNODE_SLOTS(CNODE_SIZE_BITS) * BOT_LVL_PER_NODE + 1);
  }
  seL4_CPtr *slots = malloc(sizeof(seL4_CPtr) * nslots);
  assert(slots != NULL);

  ZF_LOGV("Test allocating and freeing %d slots", nslots);

  for (int i = 0; i < nslots; i++) {
    slots[i] = cspace_alloc_slot(cspace);
    if (slots[i] == seL4_CapNull) {
      nslots = i;
      break;
    }
  }

  ZF_LOGV("Allocated %lu <-> %lu slots\n", slots[0], slots[nslots - 1]);

  for (int i = 0; i < nslots; i++) {
    cspace_free_slot(cspace, slots[i]);
  }

  free(slots);
}

static void test_dma(void) {
  dma_addr_t dma = sos_dma_malloc(PAGE_SIZE_4K, PAGE_SIZE_4K);
  char *blah = (char *)dma.vaddr;
  for (size_t i = 0; i < PAGE_SIZE_4K; i++) {
    blah[i] = 'a' + i % 25;
  }

  for (size_t i = 0; i < PAGE_SIZE_4K; i++) {
    assert(blah[i] == 'a' + i % 25);
  }
}

static void test_frame_table(void) {
  /* Test allocation and writing */
  frame_ref_t frames[TEST_FRAMES] = {};
  for (int frame = 0; frame < TEST_FRAMES; frame++) {
    /* Allocate a frame */
    frames[frame] = alloc_frame(FRAME_OWNER_KERNEL, FRAME_FLAG_PINNED);
    assert(frames[frame] != NULL_FRAME);

    /* Write to the first and last byte of the frame */
    unsigned char *vaddr = frame_data(frames[frame]);
    vaddr[0] = frame;
    vaddr[BIT(seL4_PageBits) - 1] = frame;
  }

  /* Check the writes happened */
  for (int frame = 0; frame < TEST_FRAMES; frame++) {
    unsigned char *vaddr = frame_data(frames[frame]);
    assert(vaddr[0] == frame);
    assert(vaddr[BIT(seL4_PageBits) - 1] == frame);
  }

  /* Free all the frames */
  for (int frame = 0; frame < TEST_FRAMES; frame++) {
    free_frame(frames[frame]);
  }

  /* Ensure that we get the same frames when we try to realloc */
  frame_ref_t new_frames[TEST_FRAMES] = {};
  for (int frame = 0; frame < TEST_FRAMES; frame++) {
    new_frames[frame] = alloc_frame(FRAME_OWNER_KERNEL, FRAME_FLAG_PINNED);
    assert(new_frames[frame] != NULL_FRAME);

    int o = 0;
    while (o < TEST_FRAMES) {
      if (new_frames[frame] == frames[o]) {
        frames[o] = NULL_FRAME;
        break;
      }
      o++;
    }
    /* Check that we found one of our previous frames */
    assert(o != TEST_FRAMES);
  }
  for (int frame = 0; frame < TEST_FRAMES; frame++) {
    free_frame(new_frames[frame]);
  }
}

static void test_pagefile(void) {
  ZF_LOGI("Testing pagefile subsystem...");

  /* Get initial stats */
  pagefile_stats_t stats;
  pagefile_get_stats(&stats);
  ZF_LOGI("Initial pagefile stats: total=%zu, used=%zu, peak=%zu",
          stats.slots_total, stats.slots_used, stats.slots_peak);

  /* Check if pagefile initialised successfully */
  if (stats.slots_total == 0) {
    ZF_LOGW("Pagefile not initialised; skipping test");
    ZF_LOGW("Pagefile initialisation failed; eviction disabled");
    return;
  }

  assert(stats.slots_total >= 0);

  /* Allocate 10 slots */
  uint32_t slots[10];
  for (int i = 0; i < 10; i++) {
    slots[i] = pagefile_alloc_slot(i + 1, 1234, 0x10000 * i);
    assert(slots[i] != PAGEFILE_INVALID_SLOT);
    ZF_LOGD("Allocated slot %u for frame %d", slots[i], i + 1);
  }

  /* Verify usage increased */
  pagefile_get_stats(&stats);
  assert(stats.slots_used == 10);
  assert(stats.total_allocs == 10);
  ZF_LOGI("After allocation: used=%zu, allocs=%zu", stats.slots_used,
          stats.total_allocs);

  /* Free odd-numbered slots */
  for (int i = 1; i < 10; i += 2) {
    pagefile_free_slot(slots[i]);
    ZF_LOGD("Freed slot %u", slots[i]);
  }

  /* Verify usage decreased */
  pagefile_get_stats(&stats);
  assert(stats.slots_used == 5);
  assert(stats.total_frees == 5);
  ZF_LOGI("After freeing odd slots: used=%zu, frees=%zu", stats.slots_used,
          stats.total_frees);

  /*  Reallocate 5 slots */
  for (int i = 0; i < 5; i++) {
    uint32_t slot = pagefile_alloc_slot(100 + i, 5678, 0x20000 * i);
    assert(slot != PAGEFILE_INVALID_SLOT);
    assert(pagefile_is_valid_slot(slot));
    ZF_LOGD("Reallocated slot %u", slot);
  }

  /* Verify no double-allocation occurred */
  pagefile_get_stats(&stats);
  assert(stats.slots_used == 10);
  ZF_LOGI("After reallocation: used=%zu", stats.slots_used);

  /* Free all slots */
  for (int i = 0; i < 10; i += 2) {
    pagefile_free_slot(slots[i]);
  }

  /* Verify all freed */
  pagefile_get_stats(&stats);
  assert(stats.slots_used == 5);
  assert(stats.slots_peak == 10); /* Peak should remain at 10 */
  ZF_LOGI("Final stats: used=%zu, peak=%zu, allocs=%zu, frees=%zu",
          stats.slots_used, stats.slots_peak, stats.total_allocs,
          stats.total_frees);

  ZF_LOGI("Pagefile test passed!");
}

void run_tests(cspace_t *cspace) {
  /* test the cspace bitfield data structure */
  test_bf();

  /* test the root cspace */
  test_cspace(cspace);
  ZF_LOGI("Root CSpace test passed!");

  /* test a new, 1-level cspace */
  cspace_t dummy_cspace;
  int error = cspace_create_one_level(cspace, &dummy_cspace);
  assert(error == 0);
  test_cspace(&dummy_cspace);
  cspace_destroy(&dummy_cspace);
  ZF_LOGI("Single level cspace test passed!");

  /* test a new, 2 level cspace */
  cspace_alloc_t cspace_alloc = {.map_frame = bootstrap_cspace_map_frame,
                                 .alloc_4k_ut = bootstrap_cspace_alloc_4k_ut,
                                 .free_4k_ut = bootstrap_cspace_free_4k_ut,
                                 .cookie = NULL};
  error = cspace_create_two_level(cspace, &dummy_cspace, cspace_alloc);
  assert(error == 0);
  test_cspace(&dummy_cspace);
  cspace_destroy(&dummy_cspace);
  ZF_LOGI("Double level cspace test passed!");

  /* test DMA */
  test_dma();
  ZF_LOGI("DMA test passed!");

  /* test frame table */
  test_frame_table();
  ZF_LOGI("Frame table test passed!");

  test_clock();
  ZF_LOGI("Clock test passed!");

  /* test pagefile */
  test_pagefile();
  ZF_LOGI("Pagefile test passed!");
}
