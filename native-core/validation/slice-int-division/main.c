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
  } else {
    (void)MOD_FN(INT64_C(1), INT64_C(0));
  }
  return 5;
}
