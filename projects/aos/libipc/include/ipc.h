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

#define MAX_CLIENTS                                                            \
  1024u // how many clients can perform a system call simultaneously

/*
 * We mint one badged endpoint capability per client so the server can identify
 * the caller on every system call via the kernel-supplied badge.
 *
 * Badge layout:
 *   [ FLAGS ... | GEN : g bits | ID : ceil(log2(MAX_CLIENTS)) bits ]
 *
 *  - ID indexes a fixed/segmented client table.
 *  - GEN is a small generation counter for that ID slot.
 *  - Remaining high bits may be reserved for flags (e.g., class/diagnostics).
 *
 * Lifecycle:
 *  - On client creation, we allocate an ID slot, increment its GEN, publish
 *    clients[ID] = <state>, and mint the client’s endpoint cap with
 *    badge = pack(FLAGS, GEN, ID).
 *  - On each system call, the server receives the badge from
 *    seL4_Recv/ReplyRecv, extracts (ID, GEN), and accepts only if clients[ID]
 *    is non-NULL AND gen_tab[ID] == GEN. This rejects stale or forged calls.
 *  - On client teardow, we clear clients[ID], revoke the client’s badged caps,
 *    and return ID to the free list. GEN will be incremented next time the
 *    slot is reused.
 *
 * NOTE: Generation counters DO NOT change after each syscall; they change
 * only when the slot is reused for a different client, preventing ABA (see:
 * https://en.wikipedia.org/wiki/ABA_problem).
 */
#define ID_BITS 10u // log(MAX_CLIENTS)
#define GEN_BITS 8u
#define ID_MASK ((1u << ID_BITS) - 1)

static inline seL4_Word badge_make(unsigned id, unsigned gen, unsigned flags) {
  return (flags) | ((seL4_Word)gen << ID_BITS) | (seL4_Word)id;
}
static inline unsigned badge_id(seL4_Word b) { return b & ID_MASK; }
static inline unsigned badge_gen(seL4_Word b) {
  return (b >> ID_BITS) & ((1u << GEN_BITS) - 1);
}
