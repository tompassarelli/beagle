/* Probe for the coercion rule. Hand-written; the module under it is generated.
   With the argument "mismatch" it hands a checked extract a value carrying the
   wrong tag, which must trap instead of reading the payload as a reference.
   fn_0 pair?  fn_1 wrap-int  fn_2 pair-left-of  fn_3 pair-right-of
   fn_4 any-equal? fn_5 any-hash fn_6 any-compare fn_7 pair-copy-of
   fn_8..19 logic probes; fn_26..31 exact Bool predicate probes;
   fn_32..43 numeric scalar probes; fn_44..46 vector predicates;
   fn_47 text suffix.
   Any tags: 0 bool, 1 i64, 2 f64, 3 text, 4 keyword, 5 nil, 6 Pair. */
#include <math.h>
#include "module_0.h"

#ifndef SLICE_ANY_TYPE
#error "SLICE_ANY_TYPE must name the generated Any type"
#endif
#ifndef SLICE_NIL_TYPE
#error "SLICE_NIL_TYPE must name the generated Nil type"
#endif
#ifndef SLICE_PAIR_TYPE
#error "SLICE_PAIR_TYPE must name the generated Pair type"
#endif

typedef SLICE_ANY_TYPE slice_any;
typedef SLICE_NIL_TYPE slice_nil_value;
typedef SLICE_PAIR_TYPE slice_pair_value;

#define ARENA_BYTES ((size_t)16384)

static uint8_t arena_storage[ARENA_BYTES];

struct slice_text_blob {
  uint64_t length;
  uint8_t bytes[3];
};

static const struct slice_text_blob text_abc_left = {
  UINT64_C(3), { UINT8_C('a'), UINT8_C('b'), UINT8_C('c') }
};
static const struct slice_text_blob text_abc_right = {
  UINT64_C(3), { UINT8_C('a'), UINT8_C('b'), UINT8_C('c') }
};
static const struct slice_text_blob text_abd = {
  UINT64_C(3), { UINT8_C('a'), UINT8_C('b'), UINT8_C('d') }
};

struct slice_text_blob_2 {
  uint64_t length;
  uint8_t bytes[2];
};

static const struct slice_text_blob_2 text_42 = {
  UINT64_C(2), { UINT8_C('4'), UINT8_C('2') }
};

static slice_any slice_pair(void *target) {
  slice_any value;
  value.tag = INT64_C(6);
  value.payload.variant_6 = target;
  return value;
}

static slice_any slice_i64(int64_t number) {
  slice_any value;
  value.tag = INT64_C(1);
  value.payload.variant_1 = number;
  return value;
}

static slice_any slice_f64(double number) {
  slice_any value;
  value.tag = INT64_C(2);
  value.payload.variant_2 = number;
  return value;
}

static slice_any slice_text(const struct slice_text_blob *blob) {
  slice_any value;
  value.tag = INT64_C(3);
  value.payload.variant_3 = (uint64_t)(uintptr_t)blob;
  return value;
}

static slice_any slice_bool(bool flag) {
  slice_any value;
  value.tag = INT64_C(0);
  value.payload.variant_0 = flag;
  return value;
}

static slice_any slice_nil(void) {
  slice_any value = { .tag = INT64_C(5) };
  return value;
}

static uint64_t text_value(native_arena *arena, const char *value) {
  uint8_t *bytes;
  size_t length = strlen(value);
  uint64_t handle = native_text_alloc(arena, (uint64_t)length, &bytes);
  if (length > 0U) {
    memcpy(bytes, value, length);
  }
  return handle;
}

int main(int argc, char **argv) {
  native_arena arena;
  slice_pair_value pair = { INT64_C(3), INT64_C(4) };
  slice_pair_value equal_pair = { INT64_C(3), INT64_C(4) };
  slice_pair_value different_pair = { INT64_C(3), INT64_C(5) };
  slice_any as_pair = slice_pair(&pair);
  slice_any as_equal_pair = slice_pair(&equal_pair);
  slice_any as_different_pair = slice_pair(&different_pair);
  slice_any as_number = slice_i64(INT64_C(42));
  slice_any as_zero = slice_f64(0.0);
  slice_any as_negative_zero = slice_f64(-0.0);
  slice_any as_abc_left = slice_text(&text_abc_left);
  slice_any as_abc_right = slice_text(&text_abc_right);
  slice_any as_abd = slice_text(&text_abd);
  slice_any as_false = slice_bool(false);
  slice_any as_true = slice_bool(true);
  slice_any as_nil = slice_nil();

  native_arena_init(&arena, arena_storage, ARENA_BYTES);

  if ((argc > 1) && (argv[1][0] == 'n')) {
    native_m0_fn_7(slice_pair(NULL));
    return 10;
  }

  if ((argc > 1) && (argv[1][0] == 'd')) {
    native_m0_fn_35(as_abc_left);
    return 11;
  }

  if ((argc > 1) && (argv[1][0] == 'm')) {
    /* the extract expects the Pair tag and this value carries i64 */
    native_m0_fn_2(as_number);
    return 9;
  }

  /* tag inject: a concrete Int widens into the closed Any union */
  slice_any wrapped = native_m0_fn_1(INT64_C(42));
  if ((wrapped.tag != INT64_C(1)) || (wrapped.payload.variant_1 != INT64_C(42))) {
    return 1;
  }

  /* checked extract: the payload comes back out as the Pair reference and the
     field read goes through it */
  if (native_m0_fn_2(as_pair) != INT64_C(3)) {
    return 2;
  }
  if (native_m0_fn_3(as_pair) != INT64_C(4)) {
    return 3;
  }

  if (!native_m0_fn_0(as_pair)) {
    return 4;
  }
  if (native_m0_fn_0(as_number) || native_m0_fn_0(wrapped)) {
    return 5;
  }
  if (!native_m0_fn_4(as_pair, as_equal_pair)
      || native_m0_fn_4(as_pair, as_different_pair)
      || native_m0_fn_4(as_pair, as_number)
      || !native_m0_fn_4(as_number, wrapped)
      || !native_m0_fn_4(as_zero, as_negative_zero)
      || !native_m0_fn_4(as_abc_left, as_abc_right)) {
    return 6;
  }
  if ((native_m0_fn_5(as_pair) != native_m0_fn_5(as_equal_pair))
      || (native_m0_fn_5(as_number) != native_m0_fn_5(wrapped))
      || (native_m0_fn_5(as_zero) != native_m0_fn_5(as_negative_zero))
      || (native_m0_fn_5(as_abc_left) != native_m0_fn_5(as_abc_right))
      || (native_m0_fn_5(as_number) != INT64_C(6352684378363895460))
      || (native_m0_fn_5(as_pair) != INT64_C(491762441038723618))
      || (native_m0_fn_5(as_abc_left) != INT64_C(4838897213494911832))) {
    return 7;
  }
  if ((native_m0_fn_6(as_pair, as_equal_pair) != INT64_C(0))
      || (native_m0_fn_6(as_pair, as_different_pair) >= INT64_C(0))
      || (native_m0_fn_6(as_different_pair, as_pair) <= INT64_C(0))
      || (native_m0_fn_6(as_number, as_pair) >= INT64_C(0))
      || (native_m0_fn_6(as_zero, as_negative_zero) != INT64_C(0))
      || (native_m0_fn_6(as_abc_left, as_abc_right) != INT64_C(0))
      || (native_m0_fn_6(as_abc_left, as_abd) >= INT64_C(0))) {
    return 8;
  }
  slice_pair_value copied_pair = native_m0_fn_7(as_pair);
  if ((copied_pair.field_0 != INT64_C(3)) ||
      (copied_pair.field_1 != INT64_C(4))) {
    return 9;
  }

  slice_any result = native_m0_fn_8(as_number, as_pair);
  if ((result.tag != INT64_C(6)) || (result.payload.variant_6 != &pair)) {
    return 10;
  }
  result = native_m0_fn_8(as_nil, as_number);
  if (result.tag != INT64_C(5)) {
    return 11;
  }
  result = native_m0_fn_8(as_false, as_number);
  if ((result.tag != INT64_C(0)) || result.payload.variant_0) {
    return 12;
  }

  result = native_m0_fn_9(as_number, as_pair);
  if ((result.tag != INT64_C(1)) || (result.payload.variant_1 != INT64_C(42))) {
    return 13;
  }
  result = native_m0_fn_9(as_nil, as_pair);
  if ((result.tag != INT64_C(6)) || (result.payload.variant_6 != &pair)) {
    return 14;
  }

  result = native_m0_fn_10(as_number, as_pair, as_abc_left);
  if ((result.tag != INT64_C(3))
      || (result.payload.variant_3 != (uint64_t)(uintptr_t)&text_abc_left)) {
    return 15;
  }
  result = native_m0_fn_10(as_number, as_nil, as_abc_left);
  if (result.tag != INT64_C(5)) {
    return 16;
  }
  result = native_m0_fn_11(as_nil, as_false, as_abc_left);
  if ((result.tag != INT64_C(3))
      || (result.payload.variant_3 != (uint64_t)(uintptr_t)&text_abc_left)) {
    return 17;
  }
  result = native_m0_fn_11(as_nil, as_number, as_abc_left);
  if ((result.tag != INT64_C(1)) || (result.payload.variant_1 != INT64_C(42))) {
    return 18;
  }

  result = native_m0_fn_12(INT64_C(42));
  if ((result.tag != INT64_C(1)) || (result.payload.variant_1 != INT64_C(42))) {
    return 19;
  }
  result = native_m0_fn_13(INT64_C(42));
  if ((result.tag != INT64_C(1)) || (result.payload.variant_1 != INT64_C(42))) {
    return 20;
  }
  if (!native_m0_fn_14()) {
    return 21;
  }
  slice_nil_value empty_or = native_m0_fn_15();
  if (empty_or.tag != INT64_C(0)) {
    return 22;
  }

  result = native_m0_fn_16(as_pair);
  if ((result.tag != INT64_C(6)) || (result.payload.variant_6 != &pair)) {
    return 23;
  }
  result = native_m0_fn_17(as_number);
  if ((result.tag != INT64_C(1)) || (result.payload.variant_1 != INT64_C(42))) {
    return 24;
  }
  result = native_m0_fn_18(as_number);
  if ((result.tag != INT64_C(1)) || (result.payload.variant_1 != INT64_C(42))) {
    return 25;
  }
  result = native_m0_fn_19(as_nil);
  if (result.tag != INT64_C(5)) {
    return 26;
  }
  if (!native_m0_fn_26(false) || native_m0_fn_26(true)) {
    return 27;
  }
  if (!native_m0_fn_27(true) || native_m0_fn_27(false)) {
    return 28;
  }
  if (!native_m0_fn_28(as_false)
      || native_m0_fn_28(as_true)
      || native_m0_fn_28(as_nil)
      || native_m0_fn_28(as_number)
      || native_m0_fn_28(as_pair)) {
    return 29;
  }
  if (!native_m0_fn_29(as_true)
      || native_m0_fn_29(as_false)
      || native_m0_fn_29(as_nil)
      || native_m0_fn_29(as_number)
      || native_m0_fn_29(as_pair)) {
    return 30;
  }
  if (native_m0_fn_30(INT64_C(0)) || native_m0_fn_30(INT64_C(1))) {
    return 31;
  }
  if (native_m0_fn_31(INT64_C(0)) || native_m0_fn_31(INT64_C(1))) {
    return 32;
  }
  if (native_m0_fn_32() != 1.5) {
    return 33;
  }
  if ((native_m0_fn_33(INT64_C(42)) != 42.0)
      || (native_m0_fn_33(INT64_C(9007199254740993))
        != 9007199254740992.0)) {
    return 34;
  }
  if ((native_m0_fn_34(3.25) != 3.25)
      || !signbit(native_m0_fn_34(-0.0))
      || !isnan(native_m0_fn_34(NAN))) {
    return 35;
  }
  if ((native_m0_fn_35(as_number) != 42.0)
      || !signbit(native_m0_fn_35(as_negative_zero))) {
    return 36;
  }
  if (!native_m0_fn_36(2.5, 2.5)
      || !native_m0_fn_36(0.0, -0.0)
      || native_m0_fn_36(NAN, NAN)) {
    return 37;
  }
  if (!native_m0_fn_37(1.0, 2.0)
      || native_m0_fn_37(2.0, 1.0)
      || native_m0_fn_37(NAN, 1.0)) {
    return 38;
  }
  if (!native_m0_fn_38(1.0, 1.0)
      || !native_m0_fn_38(1.0, 2.0)
      || native_m0_fn_38(NAN, 1.0)) {
    return 39;
  }
  if (!native_m0_fn_39(2.0, 1.0)
      || native_m0_fn_39(1.0, 2.0)
      || native_m0_fn_39(NAN, 1.0)) {
    return 40;
  }
  if (!native_m0_fn_40(2.0, 2.0)
      || !native_m0_fn_40(2.0, 1.0)
      || native_m0_fn_40(NAN, 1.0)) {
    return 41;
  }

  uint64_t text_42_address = (uint64_t)(uintptr_t)&text_42;
  uint64_t text_abc_address = (uint64_t)(uintptr_t)&text_abc_left;
  if ((native_m0_fn_41(text_42_address) != INT64_C(42))
      || (native_m0_fn_41(text_abc_address) != -INT64_C(1))) {
    return 42;
  }
  if ((native_m0_fn_42(slice_text((const struct slice_text_blob *)&text_42))
        != INT64_C(42))
      || (native_m0_fn_42(as_abc_left) != -INT64_C(1))
      || (native_m0_fn_42(as_number) != -INT64_C(2))) {
    return 43;
  }
  if (!native_m0_fn_43(INT64_C(1), INT64_C(2))
      || native_m0_fn_43(INT64_C(2), INT64_C(1))) {
    return 44;
  }
  {
    native_vec *values =
        native_vec_new(&arena, INT64_C(0), INT64_C(8), (size_t)8);
    if (!native_m0_fn_45(values) || native_m0_fn_46(INT64_C(42))) {
      return 45;
    }
  }
  {
    uint64_t alphabet = text_value(&arena, "alphabet");
    uint64_t alpha = text_value(&arena, "alpha");
    uint64_t bet = text_value(&arena, "bet");
    uint64_t empty = text_value(&arena, "");
    uint64_t snowman = text_value(&arena, "snow\xE9\x9B\xAA\xE4\xBA\xBA");
    uint64_t person = text_value(&arena, "\xE4\xBA\xBA");
    if (!native_m0_fn_47(alphabet, bet) ||
        native_m0_fn_47(alphabet, alpha) ||
        !native_m0_fn_47(alphabet, alphabet) ||
        !native_m0_fn_47(alphabet, empty) ||
        !native_m0_fn_47(empty, empty) ||
        native_m0_fn_47(empty, bet) ||
        !native_m0_fn_47(snowman, person)) {
      return 46;
    }
  }
  return 0;
}
