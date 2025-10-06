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
#include "utils/page.h"
#include "utils/zf_log.h"
#include <assert.h>
#include <errno.h>
#include <ipc_common.h>
#include <sos.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#include <ipc_common.h>
#include <sel4/sel4.h>

int sos_errno = 0;

static size_t sos_debug_print(const void *vData, size_t count) {
#ifdef CONFIG_DEBUG_BUILD
  size_t i;
  const char *realdata = vData;
  for (i = 0; i < count; i++) {
    seL4_DebugPutChar(realdata[i]);
  }
#endif
  return count;
}

int sos_open(const char *path, fmode_t mode) {
  if (!path) {
    sos_errno = EINVAL;
    return -1;
  }

  size_t len = strnlen(path, MAX_IO_BUF);
  if (len >= MAX_IO_BUF) {
    sos_errno = ENAMETOOLONG;
    return -1;
  }

  char *shbuf = sos_shbuf_ptr();
  memcpy(shbuf, path, len + 1);

  sos_ipc_msg_t msg = {
      .sysno = SOS_SYS_OPEN,
      .arg = (seL4_Word)mode,
      .buf_addr = PROCESS_SHBUF_UVA,
      .buf_size = (seL4_Word)(len + 1),
  };

  seL4_MessageInfo_t request = sos_serialise_ipc_msg(&msg);
  seL4_MessageInfo_t reply = seL4_Call(SOS_IPC_EP_CAP, request);

  if (seL4_MessageInfo_get_length(reply) < 1) {
    sos_errno = EINVAL;
    return -1;
  }

  int res = (int)seL4_GetMR(0);
  if (res < 0) {
    sos_errno = -res;
    return -1;
  }

  sos_errno = 0;
  return res;
}

int sos_close(int file) {
  sos_ipc_msg_t msg = {
      .sysno = SOS_SYS_CLOSE,
      .arg = (seL4_Word)file,
      .buf_addr = 0,
      .buf_size = 0,
  };

  // Serialise our request into a message...
  seL4_MessageInfo_t req = sos_serialise_ipc_msg(&msg);
  // ...and wait for a reply from SOS.
  seL4_MessageInfo_t reply = seL4_Call(SOS_IPC_EP_CAP, req);

  // There needs to be at least something in the reply.
  if (seL4_MessageInfo_get_length(reply) < 1) {
    ZF_LOGE("[libsosapi] received an empty reply from SOS!");
    sos_errno = EINVAL;
    return -1;
  }

  int res = (int)seL4_GetMR(0);
  if (res < 0) {
    sos_errno = -res;
    return -1;
  }

  sos_errno = 0;
  return res;
}

int sos_read(int file, char *buf, size_t nbyte) {
  if (!buf) {
    sos_errno = EINVAL;
    return -1;
  }
  if (nbyte == 0) {
    sos_errno = 0;
    return 0;
  }

  size_t limit = nbyte;
  if (limit > (size_t)INT_MAX) {
    limit = (size_t)INT_MAX;
  }

  size_t total = 0;
  while (total < limit) {
    size_t req = limit - total;
    if (req > MAX_IO_BUF) {
      req = MAX_IO_BUF;
    }
    if (req == 0) {
      break;
    }

    sos_ipc_msg_t msg = {
        .sysno = SOS_SYS_READ,
        .arg = (seL4_Word)file,
        .buf_addr = PROCESS_SHBUF_UVA,
        .buf_size = (seL4_Word)req,
    };

    seL4_MessageInfo_t rep =
        seL4_Call(SOS_IPC_EP_CAP, sos_serialise_ipc_msg(&msg));
    if (seL4_MessageInfo_get_length(rep) < 1) {
      sos_errno = EINVAL;
      return -1;
    }

    int res = (int)seL4_GetMR(0); // bytes read or -errno
    if (res < 0) {
      sos_errno = -res;
      return -1;
    }
    if (res == 0) {
      break; // nothing left to read
    }

    memcpy(buf + total, sos_shbuf_ptr(), (size_t)res);
    total += (size_t)res;

    if ((size_t)res < req) {
      break; // short read, don't force another call
    }
  }
  sos_errno = 0;
  return (int)total;
}

int sos_write(int file, const char *buf, size_t nbyte) {
  if (!buf) {
    sos_errno = EINVAL;
    return -1;
  }
  if (nbyte == 0) {
    sos_errno = 0;
    return 0;
  }

  size_t limit = nbyte;
  if (limit > (size_t)INT_MAX) {
    limit = (size_t)INT_MAX;
  }

  size_t total = 0;
  char *shbuf = sos_shbuf_ptr();

  while (total < limit) {
    size_t req = limit - total;
    if (req > MAX_IO_BUF) {
      req = MAX_IO_BUF;
    }
    if (req == 0) {
      break;
    }

    memcpy(shbuf, buf + total, req);

    sos_ipc_msg_t msg = (sos_ipc_msg_t){
        .sysno = SOS_SYS_WRITE,
        .arg = (seL4_Word)file,
        .buf_addr = PROCESS_SHBUF_UVA,
        .buf_size = (seL4_Word)req,
    };

    seL4_MessageInfo_t rep =
        seL4_Call(SOS_IPC_EP_CAP, sos_serialise_ipc_msg(&msg));
    if (seL4_MessageInfo_get_length(rep) < 1) {
      sos_errno = EINVAL;
      return -1;
    }

    int res = (int)seL4_GetMR(0); // bytes written or -errno
    if (res < 0) {
      sos_errno = -res;
      return -1;
    }
    if (res == 0) {
      break; // nothing written
    }

    total += (size_t)res;
    if ((size_t)res < req) {
      break; // short write
    }
  }

  sos_errno = 0;
  return (int)total;
}

int sos_getdirent(int pos, char *name, size_t nbyte) {
  assert(!"You need to implement this");
  return -1;
}

int sos_stat(const char *path, sos_stat_t *buf) {
  assert(!"You need to implement this");
  return -1;
}

pid_t sos_process_create(const char *path) {
  assert(!"You need to implement this");
  return -1;
}

int sos_process_delete(pid_t pid) {
  assert(!"You need to implement this");
  return -1;
}

pid_t sos_my_id(void) {
  assert(!"You need to implement this");
  return -1;
}

int sos_process_status(sos_process_t *processes, unsigned max) {
  assert(!"You need to implement this");
  return -1;
}

pid_t sos_process_wait(pid_t pid) {
  assert(!"You need to implement this");
  return -1;
}

void sos_usleep(int msec) { assert(!"You need to implement this"); }

int64_t sos_time_stamp(void) {
  assert(!"You need to implement this");
  return -1;
}
