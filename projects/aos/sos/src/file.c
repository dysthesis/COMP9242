#include "file.h"
#include "utils/attribute.h"
#include <errno.h>
#include <fcntl.h>
#include <networkconsole/networkconsole.h>
#include <stdbool.h>
#include <string.h>

static int console_open(const char *name, int mode, int *out_id) {
  // enforce single-reader
  int access = mode & O_ACCMODE;
  bool read = access == O_RDONLY || access == O_RDWR;
  bool write = access == O_WRONLY || access == O_RDWR;
  if (!read && !write) {
    return -EINVAL;
  }
  if (read) {
    if (global_console.reader_in_use) {
      return -EBUSY;
    }
    global_console.reader_in_use = true;
  }
  if (write) {
    global_console.write_refcnt++;
  }
  *out_id = 0;
  return 0;
}

static int console_close(UNUSED int id) { return 0; }

static ssize_t console_write(int id, void *buf, size_t len) {
  return (ssize_t)network_console_send(sos_nc, buf, len);
}
static ssize_t console_read(UNUSED int id, UNUSED void *buf,
                            UNUSED size_t len) {
  return -ENOSYS;
}

static const file_ops_t console_ops = {
    .open = console_open,
    .read = console_read,
    .write = console_write,
    .close = console_close,
};

const dev_reg_t devices[] = {
    {"console", &console_ops},
};
const size_t dev_table_len = sizeof(devices) / sizeof(devices[0]);

const file_ops_t *vfs_lookup_ops(const char *name) {
  for (size_t i = 0; i < dev_table_len; ++i) {
    if (!strcmp(name, devices[i].name)) {
      return devices[i].ops;
    }
  }
  return NULL;
}
