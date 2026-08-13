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
  native_arena other_arena;
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
  before = arena.buffer_storage_allocation_count;
  arena_before = arena.allocation_count;
  result = BUFFER_RUN_FN(&arena, &capability, INT64_C(6));
  if (result != 3.0) {
    return 2;
  }
  if (arena.buffer_storage_allocation_count - before != UINT64_C(2)) {
    return 3;
  }
  if (arena.allocation_count - arena_before != UINT64_C(4)) {
    return 7;
  }
  if (arena.buffer_storage_current_bytes != (size_t)128U ||
      arena.buffer_storage_high_water_bytes != (size_t)128U) {
    return 8;
  }
  before = arena.buffer_storage_allocation_count;
  if (BUFFER_RUN_FN(&arena, &capability, INT64_C(-1)) != 0.0 ||
      arena.buffer_storage_allocation_count != before) {
    return 4;
  }
  empty_left = native_buffer_new(&arena, &capability, INT64_C(0), INT64_C(8),
                                 (size_t)8);
  empty_right = native_buffer_new(&arena, &capability, INT64_C(0), INT64_C(8),
                                  (size_t)8);
  if (arena.buffer_storage_allocation_count != before ||
      arena.buffer_storage_current_bytes != (size_t)128U) {
    return 9;
  }
  if (BUFFER_FILL_FN(&arena, &capability, empty_left) != 0.0 ||
      BUFFER_STENCIL_FN(&arena, &capability, empty_left, empty_right) != 0.0) {
    return 5;
  }
  one = native_buffer_new(&arena, &capability, INT64_C(1), INT64_C(8),
                          (size_t)8);
  if (arena.buffer_storage_allocation_count != before + UINT64_C(1) ||
      arena.buffer_storage_current_bytes != (size_t)136U ||
      arena.buffer_storage_high_water_bytes != (size_t)136U) {
    return 10;
  }
  if (BUFFER_STENCIL_FN(&arena, &capability, empty_left, one) != 0.0) {
    return 6;
  }
  if (!native_arena_init_growable(&other_arena, (size_t)4096U)) {
    return 11;
  }
  (void)native_buffer_new(&other_arena, &capability, INT64_C(2), INT64_C(8),
                          (size_t)8U);
  if (other_arena.buffer_storage_allocation_count != UINT64_C(1) ||
      other_arena.buffer_storage_current_bytes != (size_t)16U ||
      other_arena.buffer_storage_high_water_bytes != (size_t)16U ||
      arena.buffer_storage_current_bytes != (size_t)136U) {
    return 12;
  }
  native_arena_reset(&arena);
  if (arena.allocation_count != UINT64_C(0) ||
      arena.buffer_storage_allocation_count != UINT64_C(0) ||
      arena.buffer_storage_current_bytes != (size_t)0U ||
      arena.buffer_storage_high_water_bytes != (size_t)136U) {
    return 13;
  }
  (void)native_buffer_new(&arena, &capability, INT64_C(1), INT64_C(8),
                          (size_t)8U);
  if (arena.buffer_storage_current_bytes != (size_t)8U ||
      arena.buffer_storage_high_water_bytes != (size_t)136U) {
    return 14;
  }
  native_arena_destroy(&other_arena);
  native_arena_destroy(&arena);
  return 0;
}
