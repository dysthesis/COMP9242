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
  void *data;
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
  if (!clock.timer_running) {
    printf("[register_timer]: timer not running\n");
    return CLOCK_R_UINT;
  }

  // program the hardware timer to trigger an interrupt after the delay

  // we use timerA

  // delay is in microseconds

  // get the timestamp of the future where the callback needs to be called from
  // delay future timestamp = current timestamp + delay
  uint64_t current_timestamp = get_time();
  uint64_t timeout_timestamp = current_timestamp + delay;

  // check for overflow
  if (timeout_timestamp < current_timestamp) {
    printf("[register_timer]: overflow\n");
    return 0; // too large to handle
  }

  // set the timer to trigger an interrupt after the delay
  // delay is in microseconds and it is a 64 bit value
  // all the timers are 16 bit, which are fucking useless and
  // we have to break them into several timer interrupts

  // i wont do a sophisticated timebase selection algorithm
  // for now, let's just use the 1us one which will trigger more interrupts

  // now we need store this timeout information somewhere and allocate an id

  timeout_t *new_timeout = malloc(sizeof(*new_timeout));
  if (new_timeout == NULL) {
    printf("[register_timer]: failed to allocate memory for new timeout");
    return 0;
  }
  new_timeout->deadline = timeout_timestamp;
  new_timeout->callback = callback;
  new_timeout->data = data;

  // now find a slot to store this, the index will be used as id

  int slot_index = -1;
  // TODO: This is why we need a hash table to keep track of the timeouts
  // allocate id would be O(1) if we do that
  for (int i = 0; i < clock.num_timeouts; i++) {
    if (clock.timeouts[i] == NULL) {
      slot_index = i;
      break;
    }
  }

  if (slot_index == -1) {
    // need to reallocate memory
    clock.num_timeouts++;
    clock.timeouts =
        realloc(clock.timeouts, clock.num_timeouts * sizeof(timeout_t *));
    if (clock.timeouts == NULL) {
      printf("[register_timer]: failed to reallocate memory for timeouts\n");
      return 0;
    }
    slot_index = clock.num_timeouts - 1;
  }

  // now we have a slot to store the timeout, update the id

  new_timeout->id = slot_index;

  // now insert
  clock.timeouts[slot_index] = new_timeout;

  int success = pqueue_insert(clock.timeouts_queue, new_timeout);
  if (success != 0) {
    printf("[register_timer]: failed to insert\n");
    // should free the memory here, but i am lazy
    return 0; // failed to insert
  }

  // after we insert the timeout, we need to set the timer to the earliest
  // timeout

  // get next earliest timeout
  timeout_t *earliest = pqueue_peek(clock.timeouts_queue);

  if (earliest->id == new_timeout->id) {
    // if we reach here, I am the earliest timeout, I set the timer

    // if the delay is bigger than the max value of 16 bit timer, we have no
    // choice just set the timer to the max value and recheck it when it goes
    // off next time.
    // we repeat this process until the delay is less than the max value which
    // then we set the timer to that value

    uint64_t timeout_us = delay;
    if (timeout_us > UINT16_MAX) {
      timeout_us = UINT16_MAX;
    }

    configure_timeout(clock.regs, MESON_TIMER_A, true, false,
                      TIMEOUT_TIMEBASE_1_US, (uint16_t)timeout_us);
  } else {
    // not the earliest timeout, do nothing
  }

  return new_timeout->id;
}

int remove_timer(uint32_t id) {
  // find the timeout with the id and remove it

  if (clock.timeouts == NULL) {
    printf("[remove_timer]: clock has been deallocated, nothing to remove\n");
    return CLOCK_R_UINT;
  }

  // since we are using index as id, it is easy to find the timeout

  if (id >= clock.num_timeouts) {
    // definitely something wrong
    printf("[remove_timer]: id: %u out of bounds\n", id);
    return CLOCK_R_FAIL;
  }

  timeout_t *timeout_to_remove = clock.timeouts[id];

  if (timeout_to_remove == NULL) {
    // already removed
    printf("[remove_timer]: removing an already removed timeout\n");
    return CLOCK_R_FAIL;
  }

  // remove the timeout from the queue
  int success = pqueue_remove(clock.timeouts_queue, timeout_to_remove);
  if (success != 0) {
    printf("[remove_timer]: failed to remove from queue\n");
    return CLOCK_R_FAIL;
  }

  // free the timeout from the array
  free(timeout_to_remove);

  clock.timeouts[id] = NULL;

  // may need to turn off the timer here as well if there are no more timeouts

  return CLOCK_R_OK;
}

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
