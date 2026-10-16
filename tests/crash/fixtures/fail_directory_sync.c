/* Fail one directory fsync when the test creates its marker. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

static int fail_directory_sync(int fd) {
    const char *marker = getenv("AKASHA_FSYNC_FAIL_MARKER");
    struct stat status;
    if (marker && fstat(fd, &status) == 0 && S_ISDIR(status.st_mode)
        && unlink(marker) == 0) {
        errno = EIO;
        return -1;
    }
#ifdef __APPLE__
    /* dyld leaves calls from the interposing image bound to the original. */
    return fsync(fd);
#else
    int (*original)(int) = (int (*)(int))dlsym(RTLD_NEXT, "fsync");
    if (!original) {
        errno = ENOSYS;
        return -1;
    }
    return original(fd);
#endif
}

#ifdef __APPLE__
/* dyld's interpose table is a pair of replacement/original function addresses.
 * https://github.com/apple-oss-distributions/dyld/blob/main/include/mach-o/dyld-interposing.h
 */
__attribute__((used, section("__DATA,__interpose")))
static const struct {
    int (*replacement)(int);
    int (*original)(int);
} directory_sync_interpose = {fail_directory_sync, fsync};
#else
int fsync(int fd) {
    return fail_directory_sync(fd);
}
#endif
