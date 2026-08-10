/* Probe for the S5 promote surface fixtures. Hand-written driver INPUT, not a
   generated artifact.

   Module 0 is native.promote-probe under DERIVED assignment. fn_0 is
   `(bgl/promote (str "epoch" tail))`: the concatenation lives in an epoch the
   stage minted and destroys before returning, so the handle this file reads
   afterwards points at the promoted COPY or at freed memory. Reading it is the
   gate — under ASan there is no third outcome.

   fn_1 is the same body without the form, fn_2 is the epoch-free promote the
   lowerer turned into a plain copy, fn_3 the promote of a caller-owned
   parameter the stage collapsed. Module 1 is the whole program under IDENTITY
   assignment, where every promote collapsed: it must compute the same
   answers, which is what makes the collapse a rewrite and not a behaviour
   change. */

#include "module_0.h"
#include "module_1.h"

#include <stdio.h>
#include <string.h>

static const char probe_tail[] = "-tail";
static const char probe_expected[] = "epoch-tail";

static uint64_t text_of(native_arena *arena, const char *value) {
  uint8_t *bytes = NULL;
  uint64_t length = (uint64_t)strlen(value);
  uint64_t handle = native_text_alloc(arena, length, &bytes);

  if ((length != UINT64_C(0)) && (bytes != NULL)) {
    memcpy(bytes, value, (size_t)length);
  }
  return handle;
}

static int text_is(uint64_t handle, const char *expected) {
  uint64_t length = native_text_length(handle);

  if (length != (uint64_t)strlen(expected)) {
    return 0;
  }
  if (length == UINT64_C(0)) {
    return 1;
  }
  return memcmp(native_text_bytes(handle), expected, (size_t)length) == 0;
}

int main(void) {
  native_arena arena;
  native_capability capability = {UINT64_C(1)};
  uint64_t tail;
  int failures = 0;
  int index;

  if (!native_arena_init_growable(&arena, (size_t)0U)) {
    fprintf(stderr, "main.c: root arena did not initialise\n");
    return 1;
  }

  tail = text_of(&arena, probe_tail);

  /* Repeated so the destroyed epoch chunk is a candidate for reuse: a promote
     that had not copied would read a recycled allocation, not just a freed
     one. */
  for (index = 0; index < 64; index++) {
    uint64_t promoted = native_m0_fn_0(&arena, &capability, tail);
    uint64_t identity = native_m1_fn_0(&arena, &capability, tail);

    if (!text_is(promoted, probe_expected)) {
      fprintf(stderr, "main.c: derived promote lost its bytes at %d\n", index);
      failures++;
      break;
    }
    if (!text_is(identity, probe_expected)) {
      fprintf(stderr, "main.c: identity promote lost its bytes at %d\n", index);
      failures++;
      break;
    }
  }

  if (!text_is(native_m0_fn_1(&arena, &capability, tail), probe_expected)) {
    fprintf(stderr, "main.c: escaping text disagreed\n");
    failures++;
  }
  if (!text_is(native_m1_fn_1(&arena, &capability, tail), probe_expected)) {
    fprintf(stderr, "main.c: identity escaping text disagreed\n");
    failures++;
  }
  if (native_m0_fn_2(INT64_C(41)) != INT64_C(42)) {
    fprintf(stderr, "main.c: epoch-free promote disagreed\n");
    failures++;
  }
  if (native_m1_fn_2(INT64_C(41)) != INT64_C(42)) {
    fprintf(stderr, "main.c: identity epoch-free promote disagreed\n");
    failures++;
  }
  if (!text_is(native_m0_fn_3(&arena, &capability, tail), probe_tail)) {
    fprintf(stderr, "main.c: collapsed parameter promote disagreed\n");
    failures++;
  }
  if (!text_is(native_m1_fn_3(&arena, &capability, tail), probe_tail)) {
    fprintf(stderr, "main.c: identity parameter promote disagreed\n");
    failures++;
  }

  native_arena_destroy(&arena);
  printf("promote surface fixture: %s\n", (failures == 0) ? "ok" : "FAILED");
  return (failures == 0) ? 0 : 1;
}
