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
#include <autoconf.h>
#include <stdio.h>
#include <stdint.h>
#include <stdarg.h>
#include <sys/mman.h>
#include <errno.h>
#include <assert.h>
#include <utils/util.h>

/*
 * Statically allocated morecore area.
 *
 * This is rather terrible, but is the simplest option without a
 * huge amount of infrastructure.
 */
#include "morecore.h"

// Static heap size (16 MiB). Increased from 8 MiB to accommodate vendor library consumption.
//
// Heap consumption breakdown (measured via runtime diagnostics):
// - libnfs library (NFS client state, PDU buffers, RPC machinery): ~6.5 MiB
// - picotcp network stack (socket buffers, routing tables, protocol state): ~1.5 MiB
// - NFS heap reserve (emergency cushion for eviction operations): 256 KiB
// - Runtime allocations (pagefile metadata, client state, workers): ~2 MiB
// - Safety margin for transient allocations: ~5.75 MiB
//
// Note: Client metadata arrays (vm/client.zig metadata_pages) are in BSS (static storage),
// not on this heap. The previous 8 MiB sizing was based on an incorrect attribution of
// those arrays to heap consumption. Actual heap exhaustion occurs due to vendor libraries
// consuming ~8 MiB during network/NFS initialisation, leaving insufficient headroom for
// runtime operations (eviction requires 320+ KiB for NFS PDU encoding).
#define MORECORE_AREA_BYTE_SIZE 0x1000000
char morecore_area[MORECORE_AREA_BYTE_SIZE];

/* Pointer to free space in the morecore area. */
static uintptr_t morecore_base = (uintptr_t) &morecore_area;
static uintptr_t morecore_top = (uintptr_t) &morecore_area[MORECORE_AREA_BYTE_SIZE];

/* Actual morecore implementation
   returns 0 if failure, returns newbrk if success.
*/

long sys_brk(va_list ap)
{
    uintptr_t ret;
    uintptr_t newbrk = va_arg(ap, uintptr_t);

    /*if the newbrk is 0, return the bottom of the heap*/
    if (!newbrk) {
        ret = morecore_base;
    } else if (newbrk < morecore_top && newbrk > (uintptr_t)&morecore_area[0]) {
        ret = morecore_base = newbrk;
    } else {
        ret = 0;
    }

    return ret;
}

/* Large mallocs will result in muslc calling mmap, so we do a minimal implementation
   here to support that. We make a bunch of assumptions in the process */

long sys_mmap(va_list ap)
{
    UNUSED void *addr = va_arg(ap, void *);
    size_t length = va_arg(ap, size_t);
    UNUSED int prot = va_arg(ap, int);
    int flags = va_arg(ap, int);
    UNUSED int fd = va_arg(ap, int);
    UNUSED off_t offset = va_arg(ap, off_t);

    if (flags & MAP_ANONYMOUS) {
        /* Check that we don't try and allocate more than exists */
        if (length > morecore_top - morecore_base) {
            return -ENOMEM;
        }
        /* Steal from the top */
        morecore_top -= length;
        return morecore_top;
    }
    ZF_LOGF("not implemented");
    return -ENOMEM;
}

long sys_madvise(UNUSED va_list ap)
{
    return 0;
}

/* Introspection helpers for diagnostics and guardrails. */
size_t morecore_total_bytes(void)
{
    return MORECORE_AREA_BYTE_SIZE;
}

size_t morecore_free_bytes(void)
{
    /* morecore_top grows downward only via mmap; base grows upward via brk. */
    if (morecore_top <= morecore_base) {
        return 0;
    }
    return morecore_top - morecore_base;
}
