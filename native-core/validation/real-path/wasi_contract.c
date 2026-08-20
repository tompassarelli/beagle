#include "native_shim.h"

#include <errno.h>
#include <stdint.h>

int main(void) {
  native_arena arena;
  native_capability capability = {UINT64_C(1)};
  uint64_t out = UINT64_C(7);

  native_arena_init(&arena, NULL, (size_t)0U);
  if (native_host_filesystem_real_path_v0(
          &arena, &capability, UINT64_C(0), &out) != ENOTSUP) {
    return 1;
  }
  return (out == UINT64_C(0)) ? 0 : 2;
}
