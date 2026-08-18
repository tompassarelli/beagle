/* Probe for the coercion rule. Hand-written; the module under it is generated.
   With the argument "mismatch" it hands a checked extract a value carrying the
   wrong tag, which must trap instead of reading the payload as a reference.
   fn_0 pair?  fn_1 wrap-int  fn_2 pair-left-of  fn_3 pair-right-of
   fn_4 any-equal? fn_5 any-hash fn_6 any-compare fn_7 pair-copy-of
   fn_8..19 logic probes; fn_26..31 exact Bool predicate probes;
   fn_32..43 numeric scalar probes; fn_44..46 vector predicates;
   fn_47 text suffix.
   Any tags: 0 bool, 1 i64, 2 f64, 3 text, 4 keyword, 5 nil, 6 Pair,
   7 StoreIndex, 8 RecursiveValue, 9 OpaqueIndex, 10 LateUnsafe,
   11 ValueRow, 12 TaggedValue. */
#include <math.h>
#include "module_0.h"

#ifndef SLICE_ANY_TYPE
#error "SLICE_ANY_TYPE must name the generated Any type"
#endif
#ifndef SLICE_NIL_TYPE
#error "SLICE_NIL_TYPE must name the generated Nil type"
#endif
#ifndef SLICE_PAIR_TYPE
#error "SLICE_PAIR_TYPE must name the generated Pair type"
#endif

typedef SLICE_ANY_TYPE slice_any;
typedef SLICE_NIL_TYPE slice_nil_value;
typedef SLICE_PAIR_TYPE slice_pair_value;

struct slice_recursive_value {
  slice_any next;
};

#define ARENA_BYTES ((size_t)16384)
#define RECURSIVE_DEPTH ((size_t)160U)

static uint8_t arena_storage[ARENA_BYTES];
static const native_capability capability = { UINT64_C(0) };

struct slice_text_blob {
  uint64_t length;
  uint8_t bytes[3];
};

struct slice_store_index {
  native_vec *cells;
};

struct slice_opaque_index {
  native_set *members;
};

struct slice_late_unsafe {
  int64_t prefix;
  native_vec *cells;
};

static const struct slice_text_blob text_abc_left = {
  UINT64_C(3), { UINT8_C('a'), UINT8_C('b'), UINT8_C('c') }
};
static const struct slice_text_blob text_abc_right = {
  UINT64_C(3), { UINT8_C('a'), UINT8_C('b'), UINT8_C('c') }
};
static const struct slice_text_blob text_abd = {
  UINT64_C(3), { UINT8_C('a'), UINT8_C('b'), UINT8_C('d') }
};

struct slice_text_blob_2 {
  uint64_t length;
  uint8_t bytes[2];
};

static const struct slice_text_blob_2 text_42 = {
  UINT64_C(2), { UINT8_C('4'), UINT8_C('2') }
};

static const native_value_descriptor vector_cycle_descriptor = {
  .abi_version = NATIVE_VALUE_ABI_VERSION,
  .kind = NATIVE_VALUE_VECTOR,
  .size = sizeof(native_vec *),
  .alignment = _Alignof(native_vec *),
  .tag_offset = (size_t)0,
  .fields = NULL,
  .field_count = (size_t)0,
  .variants = NULL,
  .variant_count = (size_t)0,
  .element = &vector_cycle_descriptor,
  .stride = sizeof(native_vec *),
  .map_key = NULL,
  .map_value = NULL,
  .keywords = NULL,
  .keyword_count = (size_t)0
};

static slice_any slice_pair(void *target) {
  slice_any value;
  value.tag = INT64_C(6);
  value.payload.variant_6 = target;
  return value;
}

static slice_any slice_store_index(void *target) {
  slice_any value;
  value.tag = INT64_C(7);
  value.payload.variant_7 = target;
  return value;
}

static slice_any slice_recursive_value(void *target) {
  slice_any value;
  value.tag = INT64_C(8);
  value.payload.variant_8 = target;
  return value;
}

static slice_any slice_opaque_index(void *target) {
  slice_any value;
  value.tag = INT64_C(9);
  value.payload.variant_9 = target;
  return value;
}

static slice_any slice_late_unsafe(void *target) {
  slice_any value;
  value.tag = INT64_C(10);
  value.payload.variant_10 = target;
  return value;
}

static slice_any slice_i64(int64_t number) {
  slice_any value;
  value.tag = INT64_C(1);
  value.payload.variant_1 = number;
  return value;
}

static slice_any slice_f64(double number) {
  slice_any value;
  value.tag = INT64_C(2);
  value.payload.variant_2 = number;
  return value;
}

static slice_any slice_text(const struct slice_text_blob *blob) {
  slice_any value;
  value.tag = INT64_C(3);
  value.payload.variant_3 = (uint64_t)(uintptr_t)blob;
  return value;
}

static slice_any slice_keyword(const struct slice_text_blob *blob) {
  slice_any value;
  value.tag = INT64_C(4);
  value.payload.variant_4 = (uint64_t)(uintptr_t)blob;
  return value;
}

static slice_any slice_bool(bool flag) {
  slice_any value;
  value.tag = INT64_C(0);
  value.payload.variant_0 = flag;
  return value;
}

static slice_any slice_nil(void) {
  slice_any value = { .tag = INT64_C(5) };
  return value;
}

static uint64_t text_value(native_arena *arena, const char *value) {
  uint8_t *bytes;
  size_t length = strlen(value);
  uint64_t handle = native_text_alloc(arena, (uint64_t)length, &bytes);
  if (length > 0U) {
    memcpy(bytes, value, length);
  }
  return handle;
}

int main(int argc, char **argv) {
  native_arena arena;
  slice_pair_value pair = { INT64_C(3), INT64_C(4) };
  slice_pair_value equal_pair = { INT64_C(3), INT64_C(4) };
  slice_pair_value different_pair = { INT64_C(3), INT64_C(5) };
  slice_any as_pair = slice_pair(&pair);
  slice_any as_equal_pair = slice_pair(&equal_pair);
  slice_any as_different_pair = slice_pair(&different_pair);
  slice_any as_number = slice_i64(INT64_C(42));
  slice_any as_zero = slice_f64(0.0);
  slice_any as_negative_zero = slice_f64(-0.0);
  slice_any as_abc_left = slice_text(&text_abc_left);
  slice_any as_abc_right = slice_text(&text_abc_right);
  slice_any as_abd = slice_text(&text_abd);
  slice_any as_false = slice_bool(false);
  slice_any as_true = slice_bool(true);
  slice_any as_nil = slice_nil();
  struct slice_recursive_value recursive[RECURSIVE_DEPTH];
  struct slice_recursive_value equal_recursive[RECURSIVE_DEPTH];
  struct slice_recursive_value recursive_cycle;
  struct slice_store_index unsafe_index;
  struct slice_store_index null_vector_index = { NULL };
  struct slice_opaque_index opaque_index = { NULL };
  struct slice_late_unsafe late_left;
  struct slice_late_unsafe late_right;
  native_atom *cell = NULL;
  native_vec *cells;
  slice_any as_recursive;
  slice_any as_equal_recursive;
  slice_any as_cycle;
  slice_any unsupported;
  slice_any opaque;
  slice_any late_unsafe_left;
  slice_any late_unsafe_right;
  slice_any null_text = slice_text(NULL);
  slice_any null_keyword = slice_keyword(NULL);
  slice_any null_vector = slice_store_index(&null_vector_index);
  native_vec *vector_cycle;
  native_vec *vector_cycle_element;
  size_t depth;

  native_arena_init(&arena, arena_storage, ARENA_BYTES);

  recursive[0].next = as_number;
  equal_recursive[0].next = as_number;
  for (depth = 1U; depth < RECURSIVE_DEPTH; depth++) {
    recursive[depth].next = slice_recursive_value(&recursive[depth - 1U]);
    equal_recursive[depth].next =
        slice_recursive_value(&equal_recursive[depth - 1U]);
  }
  as_recursive = slice_recursive_value(&recursive[RECURSIVE_DEPTH - 1U]);
  as_equal_recursive =
      slice_recursive_value(&equal_recursive[RECURSIVE_DEPTH - 1U]);
  recursive_cycle.next = slice_recursive_value(&recursive_cycle);
  as_cycle = slice_recursive_value(&recursive_cycle);

  cells = native_vec_new(
      &arena, INT64_C(1), (int64_t)sizeof cell, _Alignof(native_atom *));
  cells = native_vec_push(&arena, cells, &cell, (int64_t)sizeof cell,
                          _Alignof(native_atom *));
  unsafe_index.cells = cells;
  unsupported = slice_store_index(&unsafe_index);
  opaque = slice_opaque_index(&opaque_index);
  late_left.prefix = INT64_C(0);
  late_left.cells = cells;
  late_right.prefix = INT64_C(1);
  late_right.cells = cells;
  late_unsafe_left = slice_late_unsafe(&late_left);
  late_unsafe_right = slice_late_unsafe(&late_right);
  vector_cycle = native_vec_new(
      &arena, INT64_C(1), (int64_t)sizeof vector_cycle,
      _Alignof(native_vec *));
  vector_cycle = native_vec_push(
      &arena, vector_cycle, &vector_cycle, (int64_t)sizeof vector_cycle,
      _Alignof(native_vec *));
  /* push copies the old header pointer. Rewrite that test-only payload after
     the final persistent header exists so this is a genuine vector-only cycle. */
  memcpy(vector_cycle->elements, &vector_cycle, sizeof vector_cycle);
  memcpy(&vector_cycle_element, vector_cycle->elements,
         sizeof vector_cycle_element);
  if (vector_cycle_element != vector_cycle) {
    return 104;
  }

  if ((argc > 1) && (argv[1][0] == 'u')) {
    if (argv[1][1] == 'e') {
      (void)SLICE_FN_4(unsupported, unsupported);
    } else if (argv[1][1] == 'h') {
      (void)SLICE_FN_5(unsupported);
    } else {
      (void)SLICE_FN_6(unsupported, unsupported);
    }
    return 12;
  }

  if ((argc > 1) && (argv[1][0] == 'o')) {
    if (argv[1][1] == 'e') {
      (void)SLICE_FN_4(opaque, opaque);
    } else if (argv[1][1] == 'h') {
      (void)SLICE_FN_5(opaque);
    } else {
      (void)SLICE_FN_6(opaque, opaque);
    }
    return 13;
  }

  if ((argc > 1) && (argv[1][0] == 'c')) {
    if (argv[1][1] == 'e') {
      (void)SLICE_FN_4(as_cycle, as_cycle);
    } else if (argv[1][1] == 'h') {
      (void)SLICE_FN_5(as_cycle);
    } else {
      (void)SLICE_FN_6(as_cycle, as_cycle);
    }
    return 14;
  }

  if ((argc > 1) && (argv[1][0] == 'l')) {
    if (argv[1][1] == 'e') {
      (void)SLICE_FN_4(late_unsafe_left, late_unsafe_right);
    } else {
      (void)SLICE_FN_6(late_unsafe_left, late_unsafe_right);
    }
    return 15;
  }

  if ((argc > 1) && (argv[1][0] == 'x')) {
    if (argv[1][1] == 'e') {
      (void)SLICE_FN_4(as_number, unsupported);
    } else {
      (void)SLICE_FN_6(as_number, unsupported);
    }
    return 16;
  }

  if ((argc > 1) && (argv[1][0] == 'y')) {
    if (argv[1][1] == 'e') {
      (void)SLICE_FN_4(unsupported, as_number);
    } else {
      (void)SLICE_FN_6(unsupported, as_number);
    }
    return 17;
  }

  if ((argc > 1) && (argv[1][0] == 'z')) {
    if (argv[1][1] == 'a') {
      (void)SLICE_FN_63(unsupported);
    } else if (argv[1][1] == 'b') {
      (void)SLICE_FN_64(unsupported);
    } else {
      (void)SLICE_FN_65(unsupported);
    }
    return 18;
  }

  if ((argc > 1) && (argv[1][0] == 'v')) {
    if (argv[1][1] == 'e') {
      (void)native_dynamic_value_equal(
          &vector_cycle_descriptor, &vector_cycle, &vector_cycle);
    } else if (argv[1][1] == 'h') {
      (void)native_dynamic_value_hash(
          &vector_cycle_descriptor, &vector_cycle);
    } else if (argv[1][1] == 'c') {
      (void)native_dynamic_value_compare(
          &vector_cycle_descriptor, &vector_cycle, &vector_cycle);
    } else {
      native_dynamic_value_validate(
          &vector_cycle_descriptor, &vector_cycle);
    }
    return 19;
  }

  if ((argc > 1) && (argv[1][0] == 'w')) {
    if (argv[1][1] == 'e') {
      (void)SLICE_FN_4(null_text, null_text);
    } else if (argv[1][1] == 'h') {
      (void)SLICE_FN_5(null_text);
    } else {
      (void)SLICE_FN_6(null_text, null_text);
    }
    return 20;
  }

  if ((argc > 1) && (argv[1][0] == 'i')) {
    if (argv[1][1] == 'e') {
      (void)SLICE_FN_4(null_keyword, null_keyword);
    } else if (argv[1][1] == 'h') {
      (void)SLICE_FN_5(null_keyword);
    } else {
      (void)SLICE_FN_6(null_keyword, null_keyword);
    }
    return 21;
  }

  if ((argc > 1) && (argv[1][0] == 'p')) {
    if (argv[1][1] == 'e') {
      (void)SLICE_FN_4(null_vector, null_vector);
    } else if (argv[1][1] == 'h') {
      (void)SLICE_FN_5(null_vector);
    } else {
      (void)SLICE_FN_6(null_vector, null_vector);
    }
    return 22;
  }

  if ((argc > 1) && (argv[1][0] == 'g')) {
    native_map *map = SLICE_FN_50(&arena, &capability);
    (void)SLICE_FN_51(map, unsupported);
    return 23;
  }

  if ((argc > 1) && (argv[1][0] == 'q')) {
    native_map *map = SLICE_FN_50(&arena, &capability);
    (void)SLICE_FN_57(map, unsupported);
    return 24;
  }

  if ((argc > 1) && (argv[1][0] == 'a')) {
    native_map *map = SLICE_FN_50(&arena, &capability);
    (void)SLICE_FN_52(&arena, &capability, map, unsupported, INT64_C(1));
    return 25;
  }

  if ((argc > 1) && (argv[1][0] == 's')) {
    native_set *set = SLICE_FN_53(&arena, &capability);
    (void)SLICE_FN_54(set, unsupported);
    return 26;
  }

  if ((argc > 1) && (argv[1][0] == 'j')) {
    native_set *set = SLICE_FN_53(&arena, &capability);
    (void)SLICE_FN_55(&arena, &capability, set, unsupported);
    return 27;
  }

  if ((argc > 1) && (argv[1][0] == 'k')) {
    native_map *map = SLICE_FN_50(&arena, &capability);
    (void)SLICE_FN_58(&arena, &capability, map, unsupported);
    return 28;
  }

  if ((argc > 1) && (argv[1][0] == 'r')) {
    native_set *set = SLICE_FN_53(&arena, &capability);
    (void)SLICE_FN_60(&arena, &capability, set, unsupported);
    return 29;
  }

  if ((argc > 1) && (argv[1][0] == 't')) {
    if (argv[1][1] == 'm') {
      (void)SLICE_FN_61(
          &arena, &capability, unsupported, unsupported);
    } else {
      (void)SLICE_FN_62(
          &arena, &capability, unsupported, unsupported);
    }
    return 30;
  }

  if ((argc > 1) && (argv[1][0] == 'n')) {
    SLICE_FN_7(slice_pair(NULL));
    return 10;
  }

  if ((argc > 1) && (argv[1][0] == 'd')) {
    SLICE_FN_35(as_abc_left);
    return 11;
  }

  if ((argc > 1) && (argv[1][0] == 'm')) {
    /* the extract expects the Pair tag and this value carries i64 */
    SLICE_FN_2(as_number);
    return 9;
  }

  /* tag inject: a concrete Int widens into the closed Any union */
  slice_any wrapped = SLICE_FN_1(INT64_C(42));
  if ((wrapped.tag != INT64_C(1)) || (wrapped.payload.variant_1 != INT64_C(42))) {
    return 1;
  }

  /* checked extract: the payload comes back out as the Pair reference and the
     field read goes through it */
  if (SLICE_FN_2(as_pair) != INT64_C(3)) {
    return 2;
  }
  if (SLICE_FN_3(as_pair) != INT64_C(4)) {
    return 3;
  }

  if (!SLICE_FN_0(as_pair)) {
    return 4;
  }
  if (SLICE_FN_0(as_number) || SLICE_FN_0(wrapped)) {
    return 5;
  }
  if (!SLICE_FN_4(as_pair, as_equal_pair)
      || SLICE_FN_4(as_pair, as_different_pair)
      || SLICE_FN_4(as_pair, as_number)
      || !SLICE_FN_4(as_number, wrapped)
      || !SLICE_FN_4(as_zero, as_negative_zero)
      || !SLICE_FN_4(as_abc_left, as_abc_right)) {
    return 6;
  }
  if ((SLICE_FN_5(as_pair) != SLICE_FN_5(as_equal_pair))
      || (SLICE_FN_5(as_number) != SLICE_FN_5(wrapped))
      || (SLICE_FN_5(as_zero) != SLICE_FN_5(as_negative_zero))
      || (SLICE_FN_5(as_abc_left) != SLICE_FN_5(as_abc_right))
      || (SLICE_FN_5(as_number) != INT64_C(6352684378363895460))
      || (SLICE_FN_5(as_pair) != INT64_C(491762441038723618))
      || (SLICE_FN_5(as_abc_left) != INT64_C(4838897213494911832))) {
    return 7;
  }
  if ((SLICE_FN_6(as_pair, as_equal_pair) != INT64_C(0))
      || (SLICE_FN_6(as_pair, as_different_pair) >= INT64_C(0))
      || (SLICE_FN_6(as_different_pair, as_pair) <= INT64_C(0))
      || (SLICE_FN_6(as_number, as_pair) >= INT64_C(0))
      || (SLICE_FN_6(as_zero, as_negative_zero) != INT64_C(0))
      || (SLICE_FN_6(as_abc_left, as_abc_right) != INT64_C(0))
      || (SLICE_FN_6(as_abc_left, as_abd) >= INT64_C(0))) {
    return 8;
  }
  if (!SLICE_FN_4(as_recursive, as_equal_recursive)
      || (SLICE_FN_5(as_recursive)
          != SLICE_FN_5(as_equal_recursive))
      || (SLICE_FN_6(as_recursive, as_equal_recursive) != INT64_C(0))) {
    return 47;
  }
  {
    slice_any null_record = slice_pair(NULL);
    if (!SLICE_FN_4(null_record, null_record)
        || (SLICE_FN_5(null_record) != SLICE_FN_5(null_record))
        || (SLICE_FN_6(null_record, null_record) != INT64_C(0))) {
      return 48;
    }
  }
  {
    native_map *map = SLICE_FN_50(&arena, &capability);
    native_set *set = SLICE_FN_53(&arena, &capability);
    if ((SLICE_FN_56(map) != INT64_C(0))
        || (SLICE_FN_59(set) != INT64_C(0))
        || SLICE_FN_51(map, as_pair)
        || SLICE_FN_54(set, as_pair)) {
      return 49;
    }
    map = SLICE_FN_52(
        &arena, &capability, map, as_pair, INT64_C(7));
    set = SLICE_FN_55(&arena, &capability, set, as_pair);
    map = SLICE_FN_52(
        &arena, &capability, map, as_equal_pair, INT64_C(8));
    set = SLICE_FN_55(&arena, &capability, set, as_equal_pair);
    if ((SLICE_FN_56(map) != INT64_C(1))
        || (SLICE_FN_57(map, as_pair) != INT64_C(8))
        || (SLICE_FN_57(map, as_equal_pair) != INT64_C(8))
        || (SLICE_FN_59(set) != INT64_C(1))
        || !SLICE_FN_51(map, as_pair)
        || !SLICE_FN_51(map, as_equal_pair)
        || !SLICE_FN_54(set, as_pair)
        || !SLICE_FN_54(set, as_equal_pair)) {
      return 50;
    }
    map = SLICE_FN_58(&arena, &capability, map, as_equal_pair);
    set = SLICE_FN_60(&arena, &capability, set, as_equal_pair);
    if ((SLICE_FN_56(map) != INT64_C(0))
        || (SLICE_FN_59(set) != INT64_C(0))
        || SLICE_FN_51(map, as_pair)
        || SLICE_FN_54(set, as_pair)) {
      return 51;
    }
  }
  {
    native_map *map = SLICE_FN_61(
        &arena, &capability, as_pair, as_equal_pair);
    native_set *set = SLICE_FN_62(
        &arena, &capability, as_pair, as_equal_pair);
    if ((SLICE_FN_56(map) != INT64_C(1))
        || (SLICE_FN_57(map, as_pair) != INT64_C(2))
        || (SLICE_FN_57(map, as_equal_pair) != INT64_C(2))
        || (SLICE_FN_59(set) != INT64_C(1))
        || !SLICE_FN_54(set, as_pair)
        || !SLICE_FN_54(set, as_equal_pair)) {
      return 52;
    }
  }
  if (!SLICE_FN_63(as_number)
      || !SLICE_FN_64(as_number)
      || SLICE_FN_65(as_number)
      || SLICE_FN_63(as_pair)
      || SLICE_FN_64(as_pair)
      || !SLICE_FN_65(as_pair)) {
    return 53;
  }
  slice_pair_value copied_pair = SLICE_FN_7(as_pair);
  if ((copied_pair.field_0 != INT64_C(3)) ||
      (copied_pair.field_1 != INT64_C(4))) {
    return 9;
  }

  slice_any result = SLICE_FN_8(as_number, as_pair);
  if ((result.tag != INT64_C(6)) || (result.payload.variant_6 != &pair)) {
    return 10;
  }
  result = SLICE_FN_8(as_nil, as_number);
  if (result.tag != INT64_C(5)) {
    return 11;
  }
  result = SLICE_FN_8(as_false, as_number);
  if ((result.tag != INT64_C(0)) || result.payload.variant_0) {
    return 12;
  }

  result = SLICE_FN_9(as_number, as_pair);
  if ((result.tag != INT64_C(1)) || (result.payload.variant_1 != INT64_C(42))) {
    return 13;
  }
  result = SLICE_FN_9(as_nil, as_pair);
  if ((result.tag != INT64_C(6)) || (result.payload.variant_6 != &pair)) {
    return 14;
  }

  result = SLICE_FN_10(as_number, as_pair, as_abc_left);
  if ((result.tag != INT64_C(3))
      || (result.payload.variant_3 != (uint64_t)(uintptr_t)&text_abc_left)) {
    return 15;
  }
  result = SLICE_FN_10(as_number, as_nil, as_abc_left);
  if (result.tag != INT64_C(5)) {
    return 16;
  }
  result = SLICE_FN_11(as_nil, as_false, as_abc_left);
  if ((result.tag != INT64_C(3))
      || (result.payload.variant_3 != (uint64_t)(uintptr_t)&text_abc_left)) {
    return 17;
  }
  result = SLICE_FN_11(as_nil, as_number, as_abc_left);
  if ((result.tag != INT64_C(1)) || (result.payload.variant_1 != INT64_C(42))) {
    return 18;
  }

  result = SLICE_FN_12(INT64_C(42));
  if ((result.tag != INT64_C(1)) || (result.payload.variant_1 != INT64_C(42))) {
    return 19;
  }
  result = SLICE_FN_13(INT64_C(42));
  if ((result.tag != INT64_C(1)) || (result.payload.variant_1 != INT64_C(42))) {
    return 20;
  }
  if (!SLICE_FN_14()) {
    return 21;
  }
  slice_nil_value empty_or = SLICE_FN_15();
  if (empty_or.tag != INT64_C(0)) {
    return 22;
  }

  result = SLICE_FN_16(as_pair);
  if ((result.tag != INT64_C(6)) || (result.payload.variant_6 != &pair)) {
    return 23;
  }
  result = SLICE_FN_17(as_number);
  if ((result.tag != INT64_C(1)) || (result.payload.variant_1 != INT64_C(42))) {
    return 24;
  }
  result = SLICE_FN_18(as_number);
  if ((result.tag != INT64_C(1)) || (result.payload.variant_1 != INT64_C(42))) {
    return 25;
  }
  result = SLICE_FN_19(as_nil);
  if (result.tag != INT64_C(5)) {
    return 26;
  }
  if (!SLICE_FN_26(false) || SLICE_FN_26(true)) {
    return 27;
  }
  if (!SLICE_FN_27(true) || SLICE_FN_27(false)) {
    return 28;
  }
  if (!SLICE_FN_28(as_false)
      || SLICE_FN_28(as_true)
      || SLICE_FN_28(as_nil)
      || SLICE_FN_28(as_number)
      || SLICE_FN_28(as_pair)) {
    return 29;
  }
  if (!SLICE_FN_29(as_true)
      || SLICE_FN_29(as_false)
      || SLICE_FN_29(as_nil)
      || SLICE_FN_29(as_number)
      || SLICE_FN_29(as_pair)) {
    return 30;
  }
  if (SLICE_FN_30(INT64_C(0)) || SLICE_FN_30(INT64_C(1))) {
    return 31;
  }
  if (SLICE_FN_31(INT64_C(0)) || SLICE_FN_31(INT64_C(1))) {
    return 32;
  }
  if (SLICE_FN_32() != 1.5) {
    return 33;
  }
  if ((SLICE_FN_33(INT64_C(42)) != 42.0)
      || (SLICE_FN_33(INT64_C(9007199254740993))
        != 9007199254740992.0)) {
    return 34;
  }
  if ((SLICE_FN_34(3.25) != 3.25)
      || !signbit(SLICE_FN_34(-0.0))
      || !isnan(SLICE_FN_34(NAN))) {
    return 35;
  }
  if ((SLICE_FN_35(as_number) != 42.0)
      || !signbit(SLICE_FN_35(as_negative_zero))) {
    return 36;
  }
  if (!SLICE_FN_36(2.5, 2.5)
      || !SLICE_FN_36(0.0, -0.0)
      || SLICE_FN_36(NAN, NAN)) {
    return 37;
  }
  if (!SLICE_FN_37(1.0, 2.0)
      || SLICE_FN_37(2.0, 1.0)
      || SLICE_FN_37(NAN, 1.0)) {
    return 38;
  }
  if (!SLICE_FN_38(1.0, 1.0)
      || !SLICE_FN_38(1.0, 2.0)
      || SLICE_FN_38(NAN, 1.0)) {
    return 39;
  }
  if (!SLICE_FN_39(2.0, 1.0)
      || SLICE_FN_39(1.0, 2.0)
      || SLICE_FN_39(NAN, 1.0)) {
    return 40;
  }
  if (!SLICE_FN_40(2.0, 2.0)
      || !SLICE_FN_40(2.0, 1.0)
      || SLICE_FN_40(NAN, 1.0)) {
    return 41;
  }

  uint64_t text_42_address = (uint64_t)(uintptr_t)&text_42;
  uint64_t text_abc_address = (uint64_t)(uintptr_t)&text_abc_left;
  if ((SLICE_FN_41(text_42_address) != INT64_C(42))
      || (SLICE_FN_41(text_abc_address) != -INT64_C(1))) {
    return 42;
  }
  if ((SLICE_FN_42(slice_text((const struct slice_text_blob *)&text_42))
        != INT64_C(42))
      || (SLICE_FN_42(as_abc_left) != -INT64_C(1))
      || (SLICE_FN_42(as_number) != -INT64_C(2))) {
    return 43;
  }
  if (!SLICE_FN_43(INT64_C(1), INT64_C(2))
      || SLICE_FN_43(INT64_C(2), INT64_C(1))) {
    return 44;
  }
  {
    native_vec *values =
        native_vec_new(&arena, INT64_C(0), INT64_C(8), (size_t)8);
    if (!SLICE_FN_45(values) || SLICE_FN_46(INT64_C(42))) {
      return 45;
    }
  }
  {
    uint64_t alphabet = text_value(&arena, "alphabet");
    uint64_t alpha = text_value(&arena, "alpha");
    uint64_t bet = text_value(&arena, "bet");
    uint64_t empty = text_value(&arena, "");
    uint64_t snowman = text_value(&arena, "snow\xE9\x9B\xAA\xE4\xBA\xBA");
    uint64_t person = text_value(&arena, "\xE4\xBA\xBA");
    if (!SLICE_FN_47(alphabet, bet) ||
        SLICE_FN_47(alphabet, alpha) ||
        !SLICE_FN_47(alphabet, alphabet) ||
        !SLICE_FN_47(alphabet, empty) ||
        !SLICE_FN_47(empty, empty) ||
        SLICE_FN_47(empty, bet) ||
        !SLICE_FN_47(snowman, person)) {
      return 46;
    }
  }
  return 0;
}
