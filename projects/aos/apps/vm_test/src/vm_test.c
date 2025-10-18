#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

static uint8_t pattern_byte(uint8_t seed, size_t index) {
  return (uint8_t)(seed + (uint8_t)(index & 0xff));
}

static void touch_range(uint8_t *base, size_t length, uint8_t seed) {
  for (size_t i = 0; i < length; i++) {
    base[i] = pattern_byte(seed, i);
  }

  for (size_t i = 0; i < length; i++) {
    uint8_t want = pattern_byte(seed, i);
    if (base[i] != want) {
      fprintf(stderr, "memory mismatch at +%zu: got 0x%02x, expected 0x%02x\n",
              i, base[i], want);
      exit(1);
    }
  }
}

int main(void) {
  const long page_size = sysconf(_SC_PAGESIZE);
  if (page_size <= 0) {
    fprintf(stderr, "page size unavailable\n");
    return 1;
  }

  printf("[vm_test] page size = %ld bytes\n", page_size);

  void *heap_base = sbrk(0);
  if (heap_base == (void *)-1) {
    perror("sbrk(0)");
    return 1;
  }

  const size_t heap_pages = 8;
  const size_t heap_bytes = (size_t)page_size * heap_pages;

  if (sbrk(heap_bytes) == (void *)-1) {
    perror("sbrk(grow)");
    return 1;
  }

  printf("[vm_test] grew heap by %zu bytes from %p\n", heap_bytes, heap_base);
  touch_range((uint8_t *)heap_base, heap_bytes, 0x5a);
  printf("[vm_test] heap touch complete\n");

  const size_t anon_bytes = 512 * 1024;
  void *anon_map = mmap(NULL, anon_bytes, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (anon_map == MAP_FAILED) {
    perror("mmap");
    return 1;
  }

  printf("[vm_test] mapped %zu anonymous bytes at %p\n", anon_bytes, anon_map);
  touch_range((uint8_t *)anon_map, anon_bytes, 0xa5);
  printf("[vm_test] mmap touch complete\n");

  if (munmap(anon_map, anon_bytes) != 0) {
    if (errno != ENOSYS) {
      perror("munmap");
      return 1;
    }
    printf("[vm_test] munmap not implemented yet (errno=ENOSYS); skipping\n");
  } else {
    printf("[vm_test] unmapped anonymous region\n");
  }

  printf("[vm_test] success\n");
  return 0;
}
