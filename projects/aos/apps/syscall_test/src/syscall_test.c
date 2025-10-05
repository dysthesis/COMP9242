#include "unistd.h"
#include <aos/sel4_zf_logif.h>
#include <assert.h>
#include <sel4/arch/constants.h>
#include <sel4/sel4.h>
#include <sos.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#define SMALL_BUF_SZ 2
#define MEDIUM_BUF_SZ 256

enum {
  SOS_SHARED_PAGE_ALLOC = 0x100u,
  SOS_SHARED_PAGE_FREE = 0x101u,
};

#define SHARED_PAGE_TEST_BASE 0xC0000000u
_Static_assert((SHARED_PAGE_TEST_BASE & ((1u << seL4_PageBits) - 1u)) == 0,
               "Test VA must remain page aligned");

static const uintptr_t shared_page_test_base = SHARED_PAGE_TEST_BASE;

static inline size_t shared_page_size(void) { return 1u << seL4_PageBits; }

static int shared_page_syscall(seL4_Word sysno, uintptr_t va, size_t size) {
  seL4_MessageInfo_t tag = seL4_MessageInfo_new(0, 0, 0, 4);
  seL4_SetMR(0, sysno);
  seL4_SetMR(1, (seL4_Word)va);
  seL4_SetMR(2, (seL4_Word)size);
  seL4_SetMR(3, 0);
  tag = seL4_Call(SOS_IPC_EP_CAP, tag);
  return (int32_t)seL4_GetMR(0);
}

static int shared_page_alloc(uintptr_t va, size_t size) {
  return shared_page_syscall(SOS_SHARED_PAGE_ALLOC, va, size);
}

static int shared_page_free(uintptr_t va) {
  return shared_page_syscall(SOS_SHARED_PAGE_FREE, va, 0);
}

void test_shared_page(void) {
  ZF_LOGV("[syscall_test] testing shared page allocation...\n");
  const size_t page_sz = shared_page_size();
  const uintptr_t user_va = shared_page_test_base;

  int err = shared_page_alloc(user_va, page_sz);
  assert(err == 0);

  volatile uint8_t *shared_page = (volatile uint8_t *)user_va;

  for (size_t i = 0; i < page_sz; i++) {
    assert(shared_page[i] == 0);
  }

  for (size_t i = 0; i < page_sz; i++) {
    shared_page[i] = (uint8_t)(i & 0xFFu);
  }

  for (size_t i = 0; i < page_sz; i++) {
    assert(shared_page[i] == (uint8_t)(i & 0xFFu));
  }

  err = shared_page_free(user_va);
  assert(err == 0);

  err = shared_page_alloc(user_va, page_sz);
  assert(err == 0);

  for (size_t i = 0; i < page_sz; i++) {
    assert(shared_page[i] == 0);
  }

  err = shared_page_free(user_va);
  assert(err == 0);
}

char test_str[] = "Basic test string for read/write";
char small_buf[SMALL_BUF_SZ];

int test_buffers(int console_fd) {
  ZF_LOGV("[syscall_test] testing syscalls...\n");
  /* test a small string from the code segment */
  int result = sos_write(console_fd, test_str, strlen(test_str));
  assert(result == strlen(test_str));

  /* test reading to a small buffer */
  result = sos_read(console_fd, small_buf, SMALL_BUF_SZ);
  /* make sure you type in at least SMALL_BUF_SZ */
  assert(result == SMALL_BUF_SZ);

  /* test reading into a large on-stack buffer */
  char stack_buf[MEDIUM_BUF_SZ];
  /* for this test you'll need to paste a lot of data into
     the console, without newlines */

  result = sos_read(console_fd, &stack_buf, MEDIUM_BUF_SZ);
  assert(result == MEDIUM_BUF_SZ);

  result = sos_write(console_fd, &stack_buf, MEDIUM_BUF_SZ);
  assert(result == MEDIUM_BUF_SZ);

  /* try sleeping */
  for (int i = 0; i < 5; i++) {
    time_t prev_seconds = time(NULL);
    sleep(1);
    time_t next_seconds = time(NULL);
    assert(next_seconds > prev_seconds);
    printf("Tick\n");
  }
}

int main(void) {
  ZF_LOGV("[syscall_test] Entered syscall testing app!\n");
  test_shared_page();
  ZF_LOGV("[syscall_test] shared page test passed!");
  test_buffers(10);
  ZF_LOGV("[syscall_test] syscall test passed!");

  return 0;
}
