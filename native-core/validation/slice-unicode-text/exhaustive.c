#include "native_shim.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define ARENA_BYTES 1024U
#define OUTPUT_BUFFER_BYTES (1024U * 1024U)

static size_t encode_scalar(uint32_t codepoint, uint8_t bytes[4]) {
  if (codepoint <= UINT32_C(0x7f)) {
    bytes[0] = (uint8_t)codepoint;
    return 1U;
  }
  if (codepoint <= UINT32_C(0x7ff)) {
    bytes[0] = (uint8_t)(UINT32_C(0xc0) | (codepoint >> 6));
    bytes[1] = (uint8_t)(UINT32_C(0x80) | (codepoint & UINT32_C(0x3f)));
    return 2U;
  }
  if (codepoint <= UINT32_C(0xffff)) {
    bytes[0] = (uint8_t)(UINT32_C(0xe0) | (codepoint >> 12));
    bytes[1] =
        (uint8_t)(UINT32_C(0x80) | ((codepoint >> 6) & UINT32_C(0x3f)));
    bytes[2] = (uint8_t)(UINT32_C(0x80) | (codepoint & UINT32_C(0x3f)));
    return 3U;
  }
  bytes[0] = (uint8_t)(UINT32_C(0xf0) | (codepoint >> 18));
  bytes[1] =
      (uint8_t)(UINT32_C(0x80) | ((codepoint >> 12) & UINT32_C(0x3f)));
  bytes[2] =
      (uint8_t)(UINT32_C(0x80) | ((codepoint >> 6) & UINT32_C(0x3f)));
  bytes[3] = (uint8_t)(UINT32_C(0x80) | (codepoint & UINT32_C(0x3f)));
  return 4U;
}

static uint64_t text_from_bytes(native_arena *arena, const uint8_t *bytes,
                                size_t length) {
  uint8_t *destination = NULL;
  uint64_t result = native_text_alloc(arena, (uint64_t)length, &destination);
  if (length != 0U) {
    memcpy(destination, bytes, length);
  }
  return result;
}

static int emit_scalar(native_arena *arena, uint32_t codepoint) {
  static const uint8_t pattern_bytes[] = "[\\p{L}\\p{Nd}]+";
  uint8_t source_bytes[4];
  uint8_t record[UINT8_MAX + 2U];
  size_t source_length = encode_scalar(codepoint, source_bytes);
  uint64_t source = text_from_bytes(arena, source_bytes, source_length);
  uint64_t pattern = text_from_bytes(arena, pattern_bytes,
                                     sizeof pattern_bytes - 1U);
  native_vec *runs = native_text_letter_decimal_runs(arena, source, pattern);
  int64_t run_count = native_vec_length(runs);
  uint64_t lowered = native_text_lower_root(arena, source);
  uint64_t lowered_length = native_text_length(lowered);

  if ((run_count < INT64_C(0)) || (run_count > INT64_C(1)) ||
      (lowered_length > UINT64_C(255))) {
    return 1;
  }
  record[0] = (run_count == INT64_C(1)) ? UINT8_C(1) : UINT8_C(0);
  if (run_count == INT64_C(1)) {
    uint64_t run;
    memcpy(&run, native_vec_at(runs, INT64_C(0), INT64_C(8)), sizeof run);
    if ((native_text_length(run) != (uint64_t)source_length) ||
        (memcmp(native_text_bytes(run), source_bytes, source_length) != 0)) {
      return 1;
    }
  }
  record[1] = (uint8_t)lowered_length;
  if (lowered_length != UINT64_C(0)) {
    memcpy(record + 2U, native_text_bytes(lowered), (size_t)lowered_length);
  }
  return fwrite(record, 1U, (size_t)lowered_length + 2U, stdout) ==
                 (size_t)lowered_length + 2U
             ? 0
             : 1;
}

int main(void) {
  static uint8_t arena_storage[ARENA_BYTES];
  static char output_buffer[OUTPUT_BUFFER_BYTES];
  native_arena arena;
  uint32_t codepoint;

  if (setvbuf(stdout, output_buffer, _IOFBF, sizeof output_buffer) != 0) {
    return 1;
  }
  native_arena_init(&arena, arena_storage, sizeof arena_storage);
  for (codepoint = UINT32_C(0); codepoint <= UINT32_C(0x10ffff);
       codepoint += UINT32_C(1)) {
    if ((codepoint >= UINT32_C(0xd800)) &&
        (codepoint <= UINT32_C(0xdfff))) {
      continue;
    }
    native_arena_reset(&arena);
    if (emit_scalar(&arena, codepoint) != 0) {
      return 1;
    }
  }
  return fflush(stdout) == 0 ? 0 : 1;
}
