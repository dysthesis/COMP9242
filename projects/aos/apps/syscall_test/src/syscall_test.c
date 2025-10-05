#include "unistd.h"
#include <aos/sel4_zf_logif.h>
#include <assert.h>
#include <sel4/sel4.h>
#include <sos.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#define SMALL_BUF_SZ 2
#define MEDIUM_BUF_SZ 256

char test_str[] = "Basic test string for read/write";
char small_buf[SMALL_BUF_SZ];

int test_buffers(int console_fd) {
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
  test_buffers(10);

  return 0;
}
