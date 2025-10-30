#include <stddef.h>

extern void nfsGenericCallbackZig(int err, void *nfs, void *data,
                                  void *private_data);

/**
 * C callback bridge for libnfs async operations
 *
 * This function is passed to libnfs and calls the Zig implementation.
 */
void nfs_callback_c_bridge(int err, void *nfs, void *data, void *private_data) {
  nfsGenericCallbackZig(err, nfs, data, private_data);
}
