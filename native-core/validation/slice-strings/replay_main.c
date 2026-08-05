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

static native_m0_type_3 vector_text(native_m0_type_14 values, int64_t index) {
  return *(const native_m0_type_3 *)native_vec_at(values, index, INT64_C(8));
}

static native_m0_type_4 vector_fact(native_m0_type_17 facts, int64_t index) {
  return *(const native_m0_type_4 *)native_vec_at(facts, index, INT64_C(40));
}

static native_m0_type_14 strings_of(const char *const *values, int64_t count) {
  native_m0_type_14 result =
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

static bool op_is(native_m0_type_18 operation, int64_t kind,
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

static native_m0_type_5 triple_of(const char *t1, const char *t2,
                                  const char *t3) {
  native_m0_type_5 triple;
  triple.field_0 = text_of(t1);
  triple.field_1 = text_of(t2);
  triple.field_2 = text_of(t3);
  return triple;
}

static native_m0_type_19 triple_vector(int64_t capacity) {
  return native_vec_new(&arena, capacity, INT64_C(24), (size_t)8);
}

static native_m0_type_19 push_triple(native_m0_type_19 triples,
                                     native_m0_type_5 triple) {
  return native_vec_push(&arena, triples, &triple, INT64_C(24), (size_t)8);
}

static native_m0_type_5 vector_triple(native_m0_type_19 triples,
                                      int64_t index) {
  return *(const native_m0_type_5 *)native_vec_at(triples, index,
                                                  INT64_C(24));
}

static native_m0_type_6 vector_commit(native_m0_type_23 commits,
                                      int64_t index) {
  return *(const native_m0_type_6 *)native_vec_at(commits, index,
                                                  INT64_C(32));
}

static native_m0_type_15 vector_outcome(native_m0_type_16 outcomes,
                                        int64_t index) {
  return *(const native_m0_type_15 *)native_vec_at(outcomes, index,
                                                   INT64_C(48));
}

static native_m0_type_25 vector_frame(native_m0_type_21 frames,
                                      int64_t index) {
  return *(const native_m0_type_25 *)native_vec_at(frames, index,
                                                   INT64_C(16));
}

static bool triple_is(native_m0_type_5 triple, const char *t1,
                      const char *t2, const char *t3) {
  return text_is(triple.field_0, t1) && text_is(triple.field_1, t2) &&
         text_is(triple.field_2, t3);
}

static native_m0_type_7 action_of(int64_t operation, const char *t1,
                                  const char *t2, const char *t3,
                                  bool local_base) {
  native_m0_type_7 action;
  action.field_0 = operation;
  action.field_1 = text_of(t1);
  action.field_2 = text_of(t2);
  action.field_3 = text_of(t3);
  action.field_4 = local_base;
  return action;
}

static native_m0_type_13 action_vector(int64_t capacity) {
  return native_vec_new(&arena, capacity, INT64_C(40), (size_t)8);
}

static native_m0_type_13 push_action(native_m0_type_13 actions,
                                     native_m0_type_7 action) {
  return native_vec_push(&arena, actions, &action, INT64_C(40), (size_t)8);
}

static bool apply_is(native_m0_type_24 result, int64_t version,
                     int64_t triple_count, bool changed, bool collapse,
                     int64_t commit_count) {
  return result.field_0.field_1 == version &&
         native_vec_length(result.field_0.field_0) == triple_count &&
         result.field_1 == changed && result.field_2 == collapse &&
         native_vec_length(result.field_3) == commit_count;
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
  native_m0_type_5 triple;
  native_m0_type_7 action;
  native_m0_type_8 parsed;
  native_m0_type_13 actions;
  native_m0_type_14 fields;
  native_m0_type_14 parts;
  native_m0_type_17 facts;
  native_m0_type_18 operation;
  native_m0_type_19 reduced;
  native_m0_type_19 triples;
  native_m0_type_20 model;
  native_m0_type_24 applied;
  native_m0_type_26 removal;
  native_m0_type_27 mutation;
  native_m0_type_22 replayed;

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

  reset_arena();
  triples = triple_vector(INT64_C(4));
  triple = triple_of("@color", "cardinality", "single");
  triples = push_triple(triples, triple);
  triple = triple_of("subject", "color", "red");
  triples = push_triple(triples, triple);
  triple = triple_of("subject", "color", "blue");
  triples = push_triple(triples, triple);
  triple = triple_of("other", "color", "green");
  triples = push_triple(triples, triple);

  text = text_of("subject");
  separator = text_of("color");
  result = text_of("red");
  if (native_m0_fn_17(triples, text, separator, result) != INT64_C(1) ||
      native_m0_fn_18(triples, text, separator) != INT64_C(1)) {
    return 31;
  }

  reduced = native_m0_fn_19(&arena, &capability, triples, INT64_C(2));
  if (native_vec_length(reduced) != INT64_C(3) ||
      !triple_is(vector_triple(reduced, INT64_C(1)), "subject", "color",
                 "red") ||
      !triple_is(vector_triple(reduced, INT64_C(2)), "other", "color",
                 "green")) {
    return 32;
  }

  if (!native_m0_fn_20(&arena, &capability, triples, separator) ||
      native_m0_fn_21(triples, text, separator) != INT64_C(2) ||
      !native_m0_fn_22(triples, separator)) {
    return 33;
  }

  model.field_0 = triples;
  model.field_1 = INT64_C(5);
  action = action_of(INT64_C(1), "@color", "cardinality", "single", false);
  if (!native_m0_fn_23(&arena, &capability, model, action)) {
    return 34;
  }

  removal = native_m0_fn_24(&arena, &capability, triples, text, separator);
  if (native_vec_length(removal.field_0) != INT64_C(2) ||
      native_vec_length(removal.field_1) != INT64_C(2) ||
      !triple_is(vector_triple(removal.field_0, INT64_C(1)), "other", "color",
                 "green") ||
      vector_commit(removal.field_1, INT64_C(0)).field_0 != INT64_C(2) ||
      !triple_is(vector_commit(removal.field_1, INT64_C(1)).field_1,
                 "subject", "color", "blue")) {
    return 35;
  }

  reset_arena();
  triples = triple_vector(INT64_C(2));
  triple = triple_of("@color", "cardinality", "single");
  triples = push_triple(triples, triple);
  triple = triple_of("subject", "color", "red");
  triples = push_triple(triples, triple);
  model.field_0 = triples;
  model.field_1 = INT64_C(5);
  action = action_of(INT64_C(1), "subject", "color", "blue", false);
  applied = native_m0_fn_25(&arena, &capability, model, action);
  if (!apply_is(applied, INT64_C(5), INT64_C(2), true, false,
                INT64_C(2)) ||
      !triple_is(vector_triple(applied.field_0.field_0, INT64_C(1)),
                 "subject", "color", "blue")) {
    return 36;
  }
  if (vector_commit(applied.field_3, INT64_C(0)).field_0 != INT64_C(2) ||
      vector_commit(applied.field_3, INT64_C(1)).field_0 != INT64_C(1)) {
    return 37;
  }

  action = action_of(INT64_C(2), "subject", "color", "ignored", false);
  applied = native_m0_fn_26(&arena, &capability, applied.field_0, action);
  if (!apply_is(applied, INT64_C(5), INT64_C(1), true, false,
                INT64_C(1)) ||
      !triple_is(vector_triple(applied.field_0.field_0, INT64_C(0)),
                 "@color", "cardinality", "single")) {
    return 38;
  }

  reset_arena();
  triples = triple_vector(INT64_C(3));
  triple = triple_of("@color", "cardinality", "single");
  triples = push_triple(triples, triple);
  triple = triple_of("subject", "color", "red");
  triples = push_triple(triples, triple);
  triple = triple_of("subject", "color", "blue");
  triples = push_triple(triples, triple);
  model.field_0 = triples;
  model.field_1 = INT64_C(9);
  action = action_of(INT64_C(1), "@color", "cardinality", "single", false);
  applied = native_m0_fn_27(&arena, &capability, model, action);
  if (!apply_is(applied, INT64_C(9), INT64_C(3), false, true,
                INT64_C(0))) {
    return 39;
  }

  reset_arena();
  {
    int64_t one = INT64_C(1);
    int64_t two = INT64_C(2);
    int64_t three = INT64_C(3);
    native_vec *left = native_vec_new(&arena, INT64_C(2), INT64_C(8), (size_t)8);
    native_vec *right = native_vec_new(&arena, INT64_C(1), INT64_C(8), (size_t)8);
    native_vec *joined;
    left = native_vec_push(&arena, left, &one, INT64_C(8), (size_t)8);
    left = native_vec_push(&arena, left, &two, INT64_C(8), (size_t)8);
    right = native_vec_push(&arena, right, &three, INT64_C(8), (size_t)8);
    joined = native_vec_concat(&arena, left, right, INT64_C(8), (size_t)8);
    if (native_vec_length(left) != INT64_C(2) ||
        native_vec_length(right) != INT64_C(1) ||
        native_vec_length(joined) != INT64_C(3) ||
        *(const int64_t *)native_vec_at(joined, INT64_C(0), INT64_C(8)) != one ||
        *(const int64_t *)native_vec_at(joined, INT64_C(1), INT64_C(8)) != two ||
        *(const int64_t *)native_vec_at(joined, INT64_C(2), INT64_C(8)) != three) {
      return 40;
    }
  }

  reset_arena();
  triples = triple_vector(INT64_C(2));
  model.field_0 = triples;
  model.field_1 = INT64_C(5);
  actions = action_vector(INT64_C(2));
  action = action_of(INT64_C(1), "subject", "color", "red", false);
  actions = push_action(actions, action);
  action = action_of(INT64_C(1), "subject", "shape", "round", false);
  actions = push_action(actions, action);
  mutation = native_m0_fn_31(&arena, &capability, model, actions, true);
  if (mutation.field_0.field_1 != INT64_C(6) ||
      native_vec_length(mutation.field_0.field_0) != INT64_C(2) ||
      mutation.field_1.field_0 != INT64_C(1) || !mutation.field_1.field_1 ||
      mutation.field_1.field_2 != INT64_C(6) ||
      !text_is(mutation.field_1.field_3, "") ||
      native_vec_length(mutation.field_1.field_4) != INT64_C(2) ||
      native_vec_length(mutation.field_1.field_5) != INT64_C(0) ||
      native_vec_length(mutation.field_2) != INT64_C(2) ||
      !text_is(vector_text(mutation.field_1.field_4, INT64_C(0)), "color") ||
      !text_is(vector_text(mutation.field_1.field_4, INT64_C(1)), "shape")) {
    return 41;
  }

  reset_arena();
  model.field_0 = triple_vector(INT64_C(1));
  model.field_1 = INT64_C(0);
  operation = native_m0_fn_15(
      &arena, &capability, text_of("assert\tsubject\tcolor\tred"));
  mutation = native_m0_fn_32(&arena, &capability, model, operation);
  if (mutation.field_0.field_1 != INT64_C(1) ||
      native_vec_length(mutation.field_0.field_0) != INT64_C(1) ||
      mutation.field_1.field_0 != INT64_C(1) ||
      mutation.field_1.field_2 != INT64_C(1) ||
      native_vec_length(mutation.field_2) != INT64_C(1)) {
    return 42;
  }

  reset_arena();
  replayed = native_m0_fn_33(
      &arena, &capability,
      text_of("version\nassert\tsubject\tcolor\tred\nversion\n"));
  if (replayed.field_0 != INT64_C(3) ||
      replayed.field_1.field_1 != INT64_C(1) ||
      native_vec_length(replayed.field_1.field_0) != INT64_C(1) ||
      native_vec_length(replayed.field_2) != INT64_C(3) ||
      native_vec_length(replayed.field_3) != INT64_C(1) ||
      !text_is(replayed.field_4, "") ||
      vector_outcome(replayed.field_2, INT64_C(0)).field_0 != INT64_C(0) ||
      vector_outcome(replayed.field_2, INT64_C(1)).field_0 != INT64_C(1) ||
      vector_outcome(replayed.field_2, INT64_C(2)).field_2 != INT64_C(1) ||
      vector_frame(replayed.field_3, INT64_C(0)).field_0 != INT64_C(1) ||
      native_vec_length(vector_frame(replayed.field_3, INT64_C(0)).field_1) !=
          INT64_C(1)) {
    return 43;
  }
  return 0;
}
