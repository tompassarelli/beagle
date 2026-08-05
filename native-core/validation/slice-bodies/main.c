/* Probe for the lowered fram.types bodies. Hand-written; the module under it is
   generated. "trap" and "overflow" take a trapping path instead, which aborts.
   fn_0 instant?  fn_1 instant  fn_2 instant-shift-seconds
   fn_3 instant-seconds-between  fn_4 triple?
   fn_11 rpc-page-request-cursor-value  fn_16 commit-operation?
   fn_19 atom? through fn_30 occurrence-before?
   Any tags: 0 bool, 1 i64, 2 f64, 3 text, 4 keyword, 5 nil,
   6 Instant, 7 Triple, 22 CommitOperation.
   Term tags: 0 text, 1 i64, 2 f64, 3 bool, 4 keyword, 5 Instant, 6 Triple. */
#include "module_0.h"

static native_m0_type_50 any_reference(int64_t tag, void *target) {
  native_m0_type_50 value;
  value.tag = tag;
  if (tag == INT64_C(6)) {
    value.payload.variant_6 = target;
  } else if (tag == INT64_C(7)) {
    value.payload.variant_7 = target;
  } else {
    value.payload.variant_22 = target;
  }
  return value;
}

static native_m0_type_50 any_bool(bool boolean) {
  native_m0_type_50 value = {
    .tag = INT64_C(0), .payload = { .variant_0 = boolean }
  };
  return value;
}

static native_m0_type_50 any_i64(int64_t number) {
  native_m0_type_50 value = {
    .tag = INT64_C(1), .payload = { .variant_1 = number }
  };
  return value;
}

static native_m0_type_50 any_f64(double number) {
  native_m0_type_50 value = {
    .tag = INT64_C(2), .payload = { .variant_2 = number }
  };
  return value;
}

static native_m0_type_50 any_text(uint64_t handle) {
  native_m0_type_50 value = {
    .tag = INT64_C(3), .payload = { .variant_3 = handle }
  };
  return value;
}

static native_m0_type_50 any_keyword(uint64_t keyword) {
  native_m0_type_50 value = {
    .tag = INT64_C(4), .payload = { .variant_4 = keyword }
  };
  return value;
}

static native_m0_type_9 keyword_of(native_arena *arena, const char *spelling) {
  uint8_t *bytes = NULL;
  uint64_t length = (uint64_t)strlen(spelling);
  native_m0_type_9 handle = native_text_alloc(arena, length, &bytes);
  if (length != UINT64_C(0)) {
    memcpy(bytes, spelling, (size_t)length);
  }
  return handle;
}

static native_m0_type_50 any_nil(void) {
  native_m0_type_50 value = { .tag = INT64_C(5) };
  return value;
}

/* An RpcPageRequest whose cursor is present and carries the given Term. */
static native_m0_type_72 page_request(native_m0_type_64 cursor) {
  native_m0_type_72 request;
  request.field_0 = INT64_C(10);
  request.field_1.tag = INT64_C(0);
  request.field_1.payload.variant_0 = cursor;
  return request;
}

static native_m0_type_64 term_i64(int64_t number) {
  native_m0_type_64 term;
  term.tag = INT64_C(1);
  term.payload.variant_1 = number;
  return term;
}

static native_m0_type_64 term_triple(void *target) {
  native_m0_type_64 term;
  term.tag = INT64_C(6);
  term.payload.variant_6 = target;
  return term;
}

int main(int argc, char **argv) {
  uint8_t storage[UINT16_MAX];
  native_arena arena;
  native_capability capability = { UINT64_C(0) };
  native_arena_init(&arena, storage, sizeof(storage));

  native_m0_type_2 moment = { INT64_C(0), INT64_C(0) };
  native_m0_type_50 as_instant = any_reference(INT64_C(6), &moment);
  native_m0_type_50 as_triple = any_reference(INT64_C(7), &moment);
  native_m0_type_50 as_operation = any_reference(INT64_C(22), &moment);
  native_m0_type_50 as_number = any_i64(INT64_C(42));
  native_m0_type_9 custom = keyword_of(&arena, "custom");
  native_m0_type_9 tx_sequence =
    keyword_of(&arena, "kernel/tx-sequence");
  native_m0_type_9 op_ordinal = keyword_of(&arena, "kernel/op-ordinal");
  native_m0_type_9 asserts = keyword_of(&arena, "kernel/asserts");
  native_m0_type_9 retracts = keyword_of(&arena, "kernel/retracts");
  native_m0_type_9 withdraws = keyword_of(&arena, "kernel/withdraws");
  native_m0_type_9 recorded_at = keyword_of(&arena, "kernel/recorded-at");

  if ((argc > 1) && (argv[1][0] == 't')) {
    /* nanoseconds outside [0, 1000000000) must trap, never return */
    native_m0_fn_1(INT64_C(7), INT64_C(1000000000));
    return 9;
  }
  if ((argc > 1) && (argv[1][0] == 'o')) {
    /* INT64_MAX + 1 must answer the overflow tag, whose arm traps. Returning
       here at all would mean a wrapped value escaped the checked add. */
    native_m0_type_2 edge = { INT64_MAX, INT64_C(0) };
    native_m0_type_2 escaped = native_m0_fn_2(edge, INT64_C(1));
    return (escaped.field_0 == INT64_MIN) ? 10 : 11;
  }

  if (!native_m0_fn_0(as_instant)) {
    return 1;
  }
  if (native_m0_fn_0(as_triple) || native_m0_fn_0(as_number)) {
    return 2;
  }
  if (!native_m0_fn_4(as_triple)) {
    return 3;
  }
  if (native_m0_fn_4(as_instant) || native_m0_fn_4(as_number)) {
    return 4;
  }
  if (!native_m0_fn_16(as_operation)) {
    return 5;
  }
  if (native_m0_fn_16(as_instant)) {
    return 6;
  }

  native_m0_type_2 built = native_m0_fn_1(INT64_C(-5), INT64_C(999999999));
  if ((built.field_0 != INT64_C(-5)) || (built.field_1 != INT64_C(999999999))) {
    return 7;
  }
  native_m0_type_2 zero = native_m0_fn_1(INT64_C(0), INT64_C(0));
  if ((zero.field_0 != INT64_C(0)) || (zero.field_1 != INT64_C(0))) {
    return 8;
  }

  /* checked add: the ok arm carries the exact sum and leaves nanos alone */
  native_m0_type_2 shifted = native_m0_fn_2(built, INT64_C(90));
  if ((shifted.field_0 != INT64_C(85)) ||
      (shifted.field_1 != INT64_C(999999999))) {
    return 12;
  }
  native_m0_type_2 back = native_m0_fn_2(shifted, INT64_C(-90));
  if (back.field_0 != INT64_C(-5)) {
    return 13;
  }

  /* checked subtract */
  if (native_m0_fn_3(built, shifted) != INT64_C(90)) {
    return 14;
  }
  if (native_m0_fn_3(shifted, built) != INT64_C(-90)) {
    return 15;
  }

  /* the tag decision sits exactly on the overflow boundary: one below INT64_MAX
     still takes the ok arm, and the "overflow" probe shows INT64_MAX + 1 does
     not. A wrapping add would have answered ok on both. */
  native_m0_type_2 near = { INT64_MAX - INT64_C(1), INT64_C(0) };
  native_m0_type_2 edge = native_m0_fn_2(near, INT64_C(1));
  if (edge.field_0 != INT64_MAX) {
    return 16;
  }

  /* Term? -> Any widening preserves each payload and maps absence to nil. */
  {
    native_m0_type_50 widened =
      native_m0_fn_11(page_request(term_i64(INT64_C(77))));
    if ((widened.tag != INT64_C(1)) ||
        (widened.payload.variant_1 != INT64_C(77))) {
      return 17;
    }
  }
  {
    native_m0_type_50 widened =
      native_m0_fn_11(page_request(term_triple(&moment)));
    if ((widened.tag != INT64_C(7)) ||
        (widened.payload.variant_7 != &moment)) {
      return 18;
    }
  }
  {
    native_m0_type_72 absent;
    absent.field_0 = INT64_C(10);
    absent.field_1.tag = INT64_C(1);
    absent.field_1.payload.variant_1.tag = INT64_C(0);
    native_m0_type_50 widened = native_m0_fn_11(absent);
    if (widened.tag != INT64_C(5)) {
      return 19;
    }
  }

  uint8_t *space_bytes = NULL;
  native_m0_type_8 space = native_text_alloc(&arena, UINT64_C(5), &space_bytes);
  memcpy(space_bytes, "space", 5);

  /* The nested predicate tree distinguishes every scalar tag without
     extracting the wrong union arm. */
  if (!native_m0_fn_19(any_bool(true)) ||
      !native_m0_fn_19(any_i64(INT64_C(9))) ||
      !native_m0_fn_19(any_f64(3.25)) ||
      !native_m0_fn_19(any_text(space)) ||
      !native_m0_fn_19(any_keyword(custom)) ||
      !native_m0_fn_19(as_instant)) {
    return 20;
  }
  if (native_m0_fn_19(any_nil()) || native_m0_fn_19(as_triple)) {
    return 21;
  }

  /* Constructing a recursive Term boxes the by-value Triple into the arena. */
  native_m0_type_51 scalar_triple = native_m0_fn_21(
    &arena, &capability, any_text(space), any_keyword(custom),
    any_i64(INT64_C(2)));
  native_m0_type_50 scalar_triple_ref =
    any_reference(INT64_C(7), &scalar_triple);
  if (!native_m0_fn_20(scalar_triple_ref)) {
    return 22;
  }
  native_m0_type_51 invalid_term = {
    any_nil(), any_i64(INT64_C(1)), any_i64(INT64_C(2))
  };
  if (native_m0_fn_20(any_reference(INT64_C(7), &invalid_term))) {
    return 23;
  }

  /* Boundary coercion wraps text, keyword, and integer values into Any; the
     predicate then checks and extracts them before comparing. */
  native_m0_type_51 tx =
    native_m0_fn_22(&arena, &capability, space, INT64_C(9));
  if ((tx.field_0.tag != INT64_C(3)) ||
      (tx.field_0.payload.variant_3 != space) ||
      (tx.field_1.tag != INT64_C(4)) ||
      (tx.field_1.payload.variant_4 == tx_sequence) ||
      !native_text_eq(tx.field_1.payload.variant_4, tx_sequence) ||
      (tx.field_2.tag != INT64_C(1)) ||
      (tx.field_2.payload.variant_1 != INT64_C(9)) ||
      !native_m0_fn_23(any_reference(INT64_C(7), &tx))) {
    return 24;
  }
  native_m0_type_51 dynamic_tx_predicate = tx;
  dynamic_tx_predicate.field_1 = any_keyword(tx_sequence);
  if (!native_m0_fn_23(any_reference(INT64_C(7), &dynamic_tx_predicate))) {
    return 25;
  }
  native_m0_type_51 wrong_predicate = tx;
  wrong_predicate.field_1 = any_keyword(custom);
  if (native_m0_fn_23(any_reference(INT64_C(7), &wrong_predicate))) {
    return 26;
  }

  /* Passing a direct Triple where Any is required emits an arena-owned box. */
  native_m0_type_51 occurrence =
    native_m0_fn_24(&arena, &capability, tx, INT64_C(3));
  if ((occurrence.field_0.tag != INT64_C(7)) ||
      (occurrence.field_0.payload.variant_7 == NULL) ||
      (occurrence.field_1.tag != INT64_C(4)) ||
      (occurrence.field_1.payload.variant_4 == op_ordinal) ||
      !native_text_eq(occurrence.field_1.payload.variant_4, op_ordinal) ||
      (occurrence.field_2.tag != INT64_C(1)) ||
      (occurrence.field_2.payload.variant_1 != INT64_C(3)) ||
      !native_m0_fn_25(any_reference(INT64_C(7), &occurrence))) {
    return 27;
  }
  native_m0_type_51 dynamic_occurrence_predicate = occurrence;
  dynamic_occurrence_predicate.field_1 = any_keyword(op_ordinal);
  if (!native_m0_fn_25(
        any_reference(INT64_C(7), &dynamic_occurrence_predicate))) {
    return 28;
  }
  native_m0_type_51 *boxed_tx = occurrence.field_0.payload.variant_7;
  if ((boxed_tx->field_0.tag != INT64_C(3)) ||
      (boxed_tx->field_0.payload.variant_3 != space)) {
    return 29;
  }

  /* The remaining constructors retain their predicate keyword and box each
     record-valued slot with the same arena ownership. */
  native_m0_type_51 assertion =
    native_m0_fn_26(&arena, &capability, occurrence, tx);
  native_m0_type_51 retraction =
    native_m0_fn_27(&arena, &capability, occurrence, tx);
  native_m0_type_51 later =
    native_m0_fn_24(&arena, &capability, tx, INT64_C(4));
  native_m0_type_51 withdrawal =
    native_m0_fn_28(&arena, &capability, occurrence, later);
  native_m0_type_51 recorded =
    native_m0_fn_29(&arena, &capability, tx, moment);
  if (!native_text_eq(assertion.field_1.payload.variant_4, asserts) ||
      !native_text_eq(retraction.field_1.payload.variant_4, retracts) ||
      !native_text_eq(withdrawal.field_1.payload.variant_4, withdraws) ||
      !native_text_eq(recorded.field_1.payload.variant_4, recorded_at)) {
    return 30;
  }

  if (!native_m0_fn_30(&arena, &capability, occurrence, later) ||
      native_m0_fn_30(&arena, &capability, later, occurrence)) {
    return 31;
  }
  return 0;
}
