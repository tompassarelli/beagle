/* Probe for the lowered fram.types bodies. Hand-written; the module under it is
   generated. "trap" and "overflow" take a trapping path instead, which aborts.
   fn_0 instant?  fn_1 instant  fn_2 instant-shift-seconds
   fn_3 instant-seconds-between  fn_4 triple?  fn_11 commit-operation?
   SliceValue tags: 1 = i64, 6 = Instant, 7 = Triple, 22 = CommitOperation. */
#include "module_0.h"

static native_m0_type_49 slice_reference(int64_t tag, void *target) {
  native_m0_type_49 value;
  value.tag = tag;
  value.payload.variant_6 = target;
  (void)target;
  return value;
}

static native_m0_type_49 slice_i64(int64_t number) {
  native_m0_type_49 value;
  value.tag = INT64_C(1);
  value.payload.variant_1 = number;
  return value;
}

int main(int argc, char **argv) {
  native_m0_type_6 moment = { INT64_C(0), INT64_C(0) };
  native_m0_type_49 as_instant = slice_reference(INT64_C(6), &moment);
  native_m0_type_49 as_triple = slice_reference(INT64_C(7), &moment);
  native_m0_type_49 as_operation = slice_reference(INT64_C(22), &moment);
  native_m0_type_49 as_number = slice_i64(INT64_C(42));

  if ((argc > 1) && (argv[1][0] == 't')) {
    /* nanoseconds outside [0, 1000000000) must trap, never return */
    native_m0_fn_1(INT64_C(7), INT64_C(1000000000));
    return 9;
  }
  if ((argc > 1) && (argv[1][0] == 'o')) {
    /* INT64_MAX + 1 must answer the overflow tag, whose arm traps. Returning
       here at all would mean a wrapped value escaped the checked add. */
    native_m0_type_6 edge = { INT64_MAX, INT64_C(0) };
    native_m0_type_6 escaped = native_m0_fn_2(edge, INT64_C(1));
    return (escaped.field_0 == INT64_MIN) ? 10 : 11;
  }

  if (!native_m0_fn_0(as_instant)) {
    return 1;
  }
  if (native_m0_fn_0(as_triple) || native_m0_fn_0(as_number)) {
    return 2;
  }
  if (!native_m0_fn_4(as_triple)) {
    return 3;
  }
  if (native_m0_fn_4(as_instant) || native_m0_fn_4(as_number)) {
    return 4;
  }
  if (!native_m0_fn_11(as_operation)) {
    return 5;
  }
  if (native_m0_fn_11(as_instant)) {
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

  /* checked add: the ok arm carries the exact sum and leaves nanos alone */
  native_m0_type_6 shifted = native_m0_fn_2(built, INT64_C(90));
  if ((shifted.field_0 != INT64_C(85)) ||
      (shifted.field_1 != INT64_C(999999999))) {
    return 12;
  }
  native_m0_type_6 back = native_m0_fn_2(shifted, INT64_C(-90));
  if (back.field_0 != INT64_C(-5)) {
    return 13;
  }

  /* checked subtract */
  if (native_m0_fn_3(built, shifted) != INT64_C(90)) {
    return 14;
  }
  if (native_m0_fn_3(shifted, built) != INT64_C(-90)) {
    return 15;
  }

  /* the tag decision sits exactly on the overflow boundary: one below INT64_MAX
     still takes the ok arm, and the "overflow" probe shows INT64_MAX + 1 does
     not. A wrapping add would have answered ok on both. */
  native_m0_type_6 near = { INT64_MAX - INT64_C(1), INT64_C(0) };
  native_m0_type_6 edge = native_m0_fn_2(near, INT64_C(1));
  if (edge.field_0 != INT64_MAX) {
    return 16;
  }
  return 0;
}
