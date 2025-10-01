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
#include <stdlib.h>
#include <stdint.h>
#include <clock/clock.h>

/* The functions in src/device.h should help you interact with the timer
 * to set registers and configure timeouts. */
#include "device.h"

struct delay {
    uint16_t start_count;
    timeout_timebase_t timer_base;
}

struct delay delay_to_16(uint64_t real_delay);

static struct {
    volatile meson_timer_reg_t *regs;
    /* Add fields as you see necessary */
} clock;



int start_timer(unsigned char *timer_vaddr)
{
    int err = stop_timer();
    if (err != 0) {
        return err;
    }

    clock.regs = (meson_timer_reg_t *)(timer_vaddr + TIMER_REG_START);

    return CLOCK_R_OK;
}

timestamp_t get_time(void) {
    // TODO: check if timer_e hi is meant to be higher addresses
    return timer_e_hi << 32 | timer_e;
}

uint32_t register_timer(uint64_t delay, timer_callback_t callback, void *data)
{
    // add delay to current time
    timestamp_t end_timestamp = delay + get_time();
    // TODO: store expected end timestamp on the min-heap
    uint32_t identifier = ...;
    // TODO: check if head of min-heap

    // if head start timer
    timestamp_t = head;
    uint64_t delay = head - get_time();
    struct delay timer_data =  delay_to_16(delay);
    // TODO, create timer
    configure_timeout()
    write_timeout()

    // TODO: return int identifier for the timestamp
    return identifier;
}

// converts a 64 bit delay into a 32 bit number (where lower 16 bits are..)
struct delay delay_to_16(uint64_t real_delay) {
    struct delay delay;
    delay.start_count = 0;
    // TODO: note, if more than the first 36 bits are set, it is impossible to represent as:
    // 2^35 < 2^16 -1 * 10^6 < 2^36
    // unless we make multiple delays for one delay?
    // case only lower 16 bits are set (keep in microseconds)
    if (real_delay >> 16 == 0) {
        delay.start_count |= real_delay;
        delay.timer_base = TIMEOUT_TIMEBASE_1_US;
    }
    uint64_t temp_dealy = real_delay / 10;
    // case 10 microseconds
    if (temp_dealy >> 16 == 0) {
        delay.start_count |= temp_dealy;
        delay.timer_base = TIMEOUT_TIMEBASE_10_US;
    }
    temp_dealy /= 10;
    //case 100 microseconds
    if (temp_dealy >> 16 == 0) {
        delay.start_count |= temp_dealy;
        delay.timer_base = TIMEOUT_TIMEBASE_100_US;
    }
    temp_dealy /= 10;
    // case 1 milisecond
    if (temp_dealy >> 16 == 0) {
        delay.start_count |= temp_dealy;
        delay.timer_base = TIMEOUT_TIMEBASE_1_MS;
    // case it cant be represented so do longest delay possible?
    } else {
        delay.start_count = 0xFFFF;
        delay.timer_base = TIMEOUT_TIMEBASE_1_MS;
    }
    return delay;
}

int remove_timer(uint32_t id)
{
    return CLOCK_R_FAIL;
}

int timer_irq(
    void *data,
    seL4_Word irq,
    seL4_IRQHandler irq_handler
)
{
    /* Handle the IRQ */

    /* Acknowledge that the IRQ has been handled */
    return CLOCK_R_FAIL;
}

int stop_timer(void)
{
    /* Stop the timer from producing further interrupts and remove all
     * existing timeouts */
    return CLOCK_R_FAIL;
}
