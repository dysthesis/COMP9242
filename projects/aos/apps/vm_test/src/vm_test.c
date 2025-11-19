#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <utils/page.h>

#define NBLOCKS 9
#define NPAGES_PER_BLOCK 28
#define TEST_ADDRESS 0x8000000000ull

static void do_pt_test(char **buf) {
  printf("[do_pt_test] begin buf=%p\n", (void *)buf);
  for (int b = 0; b < NBLOCKS; b++) {
    printf("[do_pt_test] setting block %d base=%p\n", b, (void *)buf[b]);
    for (int p = 0; p < NPAGES_PER_BLOCK; p++) {
      char value = (char)p;
      char *page_addr = &buf[b][p * PAGE_SIZE_4K];
      printf("[do_pt_test]   write block=%d page=%d addr=%p value=%d\n", b, p, (void *)page_addr, (int)value);
      buf[b][p * PAGE_SIZE_4K] = value;
    }
  }

  for (int b = 0; b < NBLOCKS; b++) {
    printf("[do_pt_test] verifying block %d base=%p\n", b, (void *)buf[b]);
    for (int p = 0; p < NPAGES_PER_BLOCK; p++) {
      char *page_addr = &buf[b][p * PAGE_SIZE_4K];
      char got = buf[b][p * PAGE_SIZE_4K];
      char want = (char)p;
      printf("[do_pt_test]   check block=%d page=%d addr=%p got=%d want=%d\n", b, p, (void *)page_addr, (int)got, (int)want);
      assert(got == want);
    }
  }
  printf("[do_pt_test] complete\n");
}

static void pt_test(void) {
  printf("[pt_test] begin\n");
  char buf1[NBLOCKS][NPAGES_PER_BLOCK * PAGE_SIZE_4K];
  char *buf1_ptrs[NBLOCKS];
  char *buf2[NBLOCKS];

  for (int b = 0; b < NBLOCKS; b++) {
    printf("[pt_test] buf1_ptrs[%d] initialised to %p\n", b, (void *)buf1[b]);
    buf1_ptrs[b] = buf1[b];
  }

  printf("[pt_test] asserting stack base buf1=%p exceeds test address 0x%llx\n", (void *)buf1, (unsigned long long)TEST_ADDRESS);
  assert((uintptr_t)buf1 > TEST_ADDRESS);
  printf("[pt_test] stack address assertion passed\n");

  printf("[pt_test] invoking do_pt_test on stack buffers\n");
  do_pt_test(buf1_ptrs);
  printf("[pt_test] stack buffer test complete\n");

  for (int b = 0; b < NBLOCKS; b++) {
    size_t alloc_bytes = NPAGES_PER_BLOCK * PAGE_SIZE_4K;
    printf("[pt_test] allocating heap block %d size=%zu\n", b, alloc_bytes);
    buf2[b] = malloc(NPAGES_PER_BLOCK * PAGE_SIZE_4K);
    printf("[pt_test] allocation result block %d addr=%p\n", b, (void *)buf2[b]);
    assert(buf2[b] != NULL);
  }

  printf("[pt_test] invoking do_pt_test on heap buffers\n");
  do_pt_test(buf2);
  printf("[pt_test] heap buffer test complete\n");

  for (int b = 0; b < NBLOCKS; b++) {
    printf("[pt_test] freeing heap block %d addr=%p\n", b, (void *)buf2[b]);
    free(buf2[b]);
  }
  printf("[pt_test] end\n");
}

#define FILE_TEST_PAGES 8
#define FILE_TEST_NAME "pager_test.bin"

static void file_mmap_test(void) {
  printf("[file_mmap_test] begin\n");
  const size_t length = FILE_TEST_PAGES * PAGE_SIZE_4K;
  int fd = open(FILE_TEST_NAME, O_RDWR | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) {
    printf("[file_mmap_test] open failed errno=%d\n", errno);
    abort();
  }

  for (size_t page = 0; page < FILE_TEST_PAGES; page++) {
    uint8_t byte = (uint8_t)page;
    for (size_t offset = 0; offset < PAGE_SIZE_4K; offset++) {
      if (write(fd, &byte, sizeof(byte)) != sizeof(byte)) {
        printf("[file_mmap_test] write failed errno=%d\n", errno);
        abort();
      }
    }
  }

  if (lseek(fd, 0, SEEK_SET) != 0) {
    printf("[file_mmap_test] lseek failed errno=%d\n", errno);
    abort();
  }

  uint8_t *mapped = mmap(NULL, length, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
  if (mapped == MAP_FAILED) {
    printf("[file_mmap_test] mmap failed errno=%d\n", errno);
    abort();
  }
  close(fd);

  for (size_t page = 0; page < FILE_TEST_PAGES; page++) {
    uint8_t expected = (uint8_t)page;
    uint8_t value = mapped[page * PAGE_SIZE_4K];
    printf("[file_mmap_test] page=%zu addr=%p value=%u expected=%u\n",
           page, (void *)&mapped[page * PAGE_SIZE_4K], value, expected);
    if (value != expected) {
      printf("[file_mmap_test] mismatch at page=%zu value=%u expected=%u\n",
             page, value, expected);
      abort();
    }
  }

  if (munmap(mapped, length) != 0) {
    printf("[file_mmap_test] munmap failed errno=%d\n", errno);
    abort();
  }

  if (unlink(FILE_TEST_NAME) != 0) {
    printf("[file_mmap_test] unlink failed errno=%d\n", errno);
  }
  printf("[file_mmap_test] end\n");
}

int main(void) {
  printf("[vm_test] entering main\n");
  pt_test();
  file_mmap_test();
  printf("[vm_test] main complete, exiting successfully\n");
  return 0;
}
