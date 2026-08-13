#include "native_shim.h"

#include <stdlib.h>

#ifndef BUFFER_OWNERSHIP_OP
#error "drive.sh must select a Buffer ownership regression"
#endif

static void expect_invalid_argument(uint32_t code) {
  if (code == NATIVE_TRAP_INVALID_ARGUMENT) {
    fputs("ownership-trap: invalid-argument\n", stdout);
    fflush(stdout);
    _Exit(0);
  }
  _Exit(97);
}

int main(void) {
#if BUFFER_OWNERSHIP_OP == 2 || BUFFER_OWNERSHIP_OP == 3
  uint8_t fixed_storage[512];
#endif
  native_arena arena;
#if BUFFER_OWNERSHIP_OP == 4
  native_arena other_arena;
#endif
  native_capability owner = { .token = UINT64_C(17) };
#if BUFFER_OWNERSHIP_OP == 4 || BUFFER_OWNERSHIP_OP == 5
  native_capability equal_token = { .token = UINT64_C(17) };
#endif
  native_buffer *buffer;
#if BUFFER_OWNERSHIP_OP == 1 || BUFFER_OWNERSHIP_OP == 3
  native_buffer *fresh;
#endif

#if BUFFER_OWNERSHIP_OP == 2 || BUFFER_OWNERSHIP_OP == 3
  native_arena_init(&arena, fixed_storage, sizeof fixed_storage);
#else
  if (!native_arena_init_growable(&arena, (size_t)4096U)) {
    return 1;
  }
#endif
  buffer = native_buffer_new(&arena, &owner, INT64_C(2), INT64_C(8),
                             (size_t)8U);

#if BUFFER_OWNERSHIP_OP == 0 || BUFFER_OWNERSHIP_OP == 2
  native_arena_reset(&arena);
#elif BUFFER_OWNERSHIP_OP == 1 || BUFFER_OWNERSHIP_OP == 3
  native_arena_reset(&arena);
  fresh = native_buffer_new(&arena, &owner, INT64_C(2), INT64_C(8),
                            (size_t)8U);
  if ((fresh == buffer) ||
      (native_buffer_length(&arena, fresh, &owner) != INT64_C(2))) {
    return 96;
  }
#elif BUFFER_OWNERSHIP_OP == 4
  if (!native_arena_init_growable(&other_arena, (size_t)4096U)) {
    return 2;
  }
  (void)native_buffer_new(&other_arena, &equal_token, INT64_C(2), INT64_C(8),
                          (size_t)8U);
#elif BUFFER_OWNERSHIP_OP == 6
  buffer->length = INT64_MAX;
#elif BUFFER_OWNERSHIP_OP == 7
  buffer->elements = (uint8_t *)buffer->elements + (size_t)8U;
#elif BUFFER_OWNERSHIP_OP == 8
  buffer->stride = INT64_C(16);
#elif BUFFER_OWNERSHIP_OP == 9
  buffer->owner_capability_token = UINT64_C(23);
#endif

  native_set_trap_reporter(expect_invalid_argument);
#if BUFFER_OWNERSHIP_OP == 4
  (void)native_buffer_length(&other_arena, buffer, &equal_token);
#elif BUFFER_OWNERSHIP_OP == 5
  (void)native_buffer_length(&arena, buffer, &equal_token);
#else
  (void)native_buffer_length(&arena, buffer, &owner);
#endif
  return 98;
}
