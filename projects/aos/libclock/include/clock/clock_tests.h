/*
 * Test functions for the timer driver. This should be called from tests.c.
 */
void test_clock();
void test_timeout_single(UNUSED uint32_t id, UNUSED void *data);
void test_timeout_periodic(UNUSED uint32_t id, void *data);
void print_timestamp(uint64_t microseconds);
