#include "module_0.h"

#include <stdlib.h>

#ifndef BUFFER_CAPABILITY_OP
#error "drive.sh must select length (0), get (1), or set (2)"
#endif

_Static_assert(sizeof(((native_buffer *)0)->owner_capability_token) ==
                   sizeof(uint64_t),
               "Buffer ABI must retain its creator capability token");

static void expect_invalid_argument(uint32_t code) {
  if (code == NATIVE_TRAP_INVALID_ARGUMENT) {
    fputs("capability-trap: invalid-argument\n", stdout);
    fflush(stdout);
    _Exit(0);
  }
  _Exit(97);
}

int main(void) {
  native_arena arena;
  native_capability owner = { .token = UINT64_C(11) };
  native_capability forged = { .token = UINT64_C(12) };
  native_buffer *buffer;
#if BUFFER_CAPABILITY_OP == 2
  double value = 5.0;
#endif

  if (!native_arena_init_growable(&arena, (size_t)4096U)) {
    return 1;
  }
  buffer = native_buffer_new(&arena, &owner, INT64_C(1), INT64_C(8),
                             (size_t)8);
  native_set_trap_reporter(expect_invalid_argument);
#if BUFFER_CAPABILITY_OP == 0
  (void)native_buffer_length(buffer, &forged);
#elif BUFFER_CAPABILITY_OP == 1
  (void)native_buffer_at(buffer, &forged, INT64_C(0), INT64_C(8),
                         (size_t)8U);
#elif BUFFER_CAPABILITY_OP == 2
  native_buffer_set(buffer, &forged, INT64_C(0), &value, INT64_C(8),
                    (size_t)8U);
#else
#error "unknown BUFFER_CAPABILITY_OP"
#endif
  return 98;
}
