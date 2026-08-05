#include "module_0.h"

#ifndef DRIVE_FN
#error "DRIVE_FN must name the materialized doseq driver"
#endif

#define ARENA_BYTES ((size_t)4096)

static uint8_t arena_storage[ARENA_BYTES];
static const native_capability capability = { UINT64_C(1) };

int main(int argc, char **argv) {
  (void)argv;
  native_arena arena;
  native_arena_init(&arena, arena_storage, ARENA_BYTES);

  if (argc > 1) {
    (void)DRIVE_FN(&arena, &capability, true);
    return 90;
  }
  return DRIVE_FN(&arena, &capability, false) == INT64_C(42) ? 0 : 1;
}
