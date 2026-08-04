/* Probe for the exact helpers selected from fram.fri-replay. The module under
   this file is generated into scratch by drive.sh. */
#include "module_0.h"

static uint8_t storage[1u << 20];
static native_arena arena;
static const native_capability capability = { UINT64_C(0) };

static void reset_arena(void) {
  native_arena_init(&arena, storage, sizeof storage);
}

static native_m0_type_3 text_of(const char *bytes) {
  uint8_t *destination = NULL;
  size_t length = strlen(bytes);
  uint64_t handle = native_text_alloc(&arena, (uint64_t)length, &destination);
  if (length != 0u) {
    memcpy(destination, bytes, length);
  }
  return handle;
}

static bool text_is(native_m0_type_3 handle, const char *bytes) {
  size_t length = strlen(bytes);
  return native_text_length(handle) == (uint64_t)length &&
         (length == 0u || memcmp(native_text_bytes(handle), bytes, length) == 0);
}

static native_m0_type_3 vector_text(native_m0_type_10 values, int64_t index) {
  return *(const native_m0_type_3 *)native_vec_at(values, index, INT64_C(8));
}

static native_m0_type_4 vector_fact(native_m0_type_11 facts, int64_t index) {
  return *(const native_m0_type_4 *)native_vec_at(facts, index, INT64_C(40));
}

static native_m0_type_10 strings_of(const char *const *values, int64_t count) {
  native_m0_type_10 result =
      native_vec_new(&arena, count, INT64_C(8), (size_t)8);
  for (int64_t index = INT64_C(0); index < count; ++index) {
    native_m0_type_3 value = text_of(values[index]);
    result = native_vec_push(&arena, result, &value, INT64_C(8), (size_t)8);
  }
  return result;
}

static bool fact_is(native_m0_type_4 fact, bool valid, const char *predicate,
                    const char *value, int64_t base, bool has_base) {
  return fact.field_0 == valid && text_is(fact.field_1, predicate) &&
         text_is(fact.field_2, value) && fact.field_3 == base &&
         fact.field_4 == has_base;
}

static bool op_is(native_m0_type_12 operation, int64_t kind,
                  const char *subject, const char *predicate,
                  const char *value, int64_t base, bool has_base,
                  int64_t fact_count, const char *error) {
  return operation.field_0 == kind && text_is(operation.field_1, subject) &&
         text_is(operation.field_2, predicate) &&
         text_is(operation.field_3, value) && operation.field_4 == base &&
         operation.field_5 == has_base &&
         native_vec_length(operation.field_6) == fact_count &&
         text_is(operation.field_7, error);
}

int main(void) {
  static const char *const assertion_fields[] = {
      "assert", "subject", "predicate", "value"};
  static const char *const batch_fields[] = {
      "assert-batch", "subject", "p=v|q=w@8"};
  native_m0_type_3 text;
  native_m0_type_3 separator;
  native_m0_type_3 result;
  native_m0_type_4 fact;
  native_m0_type_5 parsed;
  native_m0_type_10 fields;
  native_m0_type_10 parts;
  native_m0_type_11 facts;
  native_m0_type_12 operation;

  reset_arena();
  text = text_of("abc");
  if (!text_is(native_m0_fn_0(&arena, &capability, text, INT64_C(1)), "b")) {
    return 1;
  }

  reset_arena();
  text = text_of("a|b||c");
  separator = text_of("|");
  parts = native_m0_fn_1(&arena, &capability, text, separator);
  if (native_vec_length(parts) != INT64_C(4)) {
    return 2;
  }
  if (!text_is(vector_text(parts, INT64_C(0)), "a") ||
      !text_is(vector_text(parts, INT64_C(1)), "b") ||
      !text_is(vector_text(parts, INT64_C(2)), "") ||
      !text_is(vector_text(parts, INT64_C(3)), "c")) {
    return 3;
  }
  result = native_m0_fn_6(&arena, &capability, parts, text_of(","));
  if (!text_is(result, "a,b,,c")) {
    return 4;
  }

  reset_arena();
  text = text_of("ababa");
  separator = text_of("b");
  if (native_m0_fn_2(&arena, &capability, text, separator) != INT64_C(1)) {
    return 5;
  }
  if (native_m0_fn_3(&arena, &capability, text, separator) != INT64_C(3)) {
    return 6;
  }

  reset_arena();
  if (!native_m0_fn_4(text_of(" ")) ||
      !native_m0_fn_4(text_of("\t")) ||
      !native_m0_fn_4(text_of("\r")) || native_m0_fn_4(text_of("x"))) {
    return 7;
  }
  text = text_of(" \tabc\r ");
  if (!text_is(native_m0_fn_5(&arena, &capability, text), "abc")) {
    return 8;
  }

  reset_arena();
  if (native_m0_fn_7(&arena, &capability, text_of("0")) != INT64_C(0) ||
      native_m0_fn_7(&arena, &capability, text_of("7")) != INT64_C(7) ||
      native_m0_fn_7(&arena, &capability, text_of("x")) != INT64_C(-1)) {
    return 9;
  }

  reset_arena();
  parsed = native_m0_fn_8(&arena, &capability, text_of("42"));
  if (!parsed.field_0 || parsed.field_1 != INT64_C(42)) {
    return 10;
  }
  parsed = native_m0_fn_8(&arena, &capability, text_of("-19"));
  if (!parsed.field_0 || parsed.field_1 != INT64_C(-19)) {
    return 11;
  }
  parsed = native_m0_fn_8(&arena, &capability, text_of("12x"));
  if (parsed.field_0 || parsed.field_1 != INT64_C(0)) {
    return 12;
  }
  parsed = native_m0_fn_8(&arena, &capability, text_of(""));
  if (parsed.field_0 || parsed.field_1 != INT64_C(0)) {
    return 13;
  }
  parsed = native_m0_fn_8(&arena, &capability, text_of("-"));
  if (parsed.field_0 || parsed.field_1 != INT64_C(0)) {
    return 14;
  }

  reset_arena();
  operation = native_m0_fn_9(&arena, &capability, text_of("problem"));
  if (!op_is(operation, INT64_C(4), "", "", "", INT64_C(0), false,
             INT64_C(0), "problem")) {
    return 15;
  }

  reset_arena();
  fact = native_m0_fn_10(&arena, &capability, text_of("p=v"));
  if (!fact_is(fact, true, "p", "v", INT64_C(0), false)) {
    return 16;
  }
  fact = native_m0_fn_10(&arena, &capability, text_of("p=v@7"));
  if (!fact_is(fact, true, "p", "v", INT64_C(7), true)) {
    return 17;
  }
  fact = native_m0_fn_10(&arena, &capability, text_of("p=v@x"));
  if (!fact_is(fact, true, "p", "v@x", INT64_C(0), false)) {
    return 18;
  }
  fact = native_m0_fn_10(&arena, &capability, text_of("bad"));
  if (!fact_is(fact, false, "", "", INT64_C(0), false)) {
    return 19;
  }

  reset_arena();
  facts = native_m0_fn_11(&arena, &capability, text_of("p=v|q=w@8"));
  if (native_vec_length(facts) != INT64_C(2) ||
      !fact_is(vector_fact(facts, INT64_C(0)), true, "p", "v", INT64_C(0),
               false) ||
      !fact_is(vector_fact(facts, INT64_C(1)), true, "q", "w", INT64_C(8),
               true)) {
    return 20;
  }
  if (!native_m0_fn_12(facts)) {
    return 21;
  }
  facts = native_m0_fn_11(&arena, &capability, text_of("bad"));
  if (native_m0_fn_12(facts)) {
    return 22;
  }

  reset_arena();
  fields = strings_of(assertion_fields, INT64_C(4));
  text = text_of("assert");
  operation = native_m0_fn_13(&arena, &capability, text, fields, INT64_C(4));
  if (!op_is(operation, INT64_C(1), "subject", "predicate", "value",
             INT64_C(0), false, INT64_C(0), "")) {
    return 23;
  }

  reset_arena();
  fields = strings_of(batch_fields, INT64_C(3));
  text = text_of("assert-batch");
  operation = native_m0_fn_14(&arena, &capability, text, fields, INT64_C(3));
  if (!op_is(operation, INT64_C(3), "subject", "", "", INT64_C(0), false,
             INT64_C(2), "") ||
      !fact_is(vector_fact(operation.field_6, INT64_C(1)), true, "q", "w",
               INT64_C(8), true)) {
    return 24;
  }

  reset_arena();
  operation = native_m0_fn_15(&arena, &capability, text_of("version"));
  if (!op_is(operation, INT64_C(0), "", "", "", INT64_C(0), false,
             INT64_C(0), "")) {
    return 25;
  }

  reset_arena();
  operation = native_m0_fn_15(
      &arena, &capability, text_of("assert\tsubject\tpredicate\tvalue"));
  if (!op_is(operation, INT64_C(1), "subject", "predicate", "value",
             INT64_C(0), false, INT64_C(0), "")) {
    return 26;
  }

  reset_arena();
  operation = native_m0_fn_15(
      &arena, &capability,
      text_of("assert-batch-at-version\tsubject\t7\tp=v|q=w@8"));
  if (!op_is(operation, INT64_C(3), "subject", "", "", INT64_C(7), true,
             INT64_C(2), "") ||
      !fact_is(vector_fact(operation.field_6, INT64_C(1)), true, "q", "w",
               INT64_C(8), true)) {
    return 27;
  }

  reset_arena();
  operation = native_m0_fn_15(&arena, &capability, text_of("mystery"));
  if (!op_is(operation, INT64_C(4), "", "", "", INT64_C(0), false,
             INT64_C(0), "unknown corpus operation mystery")) {
    return 28;
  }

  reset_arena();
  if (!text_is(native_m0_fn_16(&arena, &capability, text_of("@root")),
               "root")) {
    return 29;
  }
  if (!text_is(native_m0_fn_16(&arena, &capability, text_of("root")),
               "root")) {
    return 30;
  }
  return 0;
}
