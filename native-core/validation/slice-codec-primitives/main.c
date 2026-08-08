#include "module_0.h"

#include <math.h>
#include <string.h>

static int text_equals(uint64_t value, const char *expected) {
  size_t length = strlen(expected);
  return (native_text_length(value) == (uint64_t)length) &&
         (memcmp(native_text_bytes(value), expected, length) == 0);
}

int main(int argc, char **argv) {
  uint8_t storage[4096];
  native_arena arena;
  native_capability capability = {UINT64_C(1)};
  static const uint8_t sample[] = {
      UINT8_C(0x41), UINT8_C(0xe2), UINT8_C(0x82), UINT8_C(0xac),
      UINT8_C(0xf0), UINT8_C(0x9f), UINT8_C(0x98), UINT8_C(0x80)};
  uint8_t *text_bytes;
  uint64_t text;
  native_vec *encoded;
  uint64_t decoded;
  int64_t index;

  (void)argv;
  native_arena_init(&arena, storage, sizeof storage);
  text = native_text_alloc(&arena, sizeof sample, &text_bytes);
  memcpy(text_bytes, sample, sizeof sample);
  encoded = native_m0_fn_0(&arena, &capability, text);
  if (native_vec_length(encoded) != (int64_t)sizeof sample) {
    return 1;
  }
  for (index = INT64_C(0); index < (int64_t)sizeof sample; index++) {
    int64_t value;
    memcpy(&value, native_vec_at(encoded, index, INT64_C(8)), sizeof value);
    if (value != (int64_t)sample[index]) {
      return 2;
    }
  }
  decoded = native_m0_fn_1(&arena, &capability, encoded);
  if (!native_text_eq(text, decoded)) {
    return 3;
  }
  if (native_m0_fn_2(1.0) != INT64_C(4607182418800017408)) {
    return 4;
  }
  if (native_m0_fn_2(native_float_from_bits(INT64_C(9218868437227405313))) !=
      INT64_C(9221120237041090560)) {
    return 5;
  }
  if (!signbit(native_m0_fn_3(INT64_MIN))) {
    return 6;
  }
  {
    native_vec empty = {NULL, INT64_C(0), INT64_C(0), NULL};
    int64_t abc_values[] = {INT64_C(97), INT64_C(98), INT64_C(99)};
    native_vec abc = {abc_values, INT64_C(3), INT64_C(3), NULL};
    if (!text_equals(
            native_m0_fn_4(&arena, &capability, &empty),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")) {
      return 7;
    }
    if (!text_equals(
            native_m0_fn_4(&arena, &capability, &abc),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")) {
      return 8;
    }
  }

  if (argc > 1) {
    if (strcmp(argv[1], "invalid-sha") == 0) {
      int64_t invalid_sha_bytes[] = {INT64_C(256)};
      native_vec invalid_sha = {invalid_sha_bytes, INT64_C(1), INT64_C(1), NULL};
      (void)native_m0_fn_4(&arena, &capability, &invalid_sha);
      return 9;
    } else {
      int64_t invalid_utf8_bytes[] = {INT64_C(0xc0), INT64_C(0x80)};
      native_vec invalid_utf8 = {invalid_utf8_bytes, INT64_C(2), INT64_C(2), NULL};
      (void)native_m0_fn_1(&arena, &capability, &invalid_utf8);
      return 10;
    }
  }
  return 0;
}
