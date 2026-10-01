#include <arrow/c/abi.h>
#include <stddef.h>
#include <stdio.h>

#define CHECK_WORD(member, index) \
    _Static_assert(offsetof(struct ArrowArray, member) == (index) * 8, #member)
CHECK_WORD(length, 0);
CHECK_WORD(null_count, 1);
CHECK_WORD(offset, 2);
CHECK_WORD(n_buffers, 3);
CHECK_WORD(n_children, 4);
CHECK_WORD(buffers, 5);
CHECK_WORD(children, 6);
CHECK_WORD(dictionary, 7);
CHECK_WORD(release, 8);
CHECK_WORD(private_data, 9);

int main(void) {
    printf("size=%zu\n", sizeof(struct ArrowArray));
    printf("release=%zu\n", offsetof(struct ArrowArray, release));
    printf("private=%zu\n", offsetof(struct ArrowArray, private_data));
    printf("pointer_size=%zu\n", sizeof(void *));
    printf("function_size=%zu\n", sizeof(((struct ArrowArray *)0)->release));
    printf("alignment=%zu\n", _Alignof(struct ArrowArray));
    return 0;
}
