#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define PAGEFILE_INVALID_SLOT ((uint32_t)0)

typedef struct pagefile_stats {
  size_t slots_total;
  size_t slots_used;
  size_t slots_peak;
  size_t total_allocs;
  size_t total_frees;
} pagefile_stats_t;

void pagefile_init(void);
void pagefile_shutdown(void);
uint32_t pagefile_alloc_slot(size_t frame, uint32_t pid, size_t vaddr);
void pagefile_free_slot(uint32_t slot);
bool pagefile_is_valid_slot(uint32_t slot);
void pagefile_get_stats(pagefile_stats_t *out);
bool pagefile_is_ready(void);
bool pagefile_init_failed(void);

/* Synchronous pagefile I/O helpers */
int pagefile_write_slot(uint32_t slot, const void *buf, size_t len);
int pagefile_read_slot(uint32_t slot, void *buf, size_t len);
