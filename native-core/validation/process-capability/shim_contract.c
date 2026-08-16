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

static void require_text(uint64_t actual, const char *expected,
                         const char *detail) {
  size_t length = strlen(expected);
  if ((native_text_length(actual) != (uint64_t)length) ||
      (memcmp(native_text_bytes(actual), expected, length) != 0)) {
    fail(detail, (int64_t)native_text_length(actual), (int64_t)length);
  }
}

int main(int argc, char **argv) {
  native_capability capability = {UINT64_C(1)};
  native_arena arena;
  uint64_t signal_argv[2];
  uint64_t empty_program_argv[1];
  uint64_t missing_argv[1];
  uint64_t nul_argv[1];
  uint64_t capture_argv[2];
  uint64_t large_argv[2];
  uint64_t invalid_argv[2];
  native_vec empty = {NULL, INT64_C(0), INT64_C(0), NULL};
  native_vec overflow = {(void *)&capability, INT64_MAX, INT64_MAX, NULL};
  const uint8_t embedded_nul[] = {'x', '\0', 'y'};
  int64_t actual;
  int32_t capture_status;
  void *capture_out = NULL;
  native_host_process_capture_v0 *capture;

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

  capture_argv[0] = signal_argv[0];
  capture_argv[1] = text(&arena, (const uint8_t *)"capture", (size_t)7U);
  capture_status = native_host_process_run_capture_v0(
      &arena, &capability,
      text_vector(&arena, capture_argv, INT64_C(2)),
      text(&arena, (const uint8_t *)"exact stdin\n", (size_t)12U),
      INT64_C(4096), &capture_out);
  if ((capture_status != 0) || (capture_out == NULL)) {
    fail("capture success", capture_status, 0);
  }
  capture = (native_host_process_capture_v0 *)capture_out;
  if (capture->status != INT64_C(19)) {
    fail("capture child status", capture->status, INT64_C(19));
  }
  require_text(capture->stdout_text, "stdin=<exact stdin\\n>\n",
               "capture stdout");
  require_text(capture->stderr_text, "child-stderr=<captured>\n",
               "capture stderr");

  capture_out = NULL;
  capture_status = native_host_process_run_capture_v0(
      &arena, &capability,
      text_vector(&arena, signal_argv, INT64_C(2)),
      text(&arena, (const uint8_t *)"", (size_t)0U), INT64_C(16),
      &capture_out);
  if ((capture_status != 0) || (capture_out == NULL) ||
      (((native_host_process_capture_v0 *)capture_out)->status != INT64_C(271))) {
    fail("captured signal status", capture_status, 0);
  }

  capture_out = NULL;
  capture_status = native_host_process_run_capture_v0(
      &arena, &capability,
      text_vector(&arena, missing_argv, INT64_C(1)),
      text(&arena, (const uint8_t *)"", (size_t)0U), INT64_C(16),
      &capture_out);
  if ((capture_status != ENOENT) || (capture_out != NULL)) {
    fail("capture spawn failure", capture_status, ENOENT);
  }
  capture_status = native_host_process_run_capture_v0(
      &arena, &capability, &empty,
      text(&arena, (const uint8_t *)"", (size_t)0U), INT64_C(16),
      &capture_out);
  if ((capture_status != EINVAL) || (capture_out != NULL)) {
    fail("capture empty argv", capture_status, EINVAL);
  }
  capture_out = (void *)(uintptr_t)UINT64_C(1);
  capture_status = native_host_process_run_capture_v0(
      &arena, &capability,
      text_vector(&arena, capture_argv, INT64_C(2)),
      text(&arena, (const uint8_t *)"", (size_t)0U), INT64_C(-1),
      &capture_out);
  if ((capture_status != EINVAL) || (capture_out != NULL)) {
    fail("capture negative bound", capture_status, EINVAL);
  }

  large_argv[0] = signal_argv[0];
  large_argv[1] = text(&arena, (const uint8_t *)"capture-large",
                       (size_t)13U);
  capture_out = NULL;
  capture_status = native_host_process_run_capture_v0(
      &arena, &capability, text_vector(&arena, large_argv, INT64_C(2)),
      text(&arena, (const uint8_t *)"", (size_t)0U), INT64_C(8192),
      &capture_out);
  if ((capture_status != 0) || (capture_out == NULL) ||
      (native_text_length(
           ((native_host_process_capture_v0 *)capture_out)->stdout_text) !=
       UINT64_C(8192)) ||
      (native_text_length(
           ((native_host_process_capture_v0 *)capture_out)->stderr_text) !=
       UINT64_C(8192))) {
    fail("capture independent output allowance", capture_status, 0);
  }

  capture_out = NULL;
  capture_status = native_host_process_run_capture_v0(
      &arena, &capability, text_vector(&arena, large_argv, INT64_C(2)),
      text(&arena, (const uint8_t *)"", (size_t)0U), INT64_C(4096),
      &capture_out);
  if ((capture_status != EFBIG) || (capture_out != NULL)) {
    fail("capture output overflow", capture_status, EFBIG);
  }

  invalid_argv[0] = signal_argv[0];
  invalid_argv[1] = text(&arena, (const uint8_t *)"capture-invalid",
                         (size_t)15U);
  capture_out = NULL;
  capture_status = native_host_process_run_capture_v0(
      &arena, &capability, text_vector(&arena, invalid_argv, INT64_C(2)),
      text(&arena, (const uint8_t *)"", (size_t)0U), INT64_C(16),
      &capture_out);
  if ((capture_status != EILSEQ) || (capture_out != NULL)) {
    fail("capture invalid UTF-8", capture_status, EILSEQ);
  }

  native_arena_destroy(&arena);
  (void)puts("process capability shim fixture: ok");
  return 0;
}
