#include "module_0.h"

#include <stdint.h>

#ifndef MINIMUM_FN
#error "MINIMUM_FN is required"
#endif

#ifndef NEARBY_NEGATIVE_FN
#error "NEARBY_NEGATIVE_FN is required"
#endif

int main(void) {
  if (MINIMUM_FN() != INT64_MIN) {
    return 1;
  }
  if (NEARBY_NEGATIVE_FN() != INT64_C(-7)) {
    return 2;
  }
  return 0;
}
