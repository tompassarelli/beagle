#include "module_0.h"

#ifndef BUFFER_RUN_FN
#error "drive.sh must name the generated run-stencil symbol"
#endif
#ifndef BUFFER_FILL_FN
#error "drive.sh must name the generated fill symbol"
#endif
#ifndef BUFFER_STENCIL_FN
#error "drive.sh must name the generated stencil symbol"
#endif

_Static_assert(sizeof(native_buffer *) == sizeof(void *),
               "Buffer values use the pointer-sized handle ABI");
_Static_assert(sizeof(((native_buffer *)0)->owner_capability_token) ==
                   sizeof(uint64_t),
               "Buffer headers bind their creator capability token");

int main(void) {
  native_arena arena;
  native_capability capability = { .token = UINT64_C(1) };
  uint64_t before;
  uint64_t arena_before;
  double result;
  native_buffer *empty_left;
  native_buffer *empty_right;
  native_buffer *one;

  if (!native_arena_init_growable(&arena, (size_t)4096U)) {
    return 1;
  }
  before = native_buffer_storage_allocations;
  arena_before = native_arena_allocations;
  result = BUFFER_RUN_FN(&arena, &capability, INT64_C(6));
  if (result != 3.0) {
    return 2;
  }
  if (native_buffer_storage_allocations - before != UINT64_C(2)) {
    return 3;
  }
  if (native_arena_allocations - arena_before != UINT64_C(4)) {
    return 7;
  }
  before = native_buffer_storage_allocations;
  if (BUFFER_RUN_FN(&arena, &capability, INT64_C(-1)) != 0.0 ||
      native_buffer_storage_allocations != before) {
    return 4;
  }
  empty_left = native_buffer_new(&arena, &capability, INT64_C(0), INT64_C(8),
                                 (size_t)8);
  empty_right = native_buffer_new(&arena, &capability, INT64_C(0), INT64_C(8),
                                  (size_t)8);
  if (BUFFER_FILL_FN(&arena, &capability, empty_left) != 0.0 ||
      BUFFER_STENCIL_FN(&arena, &capability, empty_left, empty_right) != 0.0) {
    return 5;
  }
  one = native_buffer_new(&arena, &capability, INT64_C(1), INT64_C(8),
                          (size_t)8);
  if (BUFFER_STENCIL_FN(&arena, &capability, empty_left, one) != 0.0) {
    return 6;
  }
  native_arena_destroy(&arena);
  return 0;
}
