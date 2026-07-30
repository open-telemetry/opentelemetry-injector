/* premapper.c
 *
 * When loaded via LD_PRELOAD (before libotelinject.so), this library's
 * constructor maps /trigger.so at a fixed low virtual address (0x1000000).
 *
 * Because all ASLR-randomized library addresses are in the 0xc.../0xf... range
 * on 64-bit kernels, 0x1000000 appears *first* in /proc/self/maps.
 *
 * The injector's second-pass scan of /proc/self/maps processes entries from
 * lowest to highest address, so it reaches the trigger.so entry before libc.
 * ElfDynLib.lookupAddress("setenv") then hits the crafted empty GNU hash
 * bucket and panics with "integer overflow".
 */
#define _GNU_SOURCE
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

static void __attribute__((constructor(101))) map_trigger(void) {
    int fd = open("/trigger.so", O_RDONLY);
    if (fd < 0) return;

    struct stat st;
    if (fstat(fd, &st) < 0) { close(fd); return; }

    /* 0x1000000 = 16 MB — well below the ASLR mmap range on 64-bit kernels */
    mmap((void *)0x1000000, (size_t)st.st_size,
         PROT_READ | PROT_EXEC,
         MAP_FIXED | MAP_PRIVATE, fd, 0);
    close(fd);
}
