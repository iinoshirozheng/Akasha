#define _DEFAULT_SOURCE 1
#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/mman.h>
#include <sys/stat.h>

#if !((defined(__APPLE__) && defined(__aarch64__)) || \
      (defined(__linux__) && defined(__x86_64__) && defined(__GLIBC__)))
#error "Unverified MappedFile ABI"
#endif

int main(void) {
    const uint32_t endian = 1;
    printf("stat_bytes=%zu\n", sizeof(struct stat));
    printf("stat_alignment=%zu\n", _Alignof(struct stat));
    printf("size_offset=%zu\n", offsetof(struct stat, st_size));
    printf("size_bytes=%zu\n", sizeof(((struct stat *)0)->st_size));
    printf("size_signed=%d\n", (off_t)-1 < 0);
    printf("mode_offset=%zu\n", offsetof(struct stat, st_mode));
    printf("mode_bytes=%zu\n", sizeof(((struct stat *)0)->st_mode));
    printf("off_t_bytes=%zu\n", sizeof(off_t));
    printf("size_t_bytes=%zu\n", sizeof(size_t));
    printf("little_endian=%d\n", *(const unsigned char *)&endian == 1);
    printf("o_rdonly=%d\n", O_RDONLY);
    printf("prot_read=%d\n", PROT_READ);
    printf("map_private=%d\n", MAP_PRIVATE);
    printf("map_failed=%ld\n", (long)(intptr_t)MAP_FAILED);
    return 0;
}
