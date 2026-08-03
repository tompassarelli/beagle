#include "module_0.h"

native_m0_type_0 native_m0_fn_0(native_arena *arena, const native_capability *capability, native_m0_type_0 native_v_0, native_m0_type_0 native_v_1) {
  (void)arena;
  (void)capability;
  int64_t native_v_2;
  if (((native_v_1 > INT64_C(0)) && (native_v_0 > (INT64_MAX - native_v_1))) ||
      ((native_v_1 < INT64_C(0)) && (native_v_0 < (INT64_MIN - native_v_1)))) {
    native_trap(NATIVE_TRAP_OVERFLOW);
  }
  native_v_2 = native_v_0 + native_v_1;
  (void)native_v_2;
  return native_v_2;
}

