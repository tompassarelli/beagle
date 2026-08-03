#ifndef NATIVE_SHIM_H
#define NATIVE_SHIM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#define NATIVE_TRAP_INVALID_ARGUMENT UINT32_C(1)
#define NATIVE_TRAP_OVERFLOW UINT32_C(2)
#define NATIVE_TRAP_ARENA_EXHAUSTED UINT32_C(3)

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

void native_arena_init(native_arena *arena, uint8_t *storage, size_t capacity);
void *native_arena_alloc(native_arena *arena, size_t size, size_t alignment);
void native_arena_reset(native_arena *arena);
_Noreturn void native_trap(uint32_t code);
bool native_byte_read(FILE *stream, uint8_t *destination, size_t length);
bool native_byte_write(FILE *stream, const uint8_t *source, size_t length);

#endif
