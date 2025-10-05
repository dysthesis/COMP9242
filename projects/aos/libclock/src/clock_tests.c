#include <clock/clock.h>
#include <clock/clock_tests.h>
#include <inttypes.h>
#include <sel4runtime.h>
#include <stdio.h>
#include <utils/util.h>
#define MAX_PERIODIC_TEST_ITERS 5

/*
 * A nice pretty-printer for timestamps
 */
void print_timestamp(uint64_t microseconds) {
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

void test_timeout_periodic(UNUSED uint32_t id, void *data) {

  timestamp_t now = get_time();

  printf("[test_timeout_periodic]: iteration %d Timestamp: ", *(int *)data);
  print_timestamp(now);

  // increment the number of iterations
  int num_itr = *(int *)data;
  if (num_itr < MAX_PERIODIC_TEST_ITERS) {
    num_itr++;

    *(int *)data = num_itr;

    // register next timeout
    register_timer(100000, test_timeout_periodic, data); // 100ms
  }
}

void test_timeout_single(UNUSED uint32_t id, UNUSED void *data) {
  timestamp_t now = get_time();

  printf("[test_timeout_single]  : Timestamp: ");
  print_timestamp(now);
}

void test_clock() {
  static int periodic_iterations = 0;

  register_timer(100000, test_timeout_periodic, &periodic_iterations);

  const uint64_t single_shot_delays[] = {
      100000000, // 100s
      30000000,  // 30s
      31000000,  // 31s
      35000000,  // 35s
      32000000,  // 32s
      34000000,  // 34s
      33000000,  // 33s
      70000000,  // 70s
  };

  for (size_t i = 0; i < ARRAY_SIZE(single_shot_delays); i++) {
    register_timer(single_shot_delays[i], test_timeout_single, NULL);
  }
}
