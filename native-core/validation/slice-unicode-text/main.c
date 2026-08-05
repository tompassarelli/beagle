#include "module_0.h"

#include <stdint.h>
#include <string.h>

#ifndef LOWER_FN
#error "LOWER_FN must name the generated root-lowercase function"
#endif
#ifndef RUNS_FN
#error "RUNS_FN must name the generated letter/decimal-runs function"
#endif

#define ARENA_BYTES (1024U * 1024U)

static uint64_t text_from_utf8(native_arena *arena, const char *value,
                               size_t length) {
  uint8_t *destination = NULL;
  uint64_t result = native_text_alloc(arena, (uint64_t)length, &destination);
  if (length != 0U) {
    memcpy(destination, value, length);
  }
  return result;
}

static bool text_equals(uint64_t actual, const char *expected,
                        size_t expected_length) {
  return (native_text_length(actual) == (uint64_t)expected_length) &&
         ((expected_length == 0U) ||
          (memcmp(native_text_bytes(actual), expected, expected_length) == 0));
}

static bool run_equals(const native_vec *runs, int64_t index,
                       const char *expected, size_t expected_length) {
  uint64_t handle;
  memcpy(&handle, native_vec_at(runs, index, INT64_C(8)), sizeof handle);
  return text_equals(handle, expected, expected_length);
}

int main(void) {
  static uint8_t storage[ARENA_BYTES];
  native_arena arena;
  const native_capability capability = {UINT64_C(1)};
  const char lower_source_bytes[] = u8"Straße İ ΣΟΣ CAFÉ 𐐀";
  const char lower_expected[] = u8"straße i̇ σος café 𐐨";
  const char runs_source_bytes[] = u8"Café_東京-१२३ é Ⅻ ² 𐐀";
  const char age_source_bytes[] =
      u8"\U0001e4d0-\U0001e4f0-\U0002ebf0-\U00010d40";
  uint64_t lower_source;
  uint64_t lowered;
  uint64_t runs_source;
  native_vec *runs;
  uint64_t age_source;
  native_vec *age_runs;

  native_arena_init(&arena, storage, sizeof storage);
  lower_source = text_from_utf8(&arena, lower_source_bytes,
                                sizeof lower_source_bytes - 1U);
  lowered = LOWER_FN(&arena, &capability, lower_source);
  if (!text_equals(lowered, lower_expected, sizeof lower_expected - 1U)) {
    return 1;
  }

  runs_source = text_from_utf8(&arena, runs_source_bytes,
                               sizeof runs_source_bytes - 1U);
  runs = RUNS_FN(&arena, &capability, runs_source);
  if ((native_vec_length(runs) != INT64_C(5)) ||
      !run_equals(runs, INT64_C(0), u8"Café", sizeof(u8"Café") - 1U) ||
      !run_equals(runs, INT64_C(1), u8"東京", sizeof(u8"東京") - 1U) ||
      !run_equals(runs, INT64_C(2), u8"१२३", sizeof(u8"१२३") - 1U) ||
      !run_equals(runs, INT64_C(3), "e", 1U) ||
      !run_equals(runs, INT64_C(4), u8"𐐀", sizeof(u8"𐐀") - 1U)) {
    return 2;
  }

  age_source = text_from_utf8(&arena, age_source_bytes,
                              sizeof age_source_bytes - 1U);
  age_runs = RUNS_FN(&arena, &capability, age_source);
  if ((native_vec_length(age_runs) != INT64_C(2)) ||
      !run_equals(age_runs, INT64_C(0), u8"\U0001e4d0",
                  sizeof(u8"\U0001e4d0") - 1U) ||
      !run_equals(age_runs, INT64_C(1), u8"\U0001e4f0",
                  sizeof(u8"\U0001e4f0") - 1U)) {
    return 3;
  }
  return 0;
}
