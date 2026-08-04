#define _POSIX_C_SOURCE 200809L

#include "function_map.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define ARENA_BYTES ((size_t)1048576)

static uint8_t arena_storage[ARENA_BYTES];
static const native_capability capability = {UINT64_C(0)};

/* Handles are the generated module_0 keyword-table indices. */
enum {
  KW_FRAM_EDIT_ENVELOPE = 0,
  KW_L = 1,
  KW_P = 2,
  KW_FRAM_EDIT_SEAL_SHA = 3,
  KW_FRAM_EDIT_CANDIDATE = 4,
  KW_FRAM_EDIT_LINE_COUNT = 5,
  KW_FRAM_EDIT_PATH = 6,
  KW_FRAM_EDIT_OPS = 7,
  KW_FRAM_EDIT_OPS_DIGEST = 8,
  KW_FRAM_EDIT_EDN_DIGEST = 9,
  KW_FRAM_EDIT_BASE_VERSION = 10,
  KW_FRAM_EDIT_INSTALLED = 11,
  KW_FRAM_EDIT_LOG = 12,
  KW_FRAM_EDIT_FINAL_VERSION = 13,
  KW_FRAM_EDIT_MODULE = 14,
  KW_FRAM_EDIT_BATCH_SHA = 15,
  KW_FRAM_EDIT_BATCH = 16,
  KW_ROLL_BACK = 17,
  KW_ROLL_FORWARD = 18,
  KW_OP = 19,
  KW_FOR_LOG = 20,
  KW_EXPECTED_LOG = 21,
  KW_REQUEST = 22,
  KW_FMT = 23,
  KW_OK = 24,
  KW_REJECT = 25,
  KW_CONFLICT = 26,
  KW_CODE = 27,
  KW_LOG_MISMATCH = 28,
  KW_SERVED_LOG = 29,
  KW_ERROR = 30,
  KW_VERSION = 31
};

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

static native_map *empty_map(native_arena *arena, int64_t value_stride,
                             size_t value_alignment) {
  return native_map_from_arrays(arena, NULL, NULL, INT64_C(0), INT64_C(8),
                                (size_t)8, value_stride, value_alignment,
                                NATIVE_COLLECTION_EQ_KEYWORD);
}

static native_map *keyword_map(native_arena *arena, const uint64_t *keys,
                               const void *values, size_t count,
                               int64_t value_stride,
                               size_t value_alignment) {
  return native_map_from_arrays(arena, keys, values, (int64_t)count,
                                INT64_C(8), (size_t)8, value_stride,
                                value_alignment, NATIVE_COLLECTION_EQ_KEYWORD);
}

static const void *keyword_map_value(const native_map *map, uint64_t key) {
  return native_map_get(map, &key, NATIVE_COLLECTION_EQ_KEYWORD);
}

static native_vec *text_vector_of(native_arena *arena, const char **values,
                                  size_t count) {
  native_vec *result = native_vec_new(arena, (int64_t)count, INT64_C(8),
                                      (size_t)8);
  size_t index;
  for (index = 0U; index < count; index++) {
    uint64_t text = text_of(arena, values[index]);
    result = native_vec_push(arena, result, &text, INT64_C(8), (size_t)8);
  }
  return result;
}

static bool child_aborted(pid_t child) {
  int status = 0;
  return (waitpid(child, &status, 0) == child) && WIFSIGNALED(status) &&
         (WTERMSIG(status) == SIGABRT);
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

  native_arena_reset(&arena);
  {
    const uint64_t keys[] = {KW_FRAM_EDIT_ENVELOPE};
    const native_m0_type_29 values[] = {
        {.tag = INT64_C(1), .payload = {.variant_1 = INT64_C(1)}}};
    native_m0_type_14 record =
        keyword_map(&arena, keys, values, 1U,
                    (int64_t)sizeof(native_m0_type_29),
                    _Alignof(native_m0_type_29));
    CHECK("edit-batch-envelope-marker?", "present",
          RT_EDIT_BATCH_ENVELOPE_MARKER_P(record));
    record = empty_map(&arena, (int64_t)sizeof(native_m0_type_29),
                       _Alignof(native_m0_type_29));
    CHECK("edit-batch-envelope-marker?", "absent",
          !RT_EDIT_BATCH_ENVELOPE_MARKER_P(record));
  }

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
  {
    const uint64_t keys[] = {KW_L, KW_P};
    native_m0_type_29 values[] = {
        {.tag = INT64_C(0),
         .payload = {.variant_0 = text_of(&arena, "@log:gen")}},
        {.tag = INT64_C(0),
         .payload = {.variant_0 = text_of(&arena, "generation")}}};
    native_m0_type_14 record =
        keyword_map(&arena, keys, values, 2U,
                    (int64_t)sizeof(native_m0_type_29),
                    _Alignof(native_m0_type_29));
    CHECK("generation-record?", "generation", RT_GENERATION_RECORD_P(record));
    values[1].payload.variant_0 = text_of(&arena, "fact");
    record = keyword_map(&arena, keys, values, 2U,
                         (int64_t)sizeof(native_m0_type_29),
                         _Alignof(native_m0_type_29));
    CHECK("generation-record?", "other", !RT_GENERATION_RECORD_P(record));
  }

  native_arena_reset(&arena);
  {
    const uint64_t keys[] = {
        KW_FRAM_EDIT_ENVELOPE,     KW_FRAM_EDIT_LOG,
        KW_FRAM_EDIT_CANDIDATE,    KW_FRAM_EDIT_BATCH,
        KW_FRAM_EDIT_MODULE,       KW_FRAM_EDIT_PATH,
        KW_FRAM_EDIT_BASE_VERSION, KW_FRAM_EDIT_FINAL_VERSION,
        KW_FRAM_EDIT_OPS,          KW_FRAM_EDIT_INSTALLED,
        KW_FRAM_EDIT_OPS_DIGEST,   KW_FRAM_EDIT_EDN_DIGEST,
        KW_FRAM_EDIT_LINE_COUNT,   KW_FRAM_EDIT_BATCH_SHA,
        KW_FRAM_EDIT_SEAL_SHA};
    uint64_t digest_a;
    uint64_t digest_b;
    native_m0_type_29 values[15];
    native_m0_type_14 record;

    for (index = 0U; index < 64U; index++) {
      digest[index] = 'a';
    }
    digest[64] = '\0';
    digest_a = text_of(&arena, digest);
    for (index = 0U; index < 64U; index++) {
      digest[index] = 'b';
    }
    digest_b = text_of(&arena, digest);
    values[0] = (native_m0_type_29){
        .tag = INT64_C(1), .payload = {.variant_1 = INT64_C(1)}};
    values[1] = (native_m0_type_29){
        .tag = INT64_C(0),
        .payload = {.variant_0 = text_of(&arena, "coord.log")}};
    values[2] = (native_m0_type_29){
        .tag = INT64_C(0),
        .payload = {.variant_0 = text_of(&arena, "batch-7")}};
    values[3] = values[2];
    values[4] = (native_m0_type_29){
        .tag = INT64_C(0),
        .payload = {.variant_0 = text_of(&arena, "fram.rt-core")}};
    values[5] = (native_m0_type_29){
        .tag = INT64_C(0),
        .payload = {.variant_0 = text_of(&arena, "src/fram/rt_core.bclj")}};
    values[6] = (native_m0_type_29){
        .tag = INT64_C(1), .payload = {.variant_1 = INT64_C(4)}};
    values[7] = (native_m0_type_29){
        .tag = INT64_C(1), .payload = {.variant_1 = INT64_C(7)}};
    values[8] = (native_m0_type_29){
        .tag = INT64_C(1), .payload = {.variant_1 = INT64_C(3)}};
    values[9] = values[8];
    values[10] = (native_m0_type_29){
        .tag = INT64_C(0), .payload = {.variant_0 = digest_a}};
    values[11] = (native_m0_type_29){
        .tag = INT64_C(0), .payload = {.variant_0 = digest_b}};
    values[12] = values[8];
    values[13] = values[10];
    values[14] = values[11];
    record = keyword_map(&arena, keys, values, 15U,
                         (int64_t)sizeof(native_m0_type_29),
                         _Alignof(native_m0_type_29));
    CHECK("valid-edit-batch-envelope?", "valid",
          RT_VALID_EDIT_BATCH_ENVELOPE_P(&arena, &capability, record,
                                         digest_b));
    CHECK("valid-edit-batch-envelope?", "wrong-seal",
          !RT_VALID_EDIT_BATCH_ENVELOPE_P(&arena, &capability, record,
                                          digest_a));
  }

  native_arena_reset(&arena);
  {
    native_m0_type_28 live = {
        .tag = INT64_C(0), .payload = {.variant_0 = INT64_C(10)}};
    native_m0_type_28 old = live;
    native_m0_type_28 replacement = {
        .tag = INT64_C(0), .payload = {.variant_0 = INT64_C(11)}};
    native_m0_type_28 old_bytes = {
        .tag = INT64_C(0), .payload = {.variant_0 = INT64_C(20)}};
    native_m0_type_28 no_int = {.tag = INT64_C(1)};
    native_m0_type_42 digest_a = {
        .tag = INT64_C(0),
        .payload = {.variant_0 = text_of(&arena, "aaa")}};
    native_m0_type_42 digest_b = {
        .tag = INT64_C(0),
        .payload = {.variant_0 = text_of(&arena, "bbb")}};
    native_m0_type_42 no_text = {.tag = INT64_C(1)};
    first = text_of(&arena, "coord.log");
    CHECK("classify-rewrite-crash", "old-inode",
          RT_CLASSIFY_REWRITE_CRASH(first, live, old, replacement, old_bytes,
                                    digest_a, digest_b, digest_b,
                                    digest_a) == (uint64_t)KW_ROLL_BACK);
    live.payload.variant_0 = INT64_C(11);
    CHECK("classify-rewrite-crash", "new-inode",
          RT_CLASSIFY_REWRITE_CRASH(first, live, old, replacement, old_bytes,
                                    digest_a, digest_b, digest_b,
                                    digest_a) == (uint64_t)KW_ROLL_FORWARD);
    {
      pid_t child = fork();
      if (child == (pid_t)0) {
        (void)RT_CLASSIFY_REWRITE_CRASH(
            first, no_int, no_int, no_int, no_int, no_text, no_text, no_text,
            no_text);
        _exit(EXIT_FAILURE);
      }
      CHECK("classify-rewrite-crash", "missing-live",
            (child > (pid_t)0) && child_aborted(child));
    }
  }

  native_arena_reset(&arena);
  {
    const uint64_t plain_keys[] = {KW_OP};
    const native_m0_type_32 plain_values[] = {
        {.tag = INT64_C(3),
         .payload = {.variant_3 = (uint64_t)KW_FOR_LOG}}};
    native_m0_type_12 request =
        keyword_map(&arena, plain_keys, plain_values, 1U,
                    (int64_t)sizeof(native_m0_type_32),
                    _Alignof(native_m0_type_32));
    native_m0_type_16 envelope;
    const native_m0_type_33 *op;
    const native_m0_type_33 *expected_log;
    const native_m0_type_33 *request_value;
    first = text_of(&arena, "coord.log");
    envelope = RT_LOG_ENVELOPE(&arena, &capability, first, request);
    op = keyword_map_value(envelope, KW_OP);
    expected_log = keyword_map_value(envelope, KW_EXPECTED_LOG);
    request_value = keyword_map_value(envelope, KW_REQUEST);
    CHECK("log-envelope", "plain",
          (native_map_count(envelope) == INT64_C(3)) && (op != NULL) &&
              (op->tag == INT64_C(3)) &&
              (op->payload.variant_3 == (uint64_t)KW_FOR_LOG) &&
              (expected_log != NULL) && (expected_log->tag == INT64_C(0)) &&
              text_is(expected_log->payload.variant_0, "coord.log") &&
              (request_value != NULL) &&
              (request_value->tag == INT64_C(8)) &&
              (request_value->payload.variant_8 == request));
    {
      const uint64_t format_keys[] = {KW_OP, KW_FMT};
      const native_m0_type_32 format_values[] = {
          {.tag = INT64_C(3),
           .payload = {.variant_3 = (uint64_t)KW_FOR_LOG}},
          {.tag = INT64_C(3),
           .payload = {.variant_3 = (uint64_t)KW_LOG_MISMATCH}}};
      const native_m0_type_33 *format;
      request = keyword_map(&arena, format_keys, format_values, 2U,
                            (int64_t)sizeof(native_m0_type_32),
                            _Alignof(native_m0_type_32));
      envelope = RT_LOG_ENVELOPE(&arena, &capability, first, request);
      request_value = keyword_map_value(envelope, KW_REQUEST);
      format = keyword_map_value(envelope, KW_FMT);
      CHECK("log-envelope", "format",
            (native_map_count(envelope) == INT64_C(4)) &&
                (request_value != NULL) &&
                (request_value->tag == INT64_C(8)) &&
                (request_value->payload.variant_8 == request) &&
                (format != NULL) && (format->tag == INT64_C(3)) &&
                (format->payload.variant_3 == (uint64_t)KW_LOG_MISMATCH));
    }
  }

  native_arena_reset(&arena);
  {
    const char *sequence[] = {"left", "right"};
    vector = text_vector_of(&arena, sequence, 2U);
    result = RT_REJECT_MESSAGE(&arena, &capability, vector);
    CHECK("reject-message", "sequence", text_is(result, "left; right"));
    {
      const char *single[] = {"conflict"};
      vector = text_vector_of(&arena, single, 1U);
      result = RT_REJECT_MESSAGE(&arena, &capability, vector);
      CHECK("reject-message", "single", text_is(result, "conflict"));
    }
  }

  native_arena_reset(&arena);
  {
    uint64_t keys[3];
    native_m0_type_40 values[3];
    native_m0_type_17 response;
    keys[0] = KW_OK;
    values[0] = (native_m0_type_40){
        .tag = INT64_C(1), .payload = {.variant_1 = INT64_C(7)}};
    response = keyword_map(&arena, keys, values, 1U,
                           (int64_t)sizeof(native_m0_type_40),
                           _Alignof(native_m0_type_40));
    result = RT_COORD_WRITE_RESPONSE(&arena, &capability, response);
    CHECK("coord-write-response", "ok", text_is(result, "ok:7"));

    keys[0] = KW_REJECT;
    values[0] = (native_m0_type_40){
        .tag = INT64_C(2),
        .payload = {.variant_2 = (uint64_t)KW_CONFLICT}};
    response = keyword_map(&arena, keys, values, 1U,
                           (int64_t)sizeof(native_m0_type_40),
                           _Alignof(native_m0_type_40));
    result = RT_COORD_WRITE_RESPONSE(&arena, &capability, response);
    CHECK("coord-write-response", "conflict", text_is(result, "conflict"));

    keys[0] = KW_CODE;
    keys[1] = KW_EXPECTED_LOG;
    keys[2] = KW_SERVED_LOG;
    values[0] = (native_m0_type_40){
        .tag = INT64_C(2),
        .payload = {.variant_2 = (uint64_t)KW_LOG_MISMATCH}};
    values[1] = (native_m0_type_40){
        .tag = INT64_C(0), .payload = {.variant_0 = text_of(&arena, "a")}};
    values[2] = (native_m0_type_40){
        .tag = INT64_C(0), .payload = {.variant_0 = text_of(&arena, "b")}};
    response = keyword_map(&arena, keys, values, 3U,
                           (int64_t)sizeof(native_m0_type_40),
                           _Alignof(native_m0_type_40));
    result = RT_COORD_WRITE_RESPONSE(&arena, &capability, response);
    CHECK("coord-write-response", "log-mismatch",
          text_is(result, "log-mismatch: expected a; daemon serves b"));

    keys[0] = KW_ERROR;
    values[0] = (native_m0_type_40){
        .tag = INT64_C(0),
        .payload = {.variant_0 = text_of(&arena, "unknown op")}};
    response = keyword_map(&arena, keys, values, 1U,
                           (int64_t)sizeof(native_m0_type_40),
                           _Alignof(native_m0_type_40));
    result = RT_COORD_WRITE_RESPONSE(&arena, &capability, response);
    CHECK("coord-write-response", "incompatible",
          text_is(result, "protocol-incompatible"));

    {
      const char *rejections[] = {"one", "two"};
      keys[0] = KW_REJECT;
      values[0] = (native_m0_type_40){
          .tag = INT64_C(3),
          .payload = {
              .variant_3 = text_vector_of(&arena, rejections, 2U)}};
      response = keyword_map(&arena, keys, values, 1U,
                             (int64_t)sizeof(native_m0_type_40),
                             _Alignof(native_m0_type_40));
      result = RT_COORD_WRITE_RESPONSE(&arena, &capability, response);
      CHECK("coord-write-response", "rejected",
            text_is(result, "reject:one; two"));
    }

    keys[0] = KW_ERROR;
    values[0] = (native_m0_type_40){
        .tag = INT64_C(0),
        .payload = {.variant_0 = text_of(&arena, "broken")}};
    response = keyword_map(&arena, keys, values, 1U,
                           (int64_t)sizeof(native_m0_type_40),
                           _Alignof(native_m0_type_40));
    result = RT_COORD_WRITE_RESPONSE(&arena, &capability, response);
    CHECK("coord-write-response", "error",
          text_is(result, "error:{:error \"broken\"}"));
  }

  native_arena_reset(&arena);
  {
    const uint64_t version_key[] = {KW_VERSION};
    const native_m0_type_29 version_value[] = {
        {.tag = INT64_C(1), .payload = {.variant_1 = INT64_C(19)}}};
    native_m0_type_14 response =
        keyword_map(&arena, version_key, version_value, 1U,
                    (int64_t)sizeof(native_m0_type_29),
                    _Alignof(native_m0_type_29));
    CHECK("coord-version-response", "version",
          RT_COORD_VERSION_RESPONSE(response) == INT64_C(19));
    response = empty_map(&arena, (int64_t)sizeof(native_m0_type_29),
                         _Alignof(native_m0_type_29));
    CHECK("coord-version-response", "missing",
          RT_COORD_VERSION_RESPONSE(response) == INT64_C(-1));
  }
  {
    uint64_t key[] = {KW_VERSION};
    native_m0_type_38 value[] = {
        {.tag = INT64_C(1), .payload = {.variant_1 = INT64_C(19)}}};
    native_m0_type_15 response =
        keyword_map(&arena, key, value, 1U,
                    (int64_t)sizeof(native_m0_type_38),
                    _Alignof(native_m0_type_38));
    CHECK("coord-version-for-log-response", "version",
          RT_COORD_VERSION_FOR_LOG_RESPONSE(response) == INT64_C(19));
    key[0] = KW_CODE;
    value[0] = (native_m0_type_38){
        .tag = INT64_C(2),
        .payload = {.variant_2 = (uint64_t)KW_LOG_MISMATCH}};
    response = keyword_map(&arena, key, value, 1U,
                           (int64_t)sizeof(native_m0_type_38),
                           _Alignof(native_m0_type_38));
    CHECK("coord-version-for-log-response", "mismatch",
          RT_COORD_VERSION_FOR_LOG_RESPONSE(response) == INT64_C(-2));
    response = empty_map(&arena, (int64_t)sizeof(native_m0_type_38),
                         _Alignof(native_m0_type_38));
    CHECK("coord-version-for-log-response", "unusable",
          RT_COORD_VERSION_FOR_LOG_RESPONSE(response) == INT64_C(-3));
  }

  native_arena_reset(&arena);
  {
    uint64_t keys[3];
    native_m0_type_36 values[3];
    native_m0_type_13 response;
    keys[0] = KW_VERSION;
    values[0] = (native_m0_type_36){
        .tag = INT64_C(1), .payload = {.variant_1 = INT64_C(19)}};
    response = keyword_map(&arena, keys, values, 1U,
                           (int64_t)sizeof(native_m0_type_36),
                           _Alignof(native_m0_type_36));
    result = RT_COORD_STATUS_RESPONSE(&arena, &capability, INT64_C(7788),
                                      response);
    CHECK("coord-status-response", "up",
          text_is(result, "coordinator UP on 127.0.0.1:7788 (v19)"));

    keys[0] = KW_CODE;
    keys[1] = KW_EXPECTED_LOG;
    keys[2] = KW_SERVED_LOG;
    values[0] = (native_m0_type_36){
        .tag = INT64_C(4),
        .payload = {.variant_4 = (uint64_t)KW_LOG_MISMATCH}};
    values[1] = (native_m0_type_36){
        .tag = INT64_C(0), .payload = {.variant_0 = text_of(&arena, "a")}};
    values[2] = (native_m0_type_36){
        .tag = INT64_C(0), .payload = {.variant_0 = text_of(&arena, "b")}};
    response = keyword_map(&arena, keys, values, 3U,
                           (int64_t)sizeof(native_m0_type_36),
                           _Alignof(native_m0_type_36));
    result = RT_COORD_STATUS_RESPONSE(&arena, &capability, INT64_C(7788),
                                      response);
    CHECK("coord-status-response", "wrong-log",
          text_is(result,
                  "coordinator WRONG LOG on 127.0.0.1:7788 — expected a; "
                  "daemon serves b; refusing fenced reads and writes"));

    keys[0] = KW_ERROR;
    values[0] = (native_m0_type_36){
        .tag = INT64_C(0),
        .payload = {.variant_0 = text_of(&arena, "unknown op")}};
    response = keyword_map(&arena, keys, values, 1U,
                           (int64_t)sizeof(native_m0_type_36),
                           _Alignof(native_m0_type_36));
    result = RT_COORD_STATUS_RESPONSE(&arena, &capability, INT64_C(7788),
                                      response);
    CHECK("coord-status-response", "incompatible",
          text_is(result,
                  "coordinator INCOMPATIBLE on 127.0.0.1:7788 — daemon lacks "
                  "required log-fence protocol; restart it with current "
                  "Fram"));

    values[0] = (native_m0_type_36){
        .tag = INT64_C(0),
        .payload = {.variant_0 = text_of(&arena, "broken")}};
    response = keyword_map(&arena, keys, values, 1U,
                           (int64_t)sizeof(native_m0_type_36),
                           _Alignof(native_m0_type_36));
    result = RT_COORD_STATUS_RESPONSE(&arena, &capability, INT64_C(7788),
                                      response);
    CHECK("coord-status-response", "unusable",
          text_is(result,
                  "coordinator UNUSABLE on 127.0.0.1:7788 — {:error "
                  "\"broken\"}"));
  }

  native_arena_reset(&arena);
  result = RT_COORD_STATUS_DOWN(&arena, &capability, INT64_C(7788));
  CHECK("coord-status-down", "down",
        text_is(result,
                "coordinator DOWN on 127.0.0.1:7788 — start it with bin/fram-up"));

  native_arena_reset(&arena);
  {
    uint64_t key[] = {KW_ERROR};
    native_m0_type_37 value[] = {
        {.tag = INT64_C(0),
         .payload = {.variant_0 = text_of(&arena, "unknown op")}}};
    native_m0_type_20 response =
        keyword_map(&arena, key, value, 1U,
                    (int64_t)sizeof(native_m0_type_37),
                    _Alignof(native_m0_type_37));
    native_m0_type_43 actual = RT_WARM_READ_RESPONSE(response);
    CHECK("warm-read-response", "unknown", actual.tag == INT64_C(1));
    {
      native_m0_type_34 cells[] = {
          {.tag = INT64_C(0),
           .payload = {.variant_0 = text_of(&arena, "s")}},
          {.tag = INT64_C(0),
           .payload = {.variant_0 = text_of(&arena, "p")}},
          {.tag = INT64_C(0),
           .payload = {.variant_0 = text_of(&arena, "o")}}};
      native_vec *row = native_vec_new(&arena, INT64_C(3), INT64_C(16),
                                       (size_t)8);
      native_vec *rows = native_vec_new(&arena, INT64_C(1), INT64_C(8),
                                        (size_t)8);
      for (index = 0U; index < 3U; index++) {
        row = native_vec_push(&arena, row, &cells[index], INT64_C(16),
                              (size_t)8);
      }
      rows = native_vec_push(&arena, rows, &row, INT64_C(8), (size_t)8);
      key[0] = KW_REQUEST;
      value[0] = (native_m0_type_37){
          .tag = INT64_C(7), .payload = {.variant_7 = rows}};
      response = keyword_map(&arena, key, value, 1U,
                             (int64_t)sizeof(native_m0_type_37),
                             _Alignof(native_m0_type_37));
      actual = RT_WARM_READ_RESPONSE(response);
      CHECK("warm-read-response", "value",
            (actual.tag == INT64_C(0)) &&
                (actual.payload.variant_0 == response));
    }

    key[0] = KW_ERROR;
    value[0] = (native_m0_type_37){
        .tag = INT64_C(0),
        .payload = {.variant_0 = text_of(&arena, "unknown op")}};
    response = keyword_map(&arena, key, value, 1U,
                           (int64_t)sizeof(native_m0_type_37),
                           _Alignof(native_m0_type_37));
    actual = RT_WARM_READ_FOR_LOG_RESPONSE(response);
    CHECK("warm-read-for-log-response", "unknown",
          actual.tag == INT64_C(1));
    key[0] = KW_REJECT;
    value[0] = (native_m0_type_37){
        .tag = INT64_C(4),
        .payload = {.variant_4 = (uint64_t)KW_LOG_MISMATCH}};
    response = keyword_map(&arena, key, value, 1U,
                           (int64_t)sizeof(native_m0_type_37),
                           _Alignof(native_m0_type_37));
    actual = RT_WARM_READ_FOR_LOG_RESPONSE(response);
    CHECK("warm-read-for-log-response", "rejected",
          actual.tag == INT64_C(1));
    {
      native_m0_type_34 cells[] = {
          {.tag = INT64_C(1), .payload = {.variant_1 = INT64_C(1)}},
          {.tag = INT64_C(3), .payload = {.variant_3 = true}},
          {.tag = INT64_C(5)}};
      native_vec *row = native_vec_new(&arena, INT64_C(3), INT64_C(16),
                                       (size_t)8);
      native_vec *rows = native_vec_new(&arena, INT64_C(1), INT64_C(8),
                                        (size_t)8);
      for (index = 0U; index < 3U; index++) {
        row = native_vec_push(&arena, row, &cells[index], INT64_C(16),
                              (size_t)8);
      }
      rows = native_vec_push(&arena, rows, &row, INT64_C(8), (size_t)8);
      key[0] = KW_REQUEST;
      value[0] = (native_m0_type_37){
          .tag = INT64_C(7), .payload = {.variant_7 = rows}};
      response = keyword_map(&arena, key, value, 1U,
                             (int64_t)sizeof(native_m0_type_37),
                             _Alignof(native_m0_type_37));
      actual = RT_WARM_READ_FOR_LOG_RESPONSE(response);
      CHECK("warm-read-for-log-response", "value",
            (actual.tag == INT64_C(0)) &&
                (actual.payload.variant_0 == response));
    }
  }

  return EXIT_SUCCESS;
}
