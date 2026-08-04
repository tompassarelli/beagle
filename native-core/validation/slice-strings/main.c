/* Probe for the lowered native.text-ops bodies. Hand-written; the module under
   it is generated. With any argument it takes the out-of-range subs path
   instead, which must trap rather than return.
   fn_0 text-equal?  fn_1 text-length  fn_2 text-slice  fn_3 text-tail
   fn_4 text-join    fn_5 labelled     fn_6 keyword-equal?
   fn_7 assert-action?  fn_8 retract-action?  fn_9 prefix-is?
   fn_10 tagged      fn_11 strip-at    fn_12 any-three?  fn_13 all-three?
   fn_14 any-none?   fn_15 all-none?   fn_16 any-one?    fn_17 all-one?
   fn_18 any-short-circuits?            fn_19 all-short-circuits?
   fn_20 trim-byte?  fn_21 global-size  fn_22 parameter-shadow-size
   fn_23 local-shadow-size  fn_24 render-float  fn_25 print-float
   fn_26 render-bool  fn_27 print-text  fn_28 print-int
   fn_29 render-keyword  fn_30 render-nil  fn_31 print-nil
   fn_32 render-text-vector  fn_33 print-text-vector
   fn_34 render-text-map  fn_35 print-text-map
   fn_36 render-printable  fn_37 print-printable
   type_1 Int  type_2 Bool  type_3 Float  type_4 Text  type_5 Keyword
   type_8 Nil  type_9 Map  type_10 Vec  type_11 Printable */
#include "module_0.h"

#include <math.h>

static uint8_t storage[1u << 16];
static native_arena arena;
static const native_capability capability = { UINT64_C(0) };

/* A fresh arena blob per call, so equal bytes never share a handle. */
static native_m0_type_4 text_of(const char *bytes) {
  uint8_t *destination = NULL;
  size_t length = strlen(bytes);
  uint64_t handle = native_text_alloc(&arena, (uint64_t)length, &destination);
  if (length != 0u) {
    memcpy(destination, bytes, length);
  }
  return handle;
}

static bool text_is(native_m0_type_4 handle, const char *bytes) {
  size_t length = strlen(bytes);
  if (native_text_length(handle) != (uint64_t)length) {
    return false;
  }
  if (length == 0u) {
    return true;
  }
  return memcmp(native_text_bytes(handle), bytes, length) == 0;
}

static native_m0_type_11 printable_text(native_m0_type_4 value) {
  native_m0_type_11 result = { 0 };
  result.tag = INT64_C(0);
  result.payload.variant_0 = value;
  return result;
}

static native_m0_type_11 printable_int(native_m0_type_1 value) {
  native_m0_type_11 result = { 0 };
  result.tag = INT64_C(1);
  result.payload.variant_1 = value;
  return result;
}

static native_m0_type_11 printable_float(native_m0_type_3 value) {
  native_m0_type_11 result = { 0 };
  result.tag = INT64_C(2);
  result.payload.variant_2 = value;
  return result;
}

static native_m0_type_11 printable_bool(native_m0_type_2 value) {
  native_m0_type_11 result = { 0 };
  result.tag = INT64_C(3);
  result.payload.variant_3 = value;
  return result;
}

static native_m0_type_11 printable_keyword(native_m0_type_5 value) {
  native_m0_type_11 result = { 0 };
  result.tag = INT64_C(4);
  result.payload.variant_4 = value;
  return result;
}

static native_m0_type_11 printable_nil(void) {
  native_m0_type_11 result = { 0 };
  result.tag = INT64_C(5);
  result.payload.variant_5.tag = INT64_C(0);
  return result;
}

static void stringify_cycle(void) {
  native_value_descriptor cycle = {
    .abi_version = NATIVE_VALUE_ABI_VERSION,
    .kind = NATIVE_VALUE_VECTOR,
    .size = sizeof(native_vec *),
    .alignment = _Alignof(native_vec *),
    .stride = sizeof(native_vec *)
  };
  native_vec *value = NULL;
  cycle.element = &cycle;
  (void)native_value_to_text(&arena, &cycle, &value, NATIVE_VALUE_PR_STR);
}

static void stringify_reference(void) {
  native_value_descriptor reference = {
    .abi_version = NATIVE_VALUE_ABI_VERSION,
    .kind = NATIVE_VALUE_REFERENCE,
    .size = sizeof(void *),
    .alignment = _Alignof(void *)
  };
  void *value = NULL;
  (void)native_value_to_text(&arena, &reference, &value, NATIVE_VALUE_PR_STR);
}

int main(int argc, char **argv) {
  native_m0_type_4 hello_a;
  native_m0_type_4 hello_b;
  native_m0_type_4 hell;
  native_m0_type_4 empty;

  (void)argv;
  native_arena_init(&arena, storage, sizeof storage);
  hello_a = text_of("hello");
  hello_b = text_of("hello");
  hell = text_of("hell");
  empty = text_of("");

  if (argc > 1) {
    if (strcmp(argv[1], "cycle") == 0) {
      stringify_cycle();
      return 97;
    }
    if (strcmp(argv[1], "reference") == 0) {
      stringify_reference();
      return 98;
    }
    /* end beyond the blob must trap, never return */
    (void)native_m0_fn_2(&arena, &capability, hello_a, INT64_C(0), INT64_C(9));
    return 99;
  }

  /* equal bytes, distinct handles: the memcmp path, not handle identity */
  if (hello_a == hello_b) {
    return 1;
  }
  if (!native_m0_fn_0(hello_a, hello_b)) {
    return 2;
  }
  /* identity fast path */
  if (!native_m0_fn_0(hello_a, hello_a)) {
    return 3;
  }
  /* unequal length answers before any byte is read */
  if (native_m0_fn_0(hello_a, hell)) {
    return 4;
  }
  if (native_m0_fn_0(hello_a, empty) || native_m0_fn_0(empty, hello_a)) {
    return 5;
  }
  if (!native_m0_fn_0(empty, text_of(""))) {
    return 6;
  }

  /* count is byte-indexed */
  if (native_m0_fn_1(hello_a) != INT64_C(5)) {
    return 7;
  }
  if (native_m0_fn_1(empty) != INT64_C(0)) {
    return 8;
  }

  /* subs copies into the arena: a new handle carrying the right bytes */
  {
    native_m0_type_4 ell =
        native_m0_fn_2(&arena, &capability, hello_a, INT64_C(1), INT64_C(4));
    if (!text_is(ell, "ell")) {
      return 9;
    }
    if (ell == hello_a) {
      return 10;
    }
    if (!text_is(native_m0_fn_2(&arena, &capability, hello_a, INT64_C(0),
                                INT64_C(5)),
                 "hello")) {
      return 11;
    }
    if (!text_is(native_m0_fn_2(&arena, &capability, hello_a, INT64_C(2),
                                INT64_C(2)),
                 "")) {
      return 12;
    }
    if (!text_is(native_m0_fn_3(&arena, &capability, hello_a, INT64_C(3)),
                 "lo")) {
      return 13;
    }
  }

  /* str concatenation, including Int rendered as decimal */
  if (!text_is(native_m0_fn_4(&arena, &capability, hello_a, hell), "hellohell")) {
    return 14;
  }
  if (!text_is(native_m0_fn_4(&arena, &capability, empty, hello_a), "hello")) {
    return 15;
  }
  if (!text_is(native_m0_fn_5(&arena, &capability, hello_a, INT64_C(42)),
               "hello=42")) {
    return 16;
  }
  if (!text_is(native_m0_fn_5(&arena, &capability, hello_a, INT64_C(0)),
               "hello=0")) {
    return 17;
  }
  if (!text_is(native_m0_fn_5(&arena, &capability, hello_a, INT64_C(-7)),
               "hello=-7")) {
    return 18;
  }
  if (!text_is(native_m0_fn_5(&arena, &capability, hello_a, INT64_MIN),
               "hello=-9223372036854775808")) {
    return 19;
  }
  if (!text_is(native_m0_fn_10(&arena, &capability, hello_a), "<hello>")) {
    return 20;
  }

  /* keyword handles are sealed table indices, compared as integers */
  if (!native_m0_fn_7(UINT64_C(0)) || native_m0_fn_7(UINT64_C(1))) {
    return 21;
  }
  if (!native_m0_fn_8(UINT64_C(1)) || native_m0_fn_8(UINT64_C(0))) {
    return 22;
  }
  if (!native_m0_fn_6(UINT64_C(1), UINT64_C(1)) ||
      native_m0_fn_6(UINT64_C(0), UINT64_C(1))) {
    return 23;
  }

  /* an arena slice compared against a constant-pool blob */
  if (!native_m0_fn_9(&arena, &capability, hello_a, INT64_C(4), hell)) {
    return 24;
  }
  if (native_m0_fn_9(&arena, &capability, hello_a, INT64_C(3), hell)) {
    return 25;
  }

  if (!text_is(native_m0_fn_11(&arena, &capability, text_of("@root")), "root")) {
    return 26;
  }
  if (!text_is(native_m0_fn_11(&arena, &capability, hello_a), "hello")) {
    return 27;
  }
  if (!native_m0_fn_12(false, false, true) ||
      native_m0_fn_12(false, false, false)) {
    return 28;
  }
  if (!native_m0_fn_13(true, true, true) ||
      native_m0_fn_13(true, false, true)) {
    return 29;
  }
  if (native_m0_fn_14()) {
    return 30;
  }
  if (!native_m0_fn_15()) {
    return 31;
  }
  if (!native_m0_fn_16(true) || native_m0_fn_16(false)) {
    return 32;
  }
  if (!native_m0_fn_17(true) || native_m0_fn_17(false)) {
    return 33;
  }
  if (!native_m0_fn_18(&arena, &capability, hello_a)) {
    return 34;
  }
  if (native_m0_fn_19(&arena, &capability, hello_a)) {
    return 35;
  }
  if (!native_m0_fn_20(text_of(" ")) ||
      !native_m0_fn_20(text_of("\t")) ||
      !native_m0_fn_20(text_of("\r")) ||
      native_m0_fn_20(text_of("x"))) {
    return 36;
  }
  if (native_m0_fn_21(&arena, &capability) != INT64_C(2)) {
    return 37;
  }
  if (native_m0_fn_22(text_of("abc")) != INT64_C(3)) {
    return 38;
  }
  if (native_m0_fn_23() != INT64_C(3)) {
    return 39;
  }

  if (!text_is(native_m0_fn_24(&arena, &capability, 1.0), "1.0") ||
      !text_is(native_m0_fn_24(&arena, &capability, 10000000.0), "1.0E7") ||
      !text_is(native_m0_fn_24(&arena, &capability, 0.001), "0.001") ||
      !text_is(native_m0_fn_24(&arena, &capability, 0.0001), "1.0E-4") ||
      !text_is(native_m0_fn_24(&arena, &capability, -0.0), "-0.0") ||
      !text_is(native_m0_fn_24(&arena, &capability, NAN), "NaN") ||
      !text_is(native_m0_fn_24(&arena, &capability, INFINITY), "Infinity") ||
      !text_is(native_m0_fn_24(&arena, &capability, -INFINITY), "-Infinity") ||
      !text_is(native_m0_fn_25(&arena, &capability, 1.25), "1.25")) {
    return 40;
  }
  if (!text_is(native_m0_fn_26(&arena, &capability, true), "true") ||
      !text_is(native_m0_fn_26(&arena, &capability, false), "false")) {
    return 41;
  }
  if (!text_is(native_m0_fn_27(&arena, &capability, text_of("line\n\"")),
               "\"line\\n\\\"\"") ||
      !text_is(native_m0_fn_28(&arena, &capability, INT64_MIN),
               "-9223372036854775808") ||
      !text_is(native_m0_fn_29(&arena, &capability, UINT64_C(0)), ":assert") ||
      !text_is(native_m0_fn_30(&arena, &capability), "") ||
      !text_is(native_m0_fn_31(&arena, &capability), "nil")) {
    return 42;
  }
  {
    native_m0_type_4 items[] = { text_of("alpha"), text_of("line\n\"") };
    native_m0_type_10 vector = native_vec_new(
        &arena, INT64_C(2), (int64_t)sizeof(items[0]), _Alignof(native_m0_type_4));
    vector = native_vec_push(&arena, vector, &items[0],
                             (int64_t)sizeof(items[0]), _Alignof(native_m0_type_4));
    vector = native_vec_push(&arena, vector, &items[1],
                             (int64_t)sizeof(items[1]), _Alignof(native_m0_type_4));
    if (!text_is(native_m0_fn_32(&arena, &capability, vector),
                 "[\"alpha\" \"line\\n\\\"\"]") ||
        !text_is(native_m0_fn_33(&arena, &capability, vector),
                 "[\"alpha\" \"line\\n\\\"\"]")) {
      return 43;
    }
  }
  {
    native_m0_type_5 keys[] = { UINT64_C(1), UINT64_C(0) };
    native_m0_type_4 values[] = { text_of("two"), text_of("line\n\"") };
    native_m0_type_9 map = native_map_from_arrays(
        &arena, keys, values, INT64_C(2), (int64_t)sizeof(keys[0]),
        _Alignof(native_m0_type_5), (int64_t)sizeof(values[0]),
        _Alignof(native_m0_type_4), NATIVE_COLLECTION_EQ_KEYWORD);
    const char *expected = "{:retract \"two\", :assert \"line\\n\\\"\"}";
    if (!text_is(native_m0_fn_34(&arena, &capability, map), expected) ||
        !text_is(native_m0_fn_35(&arena, &capability, map), expected)) {
      return 44;
    }
  }
  if (!text_is(native_m0_fn_36(&arena, &capability,
                               printable_text(text_of("raw"))), "raw") ||
      !text_is(native_m0_fn_37(&arena, &capability,
                               printable_text(text_of("raw"))), "\"raw\"") ||
      !text_is(native_m0_fn_36(&arena, &capability,
                               printable_int(INT64_C(-9))), "-9") ||
      !text_is(native_m0_fn_37(&arena, &capability,
                               printable_float(1.5)), "1.5") ||
      !text_is(native_m0_fn_36(&arena, &capability,
                               printable_bool(false)), "false") ||
      !text_is(native_m0_fn_37(&arena, &capability,
                               printable_keyword(UINT64_C(1))), ":retract") ||
      !text_is(native_m0_fn_36(&arena, &capability, printable_nil()), "") ||
      !text_is(native_m0_fn_37(&arena, &capability, printable_nil()), "nil")) {
    return 45;
  }
  return 0;
}
