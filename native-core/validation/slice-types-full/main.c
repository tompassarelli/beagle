/* Hand-written probe for the emitted C17 projection: arena-allocates every
   materialized record, round-trips its fields, and gives ASan/UBSan a live
   allocation to watch. Not generated — the materializer emits types only. */
#include "module_0.h"

int main(void) {
  uint8_t storage[256];
  native_arena arena;
  native_arena_init(&arena, storage, sizeof(storage));

  native_m0_type_0 scalar = INT64_C(-9007199254740993);
  if (scalar + INT64_C(1) != INT64_C(-9007199254740992)) {
    return 1;
  }

  native_m0_type_1 *triple =
      native_arena_alloc(&arena, sizeof(*triple), _Alignof(native_m0_type_1));
  if (triple == NULL) {
    return 2;
  }
  triple->field_0 = INT64_C(1);
  triple->field_1 = INT64_C(2);
  triple->field_2 = INT64_C(3);

  native_m0_type_2 *pair_a =
      native_arena_alloc(&arena, sizeof(*pair_a), _Alignof(native_m0_type_2));
  native_m0_type_3 *pair_b =
      native_arena_alloc(&arena, sizeof(*pair_b), _Alignof(native_m0_type_3));
  native_m0_type_4 *triple_b =
      native_arena_alloc(&arena, sizeof(*triple_b), _Alignof(native_m0_type_4));
  if ((pair_a == NULL) || (pair_b == NULL) || (triple_b == NULL)) {
    return 3;
  }
  pair_a->field_0 = scalar;
  pair_a->field_1 = INT64_C(0);
  pair_b->field_0 = INT64_C(0);
  pair_b->field_1 = scalar;
  triple_b->field_0 = triple->field_0;
  triple_b->field_1 = triple->field_1;
  triple_b->field_2 = triple->field_2;

  if ((triple->field_0 + triple->field_1 + triple->field_2) != INT64_C(6)) {
    return 4;
  }
  if ((pair_a->field_0 != scalar) || (pair_b->field_1 != scalar)) {
    return 5;
  }
  if (triple_b->field_2 != INT64_C(3)) {
    return 6;
  }

  native_arena_reset(&arena);
  return 0;
}
