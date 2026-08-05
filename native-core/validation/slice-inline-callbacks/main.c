#include "module_0.h"

#ifndef CAPTURED_REDUCE_FN
#error "CAPTURED_REDUCE_FN must name captured-reduce"
#endif
#ifndef CAPTURED_MAP_FN
#error "CAPTURED_MAP_FN must name captured-map"
#endif
#ifndef CAPTURED_FILTER_FN
#error "CAPTURED_FILTER_FN must name captured-filter"
#endif
#ifndef CAPTURED_EVERY_FN
#error "CAPTURED_EVERY_FN must name captured-every?"
#endif
#ifndef CAPTURED_SOME_FN
#error "CAPTURED_SOME_FN must name captured-some?"
#endif
#ifndef SHADOWED_MAP_FN
#error "SHADOWED_MAP_FN must name shadowed-map-parameter"
#endif
#ifndef NESTED_CAPTURES_FN
#error "NESTED_CAPTURES_FN must name nested-captures"
#endif
#ifndef CONTEXTUAL_REDUCE_FN
#error "CONTEXTUAL_REDUCE_FN must name contextual-reduce-any"
#endif
#ifndef CONTEXTUAL_MAP_FN
#error "CONTEXTUAL_MAP_FN must name contextual-map-any"
#endif
#ifndef SET_REDUCE_FN
#error "SET_REDUCE_FN must name insertion-order-set-reduce"
#endif
#ifndef MAP_REDUCE_KV_FN
#error "MAP_REDUCE_KV_FN must name insertion-order-map-reduce-kv"
#endif

#define ARENA_BYTES ((size_t)65536)

static uint8_t arena_storage[ARENA_BYTES];
static const native_capability capability = { UINT64_C(1) };

int main(void) {
  native_arena arena;
  native_arena_init(&arena, arena_storage, ARENA_BYTES);

  if (CAPTURED_REDUCE_FN(&arena, &capability, INT64_C(2)) != INT64_C(12)) {
    return 1;
  }
  if (CAPTURED_MAP_FN(&arena, &capability, INT64_C(5)) != INT64_C(7)) {
    return 2;
  }
  if (CAPTURED_FILTER_FN(&arena, &capability, INT64_C(3)) != INT64_C(2)) {
    return 3;
  }
  if (!CAPTURED_EVERY_FN(&arena, &capability, INT64_C(0))
      || CAPTURED_EVERY_FN(&arena, &capability, INT64_C(1))) {
    return 4;
  }
  if (!CAPTURED_SOME_FN(&arena, &capability, INT64_C(3))
      || CAPTURED_SOME_FN(&arena, &capability, INT64_C(2))) {
    return 5;
  }
  if (SHADOWED_MAP_FN(&arena, &capability, INT64_C(999)) != INT64_C(11)) {
    return 6;
  }
  if (!NESTED_CAPTURES_FN(&arena, &capability, INT64_C(1))
      || NESTED_CAPTURES_FN(&arena, &capability, INT64_C(3))) {
    return 7;
  }
  if (!CONTEXTUAL_REDUCE_FN(&arena, &capability, INT64_C(5))) {
    return 8;
  }
  if (CONTEXTUAL_MAP_FN(&arena, &capability, INT64_C(5)) != INT64_C(2)) {
    return 9;
  }
  if (SET_REDUCE_FN(&arena, &capability) != INT64_C(312)) {
    return 10;
  }
  if (MAP_REDUCE_KV_FN(&arena, &capability) != INT64_C(3412)) {
    return 11;
  }
  return 0;
}
