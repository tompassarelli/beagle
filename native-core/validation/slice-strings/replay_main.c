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

static native_m0_type_3 vector_text(native_m0_type_9 values, int64_t index) {
  return *(const native_m0_type_3 *)native_vec_at(values, index, INT64_C(8));
}

int main(void) {
  native_m0_type_3 text;
  native_m0_type_3 separator;
  native_m0_type_3 result;
  native_m0_type_9 parts;
  native_m0_type_4 parsed;

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
  if (!text_is(native_m0_fn_9(&arena, &capability, text_of("@root")), "root")) {
    return 15;
  }
  if (!text_is(native_m0_fn_9(&arena, &capability, text_of("root")), "root")) {
    return 16;
  }
  return 0;
}
