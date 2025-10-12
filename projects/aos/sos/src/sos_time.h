#pragma once

#include "ut.h"
#include <clock/clock.h>
#include <sel4/sel4.h>
#include <sel4/simple_types.h>
#include <stdint.h>

seL4_Word ts_get_timestamp(void);
int32_t ts_usleep(ssize_t duration, seL4_CPtr reply, ut_t *reply_ut);
