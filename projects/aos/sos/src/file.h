#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

typedef enum { FD_NONE = 0, FD_DEV_CONSOLE, FD_FILE_REGULAR } fd_kind_t;

typedef ssize_t (*file_read_fn)(int id, void *buf, size_t len);
typedef ssize_t (*file_write_fn)(int id, const void *buf, size_t len);
typedef int (*file_open_fn)(const char *name, int mode, int *out_id);
typedef int (*file_close_fn)(int id);
typedef struct {
    file_open_fn open;
    file_read_fn read;
    file_write_fn write;
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
    size_t offset;
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
