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
