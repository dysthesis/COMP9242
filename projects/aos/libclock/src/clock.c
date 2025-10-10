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
#include <string.h>

/* The functions in src/device.h should help you interact with the timer
 * to set registers and configure timeouts. */
#include "device.h"

// initial number of timeouts
#define INITIAL_TIMEOUTS 10

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

struct delay {
  uint16_t start_count;
  timeout_timebase_t timer_base;
};

struct delay delay_to_16(uint64_t real_delay);

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

  if (clock.timer_running) {
    // perform implicit stop if timer is already initialised
    int ret = stop_timer();
    if (ret != CLOCK_R_OK) {
      printf("[start_timer]: failed to stop timer\n");
      return ret;
    }
  }

  clock.regs = (meson_timer_reg_t *)(timer_vaddr + TIMER_REG_START);

  // timer E is the system clock, we use this to get the current time in
  // microseconds
  configure_timestamp(clock.regs, TIMESTAMP_TIMEBASE_1_US);

  // and set timer E to zero on start up
  // according to datasheet, write any value to ISA_TIMERE 0x2662 will reset it
  // see 101/336 in the datasheet
  clock.regs->timer_e = 0;

  // initialise the timeouts

  clock.timeouts_queue = pqueue_init(INITIAL_TIMEOUTS, cmp_pri, get_pri,
                                     set_pri, get_pos, set_pos);
  if (clock.timeouts_queue == NULL) {
    printf("[start_timer]: failed to initialise pqueue\n");
    stop_timer();
    return CLOCK_R_FAIL;
  }

  clock.timeouts = malloc(sizeof(timeout_t *) * INITIAL_TIMEOUTS);
  if (clock.timeouts == NULL) {
    printf("[start_timer]: failed to allocate memory for timeouts\n");
    stop_timer();
    return CLOCK_R_FAIL;
  }
  clock.num_timeouts = INITIAL_TIMEOUTS;
  // clear the memory, for sanity
  memset(clock.timeouts, 0, sizeof(timeout_t *) * INITIAL_TIMEOUTS);

  clock.timer_running = true;

  return CLOCK_R_OK;
}

bool is_timer_running() { return clock.timer_running; }

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
  timestamp_t current_timestamp = get_time();
  timestamp_t timeout_timestamp = current_timestamp + delay;

  // check for overflow
  if (timeout_timestamp < current_timestamp) {
    printf("[register_timer]: overflow\n");
    return CLOCK_R_UINT; // too large to handle
  }

  // set the timer to trigger an interrupt after the delay
  // delay is in microseconds and it is a 64 bit value
  // all the timers are 16 bit so need to convert

  // now we need store this timeout information somewhere and allocate an id

  timeout_t *new_timeout = malloc(sizeof(*new_timeout));
  if (new_timeout == NULL) {
    printf("[register_timer]: failed to allocate memory for new timeout");
    return CLOCK_R_UINT;
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
    uint32_t new_size = clock.num_timeouts + 1;
    clock.timeouts = realloc(clock.timeouts, new_size * sizeof(timeout_t *));
    if (clock.timeouts == NULL) {
      printf("[register_timer]: failed to reallocate memory for timeouts\n");
      return CLOCK_R_UINT;
    }
    clock.num_timeouts = new_size;
    slot_index = clock.num_timeouts - 1;
  }

  // now we have a slot to store the timeout, update the id
  new_timeout->id = slot_index;

  int success = pqueue_insert(clock.timeouts_queue, new_timeout);
  if (success != 0) {
    printf("[register_timer]: failed to insert\n");

    free(new_timeout);
    return CLOCK_R_UINT; // failed to insert
  }
  // now insert
  clock.timeouts[slot_index] = new_timeout;

  // after we insert the timeout, we need to set the timer to the earliest
  // timeout

  // get next earliest timeout
  timeout_t *earliest = pqueue_peek(clock.timeouts_queue);

  // if earliest set time out
  if (earliest && earliest->id == new_timeout->id) {
    // if we reach here, I am the earliest timeout, I set the timer

    // if the delay is bigger than the max value of 16 bit timer, we have no
    // choice just set the timer to the max value and recheck it when it goes
    // off next time.
    // we repeat this process until the delay is less than the max value which
    // then we set the timer to that value

    struct delay delay_data =
        delay_to_16(new_timeout->deadline - current_timestamp);

    configure_timeout(clock.regs, MESON_TIMER_A, true, false,
                      delay_data.timer_base, delay_data.start_count);
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

// converts a 64 bit delay into a 32 bit number (where lower 16 bits are..)
struct delay delay_to_16(uint64_t us) {
  struct delay d;
  if ((us >> 16) == 0) {
    d.start_count = (uint16_t)us;
    d.timer_base = TIMEOUT_TIMEBASE_1_US;
  } else if ((us /= 10, (us >> 16) == 0)) {
    d.start_count = (uint16_t)us;
    d.timer_base = TIMEOUT_TIMEBASE_10_US;
  } else if ((us /= 10, (us >> 16) == 0)) {
    d.start_count = (uint16_t)us;
    d.timer_base = TIMEOUT_TIMEBASE_100_US;
  } else if ((us /= 10, (us >> 16) == 0)) {
    d.start_count = (uint16_t)us;
    d.timer_base = TIMEOUT_TIMEBASE_1_MS;
  } else {
    d.start_count = UINT16_MAX;
    d.timer_base = TIMEOUT_TIMEBASE_1_MS;
  }
  return d;
}

/*
 * Handle the timer that has been triggered (by the timer device).
 */
int timer_irq(void *data, seL4_Word irq, seL4_IRQHandler irq_handler) {
  // irq is the timer irq that has been triggered

  if (!clock.timer_running) {
    printf("[timer_irq]: timer not running\n");
    return CLOCK_R_UINT;
  }

  /* Handle the IRQ */

  // when this irq is triggered, we have pass at least one timeout
  // which means at least the earliest timeout has expired, may have more,
  // we need to service all of them

  // get the current timestamp
  uint64_t current_timestamp = get_time();

  timeout_t *earliest = pqueue_peek(clock.timeouts_queue);

  while (earliest != NULL && earliest->deadline <= current_timestamp) {
    // means the time now has reached or gone past the earliest timeout, timer
    // expired

    // need to service the this timeout now

    // call the callback
    earliest->callback(earliest->id, earliest->data);

    int success = remove_timer(earliest->id);
    if (success != CLOCK_R_OK) {
      printf("[timer_irq]: failed to remove timeout\n");
      return CLOCK_R_FAIL;
    }

    // check the next earliest timeout
    earliest = pqueue_peek(clock.timeouts_queue);
  }

  // if we reach here, we have serviced all the timeouts that have expired
  // unless the delay is too long and we break it
  // into several interrupts

  // if there are no timeouts, we should turn off the timer

  // otherwise, we need to set the timer to the next earliest timeout

  if (earliest != NULL) {
    // set the timer to the next earliest timeout

    struct delay delay_data =
        delay_to_16(earliest->deadline - current_timestamp);

    configure_timeout(clock.regs, MESON_TIMER_A, true, false,
                      delay_data.timer_base, delay_data.start_count);
  } else {
    // no more timeouts, turn off the timer
    configure_timeout(clock.regs, MESON_TIMER_A, false, false,
                      TIMEOUT_TIMEBASE_1_MS, 0);
    printf("[timer_irq]: no more timeouts, timer turned off\n");
  }

  /* Acknowledge that the IRQ has been handled */
  seL4_IRQHandler_Ack(irq_handler);
  return CLOCK_R_OK;
}

int stop_timer(void) {
  /* Stop the timer from producing further interrupts and remove all
   * existing timeouts */

  if (!clock.timer_running) {
    printf("[stop_timer]: timer already stopped\n");
    return CLOCK_R_OK;
  }

  clock.timer_running = false;

  // stop the timer
  configure_timeout(clock.regs, MESON_TIMER_A, false, false,
                    TIMEOUT_TIMEBASE_1_MS, 0);

  for (int i = 0; i < clock.num_timeouts; i++) {
    if (clock.timeouts[i] != NULL) {
      int success = remove_timer(clock.timeouts[i]->id);
      if (success != CLOCK_R_OK) {
        printf("[stop_timer]: failed to remove timeout\n");
        return CLOCK_R_FAIL;
      }
    }
  }
  // free the timeouts array
  free(clock.timeouts);
  clock.timeouts = NULL; // for sanity

  // free the queue
  pqueue_free(clock.timeouts_queue);
  clock.timeouts_queue = NULL; // for sanity

  // set these to NULL for sanity
  clock.regs = NULL;
  clock.num_timeouts = 0;

  printf("[stop_timer]: timer freed and stopped\n");

  return CLOCK_R_OK;
}
