#include "module_0.h"
#include "native_parallel.h"

int main(void) {
  native_arena arena;
  native_capability capability = {.token = UINT64_C(19)};
  double result;

  if (!native_parallel_configure_default_workers(INT32_C(3))) {
    return 1;
  }
  if (!native_arena_init_growable(&arena, (size_t)4096U)) {
    return 2;
  }

  result = native_m0_fn_1(&arena, &capability);
  native_arena_destroy(&arena);

  if (result != 8.0) {
    return 3;
  }
  if (native_parallel_live_workers != UINT64_C(3)) {
    return 4;
  }
  return 0;
}
