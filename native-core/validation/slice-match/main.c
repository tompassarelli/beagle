#include "module_0.h"

#include <stdint.h>

#ifndef CLASSIFY_TAG_FN
#error "CLASSIFY_TAG_FN is required"
#endif
#ifndef CLASSIFY_TAG_TYPE
#error "CLASSIFY_TAG_TYPE is required"
#endif
#ifndef UNPACK_VALUE_FN
#error "UNPACK_VALUE_FN is required"
#endif
#ifndef UNPACK_VALUE_TYPE
#error "UNPACK_VALUE_TYPE is required"
#endif

struct match_box {
  int64_t value;
};

struct match_keyword {
  uint64_t length;
  uint8_t bytes[sizeof "query/one"];
};

static const struct match_keyword keyword_one = {
  (uint64_t)(sizeof "query/one" - 1U), "query/one"
};
static const struct match_keyword keyword_two = {
  (uint64_t)(sizeof "query/two" - 1U), "query/two"
};
static const struct match_keyword keyword_other = {
  (uint64_t)(sizeof "query/zzz" - 1U), "query/zzz"
};

int main(void) {
  CLASSIFY_TAG_TYPE one = {
    .tag = 0, .payload.variant_0 = (uint64_t)(uintptr_t)&keyword_one
  };
  CLASSIFY_TAG_TYPE two = {
    .tag = 0, .payload.variant_0 = (uint64_t)(uintptr_t)&keyword_two
  };
  CLASSIFY_TAG_TYPE other = {
    .tag = 0, .payload.variant_0 = (uint64_t)(uintptr_t)&keyword_other
  };
  CLASSIFY_TAG_TYPE absent = {.tag = 1};
  struct match_box left = {.value = 7};
  struct match_box right = {.value = 8};
  UNPACK_VALUE_TYPE left_value = {.tag = 0, .payload.variant_0 = &left};
  UNPACK_VALUE_TYPE right_value = {.tag = 1, .payload.variant_1 = &right};

  if (CLASSIFY_TAG_FN(one) != 1 || CLASSIFY_TAG_FN(two) != 2 ||
      CLASSIFY_TAG_FN(other) != 0 || CLASSIFY_TAG_FN(absent) != 0 ||
      UNPACK_VALUE_FN(left_value) != 7 || UNPACK_VALUE_FN(right_value) != 9) {
    return 1;
  }
  return 0;
}
