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

static bool lower_equals(native_arena *arena,
                         const native_capability *capability,
                         const char *source, const char *expected) {
  uint64_t source_text = text_from_utf8(arena, source, strlen(source));
  uint64_t lowered = LOWER_FN(arena, capability, source_text);
  return text_equals(lowered, expected, strlen(expected));
}

int main(void) {
  static uint8_t storage[ARENA_BYTES];
  native_arena arena;
  const native_capability capability = {UINT64_C(1)};
  const char runs_source_bytes[] = u8"Café_東京-१२३ éͅ Ⅻ ² 𐐀";
  const char age_source_bytes[] =
      u8"\U0001e4d0-\U0001e4f0-\U0002ebf0-\U00010d40";
  uint64_t runs_source;
  native_vec *runs;
  uint64_t age_source;
  native_vec *age_runs;

  native_arena_init(&arena, storage, sizeof storage);
  if (!lower_equals(&arena, &capability, u8"Straße İ ΣΟΣ CAFÉ 𐐀",
                    u8"straße i̇ σος café 𐐨")) {
    return 1;
  }
  if (!lower_equals(&arena, &capability, u8"AΣ:B", u8"aς:b") ||
      !lower_equals(&arena, &capability, u8"AΣ.B", u8"aσ.b") ||
      !lower_equals(&arena, &capability, u8"AΣ’B", u8"aς’b") ||
      !lower_equals(&arena, &capability, u8"AΣ-B", u8"aσ-b") ||
      !lower_equals(&arena, &capability, u8"AΣ1:B", u8"aς1:b") ||
      !lower_equals(&arena, &capability, u8"AΣ1.2B", u8"aσ1.2b") ||
      !lower_equals(&arena, &capability, u8"AΣ東京B", u8"aς東京b") ||
      !lower_equals(&arena, &capability, u8"AΣ́B", u8"aσ́b")) {
    return 4;
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
