#include <ipc.h>
#include <sel4/sel4.h>
#include <stdbool.h>
#include <stddef.h>

_Static_assert(SOS_IPC_MSG_WORDS <= seL4_FastMessageRegisters,
               "Too many message registers for fast path");

seL4_MessageInfo_t sos_serialise_ipc_msg(const sos_ipc_msg_t *msg) {
  if (!msg) {
    return seL4_MessageInfo_new(/*label*/ 0,
                                /*capsUnwrapped*/ 0,
                                /*extraCaps*/ 0,
                                /*length*/ 0);
  }

  seL4_SetMR(0, (seL4_Word)msg->sysno);
  seL4_SetMR(1, (seL4_Word)msg->arg);
  seL4_SetMR(2, (seL4_Word)msg->buf_addr);
  seL4_SetMR(3, (seL4_Word)msg->buf_size);

  return seL4_MessageInfo_new(/*label*/ 0,
                              /*capsUnwrapped*/ 0,
                              /*extraCaps*/ 0,
                              /*length*/ SOS_IPC_MSG_WORDS);
}

int sos_deserialise_ipc_msg(const seL4_MessageInfo_t *msg_info,
                            sos_ipc_msg_t *out) {
  if (!msg_info || !out)
    return -1;

  const seL4_Word len = seL4_MessageInfo_get_length(*msg_info);
  const seL4_Word xcaps = seL4_MessageInfo_get_extraCaps(*msg_info);

  if (len < SOS_IPC_MSG_WORDS || xcaps != 0) {
    /* Normalise output to a safe default */
    out->sysno = 0;
    out->arg = 0;
    out->buf_addr = 0;
    out->buf_size = 0;
    return -1;
  }

  out->sysno = (sos_sysno_t)seL4_GetMR(0);
  out->arg = seL4_GetMR(1);
  out->buf_addr = seL4_GetMR(2);
  out->buf_size = seL4_GetMR(3);
  return 0;
}
