#include "utils/attribute.h"
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

typedef enum { FD_NONE = 0, FD_DEV_CONSOLE } fd_kind_t;

typedef ssize_t (*file_rw_fn)(int id, void *buf, size_t len);
typedef int (*file_open_fn)(const char *name, int mode, int *out_id);
typedef int (*file_close_fn)(int id);
typedef struct {
  file_open_fn open;
  file_rw_fn read;
  file_rw_fn write;
  file_close_fn close;
} file_ops_t;

typedef struct {
  bool used;
  bool readable;
  bool writable;
  fd_kind_t kind;
  void *obj;
  const file_ops_t *ops;
  int dev_id;
  uint16_t refcnt;
} sos_fd_entry_t;

typedef struct {
  bool reader_in_use;
  uint16_t reader_owner_id;
  size_t write_refcnt;
} console_dev_t;

extern console_dev_t global_console;

typedef struct {
  const char *name;
  const file_ops_t *ops;
} dev_reg_t;

extern const dev_reg_t devices[];
extern const size_t dev_table_len;

const file_ops_t *vfs_lookup_ops(const char *name);

extern struct network_console *sos_nc;

#define CONSOLE_RING_SIZE 1024u
typedef struct {
  char buf[CONSOLE_RING_SIZE];
  unsigned head;
  unsigned tail;
} console_ring_t;

static console_ring_t con_in;

static inline bool conring_empty(void) { return con_in.head == con_in.tail; }
static inline bool conring_full(void) {
  return ((con_in.head + 1) % CONSOLE_RING_SIZE) == con_in.tail;
}
static inline void conring_push(char item) {
  unsigned head = con_in.head;
  unsigned next = (head + 1) % CONSOLE_RING_SIZE;
  if (next != con_in.tail) {
    con_in.buf[head] = item;
    con_in.head = next;
  }
}

static size_t conring_pop_many(char *dst, size_t max, bool stop_on_nl) {
  size_t num = 0;
  while (num < max && !conring_empty()) {
    char curr = con_in.buf[con_in.tail];
    con_in.tail = (con_in.tail + 1) % CONSOLE_RING_SIZE;
    dst[num++] = curr;
    if (stop_on_nl && curr == '\n') {
      break;
    }
  }
  return num;
}
