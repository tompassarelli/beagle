/* Probe for the coercion rule. Hand-written; the module under it is generated.
   With the argument "mismatch" it hands a checked extract a value carrying the
   wrong tag, which must trap instead of reading the payload as a reference.
   fn_0 pair?  fn_1 wrap-int  fn_2 pair-left-of  fn_3 pair-right-of
   fn_4 any-equal? fn_5 any-hash fn_6 any-compare fn_7 pair-copy-of
   Any (type_9) tags: 0 bool, 1 i64, 2 f64, 3 text, 4 keyword, 5 nil, 6 Pair. */
#include "module_0.h"

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

static native_m0_type_9 slice_pair(void *target) {
  native_m0_type_9 value;
  value.tag = INT64_C(6);
  value.payload.variant_6 = target;
  return value;
}

static native_m0_type_9 slice_i64(int64_t number) {
  native_m0_type_9 value;
  value.tag = INT64_C(1);
  value.payload.variant_1 = number;
  return value;
}

static native_m0_type_9 slice_f64(double number) {
  native_m0_type_9 value;
  value.tag = INT64_C(2);
  value.payload.variant_2 = number;
  return value;
}

static native_m0_type_9 slice_text(const struct slice_text_blob *blob) {
  native_m0_type_9 value;
  value.tag = INT64_C(3);
  value.payload.variant_3 = (uint64_t)(uintptr_t)blob;
  return value;
}

int main(int argc, char **argv) {
  native_m0_type_2 pair = { INT64_C(3), INT64_C(4) };
  native_m0_type_2 equal_pair = { INT64_C(3), INT64_C(4) };
  native_m0_type_2 different_pair = { INT64_C(3), INT64_C(5) };
  native_m0_type_9 as_pair = slice_pair(&pair);
  native_m0_type_9 as_equal_pair = slice_pair(&equal_pair);
  native_m0_type_9 as_different_pair = slice_pair(&different_pair);
  native_m0_type_9 as_number = slice_i64(INT64_C(42));
  native_m0_type_9 as_zero = slice_f64(0.0);
  native_m0_type_9 as_negative_zero = slice_f64(-0.0);
  native_m0_type_9 as_abc_left = slice_text(&text_abc_left);
  native_m0_type_9 as_abc_right = slice_text(&text_abc_right);
  native_m0_type_9 as_abd = slice_text(&text_abd);

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
  native_m0_type_9 wrapped = native_m0_fn_1(INT64_C(42));
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
  native_m0_type_2 copied_pair = native_m0_fn_7(as_pair);
  if ((copied_pair.field_0 != INT64_C(3)) ||
      (copied_pair.field_1 != INT64_C(4))) {
    return 9;
  }
  return 0;
}
