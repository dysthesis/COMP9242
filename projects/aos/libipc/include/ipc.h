/*
 * An enum defining the system call numbers supported by SOS.
 */
#include "sel4/simple_types.h"
typedef enum {
  SYSNO_OPEN,
  SYSNO_CLOSE,
  SYSNO_READ,
  SYSNO_WRITE,
  SYSNO_USLEEP,
  SYSNO_TIMESTAMP,
} sos_sysno_t;

#define SOS_SYS_OPEN SYSNO_OPEN
#define SOS_SYS_CLOSE SYSNO_CLOSE
#define SOS_SYS_READ SYSNO_READ
#define SOS_SYS_WRITE SYSNO_WRITE
#define SOS_SYS_USLEEP SYSNO_USLEEP
#define SOS_SYS_TIMESTAMP SYSNO_TIMESTAMP

typedef struct {
  sos_sysno_t sysno; // syscall number
  seL4_Word arg;     // arguments to provide the syscall, e.g. a file descriptor
  seL4_Word buf_addr; // address of shared memory buffer
  seL4_Word buf_size; // size of the shared memory buffer
} sos_ipc_msg_t;

_Static_assert(seL4_FastMessageRegisters >= 4,
               "This ABI expects >= 4 fast MRs");
