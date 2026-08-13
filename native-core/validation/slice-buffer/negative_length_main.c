#include "module_0.h"

#include <stdlib.h>

#ifndef BUFFER_ALLOCATE_FN
#error "drive.sh must name the generated Buffer allocator"
#endif

static void expect_invalid_argument(uint32_t code) {
  if (code == NATIVE_TRAP_INVALID_ARGUMENT) {
    fputs("length-trap: invalid-argument\n", stdout);
    fflush(stdout);
    _Exit(0);
  }
  _Exit(97);
}

int main(void) {
  native_arena arena;
  native_capability capability = { .token = UINT64_C(1) };

  if (!native_arena_init_growable(&arena, (size_t)4096U)) {
    return 1;
  }
  native_set_trap_reporter(expect_invalid_argument);
  (void)BUFFER_ALLOCATE_FN(&arena, &capability, INT64_C(-1));
  return 98;
}
