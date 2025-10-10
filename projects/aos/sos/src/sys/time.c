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
#include "ut.h"
#include <clock/clock.h>
#include <clock/timestamp.h>
#include <errno.h>
#include <sel4/sel4.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <utils/util.h>

static uint64_t freq = 0;
extern cspace_t cspace;

long sys_nanosleep(va_list ap) {
  if (unlikely(freq == 0)) {
    freq = timestamp_get_freq();
  }

  struct timespec *req = va_arg(ap, struct timespec *);

  /* for now we just spin and yield -- TODO consider using a continuation
   * and setting a timeout so interrupts can be handled while sos sleeps, after
   * the timer milestone has been implemented */
  uint64_t us = req->tv_sec * US_IN_S;
  us += req->tv_nsec / NS_IN_US;

  uint64_t start = timestamp_us(freq);
  while (timestamp_us(freq) - start < us) {
    seL4_Yield();
  }

  return 0;
}

long sys_clock_gettime(va_list ap) {
  if (unlikely(freq == 0)) {
    freq = timestamp_get_freq();
  }

  clockid_t clk_id = va_arg(ap, clockid_t);
  struct timespec *res = va_arg(ap, struct timespec *);
  if (clk_id != CLOCK_REALTIME) {
    return -EINVAL;
  }
  uint64_t micros = timestamp_us(freq);
  res->tv_sec = micros / US_IN_S;
  res->tv_nsec = (micros % US_IN_S) * NS_IN_US;
  return 0;
}

// usleep stuff

#define MSEC_TO_USEC(x) (x * 1000)

typedef struct sleep_ctx {
  seL4_CPtr reply;
  ut_t *reply_ut;
} sleep_ctx_t;

static void sleep_callback(UNUSED uint32_t id, void *data) {
  sleep_ctx_t *ctx = data;
  seL4_MessageInfo_t mi = seL4_MessageInfo_new(0, 0, 0, 1);
  seL4_SetMR(0, 0);
  seL4_Send(ctx->reply, mi);
  cspace_delete(&cspace, ctx->reply);
  cspace_free_slot(&cspace, ctx->reply);
  ut_free(ctx->reply_ut);
  free(ctx);
}

int32_t ts_usleep(ssize_t duration, seL4_CPtr reply, ut_t *reply_ut) {
  if (duration < 0)
    // no need for sleeping
    return 1;
  uint32_t id;
  sleep_ctx_t *ctx = malloc(sizeof(sleep_ctx_t));

  if (!ctx) {
    ZF_LOGE("Cannot allocate memory sleep callback ctx.");
    return -1;
  }

  ctx->reply = reply;
  ctx->reply_ut = reply_ut;

  id = register_timer((uint64_t)duration, sleep_callback, ctx);
  if (id == CLOCK_R_UINT) {
    ZF_LOGE("Register timer failed.");
    free(ctx);
    return -1;
  }

  return 0;
}
seL4_Word ts_get_timestamp() {
  seL4_Word timestamp = get_time() % INT64_MAX;
  if (timestamp) {
    return timestamp;
  }
  return 1;
}
