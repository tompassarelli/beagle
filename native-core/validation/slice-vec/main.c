/* Probe for the lowered Vec vocabulary. Hand-written; the module under it is
   generated. With any argument it takes the out-of-range path, which traps.
   fn_59 bucket-size          fn_60 bucket-position-at
   fn_61 bucket-with-position fn_62 append-position
   fn_63 position-pair        fn_64 empty-positions
   fn_65 frame-operation-count fn_66 frame-operation-at
   fn_67 any-values-equal?   fn_68 increment-value
   fn_69 decrement-value     fn_70 mask-values
   fn_71 xor-values          fn_72 shifted-value
   fn_73 values-differ?      fn_74 no-positions?
   fn_75 position-slice      fn_76 position-tail
   fn_77 reversed-positions  fn_78 append-positions */
#include "module_0.h"

#define ARENA_BYTES ((size_t)65536)
#define PUSH_COUNT INT64_C(100)
/* 100 pushes from capacity 0 double as 4,8,16,32,64,128: six allocations.
   The bar is O(log n), so the assertion allows slack over the exact count. */
#define PUSH_ALLOCATION_BOUND UINT64_C(8)

static uint8_t arena_storage[ARENA_BYTES];
static const native_capability capability = { UINT64_C(1) };

static uint64_t keyword_value(native_arena *arena, const char *value) {
  uint8_t *bytes;
  size_t length = strlen(value);
  uint64_t handle = native_text_alloc(arena, (uint64_t)length, &bytes);
  if (length > 0U) {
    memcpy(bytes, value, length);
  }
  return handle;
}

int main(int argc, char **argv) {
  (void)argv;
  native_arena arena;
  native_arena_init(&arena, arena_storage, ARENA_BYTES);

  uint64_t assert_action = keyword_value(&arena, "assert");
  uint64_t retract_action = keyword_value(&arena, "retract");

  native_m0_type_20 positions = native_vec_new(&arena, INT64_C(0), INT64_C(8), (size_t)8);
  native_m0_type_21 bucket = { INT64_C(7), positions };

  native_vec_storage_allocations = UINT64_C(0);
  for (int64_t i = INT64_C(0); i < PUSH_COUNT; ++i) {
    positions = native_m0_fn_62(&arena, &capability, positions, i);
  }
  uint64_t push_allocations = native_vec_storage_allocations;
  bucket.field_1 = positions;

  if (native_m0_fn_59(bucket) != PUSH_COUNT) {
    return 1;
  }
  for (int64_t i = INT64_C(0); i < PUSH_COUNT; ++i) {
    if (native_m0_fn_60(bucket, i) != i) {
      return 2;
    }
  }
  if (push_allocations > PUSH_ALLOCATION_BOUND) {
    return 3;
  }

  if ((argc > 1) && (strcmp(argv[1], "overflow") == 0)) {
    (void)native_m0_fn_68(INT64_MAX);
    return 9;
  }
  if (argc > 1) {
    /* an index at or past the length must trap, never return */
    (void)native_m0_fn_60(bucket, PUSH_COUNT);
    return 9;
  }

  native_m0_type_21 grown = native_m0_fn_61(&arena, &capability, bucket, INT64_C(4242));
  /* conj is persistent: the bucket the conj read must still hold PUSH_COUNT */
  if ((grown.field_0 != INT64_C(7))
      || (native_m0_fn_59(grown) != (PUSH_COUNT + INT64_C(1)))
      || (native_m0_fn_60(grown, PUSH_COUNT) != INT64_C(4242))
      || (native_m0_fn_59(bucket) != PUSH_COUNT)) {
    return 4;
  }
  /* and a second conj off the same base is a fork, not a second append */
  native_m0_type_21 forked = native_m0_fn_61(&arena, &capability, bucket, INT64_C(99));
  if ((native_m0_fn_59(forked) != (PUSH_COUNT + INT64_C(1)))
      || (native_m0_fn_60(forked, PUSH_COUNT) != INT64_C(99))
      || (native_m0_fn_60(grown, PUSH_COUNT) != INT64_C(4242))
      || (native_m0_fn_59(bucket) != PUSH_COUNT)) {
    return 14;
  }

  native_vec_storage_allocations = UINT64_C(0);
  native_m0_type_20 pair = native_m0_fn_63(&arena, &capability, INT64_C(11), INT64_C(22));
  if ((native_vec_length(pair) != INT64_C(2))
      || (native_vec_storage_allocations != UINT64_C(1))) {
    return 5;
  }
  native_m0_type_21 pair_bucket = { INT64_C(0), pair };
  if ((native_m0_fn_60(pair_bucket, INT64_C(0)) != INT64_C(11))
      || (native_m0_fn_60(pair_bucket, INT64_C(1)) != INT64_C(22))) {
    return 6;
  }

  if (native_vec_length(native_m0_fn_64(&arena, &capability)) != INT64_C(0)) {
    return 7;
  }

  /* (Vec Record): a CommitOperation vector, stride 56, read back by value */
  native_m0_type_30 operations = native_vec_new(&arena, INT64_C(2), INT64_C(56), (size_t)8);
  native_m0_type_59 assert_operation = {
    .field_0 = assert_action,
    .field_1 = {
      .field_0 = { .tag = INT64_C(0), .payload.variant_0 = false },
      .field_1 = { .tag = INT64_C(0), .payload.variant_0 = false },
      .field_2 = { .tag = INT64_C(0), .payload.variant_0 = false }
    }
  };
  native_m0_type_59 retract_operation = {
    .field_0 = retract_action,
    .field_1 = {
      .field_0 = { .tag = INT64_C(0), .payload.variant_0 = false },
      .field_1 = { .tag = INT64_C(0), .payload.variant_0 = false },
      .field_2 = { .tag = INT64_C(0), .payload.variant_0 = false }
    }
  };
  operations = native_vec_push(&arena, operations, &assert_operation, INT64_C(56), (size_t)8);
  operations = native_vec_push(&arena, operations, &retract_operation, INT64_C(56), (size_t)8);
  native_m0_type_31 frame = { INT64_C(3), operations };
  if (native_m0_fn_65(frame) != INT64_C(2)) {
    return 8;
  }
  if (!native_text_eq(
          native_m0_fn_66(frame, INT64_C(0)).field_0, assert_action)
      || !native_text_eq(
          native_m0_fn_66(frame, INT64_C(1)).field_0, retract_action)) {
    return 10;
  }

  /* (Vec Any): distinct vectors compare elementwise through the Any tags. */
  native_m0_type_57 any_int = { .tag = INT64_C(1),
                                .payload.variant_1 = INT64_C(17) };
  native_m0_type_57 any_bool = { .tag = INT64_C(0),
                                 .payload.variant_0 = true };
  native_m0_type_57 any_other = { .tag = INT64_C(1),
                                  .payload.variant_1 = INT64_C(18) };
  native_m0_type_22 values = native_vec_new(&arena, INT64_C(2), INT64_C(16), (size_t)8);
  native_m0_type_22 equal_values = native_vec_new(&arena, INT64_C(2), INT64_C(16), (size_t)8);
  native_m0_type_22 different_values = native_vec_new(&arena, INT64_C(2), INT64_C(16), (size_t)8);
  values = native_vec_push(&arena, values, &any_int, INT64_C(16), (size_t)8);
  values = native_vec_push(&arena, values, &any_bool, INT64_C(16), (size_t)8);
  equal_values = native_vec_push(&arena, equal_values, &any_int, INT64_C(16), (size_t)8);
  equal_values = native_vec_push(&arena, equal_values, &any_bool, INT64_C(16), (size_t)8);
  different_values = native_vec_push(&arena, different_values, &any_int, INT64_C(16), (size_t)8);
  different_values = native_vec_push(&arena, different_values, &any_other, INT64_C(16), (size_t)8);
  if (!native_m0_fn_67(values, equal_values)
      || native_m0_fn_67(values, different_values)) {
    return 11;
  }

  if ((native_m0_fn_68(INT64_C(41)) != INT64_C(42))
      || (native_m0_fn_69(INT64_C(43)) != INT64_C(42))
      || (native_m0_fn_70(INT64_C(240), INT64_C(90)) != INT64_C(80))
      || (native_m0_fn_71(INT64_C(240), INT64_C(90)) != INT64_C(170))
      || (native_m0_fn_72(INT64_C(1), INT64_C(65)) != INT64_C(2))
      || !native_m0_fn_73(INT64_C(7), INT64_C(8))
      || native_m0_fn_73(INT64_C(7), INT64_C(7))
      || !native_m0_fn_74(native_m0_fn_64(&arena, &capability))
      || native_m0_fn_74(pair)) {
    return 12;
  }

  native_m0_type_20 first = native_m0_fn_75(
      &arena, &capability, pair, INT64_C(0), INT64_C(1));
  native_m0_type_20 tail = native_m0_fn_76(
      &arena, &capability, pair, INT64_C(1));
  native_m0_type_20 reversed = native_m0_fn_77(&arena, &capability, pair);
  native_m0_type_20 appended = native_m0_fn_78(&arena, &capability, pair, pair);
  if ((native_vec_length(first) != INT64_C(1))
      || (native_vec_length(tail) != INT64_C(1))
      || (native_vec_length(reversed) != INT64_C(2))
      || (native_vec_length(appended) != INT64_C(4))
      || (*(const int64_t *)native_vec_at(first, INT64_C(0), INT64_C(8))
          != INT64_C(11))
      || (*(const int64_t *)native_vec_at(tail, INT64_C(0), INT64_C(8))
          != INT64_C(22))
      || (*(const int64_t *)native_vec_at(reversed, INT64_C(0), INT64_C(8))
          != INT64_C(22))
      || (*(const int64_t *)native_vec_at(reversed, INT64_C(1), INT64_C(8))
          != INT64_C(11))
      || (*(const int64_t *)native_vec_at(appended, INT64_C(2), INT64_C(8))
          != INT64_C(11))
      || (native_vec_length(pair) != INT64_C(2))) {
    return 13;
  }

  printf("vec: %lld pushes, %llu element-storage allocations\n",
         (long long)PUSH_COUNT, (unsigned long long)push_allocations);
  return 0;
}
