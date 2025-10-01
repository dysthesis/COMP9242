#include <clock/clock.h>
#include <clock/clock_tests.h>
#include <inttypes.h>
#include <sel4runtime.h>
#include <stdio.h>
#include <utils/util.h>

/*
 * A nice pretty-printer for timestamps
 */
static void print_timestamp(uint64_t microseconds) {
  // Convert microseconds to total seconds and remaining microseconds
  uint64_t total_seconds = microseconds / 1000000;
  uint64_t remaining_microseconds = microseconds % 1000000;

  // Calculate hours, minutes, and seconds
  uint64_t hours = total_seconds / 3600;
  uint64_t minutes = (total_seconds % 3600) / 60;
  uint64_t seconds = total_seconds % 60;

  // Print in HH:MM:SS:microseconds format
  printf("%02" PRIu64 ":%02" PRIu64 ":%02" PRIu64 ":%06" PRIu64 "\n", hours,
         minutes, seconds, remaining_microseconds);
}

static void test_timeout_periodic(UNUSED uint32_t id, void *data) {

  timestamp_t now = get_time();

  printf("[test_timeout_periodic]: Timestamp: ");
  print_timestamp(now);

  // increment the number of iterations
  int num_itr = *(int *)data;
  num_itr++;
  *(int *)data = num_itr;

  // register next timeout

  // 100ms
  register_timer(100000, test_timeout_periodic, data);
}

static void test_timeout_single(UNUSED uint32_t id, UNUSED void *data) {
  timestamp_t now = get_time();

  printf("[test_timeout_single]  : Timestamp: ");
  print_timestamp(now);
}

void test_clock() {
  // test timeouts recursively
  // TODO: Figure out how to terminate this
  // register_timer(10000000, test_timeout_periodic, &num_itr);

  // register a few more concurrent timeouts
  // a really long one
  register_timer(100000000, test_timeout_single, NULL); // 100s

  // a few out of order one
  register_timer(15000000, test_timeout_single, NULL); // 15s
  register_timer(13000000, test_timeout_single, NULL); // 13s
  register_timer(20000000, test_timeout_single, NULL); // 20s
  register_timer(18000000, test_timeout_single, NULL); // 18s
  register_timer(14000000, test_timeout_single, NULL); // 14s

  // and a few precise ones to test 10ms precision
  register_timer(15040000, test_timeout_single, NULL); // 15.04s
  register_timer(15030000, test_timeout_single, NULL); // 15.03s
  register_timer(15020000, test_timeout_single, NULL); // 15.02s
  register_timer(15010000, test_timeout_single, NULL); // 15.01s
                                                       //
  return;
}
