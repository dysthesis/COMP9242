#include "ut.h"

seL4_CPtr ut_get_cap(const ut_t *ut) { return ut->cap; }
unsigned long ut_get_valid(const ut_t *ut) { return ut->valid; }
unsigned long ut_get_size_bits(const ut_t *ut) { return ut->size_bits; }
ut_t *ut_get_next(const ut_t *ut) { return ut->next; }
