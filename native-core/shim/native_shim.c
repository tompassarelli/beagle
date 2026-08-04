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

int64_t native_text_compare(uint64_t left, uint64_t right) {
  uint64_t left_length = native_text_length(left);
  uint64_t right_length = native_text_length(right);
  uint64_t shared = (left_length < right_length) ? left_length : right_length;
  int ordering = (shared == UINT64_C(0))
                     ? 0
                     : memcmp(native_text_bytes(left), native_text_bytes(right),
                              (size_t)shared);
  if (ordering < 0) {
    return INT64_C(-1);
  }
  if (ordering > 0) {
    return INT64_C(1);
  }
  if (left_length < right_length) {
    return INT64_C(-1);
  }
  return (left_length > right_length) ? INT64_C(1) : INT64_C(0);
}

static uint64_t native_text_copy_range(native_arena *arena, uint64_t source,
                                       uint64_t start, uint64_t end) {
  if ((end < start) || (end > native_text_length(source))) {
    native_trap(NATIVE_TRAP_OUT_OF_RANGE);
  }
  return native_text_slice(arena, source, start, end);
}

uint64_t native_text_trim(native_arena *arena, uint64_t source) {
  const uint8_t *bytes = native_text_bytes(source);
  uint64_t length = native_text_length(source);
  uint64_t offset = UINT64_C(0);
  uint64_t first = length;
  uint64_t last = UINT64_C(0);
  while (offset < length) {
    uint64_t start = offset;
    uint32_t codepoint;
    bool decoded = native_utf8_next(bytes, length, &offset, &codepoint);
    if (!decoded) {
      codepoint = (uint32_t)bytes[offset];
      offset += UINT64_C(1);
    }
    if (!native_unicode_whitespace(codepoint)) {
      if (first == length) {
        first = start;
      }
      last = offset;
    }
  }
  if (first == length) {
    return native_text_copy_range(arena, source, UINT64_C(0), UINT64_C(0));
  }
  return native_text_copy_range(arena, source, first, last);
}

uint64_t native_text_lower_ascii(native_arena *arena, uint64_t source) {
  uint64_t length = native_text_length(source);
  const uint8_t *input = native_text_bytes(source);
  uint8_t *output = NULL;
  uint64_t result = native_text_alloc(arena, length, &output);
  uint64_t index;
  for (index = UINT64_C(0); index < length; index++) {
    uint8_t byte = input[index];
    output[index] = ((byte >= (uint8_t)'A') && (byte <= (uint8_t)'Z'))
                        ? (uint8_t)(byte + ((uint8_t)'a' - (uint8_t)'A'))
                        : byte;
  }
  return result;
}

#define NATIVE_REGEX_MAX_TOKENS 128U
#define NATIVE_REGEX_MAX_CAPTURES 8U

typedef enum native_regex_kind {
  NATIVE_REGEX_LITERAL,
  NATIVE_REGEX_ANY,
  NATIVE_REGEX_CLASS,
  NATIVE_REGEX_DIGIT,
  NATIVE_REGEX_SPACE,
  NATIVE_REGEX_NONSPACE,
  NATIVE_REGEX_BEGIN,
  NATIVE_REGEX_END,
  NATIVE_REGEX_CAPTURE_BEGIN,
  NATIVE_REGEX_CAPTURE_END
} native_regex_kind;

typedef struct native_regex_token {
  native_regex_kind kind;
  uint8_t literal;
  const uint8_t *class_start;
  uint64_t class_length;
  uint64_t minimum;
  uint64_t maximum;
  uint32_t capture;
  bool negated;
} native_regex_token;

typedef struct native_regex_program {
  native_regex_token tokens[NATIVE_REGEX_MAX_TOKENS];
  uint32_t count;
  uint32_t captures;
  bool anchored;
} native_regex_program;

typedef struct native_regex_state {
  uint64_t position;
  int64_t start[NATIVE_REGEX_MAX_CAPTURES];
  int64_t end[NATIVE_REGEX_MAX_CAPTURES];
} native_regex_state;

static bool native_regex_space(uint8_t byte) {
  return (byte == (uint8_t)' ') || (byte == (uint8_t)'\t') ||
         (byte == (uint8_t)'\n') || (byte == (uint8_t)'\r') ||
         (byte == (uint8_t)'\v') || (byte == (uint8_t)'\f');
}

static bool native_regex_class_member(const native_regex_token *token,
                                      uint8_t byte) {
  uint64_t position = UINT64_C(0);
  bool member = false;
  while (position < token->class_length) {
    uint8_t first = token->class_start[position];
    if ((position + UINT64_C(2) < token->class_length) &&
        (token->class_start[position + UINT64_C(1)] == (uint8_t)'-')) {
      uint8_t last = token->class_start[position + UINT64_C(2)];
      if ((byte >= first) && (byte <= last)) {
        member = true;
      }
      position += UINT64_C(3);
    } else {
      if (byte == first) {
        member = true;
      }
      position += UINT64_C(1);
    }
  }
  return token->negated ? !member : member;
}

static bool native_regex_atom_matches(const native_regex_token *token,
                                      uint8_t byte) {
  switch (token->kind) {
  case NATIVE_REGEX_LITERAL:
    return byte == token->literal;
  case NATIVE_REGEX_ANY:
    return true;
  case NATIVE_REGEX_CLASS:
    return native_regex_class_member(token, byte);
  case NATIVE_REGEX_DIGIT:
    return (byte >= (uint8_t)'0') && (byte <= (uint8_t)'9');
  case NATIVE_REGEX_SPACE:
    return native_regex_space(byte);
  case NATIVE_REGEX_NONSPACE:
    return !native_regex_space(byte);
  default:
    return false;
  }
}

static bool native_regex_push(native_regex_program *program,
                              native_regex_token token) {
  if (program->count >= NATIVE_REGEX_MAX_TOKENS) {
    return false;
  }
  program->tokens[program->count] = token;
  program->count += UINT32_C(1);
  return true;
}

static bool native_regex_number(const uint8_t *bytes, uint64_t length,
                                uint64_t *position, uint64_t *value) {
  uint64_t result = UINT64_C(0);
  uint64_t start = *position;
  while ((*position < length) &&
         (bytes[*position] >= (uint8_t)'0') &&
         (bytes[*position] <= (uint8_t)'9')) {
    uint64_t digit = (uint64_t)(bytes[*position] - (uint8_t)'0');
    if (result > ((UINT64_MAX - digit) / UINT64_C(10))) {
      return false;
    }
    result = (result * UINT64_C(10)) + digit;
    *position += UINT64_C(1);
  }
  if (start == *position) {
    return false;
  }
  *value = result;
  return true;
}

static bool native_regex_compile(uint64_t pattern,
                                 native_regex_program *program) {
  const uint8_t *bytes = native_text_bytes(pattern);
  uint64_t length = native_text_length(pattern);
  uint64_t position = UINT64_C(0);
  memset(program, 0, sizeof *program);
  while (position < length) {
    native_regex_token token;
    memset(&token, 0, sizeof token);
    token.minimum = UINT64_C(1);
    token.maximum = UINT64_C(1);
    if (bytes[position] == (uint8_t)'(') {
      if (program->captures + UINT32_C(1) >= NATIVE_REGEX_MAX_CAPTURES) {
        return false;
      }
      program->captures += UINT32_C(1);
      token.kind = NATIVE_REGEX_CAPTURE_BEGIN;
      token.capture = program->captures;
      position += UINT64_C(1);
    } else if (bytes[position] == (uint8_t)')') {
      uint32_t capture = program->captures;
      uint32_t scan = program->count;
      while (scan > UINT32_C(0)) {
        scan -= UINT32_C(1);
        if ((program->tokens[scan].kind == NATIVE_REGEX_CAPTURE_BEGIN) &&
            (program->tokens[scan].capture <= capture)) {
          capture = program->tokens[scan].capture;
          break;
        }
      }
      token.kind = NATIVE_REGEX_CAPTURE_END;
      token.capture = capture;
      position += UINT64_C(1);
    } else if (bytes[position] == (uint8_t)'^') {
      token.kind = NATIVE_REGEX_BEGIN;
      program->anchored = true;
      position += UINT64_C(1);
    } else if (bytes[position] == (uint8_t)'$') {
      token.kind = NATIVE_REGEX_END;
      position += UINT64_C(1);
    } else if (bytes[position] == (uint8_t)'[') {
      uint64_t start;
      token.kind = NATIVE_REGEX_CLASS;
      position += UINT64_C(1);
      if ((position < length) && (bytes[position] == (uint8_t)'^')) {
        token.negated = true;
        position += UINT64_C(1);
      }
      start = position;
      while ((position < length) && (bytes[position] != (uint8_t)']')) {
        position += UINT64_C(1);
      }
      if (position >= length) {
        return false;
      }
      token.class_start = bytes + start;
      token.class_length = position - start;
      position += UINT64_C(1);
    } else if (bytes[position] == (uint8_t)'\\') {
      position += UINT64_C(1);
      if (position >= length) {
        return false;
      }
      if (bytes[position] == (uint8_t)'d') {
        token.kind = NATIVE_REGEX_DIGIT;
      } else if (bytes[position] == (uint8_t)'s') {
        token.kind = NATIVE_REGEX_SPACE;
      } else if (bytes[position] == (uint8_t)'S') {
        token.kind = NATIVE_REGEX_NONSPACE;
      } else {
        token.kind = NATIVE_REGEX_LITERAL;
        token.literal = bytes[position];
      }
      position += UINT64_C(1);
    } else if (bytes[position] == (uint8_t)'.') {
      token.kind = NATIVE_REGEX_ANY;
      position += UINT64_C(1);
    } else {
      token.kind = NATIVE_REGEX_LITERAL;
      token.literal = bytes[position];
      position += UINT64_C(1);
    }
    if ((token.kind <= NATIVE_REGEX_NONSPACE) && (position < length)) {
      if (bytes[position] == (uint8_t)'+') {
        token.maximum = UINT64_MAX;
        position += UINT64_C(1);
      } else if (bytes[position] == (uint8_t)'*') {
        token.minimum = UINT64_C(0);
        token.maximum = UINT64_MAX;
        position += UINT64_C(1);
      } else if (bytes[position] == (uint8_t)'?') {
        token.minimum = UINT64_C(0);
        position += UINT64_C(1);
      } else if (bytes[position] == (uint8_t)'{') {
        uint64_t exact;
        position += UINT64_C(1);
        if (!native_regex_number(bytes, length, &position, &exact) ||
            (position >= length) || (bytes[position] != (uint8_t)'}')) {
          return false;
        }
        token.minimum = exact;
        token.maximum = exact;
        position += UINT64_C(1);
      }
    }
    if (!native_regex_push(program, token)) {
      return false;
    }
  }
  return true;
}

static bool native_regex_match_tokens(const native_regex_program *program,
                                      uint32_t token_index,
                                      const uint8_t *source,
                                      uint64_t source_length,
                                      native_regex_state state,
                                      native_regex_state *result) {
  const native_regex_token *token;
  if (token_index >= program->count) {
    *result = state;
    return true;
  }
  token = &program->tokens[token_index];
  if (token->kind == NATIVE_REGEX_BEGIN) {
    if (state.position != UINT64_C(0)) {
      return false;
    }
    return native_regex_match_tokens(program, token_index + UINT32_C(1),
                                     source, source_length, state, result);
  }
  if (token->kind == NATIVE_REGEX_END) {
    if (state.position != source_length) {
      return false;
    }
    return native_regex_match_tokens(program, token_index + UINT32_C(1),
                                     source, source_length, state, result);
  }
  if (token->kind == NATIVE_REGEX_CAPTURE_BEGIN) {
    state.start[token->capture] = (int64_t)state.position;
    return native_regex_match_tokens(program, token_index + UINT32_C(1),
                                     source, source_length, state, result);
  }
  if (token->kind == NATIVE_REGEX_CAPTURE_END) {
    state.end[token->capture] = (int64_t)state.position;
    return native_regex_match_tokens(program, token_index + UINT32_C(1),
                                     source, source_length, state, result);
  }
  {
    uint64_t available = UINT64_C(0);
    uint64_t limit = source_length - state.position;
    if (token->maximum < limit) {
      limit = token->maximum;
    }
    while ((available < limit) &&
           native_regex_atom_matches(token,
                                     source[state.position + available])) {
      available += UINT64_C(1);
    }
    if (available < token->minimum) {
      return false;
    }
    for (;;) {
      native_regex_state next = state;
      next.position += available;
      if (native_regex_match_tokens(program, token_index + UINT32_C(1),
                                    source, source_length, next, result)) {
        return true;
      }
      if (available == token->minimum) {
        break;
      }
      available -= UINT64_C(1);
    }
  }
  return false;
}

static native_regex_state native_regex_empty_state(uint64_t position) {
  native_regex_state state;
  uint32_t capture;
  state.position = position;
  for (capture = UINT32_C(0); capture < NATIVE_REGEX_MAX_CAPTURES;
       capture++) {
    state.start[capture] = INT64_C(-1);
    state.end[capture] = INT64_C(-1);
  }
  return state;
}

static bool native_regex_search(const native_regex_program *program,
                                uint64_t source, uint64_t offset,
                                native_regex_state *result) {
  const uint8_t *bytes = native_text_bytes(source);
  uint64_t length = native_text_length(source);
  uint64_t start = program->anchored ? UINT64_C(0) : offset;
  if (program->anchored && (offset != UINT64_C(0))) {
    return false;
  }
  while (start <= length) {
    native_regex_state state = native_regex_empty_state(start);
    native_regex_state matched;
    if (native_regex_match_tokens(program, UINT32_C(0), bytes, length, state,
                                  &matched)) {
      matched.start[0] = (int64_t)start;
      matched.end[0] = (int64_t)matched.position;
      *result = matched;
      return true;
    }
    if (program->anchored || (start == length)) {
      break;
    }
    start += UINT64_C(1);
  }
  return false;
}

bool native_text_regex_matches(uint64_t source, uint64_t pattern) {
  native_regex_program program;
  native_regex_state matched;
  uint64_t length = native_text_length(source);
  if (!native_regex_compile(pattern, &program) ||
      !native_regex_search(&program, source, UINT64_C(0), &matched)) {
    return false;
  }
  return (matched.start[0] == INT64_C(0)) &&
         ((uint64_t)matched.end[0] == length);
}

uint64_t native_text_regex_replace(native_arena *arena, uint64_t source,
                                   uint64_t pattern, uint64_t replacement) {
  native_regex_program program;
  native_regex_state matched;
  uint64_t source_length = native_text_length(source);
  uint64_t replacement_length = native_text_length(replacement);
  uint64_t cursor = UINT64_C(0);
  uint64_t total = UINT64_C(0);
  uint64_t matches = UINT64_C(0);
  if (!native_regex_compile(pattern, &program)) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  while (native_regex_search(&program, source, cursor, &matched)) {
    uint64_t start = (uint64_t)matched.start[0];
    uint64_t end = (uint64_t)matched.end[0];
    if ((start < cursor) || (end < start)) {
      native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
    }
    if ((start - cursor > UINT64_MAX - total) ||
        (replacement_length > UINT64_MAX - total - (start - cursor))) {
      native_trap(NATIVE_TRAP_OVERFLOW);
    }
    total += (start - cursor) + replacement_length;
    matches += UINT64_C(1);
    if (end == start) {
      if ((end < source_length) && (total == UINT64_MAX)) {
        native_trap(NATIVE_TRAP_OVERFLOW);
      }
      total += (end < source_length) ? UINT64_C(1) : UINT64_C(0);
      cursor = (end < source_length) ? end + UINT64_C(1) : end;
      if (end == source_length) {
        break;
      }
    } else {
      cursor = end;
    }
  }
  if (source_length - cursor > UINT64_MAX - total) {
    native_trap(NATIVE_TRAP_OVERFLOW);
  }
  total += source_length - cursor;
  {
    uint8_t *output = NULL;
    uint64_t result = native_text_alloc(arena, total, &output);
    uint64_t write = UINT64_C(0);
    cursor = UINT64_C(0);
    while ((matches > UINT64_C(0)) &&
           native_regex_search(&program, source, cursor, &matched)) {
      uint64_t start = (uint64_t)matched.start[0];
      uint64_t end = (uint64_t)matched.end[0];
      uint64_t prefix = start - cursor;
      if (prefix > UINT64_C(0)) {
        memcpy(output + write, native_text_bytes(source) + cursor,
               (size_t)prefix);
        write += prefix;
      }
      if (replacement_length > UINT64_C(0)) {
        memcpy(output + write, native_text_bytes(replacement),
               (size_t)replacement_length);
        write += replacement_length;
      }
      matches -= UINT64_C(1);
      if (end == start) {
        if (end < source_length) {
          output[write] = native_text_bytes(source)[end];
          write += UINT64_C(1);
          cursor = end + UINT64_C(1);
        } else {
          cursor = end;
          break;
        }
      } else {
        cursor = end;
      }
    }
    if (cursor < source_length) {
      memcpy(output + write, native_text_bytes(source) + cursor,
             (size_t)(source_length - cursor));
    }
    return result;
  }
}

native_vec *native_text_regex_find(native_arena *arena, uint64_t source,
                                   uint64_t pattern) {
  native_regex_program program;
  native_regex_state matched;
  native_vec *result;
  uint32_t capture;
  if (!native_regex_compile(pattern, &program)) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  result = native_vec_new(arena, (int64_t)(program.captures + UINT32_C(1)),
                          INT64_C(8), _Alignof(uint64_t));
  if (!native_regex_search(&program, source, UINT64_C(0), &matched)) {
    return result;
  }
  for (capture = UINT32_C(0); capture <= program.captures; capture++) {
    uint64_t value;
    if ((matched.start[capture] < INT64_C(0)) ||
        (matched.end[capture] < matched.start[capture])) {
      value = native_text_copy_range(arena, source, UINT64_C(0), UINT64_C(0));
    } else {
      value = native_text_copy_range(arena, source,
                                     (uint64_t)matched.start[capture],
                                     (uint64_t)matched.end[capture]);
    }
    result = native_vec_push(arena, result, &value, INT64_C(8),
                             _Alignof(uint64_t));
  }
  return result;
}

native_vec *native_text_regex_split(native_arena *arena, uint64_t source,
                                    uint64_t pattern) {
  native_regex_program program;
  native_regex_state matched;
  native_vec *result =
      native_vec_new(arena, INT64_C(4), INT64_C(8), _Alignof(uint64_t));
  uint64_t cursor = UINT64_C(0);
  uint64_t length = native_text_length(source);
  if (!native_regex_compile(pattern, &program)) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  while (native_regex_search(&program, source, cursor, &matched)) {
    uint64_t start = (uint64_t)matched.start[0];
    uint64_t end = (uint64_t)matched.end[0];
    uint64_t part = native_text_copy_range(arena, source, cursor, start);
    result = native_vec_push(arena, result, &part, INT64_C(8),
                             _Alignof(uint64_t));
    if (end == start) {
      if (end == length) {
        cursor = end;
        break;
      }
      cursor = end + UINT64_C(1);
    } else {
      cursor = end;
    }
  }
  {
    uint64_t tail = native_text_copy_range(arena, source, cursor, length);
    return native_vec_push(arena, result, &tail, INT64_C(8),
                           _Alignof(uint64_t));
  }
}

native_vec *native_text_vector_trim(native_arena *arena,
                                    const native_vec *source) {
  int64_t length = native_vec_length(source);
  native_vec *result =
      native_vec_new(arena, length, INT64_C(8), _Alignof(uint64_t));
  int64_t index;
  for (index = INT64_C(0); index < length; index++) {
    uint64_t value = *(const uint64_t *)native_vec_at(source, index, INT64_C(8));
    uint64_t trimmed = native_text_trim(arena, value);
    result = native_vec_push(arena, result, &trimmed, INT64_C(8),
                             _Alignof(uint64_t));
  }
  return result;
}

native_vec *native_text_vector_remove_blank(native_arena *arena,
                                            const native_vec *source) {
  int64_t length = native_vec_length(source);
  native_vec *result =
      native_vec_new(arena, length, INT64_C(8), _Alignof(uint64_t));
  int64_t index;
  for (index = INT64_C(0); index < length; index++) {
    uint64_t value = *(const uint64_t *)native_vec_at(source, index, INT64_C(8));
    if (!native_text_is_blank(value)) {
      result = native_vec_push(arena, result, &value, INT64_C(8),
                               _Alignof(uint64_t));
    }
  }
  return result;
}

uint64_t native_text_join(native_arena *arena, uint64_t separator,
                          const native_vec *source) {
  int64_t count = native_vec_length(source);
  uint64_t separator_length = native_text_length(separator);
  uint64_t total = UINT64_C(0);
  int64_t index;
  uint8_t *output = NULL;
  uint64_t write = UINT64_C(0);
  for (index = INT64_C(0); index < count; index++) {
    uint64_t value = *(const uint64_t *)native_vec_at(source, index, INT64_C(8));
    uint64_t length = native_text_length(value);
    uint64_t delimiter = (index == INT64_C(0)) ? UINT64_C(0) : separator_length;
    if ((delimiter > UINT64_MAX - total) ||
        (length > UINT64_MAX - total - delimiter)) {
      native_trap(NATIVE_TRAP_OVERFLOW);
    }
    total += delimiter + length;
  }
  {
    uint64_t result = native_text_alloc(arena, total, &output);
    for (index = INT64_C(0); index < count; index++) {
      uint64_t value =
          *(const uint64_t *)native_vec_at(source, index, INT64_C(8));
      uint64_t length = native_text_length(value);
      if ((index != INT64_C(0)) && (separator_length > UINT64_C(0))) {
        memcpy(output + write, native_text_bytes(separator),
               (size_t)separator_length);
        write += separator_length;
      }
      if (length > UINT64_C(0)) {
        memcpy(output + write, native_text_bytes(value), (size_t)length);
        write += length;
      }
    }
    return result;
  }
}

uint64_t native_text_repeat(native_arena *arena, uint64_t source,
                            int64_t count) {
  uint64_t length = native_text_length(source);
  uint64_t repetitions;
  uint64_t total;
  uint8_t *output = NULL;
  uint64_t index;
  if (count < INT64_C(0)) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  repetitions = (uint64_t)count;
  if ((length != UINT64_C(0)) && (repetitions > UINT64_MAX / length)) {
    native_trap(NATIVE_TRAP_OVERFLOW);
  }
  total = length * repetitions;
  {
    uint64_t result = native_text_alloc(arena, total, &output);
    for (index = UINT64_C(0); index < repetitions; index++) {
      if (length > UINT64_C(0)) {
        memcpy(output + (index * length), native_text_bytes(source),
               (size_t)length);
      }
    }
    return result;
  }
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
