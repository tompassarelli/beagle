/* Probe for the coercion rule. Hand-written; the module under it is generated.
   With the argument "mismatch" it hands a checked extract a value carrying the
   wrong tag, which must trap instead of reading the payload as a reference.
   fn_0 pair?  fn_1 wrap-int  fn_2 pair-left-of  fn_3 pair-right-of
   fn_4 any-equal? fn_5 any-hash fn_6 any-compare fn_7 pair-copy-of
   fn_8..19 logic probes.
   Any tags: 0 bool, 1 i64, 2 f64, 3 text, 4 keyword, 5 nil, 6 Pair. */
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

struct slice_text_blob {
  uint64_t length;
  uint8_t bytes[3];
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

static slice_any slice_pair(void *target) {
  slice_any value;
  value.tag = INT64_C(6);
  value.payload.variant_6 = target;
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

int main(int argc, char **argv) {
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
  slice_any as_nil = slice_nil();

  if ((argc > 1) && (argv[1][0] == 'n')) {
    native_m0_fn_7(slice_pair(NULL));
    return 10;
  }

  if (argc > 1) {
    /* the extract expects the Pair tag and this value carries i64 */
    native_m0_fn_2(as_number);
    return 9;
  }

  /* tag inject: a concrete Int widens into the closed Any union */
  slice_any wrapped = native_m0_fn_1(INT64_C(42));
  if ((wrapped.tag != INT64_C(1)) || (wrapped.payload.variant_1 != INT64_C(42))) {
    return 1;
  }

  /* checked extract: the payload comes back out as the Pair reference and the
     field read goes through it */
  if (native_m0_fn_2(as_pair) != INT64_C(3)) {
    return 2;
  }
  if (native_m0_fn_3(as_pair) != INT64_C(4)) {
    return 3;
  }

  if (!native_m0_fn_0(as_pair)) {
    return 4;
  }
  if (native_m0_fn_0(as_number) || native_m0_fn_0(wrapped)) {
    return 5;
  }
  if (!native_m0_fn_4(as_pair, as_equal_pair)
      || native_m0_fn_4(as_pair, as_different_pair)
      || native_m0_fn_4(as_pair, as_number)
      || !native_m0_fn_4(as_number, wrapped)
      || !native_m0_fn_4(as_zero, as_negative_zero)
      || !native_m0_fn_4(as_abc_left, as_abc_right)) {
    return 6;
  }
  if ((native_m0_fn_5(as_pair) != native_m0_fn_5(as_equal_pair))
      || (native_m0_fn_5(as_number) != native_m0_fn_5(wrapped))
      || (native_m0_fn_5(as_zero) != native_m0_fn_5(as_negative_zero))
      || (native_m0_fn_5(as_abc_left) != native_m0_fn_5(as_abc_right))
      || (native_m0_fn_5(as_number) != INT64_C(6352684378363895460))
      || (native_m0_fn_5(as_pair) != INT64_C(491762441038723618))
      || (native_m0_fn_5(as_abc_left) != INT64_C(4838897213494911832))) {
    return 7;
  }
  if ((native_m0_fn_6(as_pair, as_equal_pair) != INT64_C(0))
      || (native_m0_fn_6(as_pair, as_different_pair) >= INT64_C(0))
      || (native_m0_fn_6(as_different_pair, as_pair) <= INT64_C(0))
      || (native_m0_fn_6(as_number, as_pair) >= INT64_C(0))
      || (native_m0_fn_6(as_zero, as_negative_zero) != INT64_C(0))
      || (native_m0_fn_6(as_abc_left, as_abc_right) != INT64_C(0))
      || (native_m0_fn_6(as_abc_left, as_abd) >= INT64_C(0))) {
    return 8;
  }
  slice_pair_value copied_pair = native_m0_fn_7(as_pair);
  if ((copied_pair.field_0 != INT64_C(3)) ||
      (copied_pair.field_1 != INT64_C(4))) {
    return 9;
  }

  slice_any result = native_m0_fn_8(as_number, as_pair);
  if ((result.tag != INT64_C(6)) || (result.payload.variant_6 != &pair)) {
    return 10;
  }
  result = native_m0_fn_8(as_nil, as_number);
  if (result.tag != INT64_C(5)) {
    return 11;
  }
  result = native_m0_fn_8(as_false, as_number);
  if ((result.tag != INT64_C(0)) || result.payload.variant_0) {
    return 12;
  }

  result = native_m0_fn_9(as_number, as_pair);
  if ((result.tag != INT64_C(1)) || (result.payload.variant_1 != INT64_C(42))) {
    return 13;
  }
  result = native_m0_fn_9(as_nil, as_pair);
  if ((result.tag != INT64_C(6)) || (result.payload.variant_6 != &pair)) {
    return 14;
  }

  result = native_m0_fn_10(as_number, as_pair, as_abc_left);
  if ((result.tag != INT64_C(3))
      || (result.payload.variant_3 != (uint64_t)(uintptr_t)&text_abc_left)) {
    return 15;
  }
  result = native_m0_fn_10(as_number, as_nil, as_abc_left);
  if (result.tag != INT64_C(5)) {
    return 16;
  }
  result = native_m0_fn_11(as_nil, as_false, as_abc_left);
  if ((result.tag != INT64_C(3))
      || (result.payload.variant_3 != (uint64_t)(uintptr_t)&text_abc_left)) {
    return 17;
  }
  result = native_m0_fn_11(as_nil, as_number, as_abc_left);
  if ((result.tag != INT64_C(1)) || (result.payload.variant_1 != INT64_C(42))) {
    return 18;
  }

  result = native_m0_fn_12(INT64_C(42));
  if ((result.tag != INT64_C(1)) || (result.payload.variant_1 != INT64_C(42))) {
    return 19;
  }
  result = native_m0_fn_13(INT64_C(42));
  if ((result.tag != INT64_C(1)) || (result.payload.variant_1 != INT64_C(42))) {
    return 20;
  }
  if (!native_m0_fn_14()) {
    return 21;
  }
  slice_nil_value empty_or = native_m0_fn_15();
  if (empty_or.tag != INT64_C(0)) {
    return 22;
  }

  result = native_m0_fn_16(as_pair);
  if ((result.tag != INT64_C(6)) || (result.payload.variant_6 != &pair)) {
    return 23;
  }
  result = native_m0_fn_17(as_number);
  if ((result.tag != INT64_C(1)) || (result.payload.variant_1 != INT64_C(42))) {
    return 24;
  }
  result = native_m0_fn_18(as_number);
  if ((result.tag != INT64_C(1)) || (result.payload.variant_1 != INT64_C(42))) {
    return 25;
  }
  result = native_m0_fn_19(as_nil);
  if (result.tag != INT64_C(5)) {
    return 26;
  }
  return 0;
}
