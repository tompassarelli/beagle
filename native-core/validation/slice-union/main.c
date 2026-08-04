/* Probe for the coercion rule. Hand-written; the module under it is generated.
   With the argument "mismatch" it hands a checked extract a value carrying the
   wrong tag, which must trap instead of reading the payload as a reference.
   fn_0 pair?  fn_1 wrap-int  fn_2 pair-left-of  fn_3 pair-right-of
   fn_4 any-equal?
   Any (type_9) tags: 0 bool, 1 i64, 2 f64, 3 text, 4 keyword, 5 nil, 6 Pair. */
#include "module_0.h"

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

int main(int argc, char **argv) {
  (void)argv;
  native_m0_type_2 pair = { INT64_C(3), INT64_C(4) };
  native_m0_type_2 equal_pair = { INT64_C(3), INT64_C(4) };
  native_m0_type_2 different_pair = { INT64_C(3), INT64_C(5) };
  native_m0_type_9 as_pair = slice_pair(&pair);
  native_m0_type_9 as_equal_pair = slice_pair(&equal_pair);
  native_m0_type_9 as_different_pair = slice_pair(&different_pair);
  native_m0_type_9 as_number = slice_i64(INT64_C(42));

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
      || !native_m0_fn_4(as_number, wrapped)) {
    return 6;
  }
  return 0;
}
