#include "module_0.h"

#include <stdint.h>
#include <string.h>

#ifndef QUOT_FN
#error "QUOT_FN must name the generated quot function"
#endif
#ifndef REM_FN
#error "REM_FN must name the generated rem function"
#endif
#ifndef MOD_FN
#error "MOD_FN must name the generated mod function"
#endif
#ifndef FLOAT_ADD_FN
#error "FLOAT_ADD_FN must name the generated float add function"
#endif
#ifndef FLOAT_DIVIDE_FN
#error "FLOAT_DIVIDE_FN must name the generated float division function"
#endif
#ifndef ADD_FN
#error "ADD_FN must name the generated variadic add function"
#endif
#ifndef MULTIPLY_FN
#error "MULTIPLY_FN must name the generated variadic multiply function"
#endif
#ifndef NEGATE_FN
#error "NEGATE_FN must name the generated unary negate function"
#endif
#ifndef KEYWORD_FN
#error "KEYWORD_FN must name the generated literal keyword function"
#endif

static int check_results(void) {
  if (QUOT_FN(INT64_C(7), INT64_C(3)) != INT64_C(2) ||
      QUOT_FN(-INT64_C(7), INT64_C(3)) != -INT64_C(2) ||
      QUOT_FN(INT64_C(7), -INT64_C(3)) != -INT64_C(2) ||
      QUOT_FN(-INT64_C(7), -INT64_C(3)) != INT64_C(2)) {
    return 1;
  }
  if (REM_FN(-INT64_C(7), INT64_C(3)) != -INT64_C(1) ||
      REM_FN(INT64_C(7), -INT64_C(3)) != INT64_C(1) ||
      REM_FN(-INT64_C(7), -INT64_C(3)) != -INT64_C(1)) {
    return 2;
  }
  if (MOD_FN(-INT64_C(7), INT64_C(3)) != INT64_C(2) ||
      MOD_FN(INT64_C(7), -INT64_C(3)) != -INT64_C(2) ||
      MOD_FN(-INT64_C(7), -INT64_C(3)) != -INT64_C(1)) {
    return 3;
  }
  if (QUOT_FN(INT64_MIN, -INT64_C(1)) != INT64_MIN ||
      REM_FN(INT64_MIN, -INT64_C(1)) != INT64_C(0) ||
      MOD_FN(INT64_MIN, -INT64_C(1)) != INT64_C(0)) {
    return 4;
  }
  if (FLOAT_ADD_FN(1.5, 2.5) != 4.0 ||
      FLOAT_DIVIDE_FN(7.5, 2.5) != 3.0) {
    return 5;
  }
  if (ADD_FN(INT64_C(2), INT64_C(3), INT64_C(4)) != INT64_C(9) ||
      MULTIPLY_FN(-INT64_C(2), INT64_C(3), INT64_C(4)) != -INT64_C(24) ||
      NEGATE_FN(INT64_C(7)) != -INT64_C(7) || !KEYWORD_FN()) {
    return 6;
  }
  return 0;
}

int main(int argc, char **argv) {
  if (argc == 1) {
    return check_results();
  }
  if (strcmp(argv[1], "zero-quot") == 0) {
    (void)QUOT_FN(INT64_C(1), INT64_C(0));
  } else if (strcmp(argv[1], "zero-rem") == 0) {
    (void)REM_FN(INT64_C(1), INT64_C(0));
  } else if (strcmp(argv[1], "zero-mod") == 0) {
    (void)MOD_FN(INT64_C(1), INT64_C(0));
  } else if (strcmp(argv[1], "zero-float") == 0) {
    (void)FLOAT_DIVIDE_FN(1.0, 0.0);
  } else {
    (void)ADD_FN(INT64_MAX, -INT64_C(1), INT64_C(2));
  }
  return 6;
}
