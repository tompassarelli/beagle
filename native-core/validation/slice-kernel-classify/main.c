#include "module_0.h"
#include "function_map.h"

#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ARENA_BYTES ((size_t)1048576)
#define EXPECTED_CASES ((size_t)77)
#define MAX_FIELDS ((size_t)8)

static uint8_t arena_storage[ARENA_BYTES];
static const native_capability capability = { UINT64_C(0) };
static const char hex_digits[] = "0123456789abcdef";

static bool fail(const char *message) {
  (void)fprintf(stderr, "kernel-classify fixture: %s\n", message);
  return false;
}

static char *read_corpus(const char *path, size_t *length_out) {
  FILE *stream;
  long end;
  size_t length;
  char *contents;

  stream = fopen(path, "rb");
  if (stream == NULL) {
    (void)fprintf(stderr, "kernel-classify fixture: cannot open %s\n", path);
    return NULL;
  }
  if ((fseek(stream, 0L, SEEK_END) != 0) || ((end = ftell(stream)) < 0L) ||
      (fseek(stream, 0L, SEEK_SET) != 0)) {
    (void)fclose(stream);
    (void)fail("cannot measure corpus");
    return NULL;
  }
  length = (size_t)end;
  if (((long)length != end) || (length == SIZE_MAX)) {
    (void)fclose(stream);
    (void)fail("corpus is too large");
    return NULL;
  }
  contents = (char *)malloc(length + 1U);
  if (contents == NULL) {
    (void)fclose(stream);
    (void)fail("cannot allocate corpus buffer");
    return NULL;
  }
  if ((fread(contents, 1U, length, stream) != length) ||
      (fclose(stream) != 0)) {
    free(contents);
    (void)fail("cannot read corpus");
    return NULL;
  }
  if (memchr(contents, '\0', length) != NULL) {
    free(contents);
    (void)fail("corpus contains a zero byte");
    return NULL;
  }
  contents[length] = '\0';
  *length_out = length;
  return contents;
}

static int hex_nibble(char byte) {
  if ((byte >= '0') && (byte <= '9')) {
    return (int)(byte - '0');
  }
  if ((byte >= 'a') && (byte <= 'f')) {
    return (int)(byte - 'a') + 10;
  }
  return -1;
}

static bool utf8_continuation(uint8_t byte) {
  return (byte >= UINT8_C(0x80)) && (byte <= UINT8_C(0xbf));
}

static bool strict_utf8(const uint8_t *bytes, size_t length) {
  size_t index = 0U;
  while (index < length) {
    uint8_t first = bytes[index];
    if (first <= UINT8_C(0x7f)) {
      index += 1U;
    } else if ((first >= UINT8_C(0xc2)) && (first <= UINT8_C(0xdf))) {
      if (((length - index) < 2U) || !utf8_continuation(bytes[index + 1U])) {
        return false;
      }
      index += 2U;
    } else if ((first >= UINT8_C(0xe0)) && (first <= UINT8_C(0xef))) {
      uint8_t second;
      if ((length - index) < 3U) {
        return false;
      }
      second = bytes[index + 1U];
      if (!utf8_continuation(bytes[index + 2U]) ||
          ((first == UINT8_C(0xe0)) &&
           ((second < UINT8_C(0xa0)) || (second > UINT8_C(0xbf)))) ||
          ((first == UINT8_C(0xed)) &&
           ((second < UINT8_C(0x80)) || (second > UINT8_C(0x9f)))) ||
          ((first != UINT8_C(0xe0)) && (first != UINT8_C(0xed)) &&
           !utf8_continuation(second))) {
        return false;
      }
      index += 3U;
    } else if ((first >= UINT8_C(0xf0)) && (first <= UINT8_C(0xf4))) {
      uint8_t second;
      if ((length - index) < 4U) {
        return false;
      }
      second = bytes[index + 1U];
      if (!utf8_continuation(bytes[index + 2U]) ||
          !utf8_continuation(bytes[index + 3U]) ||
          ((first == UINT8_C(0xf0)) &&
           ((second < UINT8_C(0x90)) || (second > UINT8_C(0xbf)))) ||
          ((first == UINT8_C(0xf4)) &&
           ((second < UINT8_C(0x80)) || (second > UINT8_C(0x8f)))) ||
          ((first != UINT8_C(0xf0)) && (first != UINT8_C(0xf4)) &&
           !utf8_continuation(second))) {
        return false;
      }
      index += 4U;
    } else {
      return false;
    }
  }
  return true;
}

static bool text_from_hex(native_arena *arena, const char *encoded,
                          native_m0_type_3 *out) {
  size_t encoded_length = strlen(encoded);
  size_t length;
  uint8_t *destination = NULL;
  size_t index;

  if ((encoded_length % 2U) != 0U) {
    return fail("corpus contains odd-length hex");
  }
  length = encoded_length / 2U;
  *out = native_text_alloc(arena, (uint64_t)length, &destination);
  for (index = 0U; index < length; index++) {
    int upper = hex_nibble(encoded[index * 2U]);
    int lower = hex_nibble(encoded[(index * 2U) + 1U]);
    if ((upper < 0) || (lower < 0)) {
      return fail("corpus contains non-lowercase-hex byte");
    }
    destination[index] = (uint8_t)((upper << 4) | lower);
  }
  if (!strict_utf8(destination, length)) {
    return fail("corpus contains invalid UTF-8");
  }
  return true;
}

static bool parse_boolean(const char *field, bool *out) {
  if (strcmp(field, "0") == 0) {
    *out = false;
    return true;
  }
  if (strcmp(field, "1") == 0) {
    *out = true;
    return true;
  }
  return fail("corpus contains invalid boolean");
}

static bool parse_integer(const char *field, int64_t *out) {
  char *end = NULL;
  intmax_t value;
  errno = 0;
  value = strtoimax(field, &end, 10);
  if ((errno == ERANGE) || (end == field) || (*end != '\0') ||
      (value < INT64_MIN) || (value > INT64_MAX)) {
    return fail("corpus contains invalid integer");
  }
  *out = (int64_t)value;
  return true;
}

static size_t split_fields(char *line, char **fields) {
  size_t count = 1U;
  char *cursor;
  fields[0] = line;
  for (cursor = line; *cursor != '\0'; cursor++) {
    if (*cursor == '|') {
      if (count == MAX_FIELDS) {
        return 0U;
      }
      *cursor = '\0';
      fields[count] = cursor + 1;
      count += 1U;
    }
  }
  return count;
}

static bool expect_fields(size_t actual, size_t expected) {
  return (actual == expected) ? true : fail("corpus row has wrong arity");
}

static bool emit_text(const char *operation, size_t index,
                      native_m0_type_3 value) {
  uint64_t length = native_text_length(value);
  const uint8_t *bytes = native_text_bytes(value);
  uint64_t offset;
  if (printf("%s\t%zu\t", operation, index) < 0) {
    return false;
  }
  for (offset = UINT64_C(0); offset < length; offset++) {
    uint8_t byte = bytes[offset];
    if ((putchar(hex_digits[byte >> 4]) == EOF) ||
        (putchar(hex_digits[byte & UINT8_C(0x0f)]) == EOF)) {
      return false;
    }
  }
  return putchar('\n') != EOF;
}

static bool emit_boolean(const char *operation, size_t index, bool value) {
  return printf("%s\t%zu\t%d\n", operation, index, value ? 1 : 0) >= 0;
}

static bool emit_lease(const char *operation, size_t index,
                       native_m0_type_4 lease) {
  uint64_t length = native_text_length(lease.field_0);
  const uint8_t *bytes = native_text_bytes(lease.field_0);
  uint64_t offset;
  if (printf("%s\t%zu\t", operation, index) < 0) {
    return false;
  }
  for (offset = UINT64_C(0); offset < length; offset++) {
    uint8_t byte = bytes[offset];
    if ((putchar(hex_digits[byte >> 4]) == EOF) ||
        (putchar(hex_digits[byte & UINT8_C(0x0f)]) == EOF)) {
      return false;
    }
  }
  return printf("\t%" PRId64 "\t%" PRId64 "\t%d\n", lease.field_1,
                lease.field_2, lease.field_3 ? 1 : 0) >= 0;
}

static bool configured_vector(native_arena *arena, char **fields,
                              native_m0_type_10 *out) {
  size_t index;
  native_m0_type_10 vector =
      native_vec_new(arena, INT64_C(3), (int64_t)sizeof(native_m0_type_3),
                     _Alignof(native_m0_type_3));
  for (index = 0U; index < 3U; index++) {
    native_m0_type_3 value;
    if (!text_from_hex(arena, fields[index], &value)) {
      return false;
    }
    vector = native_vec_push(arena, vector, &value,
                             (int64_t)sizeof(native_m0_type_3),
                             _Alignof(native_m0_type_3));
  }
  *out = vector;
  return true;
}

static bool run_case(native_arena *arena, size_t index, char **fields,
                     size_t count) {
  const char *operation = fields[0];

  if (strcmp(operation, "string") == 0) {
    native_m0_type_3 value;
    if (!expect_fields(count, 2U) ||
        !text_from_hex(arena, fields[1], &value)) {
      return false;
    }
    return emit_text("stripAt", index,
                     KC_STRIP_AT(arena, &capability, value)) &&
           emit_boolean("hasWhitespace", index, KC_HAS_WHITESPACE(value)) &&
           emit_boolean("refShape", index, KC_REF_SHAPE(value));
  }
  if (strcmp(operation, "predicate") == 0) {
    native_m0_type_3 predicate;
    native_m0_type_10 configured;
    if (!expect_fields(count, 5U) ||
        !text_from_hex(arena, fields[1], &predicate) ||
        !configured_vector(arena, &fields[2], &configured)) {
      return false;
    }
    return emit_boolean("vecMember", index,
                        KC_VEC_MEMBER(configured, predicate)) &&
           emit_boolean("configuredSingle", index,
                        KC_CONFIGURED_SINGLE(configured, predicate)) &&
           emit_boolean("emojiSingle", index, KC_EMOJI_SINGLE(predicate));
  }
  if (strcmp(operation, "meta") == 0) {
    native_m0_type_3 predicate;
    if (!expect_fields(count, 2U) ||
        !text_from_hex(arena, fields[1], &predicate)) {
      return false;
    }
    return emit_boolean("metaSingleSeed", index,
                        KC_META_SINGLE_SEED(predicate));
  }
  if (strcmp(operation, "single") == 0) {
    bool declared_present;
    bool declared_single;
    bool configured;
    native_m0_type_3 predicate;
    if (!expect_fields(count, 5U) ||
        !parse_boolean(fields[1], &declared_present) ||
        !parse_boolean(fields[2], &declared_single) ||
        !parse_boolean(fields[3], &configured) ||
        !text_from_hex(arena, fields[4], &predicate)) {
      return false;
    }
    return emit_boolean(
        "singleEff", index,
        KC_SINGLE_EFF(arena, &capability, declared_present, declared_single,
                      configured, predicate));
  }
  if (strcmp(operation, "group") == 0) {
    native_m0_type_3 left;
    native_m0_type_3 predicate;
    if (!expect_fields(count, 3U) ||
        !text_from_hex(arena, fields[1], &left) ||
        !text_from_hex(arena, fields[2], &predicate)) {
      return false;
    }
    return emit_text("keyOfGroup", index,
                     KC_KEY_OF_GROUP(arena, &capability, left, predicate));
  }
  if (strcmp(operation, "triple") == 0) {
    native_m0_type_3 left;
    native_m0_type_3 predicate;
    native_m0_type_3 right;
    if (!expect_fields(count, 4U) ||
        !text_from_hex(arena, fields[1], &left) ||
        !text_from_hex(arena, fields[2], &predicate) ||
        !text_from_hex(arena, fields[3], &right)) {
      return false;
    }
    return emit_text(
        "keyOfTriple", index,
        KC_KEY_OF_TRIPLE(arena, &capability, left, predicate, right));
  }
  if (strcmp(operation, "normalize") == 0) {
    native_m0_type_3 value_kind;
    native_m0_type_3 value;
    if (!expect_fields(count, 3U) ||
        !text_from_hex(arena, fields[1], &value_kind) ||
        !text_from_hex(arena, fields[2], &value)) {
      return false;
    }
    return emit_text(
        "normalizeRefValue", index,
        KC_NORMALIZE_REF_VALUE(arena, &capability, value_kind, value));
  }
  if (strcmp(operation, "lease-subject") == 0) {
    native_m0_type_3 resource;
    if (!expect_fields(count, 2U) ||
        !text_from_hex(arena, fields[1], &resource)) {
      return false;
    }
    return emit_text("leaseSubject", index,
                     KC_LEASE_SUBJECT(arena, &capability, resource));
  }
  if (strcmp(operation, "lease-encode") == 0) {
    native_m0_type_3 holder;
    int64_t exp;
    int64_t epoch;
    if (!expect_fields(count, 4U) ||
        !text_from_hex(arena, fields[1], &holder) ||
        !parse_integer(fields[2], &exp) || !parse_integer(fields[3], &epoch)) {
      return false;
    }
    return emit_text(
        "leaseEncode", index,
        KC_LEASE_ENCODE(arena, &capability, holder, exp, epoch));
  }
  if (strcmp(operation, "lease-decode") == 0) {
    native_m0_type_3 value;
    if (!expect_fields(count, 2U) ||
        !text_from_hex(arena, fields[1], &value)) {
      return false;
    }
    return emit_lease("leaseDecode", index,
                      KC_LEASE_DECODE(arena, &capability, value));
  }
  if (strcmp(operation, "lease-invalid") == 0) {
    if (!expect_fields(count, 1U)) {
      return false;
    }
    return emit_lease("leaseInvalid", index, KC_LEASE_INVALID());
  }
  if (strcmp(operation, "delivery") == 0) {
    native_m0_type_3 predicate;
    if (!expect_fields(count, 2U) ||
        !text_from_hex(arena, fields[1], &predicate)) {
      return false;
    }
    return emit_boolean("deliveryTrigger", index,
                        KC_DELIVERY_TRIGGER(predicate));
  }
  return fail("corpus contains unknown operation");
}

static bool emit_text_vector(const char *operation, native_m0_type_10 values) {
  int64_t length = native_vec_length(values);
  int64_t index;
  if (length < INT64_C(0)) {
    return fail("observed vector has negative length");
  }
  for (index = INT64_C(0); index < length; index++) {
    const native_m0_type_3 *value =
        (const native_m0_type_3 *)native_vec_at(
            values, index, (int64_t)sizeof(native_m0_type_3));
    if (!emit_text(operation, (size_t)index, *value)) {
      return false;
    }
  }
  return true;
}

static bool emit_observed_globals(native_arena *arena) {
  native_m0_type_10 fallback =
      KC_OBSERVED_FALLBACK_SINGLE(arena, &capability);
  native_m0_type_3 separator = KC_OBSERVED_KEY_SEP();
  native_m0_type_10 schema =
      KC_OBSERVED_LEASE_SCHEMA_LINES(arena, &capability);
  return emit_text_vector("fallbackSingle", fallback) &&
         emit_text("keySep", 0U, separator) &&
         emit_text_vector("leaseSchemaLine", schema);
}

int main(int argc, char **argv) {
  native_arena arena;
  size_t corpus_length = 0U;
  char *corpus;
  char *line;
  size_t index = 0U;

  if (argc != 2) {
    (void)fprintf(stderr, "usage: %s <corpus.tsv>\n", argv[0]);
    return 2;
  }
  corpus = read_corpus(argv[1], &corpus_length);
  if (corpus == NULL) {
    return 2;
  }
  native_arena_init(&arena, arena_storage, sizeof arena_storage);
  line = corpus;
  while (line < (corpus + corpus_length)) {
    char *newline = strchr(line, '\n');
    char *fields[MAX_FIELDS];
    size_t count;
    if (newline != NULL) {
      *newline = '\0';
    }
    if ((line[0] != '\0') && (line[0] != '#')) {
      size_t line_length = strlen(line);
      if ((line_length != 0U) && (line[line_length - 1U] == '\r')) {
        line[line_length - 1U] = '\0';
      }
      count = split_fields(line, fields);
      if ((count == 0U) || !run_case(&arena, index, fields, count)) {
        free(corpus);
        return 3;
      }
      index += 1U;
    }
    if (newline == NULL) {
      break;
    }
    line = newline + 1;
  }
  free(corpus);
  if (index != EXPECTED_CASES) {
    (void)fail("corpus does not contain exactly 77 cases");
    return 4;
  }
  if (!emit_observed_globals(&arena) || (fflush(stdout) != 0)) {
    (void)fail("cannot write fixture output");
    return 5;
  }
  return 0;
}
