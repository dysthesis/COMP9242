#pragma once
#include "ut.h"

#ifdef __GNUC__
#define UT_NONNULL_1 __attribute__((nonnull(1)))
#else
#define UT_NONNULL_1
#endif

seL4_CPtr ut_get_cap(const ut_t *ut) UT_NONNULL_1;
unsigned long ut_get_valid(const ut_t *ut) UT_NONNULL_1;
unsigned long ut_get_size_bits(const ut_t *ut) UT_NONNULL_1;
ut_t *ut_get_next(const ut_t *ut) UT_NONNULL_1;
