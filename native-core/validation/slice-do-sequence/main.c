#include "module_0.h"

#ifndef BODY_LAST_FN
#error "BODY_LAST_FN must name the materialized body-last function"
#endif
#ifndef DO_LAST_FN
#error "DO_LAST_FN must name the materialized do-last function"
#endif
#ifndef DO_FIRST_TRAPS_FN
#error "DO_FIRST_TRAPS_FN must name the materialized do-first-traps function"
#endif
#ifndef DO_REF_LAST_FN
#error "DO_REF_LAST_FN must name the materialized do-ref-last function"
#endif
#ifndef DO_BRANCH_LAST_FN
#error "DO_BRANCH_LAST_FN must name the materialized do-branch-last function"
#endif

int main(int argc, char **argv) {
  if ((argc > 1) && (argv[1][0] == 't')) {
    (void)DO_FIRST_TRAPS_FN(INT64_MAX);
    return 90;
  }
  if (BODY_LAST_FN(INT64_C(5)) != INT64_C(7)) {
    return 1;
  }
  if (DO_LAST_FN(INT64_C(5)) != INT64_C(9)) {
    return 2;
  }
  if (DO_FIRST_TRAPS_FN(INT64_C(5)) != INT64_C(7)) {
    return 3;
  }
  if (DO_REF_LAST_FN(INT64_C(99)) != INT64_C(11)) {
    return 4;
  }
  if ((DO_BRANCH_LAST_FN(true) != INT64_C(12)) ||
      (DO_BRANCH_LAST_FN(false) != INT64_C(12))) {
    return 5;
  }
  return 0;
}
