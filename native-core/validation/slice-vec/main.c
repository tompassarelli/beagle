/* Probe for the lowered Vec vocabulary. Hand-written; the module under it is
   generated. With any argument it takes the out-of-range path, which traps.
   fn_35 bucket-size          fn_36 bucket-position-at
   fn_37 bucket-with-position fn_38 append-position
   fn_39 position-pair        fn_40 empty-positions
   fn_41 frame-operation-count fn_42 frame-operation-at */
#include "module_0.h"

#define ARENA_BYTES ((size_t)65536)
#define PUSH_COUNT INT64_C(100)
/* 100 pushes from capacity 0 double as 4,8,16,32,64,128: six storage claims.
   The bar is O(log n), so the assertion allows slack over the exact count. */
#define PUSH_ALLOCATION_BOUND UINT64_C(8)

static uint8_t arena_storage[ARENA_BYTES];
static const native_capability capability = { UINT64_C(1) };

int main(int argc, char **argv) {
  (void)argv;
  native_arena arena;
  native_arena_init(&arena, arena_storage, ARENA_BYTES);

  native_m0_type_16 positions = native_vec_new(&arena, INT64_C(0), INT64_C(8), (size_t)8);
  native_m0_type_17 bucket = { INT64_C(7), positions };

  native_vec_storage_allocations = UINT64_C(0);
  for (int64_t i = INT64_C(0); i < PUSH_COUNT; ++i) {
    positions = native_m0_fn_38(&arena, &capability, positions, i);
  }
  uint64_t push_allocations = native_vec_storage_allocations;
  bucket.field_1 = positions;

  if (native_m0_fn_35(bucket) != PUSH_COUNT) {
    return 1;
  }
  for (int64_t i = INT64_C(0); i < PUSH_COUNT; ++i) {
    if (native_m0_fn_36(bucket, i) != i) {
      return 2;
    }
  }
  if (push_allocations > PUSH_ALLOCATION_BOUND) {
    return 3;
  }

  if (argc > 1) {
    /* an index at or past the length must trap, never return */
    (void)native_m0_fn_36(bucket, PUSH_COUNT);
    return 9;
  }

  native_m0_type_17 grown = native_m0_fn_37(&arena, &capability, bucket, INT64_C(4242));
  if ((grown.field_0 != INT64_C(7))
      || (native_m0_fn_35(grown) != (PUSH_COUNT + INT64_C(1)))
      || (native_m0_fn_36(grown, PUSH_COUNT) != INT64_C(4242))) {
    return 4;
  }

  native_vec_storage_allocations = UINT64_C(0);
  native_m0_type_16 pair = native_m0_fn_39(&arena, &capability, INT64_C(11), INT64_C(22));
  if ((native_vec_length(pair) != INT64_C(2))
      || (native_vec_storage_allocations != UINT64_C(1))) {
    return 5;
  }
  native_m0_type_17 pair_bucket = { INT64_C(0), pair };
  if ((native_m0_fn_36(pair_bucket, INT64_C(0)) != INT64_C(11))
      || (native_m0_fn_36(pair_bucket, INT64_C(1)) != INT64_C(22))) {
    return 6;
  }

  if (native_vec_length(native_m0_fn_40(&arena, &capability)) != INT64_C(0)) {
    return 7;
  }

  /* (Vec Record): a CommitOperation vector, stride 56, read back by value */
  native_m0_type_28 operations = native_vec_new(&arena, INT64_C(2), INT64_C(56), (size_t)8);
  native_m0_type_53 assert_operation = { UINT64_C(101), { { INT64_C(0) }, { INT64_C(0) }, { INT64_C(0) } } };
  native_m0_type_53 retract_operation = { UINT64_C(202), { { INT64_C(0) }, { INT64_C(0) }, { INT64_C(0) } } };
  operations = native_vec_push(&arena, operations, &assert_operation, INT64_C(56), (size_t)8);
  operations = native_vec_push(&arena, operations, &retract_operation, INT64_C(56), (size_t)8);
  native_m0_type_29 frame = { INT64_C(3), operations };
  if (native_m0_fn_41(frame) != INT64_C(2)) {
    return 8;
  }
  if ((native_m0_fn_42(frame, INT64_C(0)).field_0 != UINT64_C(101))
      || (native_m0_fn_42(frame, INT64_C(1)).field_0 != UINT64_C(202))) {
    return 10;
  }

  printf("vec: %lld pushes, %llu element-storage allocations\n",
         (long long)PUSH_COUNT, (unsigned long long)push_allocations);
  return 0;
}
