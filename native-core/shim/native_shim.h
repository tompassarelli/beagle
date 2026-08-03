#ifndef NATIVE_SHIM_H
#define NATIVE_SHIM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#include <string.h>

#define NATIVE_TRAP_INVALID_ARGUMENT UINT32_C(1)
#define NATIVE_TRAP_OVERFLOW UINT32_C(2)
#define NATIVE_TRAP_ARENA_EXHAUSTED UINT32_C(3)
#define NATIVE_TRAP_OUT_OF_RANGE UINT32_C(4)

typedef struct native_arena {
  uint8_t *bytes;
  size_t capacity;
  size_t offset;
} native_arena;

typedef struct native_capability {
  uint64_t token;
} native_capability;

typedef struct native_bytes {
  uint8_t *data;
  size_t length;
} native_bytes;

/* The native representation of a (Vec T) value is a POINTER to this header,
   never the header by value: a vector-valued record field is therefore one
   8-byte reference, and the element storage lives in the arena beside it.
   `elements` is NULL exactly when capacity is 0. */
typedef struct native_vec {
  void *elements;
  int64_t length;
  int64_t capacity;
} native_vec;

/* Counts ELEMENT-STORAGE allocations only (header allocations excluded), so a
   push sequence's reallocation count is observable from a test. */
extern uint64_t native_vec_storage_allocations;

/* A Text handle is the address of a length-prefixed strict-UTF-8 blob: an
   8-byte native-endian uint64_t length, then exactly that many bytes. Handles
   are world-local addresses and never cross a world boundary. */
#define NATIVE_TEXT_HEADER_BYTES ((uint64_t)sizeof(uint64_t))

void native_arena_init(native_arena *arena, uint8_t *storage, size_t capacity);
void *native_arena_alloc(native_arena *arena, size_t size, size_t alignment);
void native_arena_reset(native_arena *arena);
_Noreturn void native_trap(uint32_t code);

native_vec *native_vec_new(native_arena *arena, int64_t capacity, int64_t stride,
                           size_t alignment);
int64_t native_vec_length(const native_vec *vector);
/* Traps NATIVE_TRAP_OUT_OF_RANGE unless 0 <= index < length. */
const void *native_vec_at(const native_vec *vector, int64_t index, int64_t stride);
/* Linear push: the argument header is moved, not copied. Capacity doubles, so
   a run of n pushes performs O(log n) element-storage allocations. */
native_vec *native_vec_push(native_arena *arena, native_vec *vector,
                            const void *value, int64_t stride, size_t alignment);
bool native_byte_read(FILE *stream, uint8_t *destination, size_t length);
bool native_byte_write(FILE *stream, const uint8_t *source, size_t length);

uint64_t native_text_length(uint64_t handle);
const uint8_t *native_text_bytes(uint64_t handle);
bool native_text_eq(uint64_t left, uint64_t right);
uint64_t native_text_alloc(native_arena *arena, uint64_t length, uint8_t **out);
uint64_t native_text_slice(native_arena *arena, uint64_t handle, uint64_t start,
                           uint64_t end);
uint64_t native_text_from_int(native_arena *arena, int64_t value);
uint64_t native_text_concat(native_arena *arena, const uint64_t *parts,
                            uint64_t count);

#endif
