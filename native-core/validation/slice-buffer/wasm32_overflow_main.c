#include "native_shim.h"

#include <stdlib.h>

static void expect_overflow(uint32_t code) {
  if (code == NATIVE_TRAP_OVERFLOW) {
    fputs("wasm32-size-trap: overflow\n", stdout);
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
  native_set_trap_reporter(expect_overflow);
  /* 2^29 doubles require 2^32 bytes: representable by Int, not wasm32 size_t. */
  (void)native_buffer_new(&arena, &capability, INT64_C(536870912), INT64_C(8),
                          (size_t)8);
  return 98;
}
