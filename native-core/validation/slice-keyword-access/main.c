#include "module_0.h"

int main(void) {
  uint8_t storage[512];
  native_arena arena;
  native_m0_type_3 pair = {INT64_C(17), UINT64_C(0)};
  uint64_t keys[] = {native_m0_fn_1()};
  int64_t values[] = {INT64_C(42)};

  native_arena_init(&arena, storage, sizeof storage);
  native_map *present = native_map_from_arrays(
      &arena, keys, values, INT64_C(1), sizeof keys[0],
      _Alignof(uint64_t), sizeof values[0],
      _Alignof(int64_t), NATIVE_COLLECTION_EQ_KEYWORD);
  native_map *missing = native_map_from_arrays(
      &arena, NULL, NULL, INT64_C(0), sizeof keys[0],
      _Alignof(uint64_t), sizeof values[0],
      _Alignof(int64_t), NATIVE_COLLECTION_EQ_KEYWORD);

  if (native_m0_fn_0(pair) != INT64_C(17)) {
    return 1;
  }
  if (!native_m0_fn_2(present) || native_m0_fn_2(missing)) {
    return 2;
  }
  if (!native_m0_fn_3(present, INT64_C(42)) ||
      native_m0_fn_3(present, INT64_C(41)) ||
      native_m0_fn_3(missing, INT64_C(42))) {
    return 3;
  }
  return 0;
}
