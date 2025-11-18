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
#include <utils/util.h>
#include <stdio.h>
#include <stdint.h>
#include <stdarg.h>
#include <sys/mman.h>
#include <errno.h>
#include <assert.h>

extern long long sos_brk_call(uintptr_t new_break);
extern long long sos_mmap_call(uintptr_t addr, size_t length, int prot, int flags, int fd, uintptr_t offset);

/* Actual morecore implementation
   returns 0 if failure, returns newbrk if success.
*/

long sys_brk(va_list ap)
{
    uintptr_t ret;
    uintptr_t newbrk = va_arg(ap, uintptr_t);

    long long result = sos_brk_call(newbrk);
    if (result < 0) {
        errno = (int)(-result);
        ret = 0;
    } else {
        ret = (uintptr_t)result;
    }

    return ret;
}

/* Large mallocs will result in muslc calling mmap, so we do a minimal implementation
   here to support that. We make a bunch of assumptions in the process */
long sys_mmap(va_list ap)
{
    void *addr = va_arg(ap, void *);
    size_t length = va_arg(ap, size_t);
    int prot = va_arg(ap, int);
    int flags = va_arg(ap, int);
    int fd = va_arg(ap, int);
    off_t offset = va_arg(ap, off_t);

    long long result = sos_mmap_call((uintptr_t)addr, length, prot, flags, fd, (uintptr_t)offset);
    if (result < 0) {
        errno = (int)(-result);
        return (long)result;
    }
    return (long)result;
}

long sys_munmap(va_list ap)
{
    void *addr = va_arg(ap, void *);
    size_t length = va_arg(ap, size_t);
    (void)addr;
    (void)length;
    errno = ENOSYS;
    return -ENOSYS;
}
