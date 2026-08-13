#include "module_0.h"

#include <stdlib.h>

#ifndef BUFFER_BOUND_FN
#error "drive.sh must name a generated checked-access symbol"
#endif

static void expect_out_of_range(uint32_t code) {
  if (code == NATIVE_TRAP_OUT_OF_RANGE) {
    fputs("bounds-trap: out-of-range\n", stdout);
    fflush(stdout);
    _Exit(0);
  }
  _Exit(97);
}

int main(void) {
  native_arena arena;
  native_capability capability = { .token = UINT64_C(1) };
  native_buffer *buffer;

  if (!native_arena_init_growable(&arena, (size_t)4096U)) {
    return 1;
  }
  buffer = native_buffer_new(&arena, &capability, INT64_C(1), INT64_C(8),
                             (size_t)8);
  native_set_trap_reporter(expect_out_of_range);
  (void)BUFFER_BOUND_FN(&arena, &capability, buffer, INT64_C(1));
  return 98;
}
