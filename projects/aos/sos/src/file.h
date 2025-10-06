#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef enum { FD_NONE = 0, FD_DEV_CONSOLE } fd_kind_t;

typedef struct {
  bool used;
  bool readable;
  bool writable;
  fd_kind_t kind;
  void *obj;
} sos_fd_entry_t;

typedef struct {
  bool reader_in_use;
  uint16_t reader_owner_id;
  size_t write_refcnt;
} console_dev_t;

static console_dev_t global_console = {0};
