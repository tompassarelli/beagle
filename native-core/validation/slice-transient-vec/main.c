#include "module_0.h"

#include <inttypes.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef BUILD_ORDERED_FN
#error "BUILD_ORDERED_FN must name the generated build-ordered! function"
#endif

#ifndef COPY_NONEMPTY_FN
#error "COPY_NONEMPTY_FN must name the generated copy-nonempty! function"
#endif

#define APPEND_COUNT INT64_C(32768)
#define ELEMENT_STRIDE ((size_t)sizeof(int64_t))
#define FIXED_METADATA_BYTES ((size_t)4096U)
#define MAX_ARENA_OFFSET                                                     \
  (((size_t)2U * (size_t)APPEND_COUNT * ELEMENT_STRIDE) +                  \
   FIXED_METADATA_BYTES)

_Alignas(max_align_t) static uint8_t arena_storage[MAX_ARENA_OFFSET];

static int check_ordered(const native_vec *values) {
  int64_t index;

  if (native_vec_length(values) != APPEND_COUNT) {
    fprintf(stderr, "slice-transient-vec: length=%" PRId64 " expected=%" PRId64
                    "\n",
            native_vec_length(values), APPEND_COUNT);
    return 1;
  }
  for (index = INT64_C(0); index < APPEND_COUNT; index += INT64_C(1)) {
    int64_t observed = *(const int64_t *)native_vec_at(
        values, index, (int64_t)ELEMENT_STRIDE);
    if (observed != index) {
      fprintf(stderr,
              "slice-transient-vec: value[%" PRId64 "]=%" PRId64
              " expected=%" PRId64 "\n",
              index, observed, index);
      return 2;
    }
  }
  return 0;
}

static void provoke_frozen_use(bool freeze_again) {
  _Alignas(max_align_t) uint8_t storage[1024];
  native_arena arena;
  native_vec *seed;
  native_transient_vec *builder;
  int64_t value = INT64_C(1);

  native_arena_init(&arena, storage, sizeof(storage));
  seed = native_vec_new(&arena, INT64_C(0), (int64_t)ELEMENT_STRIDE,
                        _Alignof(int64_t));
  builder = native_transient_vec_new(&arena, seed, (int64_t)ELEMENT_STRIDE,
                                     _Alignof(int64_t));
  (void)native_transient_vec_freeze(builder);
  if (freeze_again) {
    (void)native_transient_vec_freeze(builder);
  } else {
    (void)native_transient_vec_push(builder, &value);
  }
  _exit(0);
}

static int expect_frozen_trap(bool freeze_again) {
  pid_t child = fork();
  int status;

  if (child < 0) {
    perror("fork");
    return 1;
  }
  if (child == 0) {
    provoke_frozen_use(freeze_again);
  }
  if (waitpid(child, &status, 0) != child) {
    perror("waitpid");
    return 1;
  }
  if (!WIFSIGNALED(status) || (WTERMSIG(status) != SIGABRT)) {
    fprintf(stderr,
            "slice-transient-vec: frozen %s did not trap with SIGABRT\n",
            freeze_again ? "freeze" : "push");
    return 1;
  }
  return 0;
}

int main(void) {
  native_arena arena;
  native_capability capability = {UINT64_C(1)};
  native_vec *ordered;
  native_vec *nonempty;
  uint8_t *initial_bytes;
  size_t initial_capacity;
  uint64_t allocation_start;
  uint64_t storage_allocations;
  int ordered_status;

  native_arena_init(&arena, arena_storage, sizeof(arena_storage));
  initial_bytes = arena.bytes;
  initial_capacity = arena.capacity;
  allocation_start = native_vec_storage_allocations;

  ordered = BUILD_ORDERED_FN(&arena, &capability);
  ordered_status = check_ordered(ordered);
  if (ordered_status != 0) {
    return ordered_status;
  }
  storage_allocations = native_vec_storage_allocations - allocation_start;
  if (storage_allocations > UINT64_C(20)) {
    fprintf(stderr,
            "slice-transient-vec: storage allocations=%" PRIu64
            " exceeds 20\n",
            storage_allocations);
    return 3;
  }
  if (arena.offset > MAX_ARENA_OFFSET) {
    fprintf(stderr,
            "slice-transient-vec: arena offset=%zu exceeds bound=%zu\n",
            arena.offset, MAX_ARENA_OFFSET);
    return 4;
  }
  if ((arena.bytes != initial_bytes) || (arena.capacity != initial_capacity) ||
      arena.growable) {
    fputs("slice-transient-vec: fixed arena changed capacity or storage\n",
          stderr);
    return 5;
  }

  native_arena_reset(&arena);
  nonempty = COPY_NONEMPTY_FN(&arena, &capability);
  if ((native_vec_length(nonempty) != INT64_C(1)) ||
      (*(const int64_t *)native_vec_at(nonempty, INT64_C(0),
                                      (int64_t)ELEMENT_STRIDE) !=
       INT64_C(41))) {
    fputs("slice-transient-vec: nonempty seed was not preserved\n", stderr);
    return 6;
  }
  if ((arena.bytes != initial_bytes) || (arena.capacity != initial_capacity) ||
      arena.growable) {
    fputs("slice-transient-vec: nonempty run changed fixed arena capacity\n",
          stderr);
    return 7;
  }
  if ((expect_frozen_trap(false) != 0) ||
      (expect_frozen_trap(true) != 0)) {
    return 8;
  }

  printf("slice-transient-vec PASS appends=%" PRId64
         " allocations=%" PRIu64 " offset=%zu bound=%zu\n",
         APPEND_COUNT, storage_allocations, arena.offset, MAX_ARENA_OFFSET);
  native_arena_destroy(&arena);
  return 0;
}
