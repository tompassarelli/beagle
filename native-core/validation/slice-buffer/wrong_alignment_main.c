#include "module_0.h"

#include <stdlib.h>

#ifndef BUFFER_ALIGNMENT_OP
#error "drive.sh must select read-expected (0), read-actual (1), set-expected (2), or set-actual (3)"
#endif

static void expect_invalid_argument(uint32_t code) {
  if (code == NATIVE_TRAP_INVALID_ARGUMENT) {
    fputs("alignment-trap: invalid-argument\n", stdout);
    fflush(stdout);
    _Exit(0);
  }
  _Exit(97);
}

int main(void) {
  native_arena arena;
  native_capability capability = { .token = UINT64_C(13) };
  native_buffer *buffer;
#if BUFFER_ALIGNMENT_OP >= 2
  double value = 5.0;
#endif

  if (!native_arena_init_growable(&arena, (size_t)4096U)) {
    return 1;
  }
  buffer = native_buffer_new(&arena, &capability, INT64_C(1), INT64_C(8),
                             (size_t)8U);
#if BUFFER_ALIGNMENT_OP == 1 || BUFFER_ALIGNMENT_OP == 3
  buffer->elements = (uint8_t *)buffer->elements + (size_t)1U;
#endif
  native_set_trap_reporter(expect_invalid_argument);
#if BUFFER_ALIGNMENT_OP == 0
  (void)native_buffer_at(buffer, &capability, INT64_C(0), INT64_C(8),
                         (size_t)4U);
#elif BUFFER_ALIGNMENT_OP == 1
  (void)native_buffer_at(buffer, &capability, INT64_C(0), INT64_C(8),
                         (size_t)8U);
#elif BUFFER_ALIGNMENT_OP == 2
  native_buffer_set(buffer, &capability, INT64_C(0), &value, INT64_C(8),
                    (size_t)4U);
#elif BUFFER_ALIGNMENT_OP == 3
  native_buffer_set(buffer, &capability, INT64_C(0), &value, INT64_C(8),
                    (size_t)8U);
#else
#error "unknown BUFFER_ALIGNMENT_OP"
#endif
  return 98;
}
