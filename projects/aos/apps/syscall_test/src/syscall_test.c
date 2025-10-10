#include "unistd.h"
#include "utils/zf_log.h"
#include <aos/sel4_zf_logif.h>
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <sel4/sel4.h>
#include <sos.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#define SMALL_BUF_SZ 2
#define MEDIUM_BUF_SZ 256

char test_str[] = "Basic test string for read/write\n";
char small_buf[SMALL_BUF_SZ];

static void test_sos_open(void) {
  ZF_LOGI("[syscall_test] Testing sos_open()...\n");
  int fd_rd = sos_open("console", O_RDONLY);
  assert(fd_rd >= 0);

  int fd_wr = sos_open("console", O_WRONLY);
  assert(fd_wr >= 0);

  int fd_invalid = sos_open("not-a-device", O_RDONLY);
  ZF_LOGD("[syscall_test] invalid open returned %d (errno=%d)\n", fd_invalid,
          sos_errno);
  assert(fd_invalid == -1);
  // assert(sos_errno == ENODEV);

  char long_name[MAX_IO_BUF + 1];
  memset(long_name, 'a', sizeof long_name);
  long_name[MAX_IO_BUF] = '\0';
  int fd_long = sos_open(long_name, O_RDONLY);
  ZF_LOGD("[syscall_test] long-name open returned %d (errno=%d)\n", fd_long,
          sos_errno);
  assert(fd_long == -1);
  // assert(sos_errno == ENAMETOOLONG);
  // Clean up
  assert(sos_close(fd_wr) == 0);
  assert(sos_close(fd_rd) == 0);
  ZF_LOGI("[syscall_test] sos_open() tests successful!\n");
}

static void test_sos_read(void) {
  ZF_LOGI("[syscall_test] Testing sos_read()...\n");

  int write = sos_open("console", O_WRONLY);
  assert(write >= 0);

  int read = sos_open("console", O_RDONLY);
  assert(read >= 0);

  char buf[16] = {'a'};
  int n = sos_read(read, buf, sizeof buf);
  ZF_LOGI("[syscall_test] read(buf): %s", buf);
  assert(n >= 0);

  char big[8192] = {'a'};
  int m = sos_read(read, big, sizeof big);
  ZF_LOGI("[syscall_test] read(big): %s", big);
  assert(m >= 0 && m <= (int)sizeof big);

  assert(sos_close(read) == 0);
  assert(sos_close(write) == 0);

  ZF_LOGI("[syscall_test] sos_read() tests successful!\n");
}

static void test_sos_close(void) {
  ZF_LOGI("[syscall_test] Testing sos_close()...\n");

  int result;
  result = sos_close(-1);
  ZF_LOGD("[syscall_test] close(-1): %d (errno=%d)\n", result, sos_errno);
  assert(result == -1);
  // assert(sos_errno == EBADF);

  result = sos_close(7);
  ZF_LOGD("[syscall_test] close(7) (unopened): %d (errno=%d)\n", result,
          sos_errno);
  assert(result == -1);
  // assert( sos_errno == EBADF);

  result = sos_close(9999);
  ZF_LOGD("[syscall_test] close(9999): %d (errno=%d)\n", result, sos_errno);
  assert(result == -1);
  // assert(sos_errno == EBADF);

  // I/O devices
  result = sos_close(0);
  assert(result == 0);
  result = sos_close(1);
  assert(result == 0);
  result = sos_close(2);
  assert(result == 0);

  // double closes
  int fd_wr = sos_open("console", O_WRONLY);
  assert(fd_wr >= 0);
  result = sos_close(fd_wr);
  ZF_LOGD("[syscall_test] close(writer): %d (errno=%d)\n", result, sos_errno);
  assert(result == 0);
  result = sos_close(fd_wr);
  ZF_LOGD("[syscall_test] close(writer) again: %d (errno=%d)\n", result,
          sos_errno);
  assert(result == -1);
  // assert(sos_errno == EBADF);

  // reader exclusivity, only one should be allowed, the rest gets EBUSY
  int fd_rd1 = sos_open("console", O_RDONLY);
  assert(fd_rd1 >= 0);
  int fd_rd2 = sos_open("console", O_RDONLY);
  ZF_LOGD("[syscall_test] second reader open: %d (errno=%d)\n", fd_rd2,
          sos_errno);
  assert(fd_rd2 == -1);
  // assert(sos_errno == EBUSY);

  result = sos_close(fd_rd1);
  ZF_LOGD("[syscall_test] close(reader) -> %d (errno=%d)\n", result, sos_errno);
  assert(result == 0);

  int fd_rd3 = sos_open("console", O_RDONLY);
  ZF_LOGD("[syscall_test] reader open after close -> %d (errno=%d)\n", fd_rd3,
          sos_errno);
  assert(fd_rd3 >= 0);

  (void)sos_close(fd_rd3);

  ZF_LOGI("[syscall_test] sos_close() tests successful!\n");
}

int test_buffers(void) {
  /* test a small string from the code segment */
  int console_fd = sos_open("console", O_RDWR);
  int result = sos_write(console_fd, test_str, strlen(test_str));
  ZF_LOGD("[syscall_test] test_buffers: got -> %d, actual string length -> %d",
          result, strlen(test_str));
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

void test_usleep_and_timestamp(void) {
  ZF_LOGI("[syscall_test] Testing sos_timestamp and sos_usleep...\n");
  for (int i = 0; i < 5; i++) {
    time_t prev_seconds = time(NULL);
    sleep(1);
    time_t next_seconds = time(NULL);
    printf("[syscall_test] tick: %lu -> %lu\n", prev_seconds, next_seconds);
    assert(next_seconds > prev_seconds);
  }
  ZF_LOGI("[syscall_test] sos_timestamp and sos_usleep tests successful\n");
}

int main(void) {
  ZF_LOGV("[syscall_test] Entered syscall testing app!\n");

  test_sos_open();
  test_sos_close();
  test_sos_read();
  test_usleep_and_timestamp();
  test_buffers();

  return 0;
}
