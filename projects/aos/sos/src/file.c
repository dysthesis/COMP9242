#include "file.h"
#include <errno.h>
#include <fcntl.h>
#include <networkconsole/networkconsole.h>
#include <stdbool.h>
#include <string.h>

console_dev_t global_console = {0};

static bool input_handler_registered = false;

static void nc_input_handler(struct network_console *UNUSED netcon, char c) {
  conring_push(c);
}

static void console_input_init(void) {
  if (!input_handler_registered) {
    network_console_register_handler(sos_nc, nc_input_handler);
    input_handler_registered = true;
  }
}

static int console_open(const char *name, int mode, int *out_id) {
  console_input_init();
  // enforce single-reader
  int access = mode & O_ACCMODE;
  bool read = access == O_RDONLY || access == O_RDWR;
  bool write = access == O_WRONLY || access == O_RDWR;
  if (!read && !write) {
    return -EINVAL;
  }

  // if (read) {
  //   if (global_console.reader_in_use) {
  //     return -EBUSY;
  //   }
  //   global_console.reader_in_use = true;
  // }
  // if (write) {
  //   global_console.write_refcnt++;
  // }

  *out_id = (read ? 1 : 0) | (write ? 2 : 0);
  return 0;
}
static ssize_t console_read(UNUSED int id, void *buf, size_t len) {
  if (!buf || len == 0) {
    return 0;
  }
  // line mode behavour toggle
  bool stop_on_nl = false;
  return (ssize_t)conring_pop_many((char *)buf, len, stop_on_nl);
}
static int console_close(int id) {
  if (id & 1) {
    global_console.reader_in_use = false;
  }
  if (id & 2) {
    if (global_console.write_refcnt)
      global_console.write_refcnt--;
  }
  return 0;
}
static ssize_t console_write(UNUSED int id, void *buf, size_t len) {
  return (ssize_t)network_console_send(sos_nc, buf, len);
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
