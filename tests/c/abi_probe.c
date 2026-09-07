#include <stdint.h>

extern int32_t akasha_abi_probe_add(int32_t a, int32_t b);

int main(void) {
    return akasha_abi_probe_add(19, 23) == 42 ? 0 : 1;
}
