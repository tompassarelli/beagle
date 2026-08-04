#include "module_0.h"

#ifndef ASSOC_PAIR_TYPE
#error "drive.sh must name the generated pair type"
#endif

int main(void) {
  uint8_t storage[128];
  native_arena arena;
  native_capability capability = { UINT64_C(1) };
  ASSOC_PAIR_TYPE source = { INT64_C(10), INT64_C(20) };
  native_arena_init(&arena, storage, sizeof(storage));

  ASSOC_PAIR_TYPE first =
    native_m0_fn_0(&arena, &capability, source, INT64_C(99));
  if ((source.field_0 != INT64_C(10)) ||
      (source.field_1 != INT64_C(20))) {
    return 1;
  }
  if ((first.field_0 != INT64_C(10)) ||
      (first.field_1 != INT64_C(99))) {
    return 2;
  }
  size_t first_offset = arena.offset;
  if (first_offset < sizeof(source)) {
    return 3;
  }

  ASSOC_PAIR_TYPE second =
    native_m0_fn_0(&arena, &capability, source, INT64_C(77));
  if ((second.field_0 != INT64_C(10)) ||
      (second.field_1 != INT64_C(77))) {
    return 4;
  }
  if (arena.offset <= first_offset) {
    return 5;
  }

  native_arena_reset(&arena);
  return 0;
}
