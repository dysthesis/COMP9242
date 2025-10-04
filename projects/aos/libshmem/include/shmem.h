#include "sel4/simple_types.h"

/*
 * A shared memory buffer.
 */
typedef struct {
  seL4_Word addr; // address of the buffer
  seL4_Word size; // size of the buffer
  seL4_CPtr cap;  // capability with the rights ot the buffer.
} sos_shared_mem_t;
