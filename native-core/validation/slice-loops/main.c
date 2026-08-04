/* Probe for the lowered native.loops bodies. Hand-written; the module under it
   is generated. */
#include "module_0.h"

int main(int argc, char **argv) {
  (void)argc;
  (void)argv;

  /* settle: the back edge is taken once, so the flag comes back inverted */
  if (native_m0_fn_0(false) != true) {
    return 1;
  }
  if (native_m0_fn_0(true) != false) {
    return 2;
  }

  /* exchange: the two accumulators cross on the back edge */
  if (native_m0_fn_1(INT64_C(0), INT64_C(0)) != INT64_C(0)) {
    return 3;
  }
  if (native_m0_fn_1(INT64_C(7), INT64_C(9)) != INT64_C(9)) {
    return 4;
  }
  if (native_m0_fn_1(INT64_C(-3), INT64_C(42)) != INT64_C(42)) {
    return 5;
  }

  /* settle-nested: the inner header decides the outer accumulator */
  if (native_m0_fn_2(true, true) != false) {
    return 6;
  }
  if (native_m0_fn_2(false, false) != true) {
    return 7;
  }
  if (native_m0_fn_2(true, false) != true) {
    return 8;
  }

  {
    native_m0_type_2 zero = native_m0_fn_3(INT64_C(0), INT64_C(0), false);
    native_m0_type_2 mixed = native_m0_fn_3(INT64_C(5), INT64_C(9), true);
    native_m0_type_2 negative = native_m0_fn_3(INT64_C(-2), INT64_C(3), false);
    if ((zero.field_0 != true) || (zero.field_1 != INT64_C(0))) {
      return 9;
    }
    if ((mixed.field_0 != false) || (mixed.field_1 != INT64_C(5))) {
      return 10;
    }
    if ((negative.field_0 != true) || (negative.field_1 != INT64_C(-2))) {
      return 11;
    }
  }

  if (native_m0_fn_4(INT64_MIN) || native_m0_fn_4(INT64_C(-1)) ||
      native_m0_fn_4(INT64_C(0)) || !native_m0_fn_4(INT64_MAX)) {
    return 12;
  }
  if (!native_m0_fn_5(INT64_MIN) || !native_m0_fn_5(INT64_C(-1)) ||
      native_m0_fn_5(INT64_C(0)) || native_m0_fn_5(INT64_MAX)) {
    return 13;
  }
  if (native_m0_fn_6(INT64_MIN) || native_m0_fn_6(INT64_C(-1)) ||
      !native_m0_fn_6(INT64_C(0)) || native_m0_fn_6(INT64_MAX)) {
    return 14;
  }
  if ((native_m0_fn_7(INT64_MIN, INT64_MAX) != INT64_MIN) ||
      (native_m0_fn_7(INT64_C(-7), INT64_C(-9)) != INT64_C(-9)) ||
      (native_m0_fn_7(INT64_C(-5), INT64_C(-5)) != INT64_C(-5))) {
    return 15;
  }
  if ((native_m0_fn_8(INT64_MAX, INT64_C(-1), INT64_MIN) != INT64_MIN) ||
      (native_m0_fn_8(INT64_C(-3), INT64_C(-9), INT64_C(-5)) != INT64_C(-9)) ||
      (native_m0_fn_8(INT64_MAX, INT64_MAX, INT64_C(0)) != INT64_C(0))) {
    return 16;
  }
  if ((native_m0_fn_9(INT64_MIN, INT64_MAX) != INT64_MAX) ||
      (native_m0_fn_9(INT64_C(-7), INT64_C(-9)) != INT64_C(-7)) ||
      (native_m0_fn_9(INT64_MIN, INT64_MIN) != INT64_MIN)) {
    return 17;
  }

  return 0;
}
