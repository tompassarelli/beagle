/* Probe for the lowered store.types bodies. Hand-written; the module under it is
   generated. "trap" and "overflow" take a trapping path instead, which aborts.
   fn_0 instant?  fn_1 instant  fn_2 instant-shift-seconds
   fn_3 instant-seconds-between  fn_4 triple?
   fn_11 rpc-page-request-cursor-value  fn_16 commit-operation?
   fn_19 operation-occurrence?  fn_20 withdrawal?
   fn_21 atom? through fn_33 withdrawal
   Term tags: 0 text, 1 i64, 2 f64, 3 bool, 4 keyword, 5 Instant, 6 Triple.
   Every generated TYPE is named through a macro drive.sh resolves out of the
   emitted header: the emitter numbers its type table in collection order, so
   an ordinal spelled here would silently mean a different type the next time
   store.types gains or loses a shape. Any TAGS stay spelled out below on
   purpose — reading a tag back out of the predicate that tests it would make
   the predicate assertions tautological. A tag that moves under store must
   surface as this probe's numbered exit, and be re-read from the source. */
#include "module_0.h"

#ifndef SLICE_ANY_TYPE
#error "SLICE_ANY_TYPE must name the generated Any type"
#endif
#ifndef SLICE_TRIPLE_TYPE
#error "SLICE_TRIPLE_TYPE must name the generated Triple type"
#endif
#ifndef SLICE_TERM_TYPE
#error "SLICE_TERM_TYPE must name the generated Term type"
#endif
#ifndef SLICE_PAGE_REQUEST_TYPE
#error "SLICE_PAGE_REQUEST_TYPE must name the generated RpcPageRequest type"
#endif
#ifndef SLICE_INSTANT_TYPE
#error "SLICE_INSTANT_TYPE must name the generated Instant type"
#endif
#ifndef SLICE_OPERATION_OCCURRENCE_TYPE
#error "SLICE_OPERATION_OCCURRENCE_TYPE must name the generated OperationOccurrence type"
#endif
#ifndef SLICE_WITHDRAWAL_TYPE
#error "SLICE_WITHDRAWAL_TYPE must name the generated Withdrawal type"
#endif

typedef SLICE_ANY_TYPE slice_any;
typedef SLICE_TRIPLE_TYPE slice_triple;
typedef SLICE_TERM_TYPE slice_term;
typedef SLICE_PAGE_REQUEST_TYPE slice_page_request;
typedef SLICE_INSTANT_TYPE slice_instant;
typedef SLICE_OPERATION_OCCURRENCE_TYPE slice_operation_occurrence;
typedef SLICE_WITHDRAWAL_TYPE slice_withdrawal;

/* Any variant tags, in store.types collection order. */
#define ANY_TAG_BOOL INT64_C(0)
#define ANY_TAG_I64 INT64_C(1)
#define ANY_TAG_F64 INT64_C(2)
#define ANY_TAG_TEXT INT64_C(3)
#define ANY_TAG_KEYWORD INT64_C(4)
#define ANY_TAG_NIL INT64_C(5)
#define ANY_TAG_INSTANT INT64_C(6)
#define ANY_TAG_TRIPLE INT64_C(7)
#define ANY_TAG_COMMIT_OPERATION INT64_C(21)
#define ANY_TAG_OPERATION_OCCURRENCE INT64_C(23)
#define ANY_TAG_WITHDRAWAL INT64_C(24)

/* Term variant tags, in store.types collection order. */
#define TERM_TAG_TEXT INT64_C(0)
#define TERM_TAG_I64 INT64_C(1)
#define TERM_TAG_KEYWORD INT64_C(4)
#define TERM_TAG_TRIPLE INT64_C(6)

/* Arms of a nullable field (Term?): present carries the value, nil does not. */
#define NULLABLE_TAG_PRESENT INT64_C(0)
#define NULLABLE_TAG_NIL INT64_C(1)

static slice_any any_reference(int64_t tag, void *target) {
  slice_any value;
  value.tag = tag;
  if (tag == ANY_TAG_INSTANT) {
    value.payload.variant_6 = target;
  } else if (tag == ANY_TAG_TRIPLE) {
    value.payload.variant_7 = target;
  } else if (tag == ANY_TAG_OPERATION_OCCURRENCE) {
    value.payload.variant_23 = target;
  } else if (tag == ANY_TAG_WITHDRAWAL) {
    value.payload.variant_24 = target;
  } else {
    value.payload.variant_21 = target;
  }
  return value;
}

static slice_any any_bool(bool boolean) {
  slice_any value = {
    .tag = ANY_TAG_BOOL, .payload = { .variant_0 = boolean }
  };
  return value;
}

static slice_any any_i64(int64_t number) {
  slice_any value = {
    .tag = ANY_TAG_I64, .payload = { .variant_1 = number }
  };
  return value;
}

static slice_any any_f64(double number) {
  slice_any value = {
    .tag = ANY_TAG_F64, .payload = { .variant_2 = number }
  };
  return value;
}

static slice_any any_text(uint64_t handle) {
  slice_any value = {
    .tag = ANY_TAG_TEXT, .payload = { .variant_3 = handle }
  };
  return value;
}

static slice_any any_keyword(uint64_t keyword) {
  slice_any value = {
    .tag = ANY_TAG_KEYWORD, .payload = { .variant_4 = keyword }
  };
  return value;
}

static uint64_t keyword_of(native_arena *arena, const char *spelling) {
  uint8_t *bytes = NULL;
  uint64_t length = (uint64_t)strlen(spelling);
  uint64_t handle = native_text_alloc(arena, length, &bytes);
  if (length != UINT64_C(0)) {
    memcpy(bytes, spelling, (size_t)length);
  }
  return handle;
}

static slice_any any_nil(void) {
  slice_any value = { .tag = ANY_TAG_NIL };
  return value;
}

/* An RpcPageRequest whose cursor is present and carries the given Term. */
static slice_page_request page_request(slice_term cursor) {
  slice_page_request request;
  request.field_0 = INT64_C(10);
  request.field_1.tag = NULLABLE_TAG_PRESENT;
  request.field_1.payload.variant_0 = cursor;
  return request;
}

static slice_term term_text(uint64_t handle) {
  slice_term term;
  term.tag = TERM_TAG_TEXT;
  term.payload.variant_0 = handle;
  return term;
}

static slice_term term_keyword(uint64_t keyword) {
  slice_term term;
  term.tag = TERM_TAG_KEYWORD;
  term.payload.variant_4 = keyword;
  return term;
}

static slice_term term_i64(int64_t number) {
  slice_term term;
  term.tag = TERM_TAG_I64;
  term.payload.variant_1 = number;
  return term;
}

static slice_term term_triple(void *target) {
  slice_term term;
  term.tag = TERM_TAG_TRIPLE;
  term.payload.variant_6 = target;
  return term;
}

int main(int argc, char **argv) {
  uint8_t storage[UINT16_MAX];
  native_arena arena;
  native_capability capability = { UINT64_C(0) };
  native_arena_init(&arena, storage, sizeof(storage));

  slice_instant moment = { INT64_C(0), INT64_C(0) };
  slice_any as_instant = any_reference(ANY_TAG_INSTANT, &moment);
  slice_any as_triple = any_reference(ANY_TAG_TRIPLE, &moment);
  slice_any as_operation = any_reference(ANY_TAG_COMMIT_OPERATION, &moment);
  slice_any as_number = any_i64(INT64_C(42));
  uint64_t custom = keyword_of(&arena, "custom");
  uint64_t tx_sequence =
    keyword_of(&arena, "kernel/tx-sequence");
  uint64_t op_ordinal = keyword_of(&arena, "kernel/op-ordinal");
  uint64_t assert_action = keyword_of(&arena, "assert");
  uint64_t retract_action = keyword_of(&arena, "retract");
  uint64_t recorded_at = keyword_of(&arena, "kernel/recorded-at");

  if ((argc > 1) && (argv[1][0] == 't')) {
    /* nanoseconds outside [0, 1000000000) must trap, never return */
    native_m0_fn_1(INT64_C(7), INT64_C(1000000000));
    return 9;
  }
  if ((argc > 1) && (argv[1][0] == 'o')) {
    /* INT64_MAX + 1 must answer the overflow tag, whose arm traps. Returning
       here at all would mean a wrapped value escaped the checked add. */
    slice_instant edge = { INT64_MAX, INT64_C(0) };
    slice_instant escaped = native_m0_fn_2(edge, INT64_C(1));
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

  slice_instant built = native_m0_fn_1(INT64_C(-5), INT64_C(999999999));
  if ((built.field_0 != INT64_C(-5)) || (built.field_1 != INT64_C(999999999))) {
    return 7;
  }
  slice_instant zero = native_m0_fn_1(INT64_C(0), INT64_C(0));
  if ((zero.field_0 != INT64_C(0)) || (zero.field_1 != INT64_C(0))) {
    return 8;
  }

  /* checked add: the ok arm carries the exact sum and leaves nanos alone */
  slice_instant shifted = native_m0_fn_2(built, INT64_C(90));
  if ((shifted.field_0 != INT64_C(85)) ||
      (shifted.field_1 != INT64_C(999999999))) {
    return 12;
  }
  slice_instant back = native_m0_fn_2(shifted, INT64_C(-90));
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
  slice_instant near = { INT64_MAX - INT64_C(1), INT64_C(0) };
  slice_instant edge = native_m0_fn_2(near, INT64_C(1));
  if (edge.field_0 != INT64_MAX) {
    return 16;
  }

  /* Term? -> Any widening preserves each payload and maps absence to nil. */
  {
    slice_any widened =
      native_m0_fn_11(page_request(term_i64(INT64_C(77))));
    if ((widened.tag != ANY_TAG_I64) ||
        (widened.payload.variant_1 != INT64_C(77))) {
      return 17;
    }
  }
  {
    slice_any widened =
      native_m0_fn_11(page_request(term_triple(&moment)));
    if ((widened.tag != ANY_TAG_TRIPLE) ||
        (widened.payload.variant_7 != &moment)) {
      return 18;
    }
  }
  {
    slice_page_request absent;
    absent.field_0 = INT64_C(10);
    absent.field_1.tag = NULLABLE_TAG_NIL;
    absent.field_1.payload.variant_1.tag = INT64_C(0); /* the sole Nil arm */
    slice_any widened = native_m0_fn_11(absent);
    if (widened.tag != ANY_TAG_NIL) {
      return 19;
    }
  }

  uint8_t *space_bytes = NULL;
  uint64_t space = native_text_alloc(&arena, UINT64_C(5), &space_bytes);
  memcpy(space_bytes, "space", 5);

  /* The nested predicate tree distinguishes every scalar tag without
     extracting the wrong union arm. */
  if (!native_m0_fn_21(any_bool(true)) ||
      !native_m0_fn_21(any_i64(INT64_C(9))) ||
      !native_m0_fn_21(any_f64(3.25)) ||
      !native_m0_fn_21(any_text(space)) ||
      !native_m0_fn_21(any_keyword(custom)) ||
      !native_m0_fn_21(as_instant)) {
    return 20;
  }
  if (native_m0_fn_21(any_nil()) || native_m0_fn_21(as_triple)) {
    return 21;
  }

  /* Constructing a recursive Term boxes the by-value Triple into the arena.
     triple takes t1/t2/t3 as Term and widens each slot into the Triple's Any. */
  slice_triple scalar_triple = native_m0_fn_23(
    &arena, &capability, term_text(space), term_keyword(custom),
    term_i64(INT64_C(2)));
  slice_any scalar_triple_ref =
    any_reference(ANY_TAG_TRIPLE, &scalar_triple);
  if (!native_m0_fn_22(scalar_triple_ref)) {
    return 22;
  }
  slice_triple invalid_term = {
    any_nil(), any_i64(INT64_C(1)), any_i64(INT64_C(2))
  };
  if (native_m0_fn_22(any_reference(ANY_TAG_TRIPLE, &invalid_term))) {
    return 23;
  }

  /* Boundary coercion wraps text, keyword, and integer values into Any; the
     predicate then checks and extracts them before comparing. */
  slice_triple tx =
    native_m0_fn_24(&arena, &capability, space, INT64_C(9));
  if ((tx.field_0.tag != ANY_TAG_TEXT) ||
      (tx.field_0.payload.variant_3 != space) ||
      (tx.field_1.tag != ANY_TAG_KEYWORD) ||
      (tx.field_1.payload.variant_4 == tx_sequence) ||
      !native_text_eq(tx.field_1.payload.variant_4, tx_sequence) ||
      (tx.field_2.tag != ANY_TAG_I64) ||
      (tx.field_2.payload.variant_1 != INT64_C(9)) ||
      !native_m0_fn_25(any_reference(ANY_TAG_TRIPLE, &tx))) {
    return 24;
  }
  slice_triple dynamic_tx_predicate = tx;
  dynamic_tx_predicate.field_1 = any_keyword(tx_sequence);
  if (!native_m0_fn_25(any_reference(ANY_TAG_TRIPLE, &dynamic_tx_predicate))) {
    return 25;
  }
  slice_triple wrong_predicate = tx;
  wrong_predicate.field_1 = any_keyword(custom);
  if (native_m0_fn_25(any_reference(ANY_TAG_TRIPLE, &wrong_predicate))) {
    return 26;
  }

  /* Passing a direct Triple where Any is required emits an arena-owned box. */
  slice_triple occurrence =
    native_m0_fn_26(&arena, &capability, tx, INT64_C(3));
  if ((occurrence.field_0.tag != ANY_TAG_TRIPLE) ||
      (occurrence.field_0.payload.variant_7 == NULL) ||
      (occurrence.field_1.tag != ANY_TAG_KEYWORD) ||
      (occurrence.field_1.payload.variant_4 == op_ordinal) ||
      !native_text_eq(occurrence.field_1.payload.variant_4, op_ordinal) ||
      (occurrence.field_2.tag != ANY_TAG_I64) ||
      (occurrence.field_2.payload.variant_1 != INT64_C(3)) ||
      !native_m0_fn_27(any_reference(ANY_TAG_TRIPLE, &occurrence))) {
    return 27;
  }
  slice_triple dynamic_occurrence_predicate = occurrence;
  dynamic_occurrence_predicate.field_1 = any_keyword(op_ordinal);
  if (!native_m0_fn_27(
        any_reference(ANY_TAG_TRIPLE, &dynamic_occurrence_predicate))) {
    return 28;
  }
  slice_triple *boxed_tx = occurrence.field_0.payload.variant_7;
  if ((boxed_tx->field_0.tag != ANY_TAG_TEXT) ||
      (boxed_tx->field_0.payload.variant_3 != space)) {
    return 29;
  }

  /* Current Beagle Store keeps assertion/retraction history out of Term. */
  slice_triple later =
    native_m0_fn_26(&arena, &capability, tx, INT64_C(4));
  slice_triple recorded =
    native_m0_fn_28(&arena, &capability, tx, moment);
  if (!native_text_eq(recorded.field_1.payload.variant_4, recorded_at)) {
    return 30;
  }

  if (!native_m0_fn_29(&arena, &capability, occurrence, later) ||
      native_m0_fn_29(&arena, &capability, later, occurrence)) {
    return 31;
  }

  slice_operation_occurrence assertion = native_m0_fn_30(
    &arena, &capability, occurrence, assert_action, scalar_triple);
  slice_operation_occurrence retraction = native_m0_fn_30(
    &arena, &capability, later, retract_action, scalar_triple);
  slice_any assertion_ref =
    any_reference(ANY_TAG_OPERATION_OCCURRENCE, &assertion);
  slice_any retraction_ref =
    any_reference(ANY_TAG_OPERATION_OCCURRENCE, &retraction);
  if (!native_m0_fn_31(&arena, &capability, assertion_ref) ||
      native_m0_fn_31(&arena, &capability, retraction_ref) ||
      !native_m0_fn_32(&arena, &capability, retraction_ref) ||
      native_m0_fn_32(&arena, &capability, assertion_ref)) {
    return 32;
  }

  slice_withdrawal withdrawal = native_m0_fn_33(
    &arena, &capability, retraction, assertion);
  if (!native_m0_fn_20(any_reference(ANY_TAG_WITHDRAWAL, &withdrawal)) ||
      !native_m0_fn_19(assertion_ref)) {
    return 33;
  }
  return 0;
}
