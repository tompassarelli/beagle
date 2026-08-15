#define _POSIX_C_SOURCE 200809L

#include "native_shim.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void fail(const char *detail, int64_t actual, int64_t expected) {
  (void)fprintf(stderr,
                "process-capability shim fixture: %s: got %lld expected %lld\n",
                detail, (long long)actual, (long long)expected);
  exit(1);
}

static uint64_t text(native_arena *arena, const uint8_t *bytes, size_t length) {
  uint8_t *destination = NULL;
  uint64_t result = native_text_alloc(arena, (uint64_t)length, &destination);
  if (length != (size_t)0U) {
    memcpy(destination, bytes, length);
  }
  return result;
}

static native_vec *text_vector(native_arena *arena, const uint64_t *values,
                               int64_t count) {
  native_vec *result = native_vec_new(arena, count, INT64_C(8), INT64_C(8));
  int64_t index;
  for (index = INT64_C(0); index < count; ++index) {
    result = native_vec_push(arena, result, &values[index], INT64_C(8),
                             (size_t)8U);
  }
  return result;
}

int main(int argc, char **argv) {
  native_capability capability = {UINT64_C(1)};
  native_arena arena;
  uint64_t signal_argv[2];
  uint64_t empty_program_argv[1];
  uint64_t missing_argv[1];
  uint64_t nul_argv[1];
  native_vec empty = {NULL, INT64_C(0), INT64_C(0), NULL};
  native_vec overflow = {(void *)&capability, INT64_MAX, INT64_MAX, NULL};
  const uint8_t embedded_nul[] = {'x', '\0', 'y'};
  int64_t actual;

  if (argc != 2) {
    return 2;
  }
  if (!native_arena_init_growable(&arena, (size_t)4096U)) {
    return 3;
  }

  actual = native_host_process_run_inherit_v0(&capability, &empty);
  if (actual != -((int64_t)EINVAL)) {
    fail("empty argv", actual, -((int64_t)EINVAL));
  }
  actual = native_host_process_run_inherit_v0(&capability, &overflow);
  if (actual != -((int64_t)EOVERFLOW)) {
    fail("overflow argv", actual, -((int64_t)EOVERFLOW));
  }
  empty_program_argv[0] = text(&arena, (const uint8_t *)"", (size_t)0U);
  actual = native_host_process_run_inherit_v0(
      &capability, text_vector(&arena, empty_program_argv, INT64_C(1)));
  if (actual != -((int64_t)EINVAL)) {
    fail("empty argv[0]", actual, -((int64_t)EINVAL));
  }
  nul_argv[0] = text(&arena, embedded_nul, sizeof embedded_nul);
  actual = native_host_process_run_inherit_v0(
      &capability, text_vector(&arena, nul_argv, INT64_C(1)));
  if (actual != -((int64_t)EINVAL)) {
    fail("embedded NUL", actual, -((int64_t)EINVAL));
  }
  missing_argv[0] = text(
      &arena, (const uint8_t *)"beagle-native-process-missing-command-v0",
      strlen("beagle-native-process-missing-command-v0"));
  actual = native_host_process_run_inherit_v0(
      &capability, text_vector(&arena, missing_argv, INT64_C(1)));
  if (actual != -((int64_t)ENOENT)) {
    fail("spawn failure", actual, -((int64_t)ENOENT));
  }

  signal_argv[0] = text(&arena, (const uint8_t *)argv[1], strlen(argv[1]));
  signal_argv[1] = text(&arena, (const uint8_t *)"signal", (size_t)6U);
  actual = native_host_process_run_inherit_v0(
      &capability, text_vector(&arena, signal_argv, INT64_C(2)));
  if (actual != INT64_C(271)) {
    fail("signal status", actual, INT64_C(271));
  }

  native_arena_destroy(&arena);
  (void)puts("process capability shim fixture: ok");
  return 0;
}
