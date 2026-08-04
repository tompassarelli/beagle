#include "function_map.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ARENA_BYTES ((size_t)1048576)

static uint8_t arena_storage[ARENA_BYTES];
static const native_capability capability = {UINT64_C(0)};

static uint64_t text_of(native_arena *arena, const char *value) {
  size_t length = strlen(value);
  uint8_t *destination = NULL;
  uint64_t handle = native_text_alloc(arena, (uint64_t)length, &destination);
  if (length > 0U) {
    (void)memcpy(destination, value, length);
  }
  return handle;
}

static bool text_is(uint64_t actual, const char *expected) {
  size_t expected_length = strlen(expected);
  return (native_text_length(actual) == (uint64_t)expected_length) &&
         (memcmp(native_text_bytes(actual), expected, expected_length) == 0);
}

static bool text_vector_is(const native_vec *actual, const char **expected,
                           size_t expected_count) {
  size_t index;
  if (native_vec_length(actual) != (int64_t)expected_count) {
    return false;
  }
  for (index = 0U; index < expected_count; index++) {
    uint64_t value = *(const uint64_t *)native_vec_at(
        actual, (int64_t)index, (int64_t)sizeof(uint64_t));
    if (!text_is(value, expected[index])) {
      return false;
    }
  }
  return true;
}

static bool pass(const char *function_name, const char *case_name,
                 bool condition) {
  if (!condition) {
    (void)fprintf(stderr, "rt_core native mismatch: %s/%s\n", function_name,
                  case_name);
    return false;
  }
  return printf("rt-core\t%s\t%s\tPASS\n", function_name, case_name) >= 0;
}

#define CHECK(function_name, case_name, condition)                           \
  do {                                                                       \
    if (!pass((function_name), (case_name), (condition))) {                  \
      return EXIT_FAILURE;                                                   \
    }                                                                        \
  } while (false)

int main(void) {
  native_arena arena;
  uint64_t first;
  uint64_t second;
  uint64_t result;
  native_vec *vector;
  char digest[65];
  size_t index;

  native_arena_init(&arena, arena_storage, ARENA_BYTES);

  first = text_of(&arena, "abcabc");
  second = text_of(&arena, "bc");
  CHECK("str-index-of", "found",
        (RT_STR_INDEX_OF(first, second).tag == INT64_C(0)) &&
            (RT_STR_INDEX_OF(first, second).payload.variant_0 == INT64_C(1)));
  native_arena_reset(&arena);
  first = text_of(&arena, "abc");
  second = text_of(&arena, "z");
  CHECK("str-index-of", "absent",
        RT_STR_INDEX_OF(first, second).tag == INT64_C(1));

  native_arena_reset(&arena);
  first = text_of(&arena, " a, ,b, c ");
  vector = RT_SPLIT_COMMA(&arena, &capability, first);
  {
    const char *expected[] = {"a", "b", "c"};
    CHECK("split-comma", "trim-remove-blank",
          text_vector_is(vector, expected, 3U));
  }

  native_arena_reset(&arena);
  first = text_of(&arena, "alpha");
  second = text_of(&arena, "beta");
  CHECK("str-lt?", "ascending", RT_STR_LT_P(first, second));
  CHECK("str-lt?", "equal", !RT_STR_LT_P(first, first));

  native_arena_reset(&arena);
  first = text_of(&arena, "  key value here  ");
  vector = RT_SPLIT_KV(&arena, &capability, first);
  {
    const char *expected[] = {"key", "value here"};
    CHECK("split-kv", "pair", text_vector_is(vector, expected, 2U));
  }
  native_arena_reset(&arena);
  first = text_of(&arena, " key ");
  vector = RT_SPLIT_KV(&arena, &capability, first);
  {
    const char *expected[] = {"key", ""};
    CHECK("split-kv", "key-only", text_vector_is(vector, expected, 2U));
  }

  native_arena_reset(&arena);
  first = text_of(&arena, "20260804123456");
  result = RT_FMT_ID(&arena, &capability, first);
  CHECK("fmt-id", "four-segments", text_is(result, "2026-08-04-123456"));

  native_arena_reset(&arena);
  first = text_of(&arena, " Hello, World! ");
  result = RT_SLUGIFY(&arena, &capability, first);
  CHECK("slugify", "punctuation", text_is(result, "hello_world"));
  native_arena_reset(&arena);
  first = text_of(&arena, "---");
  result = RT_SLUGIFY(&arena, &capability, first);
  CHECK("slugify", "empty", text_is(result, "untitled"));

  native_arena_reset(&arena);
  first = text_of(&arena, "a1-2x03");
  result = RT_FILTER_DIGITS(&arena, &capability, first);
  CHECK("filter-digits", "mixed", text_is(result, "1203"));

  native_arena_reset(&arena);
  first = text_of(&arena, "2026-08-04T12:34:56");
  CHECK("is-iso-datetime-19", "valid", RT_IS_ISO_DATETIME_19(first));
  second = text_of(&arena, "2026-08-04T12:34");
  CHECK("is-iso-datetime-19", "short", !RT_IS_ISO_DATETIME_19(second));
  CHECK("is-iso-datetime-16", "valid", RT_IS_ISO_DATETIME_16(second));
  CHECK("is-iso-datetime-16", "long", !RT_IS_ISO_DATETIME_16(first));

  native_arena_reset(&arena);
  first = text_of(&arena, "ab");
  result = RT_REPEAT_STR(&arena, &capability, first, INT64_C(3));
  CHECK("repeat-str", "positive", text_is(result, "ababab"));
  result = RT_REPEAT_STR(&arena, &capability, first, INT64_C(-2));
  CHECK("repeat-str", "negative", text_is(result, ""));

  for (index = 0U; index < 64U; index++) {
    digest[index] = 'a';
  }
  digest[64] = '\0';
  native_arena_reset(&arena);
  first = text_of(&arena, digest);
  CHECK("digest?", "valid", RT_DIGEST_P(first));
  for (index = 0U; index < 64U; index++) {
    digest[index] = 'A';
  }
  first = text_of(&arena, digest);
  CHECK("digest?", "uppercase", !RT_DIGEST_P(first));

  native_arena_reset(&arena);
  first = text_of(&arena, "x");
  CHECK("nonblank?", "text", RT_NONBLANK_P(first));
  second = text_of(&arena, " \t");
  CHECK("nonblank?", "blank", !RT_NONBLANK_P(second));

  native_arena_reset(&arena);
  result = RT_COORD_STATUS_DOWN(&arena, &capability, INT64_C(7788));
  CHECK("coord-status-down", "down",
        text_is(result,
                "coordinator DOWN on 127.0.0.1:7788 — start it with bin/fram-up"));

  return EXIT_SUCCESS;
}
