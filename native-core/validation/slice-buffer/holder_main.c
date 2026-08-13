#include "module_0.h"

#ifndef BUFFER_HOLDER_FN
#error "drive.sh must name the generated Holder field-return symbol"
#endif

int main(void) {
  native_arena arena;
  native_capability capability = { .token = UINT64_C(1) };
  uint64_t before;
  native_buffer *buffer;
  double value;

  if (!native_arena_init_growable(&arena, (size_t)4096U)) {
    return 1;
  }
  before = arena.buffer_storage_allocation_count;
  buffer = BUFFER_HOLDER_FN(&arena, &capability);
  if (buffer == NULL ||
      arena.buffer_storage_allocation_count - before != UINT64_C(1)) {
    return 2;
  }
  value = *(const double *)native_buffer_at(
      &arena, buffer, &capability, INT64_C(1), INT64_C(8), (size_t)8U);
  if (value != 6.0) {
    return 3;
  }
  native_arena_destroy(&arena);
  return 0;
}
