/* Probe for the S4 epoch fixtures. Hand-written driver INPUT, not a generated
   artifact: it owns the root arena and measures it, which is the only place a
   test can see whether an epoch actually reclaimed anything.

   Module 0 is the probe under DERIVED assignment (its interior Text lives in
   a minted epoch), module 1 the SAME program at epoch-0 (the Text lives in
   the root arena the driver owns). Running both over the same iteration
   counts is the reclamation measurement: module 0's root high-water mark must
   not move with the iteration count, module 1's must.

   Module 2 returns a Text promoted out of an epoch that is destroyed before
   the return. Reading its bytes here is a use-after-free unless promote
   really copied, which is what running this under ASan proves.

   Module 3 opens two nested epochs and closes them LIFO.

   Modules 4 and 5 are the caller/callee pair: the callee's allocation is a
   text builtin whose arena is never retargeted, so it lands in whatever arena
   the caller passes. Under derived assignment the caller passes an epoch's
   arena — the reclamation there is the caller-arena generalization and
   nothing else. */

#include "module_0.h"
#include "module_1.h"
#include "module_2.h"
#include "module_3.h"
#include "module_4.h"
#include "module_5.h"

#include <stdio.h>
#include <string.h>

static const char epoch_expected[] = "epochepoch";

static size_t run_derived(int64_t iterations) {
  native_arena arena;
  native_capability capability = {UINT64_C(1)};
  size_t reserved;
  int64_t index;

  if (!native_arena_init_growable(&arena, (size_t)0U)) {
    return (size_t)0U;
  }
  for (index = INT64_C(0); index < iterations; index++) {
    if (native_m0_fn_0(&arena, &capability, index) != index) {
      fprintf(stderr, "main.c: derived probe disagreed at %lld\n",
              (long long)index);
      native_arena_destroy(&arena);
      return (size_t)0U;
    }
  }
  reserved = native_arena_reserved_bytes(&arena);
  native_arena_destroy(&arena);
  return reserved;
}

static size_t run_identity(int64_t iterations) {
  native_arena arena;
  native_capability capability = {UINT64_C(1)};
  size_t reserved;
  int64_t index;

  if (!native_arena_init_growable(&arena, (size_t)0U)) {
    return (size_t)0U;
  }
  for (index = INT64_C(0); index < iterations; index++) {
    if (native_m1_fn_0(&arena, &capability, index) != index) {
      fprintf(stderr, "main.c: identity probe disagreed at %lld\n",
              (long long)index);
      native_arena_destroy(&arena);
      return (size_t)0U;
    }
  }
  reserved = native_arena_reserved_bytes(&arena);
  native_arena_destroy(&arena);
  return reserved;
}

static size_t run_caller_derived(int64_t iterations) {
  native_arena arena;
  native_capability capability = {UINT64_C(1)};
  size_t reserved;
  int64_t index;

  if (!native_arena_init_growable(&arena, (size_t)0U)) {
    return (size_t)0U;
  }
  for (index = INT64_C(0); index < iterations; index++) {
    if (native_m4_fn_1(&arena, &capability, INT64_C(5)) != INT64_C(5)) {
      fprintf(stderr, "main.c: derived caller disagreed at %lld\n",
              (long long)index);
      native_arena_destroy(&arena);
      return (size_t)0U;
    }
  }
  reserved = native_arena_reserved_bytes(&arena);
  native_arena_destroy(&arena);
  return reserved;
}

static size_t run_caller_identity(int64_t iterations) {
  native_arena arena;
  native_capability capability = {UINT64_C(1)};
  size_t reserved;
  int64_t index;

  if (!native_arena_init_growable(&arena, (size_t)0U)) {
    return (size_t)0U;
  }
  for (index = INT64_C(0); index < iterations; index++) {
    if (native_m5_fn_1(&arena, &capability, INT64_C(5)) != INT64_C(5)) {
      fprintf(stderr, "main.c: identity caller disagreed at %lld\n",
              (long long)index);
      native_arena_destroy(&arena);
      return (size_t)0U;
    }
  }
  reserved = native_arena_reserved_bytes(&arena);
  native_arena_destroy(&arena);
  return reserved;
}

static int check_promote(void) {
  native_arena arena;
  native_capability capability = {UINT64_C(1)};
  uint64_t handle;
  uint64_t length;
  int status = 0;

  if (!native_arena_init_growable(&arena, (size_t)0U)) {
    return 1;
  }
  handle = native_m2_fn_0(&arena, &capability);
  length = native_text_length(handle);
  if (length != (uint64_t)(sizeof epoch_expected - 1U)) {
    fprintf(stderr, "main.c: promoted text length %llu\n",
            (unsigned long long)length);
    status = 1;
  } else if (memcmp(native_text_bytes(handle), epoch_expected,
                    sizeof epoch_expected - 1U) != 0) {
    fprintf(stderr, "main.c: promoted text bytes differ\n");
    status = 1;
  }
  native_arena_destroy(&arena);
  return status;
}

static int check_nested(void) {
  native_arena arena;
  native_capability capability = {UINT64_C(1)};
  int status = 0;

  if (!native_arena_init_growable(&arena, (size_t)0U)) {
    return 1;
  }
  if (native_m3_fn_0(&arena, &capability, INT64_C(7)) != INT64_C(7)) {
    fprintf(stderr, "main.c: nested probe disagreed\n");
    status = 1;
  }
  if (native_arena_reserved_bytes(&arena) != (size_t)0U) {
    fprintf(stderr, "main.c: nested probe reserved root bytes\n");
    status = 1;
  }
  native_arena_destroy(&arena);
  return status;
}

int main(void) {
  const int64_t small = INT64_C(64);
  const int64_t large = INT64_C(65536);
  size_t derived_small = run_derived(small);
  size_t derived_large = run_derived(large);
  size_t identity_small = run_identity(small);
  size_t identity_large = run_identity(large);
  size_t caller_derived_small = run_caller_derived(small);
  size_t caller_derived_large = run_caller_derived(large);
  size_t caller_identity_small = run_caller_identity(small);
  size_t caller_identity_large = run_caller_identity(large);

  printf("watermark derived %lld %zu\n", (long long)small, derived_small);
  printf("watermark derived %lld %zu\n", (long long)large, derived_large);
  printf("watermark identity %lld %zu\n", (long long)small, identity_small);
  printf("watermark identity %lld %zu\n", (long long)large, identity_large);
  printf("watermark caller-derived %lld %zu\n", (long long)small,
         caller_derived_small);
  printf("watermark caller-derived %lld %zu\n", (long long)large,
         caller_derived_large);
  printf("watermark caller-identity %lld %zu\n", (long long)small,
         caller_identity_small);
  printf("watermark caller-identity %lld %zu\n", (long long)large,
         caller_identity_large);

  /* Bounded: the epoch returns its chunks at every close, so the root arena
     never sees the per-iteration allocation at all. */
  if (derived_small != derived_large) {
    fprintf(stderr, "main.c: derived watermark grew with the iteration count\n");
    return 1;
  }
  /* Unbounded: at epoch-0 the same allocation lands in the root arena and
     nothing reclaims it until the driver resets. */
  if (identity_large <= identity_small) {
    fprintf(stderr, "main.c: identity watermark did not grow\n");
    return 2;
  }
  if (identity_large < (size_t)large) {
    fprintf(stderr, "main.c: identity watermark implausibly small\n");
    return 3;
  }
  /* The callee allocates into the arena its caller hands it, so the same
     bound holds one call down — and only because the arena is a per-call
     operand the epoch stage could retarget. */
  if (caller_derived_small != caller_derived_large) {
    fprintf(stderr, "main.c: caller-derived watermark grew\n");
    return 4;
  }
  if (caller_identity_large <= caller_identity_small) {
    fprintf(stderr, "main.c: caller-identity watermark did not grow\n");
    return 5;
  }
  if (check_promote() != 0) {
    return 6;
  }
  if (check_nested() != 0) {
    return 7;
  }
  printf("slice-epoch: derived bounded, identity unbounded, caller-arena "
         "bounded, promote and nested ok\n");
  return 0;
}
