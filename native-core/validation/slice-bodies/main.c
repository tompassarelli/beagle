/* Probe for the lowered fram.types bodies. Hand-written; the module under it is
   generated. With any argument it takes the trapping path instead, which aborts.
   fn_0 instant?  fn_1 instant  fn_2 triple?  fn_9 commit-operation?
   SliceValue tags: 1 = i64, 6 = Instant, 7 = Triple, 22 = CommitOperation. */
#include "module_0.h"

static native_m0_type_47 slice_reference(int64_t tag, void *target) {
  native_m0_type_47 value;
  value.tag = tag;
  value.payload.variant_6 = target;
  (void)target;
  return value;
}

static native_m0_type_47 slice_i64(int64_t number) {
  native_m0_type_47 value;
  value.tag = INT64_C(1);
  value.payload.variant_1 = number;
  return value;
}

int main(int argc, char **argv) {
  (void)argv;
  native_m0_type_6 moment = { INT64_C(0), INT64_C(0) };
  native_m0_type_47 as_instant = slice_reference(INT64_C(6), &moment);
  native_m0_type_47 as_triple = slice_reference(INT64_C(7), &moment);
  native_m0_type_47 as_operation = slice_reference(INT64_C(22), &moment);
  native_m0_type_47 as_number = slice_i64(INT64_C(42));

  if (argc > 1) {
    /* nanoseconds outside [0, 1000000000) must trap, never return */
    native_m0_fn_1(INT64_C(7), INT64_C(1000000000));
    return 9;
  }

  if (!native_m0_fn_0(as_instant)) {
    return 1;
  }
  if (native_m0_fn_0(as_triple) || native_m0_fn_0(as_number)) {
    return 2;
  }
  if (!native_m0_fn_2(as_triple)) {
    return 3;
  }
  if (native_m0_fn_2(as_instant) || native_m0_fn_2(as_number)) {
    return 4;
  }
  if (!native_m0_fn_9(as_operation)) {
    return 5;
  }
  if (native_m0_fn_9(as_instant)) {
    return 6;
  }

  native_m0_type_6 built = native_m0_fn_1(INT64_C(-5), INT64_C(999999999));
  if ((built.field_0 != INT64_C(-5)) || (built.field_1 != INT64_C(999999999))) {
    return 7;
  }
  native_m0_type_6 zero = native_m0_fn_1(INT64_C(0), INT64_C(0));
  if ((zero.field_0 != INT64_C(0)) || (zero.field_1 != INT64_C(0))) {
    return 8;
  }
  return 0;
}
