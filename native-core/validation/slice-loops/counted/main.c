/* Probe for the lowered native.loops-counted bodies. Hand-written; the module
   under it is generated. fn_1 sum-below  fn_2 first-at-least  fn_3 triangle
   fn_4 scan-six. Every function is checked on its zero/empty input. */
#include "module_0.h"

int main(int argc, char **argv) {
  (void)argc;
  (void)argv;

  if (native_m0_fn_1(INT64_C(0)) != INT64_C(0)) {
    return 1;
  }
  if (native_m0_fn_1(INT64_C(1)) != INT64_C(0)) {
    return 2;
  }
  if (native_m0_fn_1(INT64_C(5)) != INT64_C(10)) {
    return 3;
  }
  if (native_m0_fn_1(INT64_C(10)) != INT64_C(45)) {
    return 4;
  }

  if (native_m0_fn_2(INT64_C(0), INT64_C(0)) != INT64_C(-1)) {
    return 5;
  }
  if (native_m0_fn_2(INT64_C(5), INT64_C(3)) != INT64_C(3)) {
    return 6;
  }
  if (native_m0_fn_2(INT64_C(5), INT64_C(0)) != INT64_C(0)) {
    return 7;
  }
  if (native_m0_fn_2(INT64_C(3), INT64_C(7)) != INT64_C(-1)) {
    return 8;
  }

  if (native_m0_fn_3(INT64_C(0)) != INT64_C(0)) {
    return 9;
  }
  if (native_m0_fn_3(INT64_C(1)) != INT64_C(0)) {
    return 10;
  }
  if (native_m0_fn_3(INT64_C(4)) != INT64_C(6)) {
    return 11;
  }
  if (native_m0_fn_3(INT64_C(5)) != INT64_C(10)) {
    return 12;
  }

  {
    native_m0_type_2 empty = native_m0_fn_4(INT64_C(0), INT64_C(0));
    native_m0_type_2 split = native_m0_fn_4(INT64_C(10), INT64_C(4));
    native_m0_type_2 all_missed = native_m0_fn_4(INT64_C(5), INT64_C(9));
    if ((empty.field_0 != INT64_C(0)) || (empty.field_1 != INT64_C(0))) {
      return 13;
    }
    if ((split.field_0 != INT64_C(6)) || (split.field_1 != INT64_C(4))) {
      return 14;
    }
    if ((all_missed.field_0 != INT64_C(0)) ||
        (all_missed.field_1 != INT64_C(5))) {
      return 15;
    }
  }

  return 0;
}
