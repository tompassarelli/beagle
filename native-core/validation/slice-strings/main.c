/* Probe for the lowered native.text-ops bodies. Hand-written; the module under
   it is generated. With any argument it takes the out-of-range subs path
   instead, which must trap rather than return.
   fn_0 text-equal?  fn_1 text-length  fn_2 text-slice  fn_3 text-tail
   fn_4 text-join    fn_5 labelled     fn_6 keyword-equal?
   fn_7 assert-action?  fn_8 retract-action?  fn_9 prefix-is?
   fn_10 tagged      fn_11 strip-at    fn_12 any-three?  fn_13 all-three?
   fn_14 any-none?   fn_15 all-none?   fn_16 any-one?    fn_17 all-one?
   fn_18 any-short-circuits?            fn_19 all-short-circuits?
   type_1 Int  type_2 Bool  type_3 Text  type_4 Keyword */
#include "module_0.h"

static uint8_t storage[1u << 16];
static native_arena arena;
static const native_capability capability = { UINT64_C(0) };

/* A fresh arena blob per call, so equal bytes never share a handle. */
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
  if (native_text_length(handle) != (uint64_t)length) {
    return false;
  }
  if (length == 0u) {
    return true;
  }
  return memcmp(native_text_bytes(handle), bytes, length) == 0;
}

int main(int argc, char **argv) {
  native_m0_type_3 hello_a;
  native_m0_type_3 hello_b;
  native_m0_type_3 hell;
  native_m0_type_3 empty;

  (void)argv;
  native_arena_init(&arena, storage, sizeof storage);
  hello_a = text_of("hello");
  hello_b = text_of("hello");
  hell = text_of("hell");
  empty = text_of("");

  if (argc > 1) {
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
    native_m0_type_3 ell =
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
  return 0;
}
