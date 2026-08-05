/* Hand-written probe for the emitted C17 projection of the store slice.
   Type indices are positional in module_0.h; the two 3-field records are the
   physical row shapes the store threads through its transaction history, the
   two 2-field records its scalar pairs. Not generated — the materializer emits
   types only, so the run-time check is the layout claim, not a store body. */
#include "module_0.h"

int main(void) {
  uint8_t storage[512];
  native_arena arena;
  native_arena_init(&arena, storage, sizeof(storage));

  native_m0_type_0 handle = INT64_C(9007199254740993);
  if (handle - INT64_C(1) != INT64_C(9007199254740992)) {
    return 1;
  }

  native_m0_type_2 *row_a =
      native_arena_alloc(&arena, sizeof(*row_a), _Alignof(native_m0_type_2));
  native_m0_type_3 *row_b =
      native_arena_alloc(&arena, sizeof(*row_b), _Alignof(native_m0_type_3));
  native_m0_type_1 *pair_a =
      native_arena_alloc(&arena, sizeof(*pair_a), _Alignof(native_m0_type_1));
  native_m0_type_4 *pair_b =
      native_arena_alloc(&arena, sizeof(*pair_b), _Alignof(native_m0_type_4));
  if ((row_a == NULL) || (row_b == NULL) || (pair_a == NULL) || (pair_b == NULL)) {
    return 2;
  }

  row_a->field_0 = INT64_C(7);
  row_a->field_1 = INT64_C(11);
  row_a->field_2 = handle;
  row_b->field_0 = row_a->field_0;
  row_b->field_1 = row_a->field_1;
  row_b->field_2 = row_a->field_2;
  if ((row_b->field_0 + row_b->field_1) != INT64_C(18)) {
    return 3;
  }
  if (row_b->field_2 != handle) {
    return 4;
  }

  pair_a->field_0 = INT64_C(-1);
  pair_a->field_1 = handle;
  pair_b->field_0 = pair_a->field_1;
  pair_b->field_1 = pair_a->field_0;
  if ((pair_b->field_0 != handle) || (pair_b->field_1 != INT64_C(-1))) {
    return 5;
  }

  /* The projected records must be distinct arena objects, never aliases. */
  if ((void *)row_a == (void *)row_b) {
    return 6;
  }

  native_arena_reset(&arena);
  return 0;
}
