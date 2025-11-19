#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <inttypes.h>
#include <sys/mman.h>
#include <utils/page.h>
#include <sos.h>

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
/* SOS exposes a flat namespace via NFS; slash characters are rejected during
 * path normalisation, so we stick to a bare filename and rely on the runtime
 * deployment to place us on a writable share. */
#define FILE_TEST_TEMPLATE "pager_test.XXXXXX"

static void log_errno(const char *label, const char *path) {
  printf("[file_mmap_test] %s (path=%s) failed errno=%d (%s)\n",
         label, path, errno, strerror(errno));
}

static int write_page_byte(int fd, uint8_t value) {
  uint8_t buf[PAGE_SIZE_4K];
  memset(buf, value, sizeof(buf));

  size_t written_total = 0;
  while (written_total < sizeof(buf)) {
    ssize_t rc = write(fd, buf + written_total, sizeof(buf) - written_total);
    if (rc <= 0) {
      return -1;
    }
    written_total += (size_t)rc;
  }
  return 0;
}

static bool file_mmap_test(void) {
  printf("[file_mmap_test] begin\n");
  const size_t length = FILE_TEST_PAGES * PAGE_SIZE_4K;
  char path[] = FILE_TEST_TEMPLATE;
  int fd = mkstemp(path);
  if (fd < 0) {
    log_errno("mkstemp", FILE_TEST_TEMPLATE);
    return false;
  }
  printf("[file_mmap_test] using backing file %s\n", path);

  bool success = false;
  uint8_t *mapped = MAP_FAILED;

  for (size_t page = 0; page < FILE_TEST_PAGES; page++) {
    uint8_t byte = (uint8_t)page;
    if (write_page_byte(fd, byte) != 0) {
      log_errno("write", path);
      goto cleanup;
    }
  }

  if (lseek(fd, 0, SEEK_SET) != 0) {
    log_errno("lseek", path);
    goto cleanup;
  }

  mapped = mmap(NULL, length, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
  if (mapped == MAP_FAILED) {
    log_errno("mmap", path);
    goto cleanup;
  }

  close(fd);
  fd = -1;

  for (size_t page = 0; page < FILE_TEST_PAGES; page++) {
    uint8_t expected = (uint8_t)page;
    uint8_t value = mapped[page * PAGE_SIZE_4K];
    printf("[file_mmap_test] page=%zu addr=%p value=%u expected=%u\n",
           page, (void *)&mapped[page * PAGE_SIZE_4K], value, expected);
    if (value != expected) {
      printf("[file_mmap_test] mismatch at page=%zu value=%u expected=%u\n",
             page, value, expected);
      goto cleanup;
    }
  }

  if (munmap(mapped, length) != 0) {
    log_errno("munmap", path);
    goto cleanup;
  }
  mapped = MAP_FAILED;

  success = true;

cleanup:
  if (mapped != MAP_FAILED) {
    munmap(mapped, length);
  }
  if (fd >= 0) {
    close(fd);
  }
  if (unlink(path) != 0) {
    log_errno("unlink", path);
  }

  if (success) {
    printf("[file_mmap_test] end\n");
  } else {
    printf("[file_mmap_test] failed; see logs above for details\n");
  }
  return success;
}

int main(void) {
  printf("[vm_test] entering main\n");
  pt_test();
  if (!file_mmap_test()) {
    printf("[vm_test] file_mmap_test failed\n");
    return 1;
  }

  printf("[vm_test] calling sos_pager_stats to capture metrics\n");
  sos_pager_stats_t stats;
  int pager_result = sos_pager_stats(&stats);
  if (pager_result == 0) {
    printf("[vm_test] PAGER STATS:\n");
    printf("  deferred_faults:   %" PRIu64 "\n", stats.deferred_faults);
    printf("  dedup_hits:        %" PRIu64 "\n", stats.dedup_hits);
    printf("  job_submissions:   %" PRIu64 "\n", stats.job_submissions);
    printf("  job_completions:   %" PRIu64 "\n", stats.job_completions);
    printf("  job_failures:      %" PRIu64 "\n", stats.job_failures);
  } else {
    printf("[vm_test] sos_pager_stats failed with errno=%d\n", sos_errno);
  }

  printf("[vm_test] main complete, exiting successfully\n");
  return 0;
}
