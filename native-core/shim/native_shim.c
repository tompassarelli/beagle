#include "native_shim.h"

#include <string.h>
#include <stdlib.h>

uint64_t native_vec_storage_allocations = UINT64_C(0);

/* Smallest capacity a first push claims; every later growth doubles, which is
   what keeps a run of n pushes at O(log n) storage allocations. */
#define NATIVE_VEC_MIN_CAPACITY INT64_C(4)

void native_arena_init(native_arena *arena, uint8_t *storage, size_t capacity) {
  if ((arena == NULL) || ((storage == NULL) && (capacity != 0U))) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  arena->bytes = storage;
  arena->capacity = capacity;
  arena->offset = 0U;
}

void *native_arena_alloc(native_arena *arena, size_t size, size_t alignment) {
  if ((arena == NULL) || (alignment == 0U) || ((alignment & (alignment - 1U)) != 0U)) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  if ((arena->offset > arena->capacity) || (arena->offset > (SIZE_MAX - size))) {
    native_trap(NATIVE_TRAP_ARENA_EXHAUSTED);
  }
  uintptr_t base = (uintptr_t)arena->bytes;
  if (base > (UINTPTR_MAX - arena->offset)) {
    native_trap(NATIVE_TRAP_OVERFLOW);
  }
  uintptr_t current = base + arena->offset;
  uintptr_t padding_mask = (uintptr_t)alignment - (uintptr_t)1U;
  if (current > (UINTPTR_MAX - padding_mask)) {
    native_trap(NATIVE_TRAP_OVERFLOW);
  }
  uintptr_t aligned = (current + padding_mask) & ~padding_mask;
  if (aligned < base) {
    native_trap(NATIVE_TRAP_OVERFLOW);
  }
  size_t aligned_offset = (size_t)(aligned - base);
  if ((aligned_offset > arena->capacity) || (size > (arena->capacity - aligned_offset))) {
    native_trap(NATIVE_TRAP_ARENA_EXHAUSTED);
  }
  arena->offset = aligned_offset + size;
  return arena->bytes + aligned_offset;
}

void native_arena_reset(native_arena *arena) {
  if (arena == NULL) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  arena->offset = 0U;
}

_Noreturn void native_trap(uint32_t code) {
  (void)code;
  abort();
}

static size_t native_vec_bytes(int64_t capacity, int64_t stride) {
  if ((capacity < INT64_C(0)) || (stride <= INT64_C(0))) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  if (capacity > (INT64_MAX / stride)) {
    native_trap(NATIVE_TRAP_OVERFLOW);
  }
  return (size_t)(capacity * stride);
}

native_vec *native_vec_new(native_arena *arena, int64_t capacity, int64_t stride,
                           size_t alignment) {
  native_vec *header =
      (native_vec *)native_arena_alloc(arena, sizeof(native_vec), _Alignof(native_vec));
  size_t bytes = native_vec_bytes(capacity, stride);
  header->elements = (bytes == 0U) ? NULL : native_arena_alloc(arena, bytes, alignment);
  header->length = INT64_C(0);
  header->capacity = capacity;
  if (bytes != 0U) {
    native_vec_storage_allocations += UINT64_C(1);
  }
  return header;
}

int64_t native_vec_length(const native_vec *vector) {
  if (vector == NULL) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  return vector->length;
}

const void *native_vec_at(const native_vec *vector, int64_t index, int64_t stride) {
  if ((vector == NULL) || (stride <= INT64_C(0))) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  if ((index < INT64_C(0)) || (index >= vector->length)) {
    native_trap(NATIVE_TRAP_OUT_OF_RANGE);
  }
  return (const void *)((const uint8_t *)vector->elements + (size_t)(index * stride));
}

native_vec *native_vec_push(native_arena *arena, native_vec *vector, const void *value,
                            int64_t stride, size_t alignment) {
  if ((vector == NULL) || (value == NULL) || (stride <= INT64_C(0))) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  if (vector->capacity == INT64_C(0)) {
    native_vec *fresh;
    if (vector->length != INT64_C(0)) {
      native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
    }
    fresh = native_vec_new(arena, NATIVE_VEC_MIN_CAPACITY, stride, alignment);
    memcpy(fresh->elements, value, (size_t)stride);
    fresh->length = INT64_C(1);
    return fresh;
  }
  if (vector->length == vector->capacity) {
    int64_t grown = (vector->capacity <= INT64_C(0))
                        ? NATIVE_VEC_MIN_CAPACITY
                        : (vector->capacity * INT64_C(2));
    if (vector->capacity > (INT64_MAX / INT64_C(2))) {
      native_trap(NATIVE_TRAP_OVERFLOW);
    }
    void *storage = native_arena_alloc(arena, native_vec_bytes(grown, stride), alignment);
    native_vec_storage_allocations += UINT64_C(1);
    if (vector->length > INT64_C(0)) {
      memcpy(storage, vector->elements, (size_t)(vector->length * stride));
    }
    vector->elements = storage;
    vector->capacity = grown;
  }
  memcpy((uint8_t *)vector->elements + (size_t)(vector->length * stride), value,
         (size_t)stride);
  vector->length += INT64_C(1);
  return vector;
}

native_vec *native_vec_concat(native_arena *arena, const native_vec *left,
                              const native_vec *right, int64_t stride,
                              size_t alignment) {
  native_vec *result;
  int64_t length;
  if ((left == NULL) || (right == NULL) || (stride <= INT64_C(0)) ||
      (left->length < INT64_C(0)) || (right->length < INT64_C(0)) ||
      (left->length > left->capacity) || (right->length > right->capacity)) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  if (left->length > (INT64_MAX - right->length)) {
    native_trap(NATIVE_TRAP_OVERFLOW);
  }
  length = left->length + right->length;
  result = native_vec_new(arena, length, stride, alignment);
  if (left->length > INT64_C(0)) {
    memcpy(result->elements, left->elements, (size_t)(left->length * stride));
  }
  if (right->length > INT64_C(0)) {
    memcpy((uint8_t *)result->elements + (size_t)(left->length * stride),
           right->elements, (size_t)(right->length * stride));
  }
  result->length = length;
  return result;
}

uint64_t native_text_length(uint64_t handle) {
  uint64_t length;
  if (handle == UINT64_C(0)) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  memcpy(&length, (const void *)(uintptr_t)handle, sizeof length);
  return length;
}

const uint8_t *native_text_bytes(uint64_t handle) {
  if (handle == UINT64_C(0)) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  return (const uint8_t *)(uintptr_t)handle + NATIVE_TEXT_HEADER_BYTES;
}

/* Handle identity is only a fast path; equality is length plus byte equality,
   so two blobs allocated separately still compare equal. */
bool native_text_eq(uint64_t left, uint64_t right) {
  uint64_t length;
  if (left == right) {
    return true;
  }
  length = native_text_length(left);
  if (length != native_text_length(right)) {
    return false;
  }
  if (length == UINT64_C(0)) {
    return true;
  }
  return memcmp(native_text_bytes(left), native_text_bytes(right),
                (size_t)length) == 0;
}

bool native_text_index_of(uint64_t source, uint64_t needle, int64_t *out) {
  uint64_t source_length = native_text_length(source);
  uint64_t needle_length = native_text_length(needle);
  const uint8_t *source_bytes = native_text_bytes(source);
  const uint8_t *needle_bytes = native_text_bytes(needle);
  uint64_t index;
  if (out == NULL) {
    return false;
  }
  if (needle_length == UINT64_C(0)) {
    *out = INT64_C(0);
    return true;
  }
  if (needle_length > source_length) {
    return false;
  }
  for (index = UINT64_C(0); index <= (source_length - needle_length); index++) {
    if (memcmp(source_bytes + index, needle_bytes, (size_t)needle_length) == 0) {
      if (index > (uint64_t)INT64_MAX) {
        native_trap(NATIVE_TRAP_OVERFLOW);
      }
      *out = (int64_t)index;
      return true;
    }
  }
  return false;
}

static bool native_unicode_whitespace(uint32_t codepoint) {
  return ((codepoint >= UINT32_C(0x0009)) &&
          (codepoint <= UINT32_C(0x000d))) ||
         ((codepoint >= UINT32_C(0x001c)) &&
          (codepoint <= UINT32_C(0x0020))) ||
         (codepoint == UINT32_C(0x1680)) ||
         ((codepoint >= UINT32_C(0x2000)) &&
          (codepoint <= UINT32_C(0x2006))) ||
         ((codepoint >= UINT32_C(0x2008)) &&
          (codepoint <= UINT32_C(0x200a))) ||
         ((codepoint >= UINT32_C(0x2028)) &&
          (codepoint <= UINT32_C(0x2029))) ||
         (codepoint == UINT32_C(0x205f)) ||
         (codepoint == UINT32_C(0x3000));
}

static bool native_utf8_next(const uint8_t *bytes, uint64_t length,
                             uint64_t *offset, uint32_t *out) {
  uint8_t first;
  uint32_t value;
  uint64_t needed;
  uint64_t index;
  if ((*offset >= length) || (out == NULL)) {
    return false;
  }
  first = bytes[*offset];
  if (first < UINT8_C(0x80)) {
    *out = (uint32_t)first;
    *offset += UINT64_C(1);
    return true;
  }
  if ((first >= UINT8_C(0xc2)) && (first <= UINT8_C(0xdf))) {
    value = (uint32_t)(first & UINT8_C(0x1f));
    needed = UINT64_C(1);
  } else if ((first >= UINT8_C(0xe0)) && (first <= UINT8_C(0xef))) {
    value = (uint32_t)(first & UINT8_C(0x0f));
    needed = UINT64_C(2);
  } else if ((first >= UINT8_C(0xf0)) && (first <= UINT8_C(0xf4))) {
    value = (uint32_t)(first & UINT8_C(0x07));
    needed = UINT64_C(3);
  } else {
    return false;
  }
  if (needed > (length - *offset - UINT64_C(1))) {
    return false;
  }
  for (index = UINT64_C(1); index <= needed; index++) {
    uint8_t continuation = bytes[*offset + index];
    if ((continuation & UINT8_C(0xc0)) != UINT8_C(0x80)) {
      return false;
    }
    value = (value << 6) | (uint32_t)(continuation & UINT8_C(0x3f));
  }
  if (((needed == UINT64_C(2)) && (value < UINT32_C(0x0800))) ||
      ((needed == UINT64_C(3)) && (value < UINT32_C(0x10000))) ||
      ((value >= UINT32_C(0xd800)) && (value <= UINT32_C(0xdfff))) ||
      (value > UINT32_C(0x10ffff))) {
    return false;
  }
  *offset += needed + UINT64_C(1);
  *out = value;
  return true;
}

bool native_text_is_blank(uint64_t handle) {
  uint64_t length = native_text_length(handle);
  const uint8_t *bytes = native_text_bytes(handle);
  uint64_t offset = UINT64_C(0);
  while (offset < length) {
    uint32_t codepoint;
    if (!native_utf8_next(bytes, length, &offset, &codepoint) ||
        !native_unicode_whitespace(codepoint)) {
      return false;
    }
  }
  return true;
}

bool native_text_parse_i64(uint64_t handle, int64_t *out) {
  const uint8_t *bytes = native_text_bytes(handle);
  uint64_t length = native_text_length(handle);
  uint64_t index = UINT64_C(0);
  uint64_t magnitude = UINT64_C(0);
  uint64_t limit;
  bool negative = false;
  if ((out == NULL) || (length == UINT64_C(0))) {
    return false;
  }
  if ((bytes[index] == (uint8_t)'-') || (bytes[index] == (uint8_t)'+')) {
    negative = bytes[index] == (uint8_t)'-';
    index += UINT64_C(1);
    if (index == length) {
      return false;
    }
  }
  limit = negative ? (UINT64_C(1) << 63) : (uint64_t)INT64_MAX;
  while (index < length) {
    uint8_t byte = bytes[index];
    uint64_t digit;
    if ((byte < (uint8_t)'0') || (byte > (uint8_t)'9')) {
      return false;
    }
    digit = (uint64_t)(byte - (uint8_t)'0');
    if (magnitude > ((limit - digit) / UINT64_C(10))) {
      return false;
    }
    magnitude = (magnitude * UINT64_C(10)) + digit;
    index += UINT64_C(1);
  }
  if (negative && (magnitude == (UINT64_C(1) << 63))) {
    *out = INT64_MIN;
  } else if (negative) {
    *out = -(int64_t)magnitude;
  } else {
    *out = (int64_t)magnitude;
  }
  return true;
}

uint64_t native_text_alloc(native_arena *arena, uint64_t length, uint8_t **out) {
  uint8_t *blob;
  if (length > (uint64_t)(SIZE_MAX - (size_t)NATIVE_TEXT_HEADER_BYTES)) {
    native_trap(NATIVE_TRAP_ARENA_EXHAUSTED);
  }
  blob = (uint8_t *)native_arena_alloc(
      arena, (size_t)(NATIVE_TEXT_HEADER_BYTES + length), sizeof(uint64_t));
  memcpy(blob, &length, sizeof length);
  if (out != NULL) {
    *out = blob + NATIVE_TEXT_HEADER_BYTES;
  }
  return (uint64_t)(uintptr_t)blob;
}

uint64_t native_text_slice(native_arena *arena, uint64_t handle, uint64_t start,
                           uint64_t end) {
  uint8_t *destination = NULL;
  uint64_t result;
  if ((end < start) || (end > native_text_length(handle))) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  result = native_text_alloc(arena, end - start, &destination);
  if (end > start) {
    memcpy(destination, native_text_bytes(handle) + start,
           (size_t)(end - start));
  }
  return result;
}

uint64_t native_text_from_int(native_arena *arena, int64_t value) {
  char digits[21];
  uint64_t magnitude;
  uint64_t written = UINT64_C(0);
  uint64_t length;
  uint8_t *destination = NULL;
  uint64_t result;
  uint64_t index;
  magnitude = (value < INT64_C(0)) ? (~(uint64_t)value + UINT64_C(1))
                                   : (uint64_t)value;
  do {
    digits[written] = (char)('0' + (int)(magnitude % UINT64_C(10)));
    magnitude /= UINT64_C(10);
    written += UINT64_C(1);
  } while (magnitude != UINT64_C(0));
  length = (value < INT64_C(0)) ? (written + UINT64_C(1)) : written;
  result = native_text_alloc(arena, length, &destination);
  index = UINT64_C(0);
  if (value < INT64_C(0)) {
    destination[index] = (uint8_t)'-';
    index += UINT64_C(1);
  }
  while (written > UINT64_C(0)) {
    written -= UINT64_C(1);
    destination[index] = (uint8_t)digits[written];
    index += UINT64_C(1);
  }
  return result;
}

uint64_t native_text_concat(native_arena *arena, const uint64_t *parts,
                            uint64_t count) {
  uint64_t total = UINT64_C(0);
  uint64_t index;
  uint64_t offset = UINT64_C(0);
  uint8_t *destination = NULL;
  uint64_t result;
  if ((parts == NULL) && (count != UINT64_C(0))) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  for (index = UINT64_C(0); index < count; index++) {
    uint64_t part = native_text_length(parts[index]);
    if (part > (UINT64_MAX - total)) {
      native_trap(NATIVE_TRAP_OVERFLOW);
    }
    total += part;
  }
  result = native_text_alloc(arena, total, &destination);
  for (index = UINT64_C(0); index < count; index++) {
    uint64_t part = native_text_length(parts[index]);
    if (part != UINT64_C(0)) {
      memcpy(destination + offset, native_text_bytes(parts[index]),
             (size_t)part);
    }
    offset += part;
  }
  return result;
}

bool native_byte_read(FILE *stream, uint8_t *destination, size_t length) {
  if ((stream == NULL) || ((destination == NULL) && (length != 0U))) {
    return false;
  }
  size_t offset = 0U;
  while (offset < length) {
    size_t read_count = fread(destination + offset, 1U, length - offset, stream);
    if (read_count == 0U) {
      return false;
    }
    offset += read_count;
  }
  return true;
}

bool native_byte_write(FILE *stream, const uint8_t *source, size_t length) {
  if ((stream == NULL) || ((source == NULL) && (length != 0U))) {
    return false;
  }
  size_t offset = 0U;
  while (offset < length) {
    size_t write_count = fwrite(source + offset, 1U, length - offset, stream);
    if (write_count == 0U) {
      return false;
    }
    offset += write_count;
  }
  return true;
}
