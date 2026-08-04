#include "module_0.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define DEMO_ARENA_BYTES ((size_t)4096)

extern bool native_m1_fn_0(uint64_t value);

static uint64_t text_from_c(native_arena *arena, const char *value) {
  size_t length = strlen(value);
  uint8_t *destination = NULL;
  uint64_t handle = native_text_alloc(arena, (uint64_t)length, &destination);
  if (length != 0U) {
    memcpy(destination, value, length);
  }
  return handle;
}

int main(int argc, char **argv) {
  uint8_t storage[DEMO_ARENA_BYTES];
  native_arena arena;
  int index;

  native_arena_init(&arena, storage, sizeof(storage));
  for (index = 1; index < argc; index++) {
    uint64_t value = text_from_c(&arena, argv[index]);
    bool c17 = native_m0_fn_15(value);
    bool qbe = native_m1_fn_0(value);
    if (printf("%d\t%d\n", c17 ? 1 : 0, qbe ? 1 : 0) < 0) {
      return 2;
    }
    if (c17 != qbe) {
      return 1;
    }
  }
  return 0;
}
