#include "module_0.h"

#include <math.h>
#include <string.h>

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

  if (argc > 1) {
    int64_t invalid_bytes[] = {INT64_C(0xc0), INT64_C(0x80)};
    native_vec invalid = {invalid_bytes, INT64_C(2), INT64_C(2)};
    (void)native_m0_fn_1(&arena, &capability, &invalid);
    return 7;
  }
  return 0;
}
