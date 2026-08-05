#include "module_0.h"
#include "function_map.h"

#include <string.h>

static uint64_t text(native_arena *arena, const char *value) {
  size_t length = strlen(value);
  uint8_t *destination = NULL;
  uint64_t handle = native_text_alloc(arena, (uint64_t)length, &destination);
  if (length != (size_t)0U) {
    memcpy(destination, value, length);
  }
  return handle;
}

int main(void) {
  uint8_t storage[4096];
  native_arena arena;
  const native_capability capability = { UINT64_C(1) };
  uint64_t present;
  uint64_t missing;
  int64_t first_clock;
  int64_t second_clock;

  native_arena_init(&arena, storage, sizeof storage);
  present = text(&arena, "BEAGLE_NATIVE_HOST_TEST");
  missing = text(&arena, "BEAGLE_NATIVE_HOST_TEST__MISSING_6B1F0B8");

  if (!HOST_GETENV_PRESENT(&arena, &capability, present)) {
    return 1;
  }
  if (HOST_GETENV_LENGTH(&arena, &capability, present) != INT64_C(16)) {
    return 2;
  }
  if (HOST_GETENV_PRESENT(&arena, &capability, missing)) {
    return 3;
  }
  if (HOST_GETENV_LENGTH(&arena, &capability, missing) != INT64_C(0)) {
    return 4;
  }
  first_clock = HOST_MONOTONIC_NOW(&capability);
  second_clock = HOST_MONOTONIC_NOW(&capability);
  if (first_clock < INT64_C(0)) {
    return 5;
  }
  if (second_clock < first_clock) {
    return 6;
  }
  return 0;
}
