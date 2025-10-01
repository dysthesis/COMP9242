/*
 * Copyright 2019, Data61
 * Commonwealth Scientific and Industrial Research Organisation (CSIRO)
 * ABN 41 687 119 230.
 *
 * This software may be distributed and modified according to the terms of
 * the GNU General Public License version 2. Note that NO WARRANTY is provided.
 * See "LICENSE_GPLv2.txt" for details.
 *
 * @TAG(DATA61_GPL)
 */
#include <clock/clock.h>
#include <pqueue.h>
#include <stdint.h>
#include <stdlib.h>

/* The functions in src/device.h should help you interact with the timer
 * to set registers and configure timeouts. */
#include "device.h"

/*
 * A singular timeout, consisting of the deadline and callback.
 *
 * NOTE: The deadline is kept in absolute terms rather than relative in order to
 * make comparison with the current time trivial. If we keep it in relative
 * terms, we would need to not only keep the relative due date but also the time
 * in which it is issued. Alternatively, we would need to update the relative
 * deadline throughout the list on every wake, which would be O(n) (hence a
 * showstopper!). Either way, absolute deadlines are just more efficient.
 */
typedef struct {
  uint32_t id;
  uint64_t deadline;         // when is this timer due (in absolute terms)?
  timer_callback_t callback; // what should this timout trigger when it expires?
  size_t pos; // comforms to the pqueue_t struct, set by the pqueue functions
              // automatically
} timeout_t;

static struct {
  volatile meson_timer_reg_t *regs;
  /* Add fields as you see necessary */
  pqueue_t *timeouts_queue; // list of pending timeouts, sorted by descending
                            // order of expiry time
  timeout_t **timeouts; // global list of unordered timeouts for ID allocation.
  int num_timeouts;     // how many pending timeouts there are
  bool timer_running;   // is the timer running?
} clock;
static int cmp_pri(pqueue_pri_t next, pqueue_pri_t curr) {
  return (next > curr); // higher priority is lower value, we need a min heap
}

static pqueue_pri_t get_pri(void *a) { return ((timeout_t *)a)->deadline; }

static void set_pri(void *a, pqueue_pri_t pri) {
  ((timeout_t *)a)->deadline = pri;
}

static size_t get_pos(void *a) { return ((timeout_t *)a)->pos; }

static void set_pos(void *a, size_t pos) { ((timeout_t *)a)->pos = pos; }

timestamp_t get_time(void) {
  /* Return the current time in microseconds */

  if (!clock.timer_running) {
    printf("[get_time]: timer not running\n");
    return 0;
  }

  // read the current time from timer E
  return read_timestamp(clock.regs);
}
int start_timer(unsigned char *timer_vaddr) {
  int err = stop_timer();
  if (err != 0) {
    return err;
  }

  clock.regs = (meson_timer_reg_t *)(timer_vaddr + TIMER_REG_START);

  return CLOCK_R_OK;
}

uint32_t register_timer(uint64_t delay, timer_callback_t callback, void *data) {
  return 0;
}

int remove_timer(uint32_t id) { return CLOCK_R_FAIL; }

int timer_irq(void *data, seL4_Word irq, seL4_IRQHandler irq_handler) {
  /* Handle the IRQ */

  /* Acknowledge that the IRQ has been handled */
  return CLOCK_R_FAIL;
}

int stop_timer(void) {
  /* Stop the timer from producing further interrupts and remove all
   * existing timeouts */
  return CLOCK_R_FAIL;
}
