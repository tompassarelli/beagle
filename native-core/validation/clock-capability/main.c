#define _POSIX_C_SOURCE 200809L

#include "native_shim.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void fail(const char *detail, int64_t actual, int64_t expected) {
  (void)fprintf(stderr,
                "clock-capability shim fixture: %s: got %lld expected %lld\n",
                detail, (long long)actual, (long long)expected);
  exit(1);
}

static void require_format(native_arena *arena,
                           const native_capability *capability,
                           int64_t epoch_nanoseconds, const char *expected) {
  uint64_t actual = UINT64_C(0);
  int32_t status = native_host_clock_format_iso8601_v0(
      arena, capability, epoch_nanoseconds, &actual);
  size_t expected_length = strlen(expected);
  if (status != 0) {
    fail("format status", status, 0);
  }
  if ((native_text_length(actual) != (uint64_t)expected_length) ||
      (memcmp(native_text_bytes(actual), expected, expected_length) != 0)) {
    fail("formatted bytes", (int64_t)native_text_length(actual),
         (int64_t)expected_length);
  }
}

int main(void) {
  native_capability capability = {UINT64_C(1)};
  native_arena arena;
  int64_t now;

  if (!native_arena_init_growable(&arena, (size_t)4096U)) {
    return 2;
  }
  now = native_host_clock_wall_nanoseconds_v0(&capability);
  if (now <= INT64_C(0)) {
    fail("wall nanoseconds", now, 1);
  }
  require_format(&arena, &capability, INT64_C(0),
                 "1970-01-01T00:00:00Z");
  require_format(&arena, &capability, INT64_C(1000000),
                 "1970-01-01T00:00:00.001Z");
  require_format(&arena, &capability, INT64_C(1000),
                 "1970-01-01T00:00:00.000001Z");
  require_format(&arena, &capability, INT64_C(1),
                 "1970-01-01T00:00:00.000000001Z");
  require_format(&arena, &capability, INT64_C(-1),
                 "1969-12-31T23:59:59.999999999Z");

  native_arena_destroy(&arena);
  (void)puts("clock capability shim fixture: ok");
  return 0;
}
