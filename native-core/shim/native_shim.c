#define _POSIX_C_SOURCE 200809L

#include "native_shim.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <stdatomic.h>
#include <string.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>

struct native_atom {
  _Atomic bool locked;
  size_t size;
  void *value;
};

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

static void native_atom_require(const native_atom *atom,
                                const native_capability *capability,
                                const void *value, size_t size) {
  if ((atom == NULL) || (capability == NULL) ||
      (capability->token == UINT64_C(0)) || (value == NULL) ||
      (size == 0U) || (size != atom->size)) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
}

static void native_atom_acquire(native_atom *atom) {
  while (atomic_exchange_explicit(&atom->locked, true,
                                  memory_order_acquire)) {
  }
}

static void native_atom_release(native_atom *atom) {
  atomic_store_explicit(&atom->locked, false, memory_order_release);
}

native_atom *native_atom_new(native_arena *arena,
                             const native_capability *capability,
                             const void *initial, size_t size,
                             size_t alignment) {
  native_atom *atom;
  if ((capability == NULL) || (capability->token == UINT64_C(0)) ||
      (initial == NULL) || (size == 0U)) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  atom = (native_atom *)native_arena_alloc(arena, sizeof(*atom),
                                           _Alignof(native_atom));
  atom->value = native_arena_alloc(arena, size, alignment);
  atomic_init(&atom->locked, false);
  atom->size = size;
  memcpy(atom->value, initial, size);
  return atom;
}

void native_atom_deref(native_atom *atom,
                       const native_capability *capability, void *out,
                       size_t size) {
  native_atom_require(atom, capability, out, size);
  native_atom_acquire(atom);
  memcpy(out, atom->value, size);
  native_atom_release(atom);
}

void native_atom_lock(native_atom *atom,
                      const native_capability *capability, void *out,
                      size_t size) {
  native_atom_require(atom, capability, out, size);
  native_atom_acquire(atom);
  memcpy(out, atom->value, size);
}

void native_atom_store_unlock(native_atom *atom,
                              const native_capability *capability,
                              const void *value, size_t size) {
  native_atom_require(atom, capability, value, size);
  memcpy(atom->value, value, size);
  native_atom_release(atom);
}

bool native_atom_compare_exchange(native_atom *atom,
                                  const native_capability *capability,
                                  const void *expected,
                                  const void *replacement, size_t size) {
  bool matches;
  native_atom_require(atom, capability, expected, size);
  native_atom_require(atom, capability, replacement, size);
  native_atom_acquire(atom);
  matches = memcmp(atom->value, expected, size) == 0;
  if (matches) {
    memcpy(atom->value, replacement, size);
  }
  native_atom_release(atom);
  return matches;
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

native_vec *native_vec_slice(native_arena *arena, const native_vec *source,
                             int64_t start, int64_t end, int64_t stride,
                             size_t alignment) {
  native_vec *result;
  int64_t length;
  size_t source_offset;
  size_t byte_count;
  if ((source == NULL) || (stride <= INT64_C(0)) ||
      (source->length < INT64_C(0)) || (source->length > source->capacity)) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  if ((start < INT64_C(0)) || (end < start) || (end > source->length)) {
    native_trap(NATIVE_TRAP_OUT_OF_RANGE);
  }
  length = end - start;
  source_offset = native_vec_bytes(start, stride);
  byte_count = native_vec_bytes(length, stride);
  result = native_vec_new(arena, length, stride, alignment);
  if (byte_count != 0U) {
    memcpy(result->elements,
           (const uint8_t *)source->elements + source_offset, byte_count);
  }
  result->length = length;
  return result;
}

native_vec *native_vec_reverse(native_arena *arena, const native_vec *source,
                               int64_t stride, size_t alignment) {
  native_vec *result;
  int64_t position;
  if ((source == NULL) || (stride <= INT64_C(0)) ||
      (source->length < INT64_C(0)) || (source->length > source->capacity)) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  result = native_vec_new(arena, source->length, stride, alignment);
  for (position = INT64_C(0); position < source->length; ++position) {
    int64_t source_position = source->length - position - INT64_C(1);
    memcpy((uint8_t *)result->elements + native_vec_bytes(position, stride),
           (const uint8_t *)source->elements +
               native_vec_bytes(source_position, stride),
           (size_t)stride);
  }
  result->length = source->length;
  return result;
}

static int64_t native_i64_from_bits(uint64_t bits) {
  int64_t value;
  memcpy(&value, &bits, sizeof(value));
  return value;
}

int64_t native_bit_and_i64(int64_t left, int64_t right) {
  return native_i64_from_bits((uint64_t)left & (uint64_t)right);
}

int64_t native_bit_or_i64(int64_t left, int64_t right) {
  return native_i64_from_bits((uint64_t)left | (uint64_t)right);
}

int64_t native_bit_xor_i64(int64_t left, int64_t right) {
  return native_i64_from_bits((uint64_t)left ^ (uint64_t)right);
}

int64_t native_bit_shift_left_i64(int64_t value, int64_t distance) {
  uint32_t shift = (uint32_t)((uint64_t)distance & UINT64_C(63));
  return native_i64_from_bits((uint64_t)value << shift);
}

int64_t native_unsigned_bit_shift_right_i64(int64_t value, int64_t distance) {
  uint32_t shift = (uint32_t)((uint64_t)distance & UINT64_C(63));
  return native_i64_from_bits((uint64_t)value >> shift);
}

static size_t native_collection_bytes(int64_t count, int64_t stride) {
  if ((count < INT64_C(0)) || (stride <= INT64_C(0))) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  if ((uint64_t)count > ((uint64_t)SIZE_MAX / (uint64_t)stride)) {
    native_trap(NATIVE_TRAP_OVERFLOW);
  }
  return (size_t)((uint64_t)count * (uint64_t)stride);
}

static void native_collection_check_equality(
    native_collection_equality equality) {
  switch (equality.kind) {
  case NATIVE_COLLECTION_EQ_KIND_BOOL:
  case NATIVE_COLLECTION_EQ_KIND_I64:
  case NATIVE_COLLECTION_EQ_KIND_F64:
  case NATIVE_COLLECTION_EQ_KIND_TEXT:
  case NATIVE_COLLECTION_EQ_KIND_KEYWORD:
    if (equality.descriptor != NULL) {
      native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
    }
    return;
  case NATIVE_COLLECTION_EQ_KIND_STRUCTURAL:
    if (equality.descriptor == NULL) {
      native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
    }
    return;
  default:
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
}

static bool native_collection_equal(const void *left, const void *right,
                                    native_collection_equality equality) {
  if ((left == NULL) || (right == NULL)) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  native_collection_check_equality(equality);
  switch (equality.kind) {
  case NATIVE_COLLECTION_EQ_KIND_BOOL: {
    bool left_value;
    bool right_value;
    memcpy(&left_value, left, sizeof left_value);
    memcpy(&right_value, right, sizeof right_value);
    return left_value == right_value;
  }
  case NATIVE_COLLECTION_EQ_KIND_I64: {
    int64_t left_value;
    int64_t right_value;
    memcpy(&left_value, left, sizeof left_value);
    memcpy(&right_value, right, sizeof right_value);
    return left_value == right_value;
  }
  case NATIVE_COLLECTION_EQ_KIND_F64: {
    double left_value;
    double right_value;
    memcpy(&left_value, left, sizeof left_value);
    memcpy(&right_value, right, sizeof right_value);
    return left_value == right_value;
  }
  case NATIVE_COLLECTION_EQ_KIND_TEXT: {
    uint64_t left_value;
    uint64_t right_value;
    memcpy(&left_value, left, sizeof left_value);
    memcpy(&right_value, right, sizeof right_value);
    return native_text_eq(left_value, right_value);
  }
  case NATIVE_COLLECTION_EQ_KIND_KEYWORD: {
    uint64_t left_value;
    uint64_t right_value;
    memcpy(&left_value, left, sizeof left_value);
    memcpy(&right_value, right, sizeof right_value);
    return left_value == right_value;
  }
  case NATIVE_COLLECTION_EQ_KIND_STRUCTURAL:
    return native_value_equal(equality.descriptor, left, right);
  default:
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
}

static native_map *native_map_new(native_arena *arena, int64_t capacity,
                                  int64_t key_stride, size_t key_alignment,
                                  int64_t value_stride,
                                  size_t value_alignment) {
  native_map *map;
  size_t key_bytes = native_collection_bytes(capacity, key_stride);
  size_t value_bytes = native_collection_bytes(capacity, value_stride);
  map = (native_map *)native_arena_alloc(arena, sizeof(native_map),
                                         _Alignof(native_map));
  map->keys = (key_bytes == 0U)
                  ? NULL
                  : native_arena_alloc(arena, key_bytes, key_alignment);
  map->values = (value_bytes == 0U)
                    ? NULL
                    : native_arena_alloc(arena, value_bytes, value_alignment);
  map->length = INT64_C(0);
  map->capacity = capacity;
  map->key_stride = key_stride;
  map->value_stride = value_stride;
  return map;
}

static void native_map_check(const native_map *map) {
  if ((map == NULL) || (map->length < INT64_C(0)) ||
      (map->capacity < map->length) || (map->key_stride <= INT64_C(0)) ||
      (map->value_stride <= INT64_C(0)) ||
      ((map->capacity == INT64_C(0)) &&
       ((map->keys != NULL) || (map->values != NULL))) ||
      ((map->capacity > INT64_C(0)) &&
       ((map->keys == NULL) || (map->values == NULL)))) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
}

static void native_map_check_shape(const native_map *map, int64_t key_stride,
                                   int64_t value_stride) {
  native_map_check(map);
  if ((map->key_stride != key_stride) ||
      (map->value_stride != value_stride)) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
}

int64_t native_map_count(const native_map *map) {
  native_map_check(map);
  return map->length;
}

const void *native_map_key_at(const native_map *map, int64_t index) {
  native_map_check(map);
  if ((index < INT64_C(0)) || (index >= map->length)) {
    native_trap(NATIVE_TRAP_OUT_OF_RANGE);
  }
  return (const uint8_t *)map->keys +
         native_collection_bytes(index, map->key_stride);
}

const void *native_map_value_at(const native_map *map, int64_t index) {
  native_map_check(map);
  if ((index < INT64_C(0)) || (index >= map->length)) {
    native_trap(NATIVE_TRAP_OUT_OF_RANGE);
  }
  return (const uint8_t *)map->values +
         native_collection_bytes(index, map->value_stride);
}

static int64_t native_map_find(const native_map *map, const void *key,
                               native_collection_equality equality) {
  int64_t index;
  native_map_check(map);
  if (key == NULL) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  native_collection_check_equality(equality);
  for (index = INT64_C(0); index < map->length; index++) {
    if (native_collection_equal(native_map_key_at(map, index), key, equality)) {
      return index;
    }
  }
  return INT64_C(-1);
}

const void *native_map_get(const native_map *map, const void *key,
                           native_collection_equality equality) {
  int64_t index = native_map_find(map, key, equality);
  return (index < INT64_C(0)) ? NULL : native_map_value_at(map, index);
}

bool native_map_contains(const native_map *map, const void *key,
                         native_collection_equality equality) {
  return native_map_find(map, key, equality) >= INT64_C(0);
}

native_map *native_map_from_arrays(
    native_arena *arena, const void *keys, const void *values, int64_t count,
    int64_t key_stride, size_t key_alignment, int64_t value_stride,
    size_t value_alignment, native_collection_equality equality) {
  native_map *map;
  int64_t index;
  native_collection_check_equality(equality);
  if (((keys == NULL) || (values == NULL)) && (count != INT64_C(0))) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  map = native_map_new(arena, count, key_stride, key_alignment, value_stride,
                       value_alignment);
  for (index = INT64_C(0); index < count; index++) {
    const void *key = (const uint8_t *)keys +
                      native_collection_bytes(index, key_stride);
    const void *value = (const uint8_t *)values +
                        native_collection_bytes(index, value_stride);
    int64_t prior = native_map_find(map, key, equality);
    if (prior >= INT64_C(0)) {
      memcpy((uint8_t *)map->values +
                 native_collection_bytes(prior, value_stride),
             value, (size_t)value_stride);
    } else {
      memcpy((uint8_t *)map->keys +
                 native_collection_bytes(map->length, key_stride),
             key, (size_t)key_stride);
      memcpy((uint8_t *)map->values +
                 native_collection_bytes(map->length, value_stride),
             value, (size_t)value_stride);
      map->length += INT64_C(1);
    }
  }
  return map;
}

native_map *native_map_assoc(
    native_arena *arena, native_map *map, const void *key, const void *value,
    int64_t key_stride, size_t key_alignment, int64_t value_stride,
    size_t value_alignment, native_collection_equality equality) {
  int64_t prior;
  int64_t length;
  native_map *result;
  native_map_check_shape(map, key_stride, value_stride);
  if ((key == NULL) || (value == NULL)) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  prior = native_map_find(map, key, equality);
  if ((prior < INT64_C(0)) && (map->length == INT64_MAX)) {
    native_trap(NATIVE_TRAP_OVERFLOW);
  }
  length = map->length + ((prior < INT64_C(0)) ? INT64_C(1) : INT64_C(0));
  result = native_map_new(arena, length, key_stride, key_alignment, value_stride,
                          value_alignment);
  if (map->length > INT64_C(0)) {
    memcpy(result->keys, map->keys,
           native_collection_bytes(map->length, key_stride));
    memcpy(result->values, map->values,
           native_collection_bytes(map->length, value_stride));
  }
  result->length = length;
  if (prior >= INT64_C(0)) {
    memcpy((uint8_t *)result->values +
               native_collection_bytes(prior, value_stride),
           value, (size_t)value_stride);
  } else {
    memcpy((uint8_t *)result->keys +
               native_collection_bytes(map->length, key_stride),
           key, (size_t)key_stride);
    memcpy((uint8_t *)result->values +
               native_collection_bytes(map->length, value_stride),
           value, (size_t)value_stride);
  }
  return result;
}

native_map *native_map_dissoc(
    native_arena *arena, native_map *map, const void *key, int64_t key_stride,
    size_t key_alignment, int64_t value_stride, size_t value_alignment,
    native_collection_equality equality) {
  int64_t removed;
  int64_t source_index;
  native_map *result;
  native_map_check_shape(map, key_stride, value_stride);
  removed = native_map_find(map, key, equality);
  if (removed < INT64_C(0)) {
    return map;
  }
  result = native_map_new(arena, map->length - INT64_C(1), key_stride,
                          key_alignment, value_stride, value_alignment);
  for (source_index = INT64_C(0); source_index < map->length; source_index++) {
    if (source_index != removed) {
      memcpy((uint8_t *)result->keys +
                 native_collection_bytes(result->length, key_stride),
             native_map_key_at(map, source_index), (size_t)key_stride);
      memcpy((uint8_t *)result->values +
                 native_collection_bytes(result->length, value_stride),
             native_map_value_at(map, source_index), (size_t)value_stride);
      result->length += INT64_C(1);
    }
  }
  return result;
}

native_vec *native_map_keys(native_arena *arena, const native_map *map,
                            size_t key_alignment) {
  native_vec *result;
  native_map_check(map);
  result = native_vec_new(arena, map->length, map->key_stride, key_alignment);
  if (map->length > INT64_C(0)) {
    memcpy(result->elements, map->keys,
           native_collection_bytes(map->length, map->key_stride));
  }
  result->length = map->length;
  return result;
}

native_vec *native_map_values(native_arena *arena, const native_map *map,
                              size_t value_alignment) {
  native_vec *result;
  native_map_check(map);
  result = native_vec_new(arena, map->length, map->value_stride,
                          value_alignment);
  if (map->length > INT64_C(0)) {
    memcpy(result->elements, map->values,
           native_collection_bytes(map->length, map->value_stride));
  }
  result->length = map->length;
  return result;
}

static native_set *native_set_new(native_arena *arena, int64_t capacity,
                                  int64_t stride, size_t alignment) {
  native_set *set;
  size_t bytes = native_collection_bytes(capacity, stride);
  set = (native_set *)native_arena_alloc(arena, sizeof(native_set),
                                         _Alignof(native_set));
  set->elements =
      (bytes == 0U) ? NULL : native_arena_alloc(arena, bytes, alignment);
  set->length = INT64_C(0);
  set->capacity = capacity;
  set->stride = stride;
  return set;
}

static void native_set_check(const native_set *set) {
  if ((set == NULL) || (set->length < INT64_C(0)) ||
      (set->capacity < set->length) || (set->stride <= INT64_C(0)) ||
      ((set->capacity == INT64_C(0)) && (set->elements != NULL)) ||
      ((set->capacity > INT64_C(0)) && (set->elements == NULL))) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
}

static void native_set_check_shape(const native_set *set, int64_t stride) {
  native_set_check(set);
  if (set->stride != stride) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
}

int64_t native_set_count(const native_set *set) {
  native_set_check(set);
  return set->length;
}

const void *native_set_item_at(const native_set *set, int64_t index) {
  native_set_check(set);
  if ((index < INT64_C(0)) || (index >= set->length)) {
    native_trap(NATIVE_TRAP_OUT_OF_RANGE);
  }
  return (const uint8_t *)set->elements +
         native_collection_bytes(index, set->stride);
}

static int64_t native_set_find(const native_set *set, const void *value,
                               native_collection_equality equality) {
  int64_t index;
  native_set_check(set);
  if (value == NULL) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  native_collection_check_equality(equality);
  for (index = INT64_C(0); index < set->length; index++) {
    if (native_collection_equal(native_set_item_at(set, index), value,
                                equality)) {
      return index;
    }
  }
  return INT64_C(-1);
}

bool native_set_contains(const native_set *set, const void *value,
                         native_collection_equality equality) {
  return native_set_find(set, value, equality) >= INT64_C(0);
}

native_set *native_set_from_array(
    native_arena *arena, const void *values, int64_t count, int64_t stride,
    size_t alignment, native_collection_equality equality) {
  native_set *set;
  int64_t index;
  native_collection_check_equality(equality);
  if ((values == NULL) && (count != INT64_C(0))) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  set = native_set_new(arena, count, stride, alignment);
  for (index = INT64_C(0); index < count; index++) {
    const void *value = (const uint8_t *)values +
                        native_collection_bytes(index, stride);
    if (native_set_find(set, value, equality) < INT64_C(0)) {
      memcpy((uint8_t *)set->elements +
                 native_collection_bytes(set->length, stride),
             value, (size_t)stride);
      set->length += INT64_C(1);
    }
  }
  return set;
}

native_set *native_set_conj(native_arena *arena, native_set *set,
                            const void *value, int64_t stride, size_t alignment,
                            native_collection_equality equality) {
  native_set *result;
  native_set_check_shape(set, stride);
  if (native_set_find(set, value, equality) >= INT64_C(0)) {
    return set;
  }
  if (set->length == INT64_MAX) {
    native_trap(NATIVE_TRAP_OVERFLOW);
  }
  result = native_set_new(arena, set->length + INT64_C(1), stride, alignment);
  if (set->length > INT64_C(0)) {
    memcpy(result->elements, set->elements,
           native_collection_bytes(set->length, stride));
  }
  memcpy((uint8_t *)result->elements +
             native_collection_bytes(set->length, stride),
         value, (size_t)stride);
  result->length = set->length + INT64_C(1);
  return result;
}

native_set *native_set_disj(native_arena *arena, native_set *set,
                            const void *value, int64_t stride, size_t alignment,
                            native_collection_equality equality) {
  int64_t removed;
  int64_t source_index;
  native_set *result;
  native_set_check_shape(set, stride);
  removed = native_set_find(set, value, equality);
  if (removed < INT64_C(0)) {
    return set;
  }
  result = native_set_new(arena, set->length - INT64_C(1), stride, alignment);
  for (source_index = INT64_C(0); source_index < set->length; source_index++) {
    if (source_index != removed) {
      memcpy((uint8_t *)result->elements +
                 native_collection_bytes(result->length, stride),
             native_set_item_at(set, source_index), (size_t)stride);
      result->length += INT64_C(1);
    }
  }
  return result;
}

native_vec *native_set_vector(native_arena *arena, const native_set *set,
                              size_t alignment) {
  native_vec *result;
  native_set_check(set);
  result = native_vec_new(arena, set->length, set->stride, alignment);
  if (set->length > INT64_C(0)) {
    memcpy(result->elements, set->elements,
           native_collection_bytes(set->length, set->stride));
  }
  result->length = set->length;
  return result;
}

static bool native_value_descriptor_valid(
    const native_value_descriptor *descriptor) {
  return (descriptor != NULL) &&
         (descriptor->abi_version == NATIVE_VALUE_ABI_VERSION) &&
         (descriptor->size > 0U) && (descriptor->alignment > 0U) &&
         ((descriptor->alignment & (descriptor->alignment - 1U)) == 0U);
}

static void native_value_vector_validate(
    const native_value_descriptor *descriptor, const native_vec *vector) {
  if ((vector == NULL) ||
      !native_value_descriptor_valid(descriptor->element) ||
      (descriptor->stride < descriptor->element->size) ||
      ((descriptor->stride % descriptor->element->alignment) != 0U) ||
      (vector->length < INT64_C(0)) || (vector->length > vector->capacity) ||
      ((uint64_t)vector->length > (uint64_t)(SIZE_MAX / descriptor->stride)) ||
      ((vector->length > INT64_C(0)) && (vector->elements == NULL))) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
}

static const native_value_variant_descriptor *native_value_variant(
    const native_value_descriptor *descriptor, int64_t tag) {
  size_t index;
  if ((descriptor->variants == NULL) && (descriptor->variant_count != 0U)) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  for (index = 0U; index < descriptor->variant_count; index++) {
    if (descriptor->variants[index].tag == tag) {
      return &descriptor->variants[index];
    }
  }
  native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
}

static bool native_value_equal_inner(const native_value_descriptor *descriptor,
                                     const void *left, const void *right) {
  size_t index;
  if (!native_value_descriptor_valid(descriptor) || (left == NULL) ||
      (right == NULL)) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  switch (descriptor->kind) {
    case NATIVE_VALUE_BOOL:
    case NATIVE_VALUE_SIGNED:
    case NATIVE_VALUE_UNSIGNED:
    case NATIVE_VALUE_KEYWORD:
      return memcmp(left, right, descriptor->size) == 0;

    case NATIVE_VALUE_FLOAT:
      if (descriptor->size == sizeof(float)) {
        float left_value;
        float right_value;
        memcpy(&left_value, left, sizeof left_value);
        memcpy(&right_value, right, sizeof right_value);
        return left_value == right_value;
      }
      if (descriptor->size == sizeof(double)) {
        double left_value;
        double right_value;
        memcpy(&left_value, left, sizeof left_value);
        memcpy(&right_value, right, sizeof right_value);
        return left_value == right_value;
      }
      native_trap(NATIVE_TRAP_INVALID_ARGUMENT);

    case NATIVE_VALUE_TEXT: {
      uint64_t left_handle;
      uint64_t right_handle;
      memcpy(&left_handle, left, sizeof left_handle);
      memcpy(&right_handle, right, sizeof right_handle);
      return native_text_eq(left_handle, right_handle);
    }

    case NATIVE_VALUE_BYTES: {
      native_bytes left_bytes;
      native_bytes right_bytes;
      memcpy(&left_bytes, left, sizeof left_bytes);
      memcpy(&right_bytes, right, sizeof right_bytes);
      if (left_bytes.length != right_bytes.length) {
        return false;
      }
      if (left_bytes.length == (size_t)0U) {
        return true;
      }
      if ((left_bytes.data == NULL) || (right_bytes.data == NULL)) {
        native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
      }
      return memcmp(left_bytes.data, right_bytes.data, left_bytes.length) == 0;
    }

    case NATIVE_VALUE_RECORD:
      if ((descriptor->fields == NULL) && (descriptor->field_count != 0U)) {
        native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
      }
      for (index = 0U; index < descriptor->field_count; index++) {
        const native_value_field_descriptor *field = &descriptor->fields[index];
        if (!native_value_equal_inner(
                field->value, (const uint8_t *)left + field->offset,
                (const uint8_t *)right + field->offset)) {
          return false;
        }
      }
      return true;

    case NATIVE_VALUE_UNION: {
      int64_t left_tag;
      int64_t right_tag;
      const native_value_variant_descriptor *variant;
      memcpy(&left_tag, (const uint8_t *)left + descriptor->tag_offset,
             sizeof left_tag);
      memcpy(&right_tag, (const uint8_t *)right + descriptor->tag_offset,
             sizeof right_tag);
      if (left_tag != right_tag) {
        return false;
      }
      variant = native_value_variant(descriptor, left_tag);
      if (variant->payload == NULL) {
        return true;
      }
      return native_value_equal_inner(
          variant->payload, (const uint8_t *)left + variant->payload_offset,
          (const uint8_t *)right + variant->payload_offset);
    }

    case NATIVE_VALUE_VECTOR: {
      const native_vec *left_vector;
      const native_vec *right_vector;
      memcpy(&left_vector, left, sizeof left_vector);
      memcpy(&right_vector, right, sizeof right_vector);
      if (left_vector == right_vector) {
        return true;
      }
      if ((left_vector == NULL) || (right_vector == NULL) ||
          !native_value_descriptor_valid(descriptor->element) ||
          (descriptor->stride < descriptor->element->size) ||
          ((descriptor->stride % descriptor->element->alignment) != 0U) ||
          (left_vector->length < INT64_C(0)) ||
          (right_vector->length < INT64_C(0)) ||
          (left_vector->length > left_vector->capacity) ||
          (right_vector->length > right_vector->capacity) ||
          ((left_vector->length > INT64_C(0)) &&
           (left_vector->elements == NULL)) ||
          ((right_vector->length > INT64_C(0)) &&
           (right_vector->elements == NULL))) {
        native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
      }
      if (left_vector->length != right_vector->length) {
        return false;
      }
      for (index = 0U; index < (size_t)left_vector->length; index++) {
        if (!native_value_equal_inner(
                descriptor->element,
                (const uint8_t *)left_vector->elements +
                    (index * descriptor->stride),
                (const uint8_t *)right_vector->elements +
                    (index * descriptor->stride))) {
          return false;
        }
      }
      return true;
    }

    case NATIVE_VALUE_REFERENCE: {
      const void *left_reference;
      const void *right_reference;
      memcpy(&left_reference, left, sizeof left_reference);
      memcpy(&right_reference, right, sizeof right_reference);
      if (left_reference == right_reference) {
        return true;
      }
      if ((left_reference == NULL) || (right_reference == NULL)) {
        return false;
      }
      if (descriptor->element == NULL) {
        native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
      }
      return native_value_equal_inner(descriptor->element, left_reference,
                                      right_reference);
    }

    case NATIVE_VALUE_MAP:
      native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
}

bool native_value_equal(const native_value_descriptor *descriptor,
                        const void *left, const void *right) {
  return native_value_equal_inner(descriptor, left, right);
}

#define NATIVE_VALUE_HASH_OFFSET UINT64_C(14695981039346656037)
#define NATIVE_VALUE_HASH_PRIME UINT64_C(1099511628211)

static uint64_t native_value_semantic_unsigned(const void *value, size_t size) {
  if (size == sizeof(uint8_t)) {
    uint8_t result;
    memcpy(&result, value, sizeof result);
    return (uint64_t)result;
  }
  if (size == sizeof(uint16_t)) {
    uint16_t result;
    memcpy(&result, value, sizeof result);
    return (uint64_t)result;
  }
  if (size == sizeof(uint32_t)) {
    uint32_t result;
    memcpy(&result, value, sizeof result);
    return (uint64_t)result;
  }
  if (size == sizeof(uint64_t)) {
    uint64_t result;
    memcpy(&result, value, sizeof result);
    return result;
  }
  native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
}

static int64_t native_value_semantic_signed(const void *value, size_t size) {
  if (size == sizeof(int8_t)) {
    int8_t result;
    memcpy(&result, value, sizeof result);
    return (int64_t)result;
  }
  if (size == sizeof(int16_t)) {
    int16_t result;
    memcpy(&result, value, sizeof result);
    return (int64_t)result;
  }
  if (size == sizeof(int32_t)) {
    int32_t result;
    memcpy(&result, value, sizeof result);
    return (int64_t)result;
  }
  if (size == sizeof(int64_t)) {
    int64_t result;
    memcpy(&result, value, sizeof result);
    return result;
  }
  native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
}

static void native_value_hash_byte(uint64_t *state, uint8_t value) {
  *state ^= (uint64_t)value;
  *state *= NATIVE_VALUE_HASH_PRIME;
}

/* Canonical low-byte-first encoding makes the hash independent of host byte
   order while retaining the full fixed-width semantic value. */
static void native_value_hash_u64(uint64_t *state, uint64_t value) {
  uint32_t shift;
  for (shift = UINT32_C(0); shift < UINT32_C(64); shift += UINT32_C(8)) {
    native_value_hash_byte(state, (uint8_t)(value >> shift));
  }
}

static void native_value_hash_float(
    const native_value_descriptor *descriptor, const void *value,
    uint64_t *state) {
  if (descriptor->size == sizeof(float)) {
    float number;
    uint32_t bits;
    memcpy(&number, value, sizeof number);
    memcpy(&bits, value, sizeof bits);
    if (number == 0.0F) {
      bits = UINT32_C(0);
    } else if (number != number) {
      bits = UINT32_C(0x7fc00000);
    }
    native_value_hash_u64(state, (uint64_t)bits);
    return;
  }
  if (descriptor->size == sizeof(double)) {
    double number;
    uint64_t bits;
    memcpy(&number, value, sizeof number);
    memcpy(&bits, value, sizeof bits);
    if (number == 0.0) {
      bits = UINT64_C(0);
    } else if (number != number) {
      bits = UINT64_C(0x7ff8000000000000);
    }
    native_value_hash_u64(state, bits);
    return;
  }
  native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
}

static void native_value_hash_inner(const native_value_descriptor *descriptor,
                                    const void *value, uint64_t *state) {
  size_t index;
  if (!native_value_descriptor_valid(descriptor) || (value == NULL) ||
      (state == NULL)) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  native_value_hash_u64(state, (uint64_t)descriptor->kind);
  switch (descriptor->kind) {
    case NATIVE_VALUE_BOOL: {
      bool boolean;
      if (descriptor->size != sizeof boolean) {
        native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
      }
      memcpy(&boolean, value, sizeof boolean);
      native_value_hash_u64(state, boolean ? UINT64_C(1) : UINT64_C(0));
      return;
    }

    case NATIVE_VALUE_SIGNED:
      native_value_hash_u64(
          state, (uint64_t)native_value_semantic_signed(value, descriptor->size));
      return;

    case NATIVE_VALUE_UNSIGNED:
    case NATIVE_VALUE_KEYWORD:
      native_value_hash_u64(
          state, native_value_semantic_unsigned(value, descriptor->size));
      return;

    case NATIVE_VALUE_FLOAT:
      native_value_hash_float(descriptor, value, state);
      return;

    case NATIVE_VALUE_TEXT: {
      uint64_t handle;
      uint64_t length;
      const uint8_t *bytes;
      uint64_t offset;
      if (descriptor->size != sizeof handle) {
        native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
      }
      memcpy(&handle, value, sizeof handle);
      length = native_text_length(handle);
      bytes = native_text_bytes(handle);
      native_value_hash_u64(state, length);
      for (offset = UINT64_C(0); offset < length; offset++) {
        native_value_hash_byte(state, bytes[offset]);
      }
      return;
    }

    case NATIVE_VALUE_BYTES: {
      native_bytes bytes;
      size_t offset;
      if (descriptor->size != sizeof bytes) {
        native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
      }
      memcpy(&bytes, value, sizeof bytes);
      if ((bytes.data == NULL) && (bytes.length != 0U)) {
        native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
      }
      native_value_hash_u64(state, (uint64_t)bytes.length);
      for (offset = 0U; offset < bytes.length; offset++) {
        native_value_hash_byte(state, bytes.data[offset]);
      }
      return;
    }

    case NATIVE_VALUE_RECORD:
      if ((descriptor->fields == NULL) && (descriptor->field_count != 0U)) {
        native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
      }
      native_value_hash_u64(state, (uint64_t)descriptor->field_count);
      for (index = 0U; index < descriptor->field_count; index++) {
        const native_value_field_descriptor *field = &descriptor->fields[index];
        native_value_hash_inner(field->value,
                                (const uint8_t *)value + field->offset, state);
      }
      return;

    case NATIVE_VALUE_UNION: {
      int64_t tag;
      const native_value_variant_descriptor *variant;
      memcpy(&tag, (const uint8_t *)value + descriptor->tag_offset, sizeof tag);
      variant = native_value_variant(descriptor, tag);
      native_value_hash_u64(state, (uint64_t)tag);
      if (variant->payload != NULL) {
        native_value_hash_inner(
            variant->payload,
            (const uint8_t *)value + variant->payload_offset, state);
      }
      return;
    }

    case NATIVE_VALUE_VECTOR: {
      const native_vec *vector;
      memcpy(&vector, value, sizeof vector);
      native_value_vector_validate(descriptor, vector);
      native_value_hash_u64(state, (uint64_t)vector->length);
      for (index = 0U; index < (size_t)vector->length; index++) {
        native_value_hash_inner(
            descriptor->element,
            (const uint8_t *)vector->elements + (index * descriptor->stride),
            state);
      }
      return;
    }

    case NATIVE_VALUE_REFERENCE: {
      const void *reference;
      if ((descriptor->size != sizeof reference) ||
          !native_value_descriptor_valid(descriptor->element)) {
        native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
      }
      memcpy(&reference, value, sizeof reference);
      if (reference == NULL) {
        native_value_hash_u64(state, UINT64_C(0));
      } else {
        native_value_hash_u64(state, UINT64_C(1));
        native_value_hash_inner(descriptor->element, reference, state);
      }
      return;
    }

    case NATIVE_VALUE_MAP:
      native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
}

int64_t native_value_hash(const native_value_descriptor *descriptor,
                          const void *value) {
  uint64_t state = NATIVE_VALUE_HASH_OFFSET;
  native_value_hash_inner(descriptor, value, &state);
  return (int64_t)(state & UINT64_C(0x7fffffffffffffff));
}

static int64_t native_value_order_i64(int64_t left, int64_t right) {
  return (left < right) ? INT64_C(-1) : ((left > right) ? INT64_C(1) : INT64_C(0));
}

static int64_t native_value_order_u64(uint64_t left, uint64_t right) {
  return (left < right) ? INT64_C(-1) : ((left > right) ? INT64_C(1) : INT64_C(0));
}

static int64_t native_value_compare_float(
    const native_value_descriptor *descriptor, const void *left,
    const void *right) {
  if (descriptor->size == sizeof(float)) {
    float left_number;
    float right_number;
    uint32_t left_bits;
    uint32_t right_bits;
    bool left_nan;
    bool right_nan;
    memcpy(&left_number, left, sizeof left_number);
    memcpy(&right_number, right, sizeof right_number);
    memcpy(&left_bits, left, sizeof left_bits);
    memcpy(&right_bits, right, sizeof right_bits);
    left_nan = left_number != left_number;
    right_nan = right_number != right_number;
    if (left_nan || right_nan) {
      if (left_nan && right_nan) {
        return native_value_order_u64((uint64_t)left_bits,
                                      (uint64_t)right_bits);
      }
      return left_nan ? INT64_C(1) : INT64_C(-1);
    }
    if (left_number == right_number) {
      return INT64_C(0);
    }
    return (left_number < right_number) ? INT64_C(-1) : INT64_C(1);
  }
  if (descriptor->size == sizeof(double)) {
    double left_number;
    double right_number;
    uint64_t left_bits;
    uint64_t right_bits;
    bool left_nan;
    bool right_nan;
    memcpy(&left_number, left, sizeof left_number);
    memcpy(&right_number, right, sizeof right_number);
    memcpy(&left_bits, left, sizeof left_bits);
    memcpy(&right_bits, right, sizeof right_bits);
    left_nan = left_number != left_number;
    right_nan = right_number != right_number;
    if (left_nan || right_nan) {
      if (left_nan && right_nan) {
        return native_value_order_u64(left_bits, right_bits);
      }
      return left_nan ? INT64_C(1) : INT64_C(-1);
    }
    if (left_number == right_number) {
      return INT64_C(0);
    }
    return (left_number < right_number) ? INT64_C(-1) : INT64_C(1);
  }
  native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
}

static int64_t native_value_compare_text(const void *left, const void *right) {
  uint64_t left_handle;
  uint64_t right_handle;
  uint64_t left_length;
  uint64_t right_length;
  uint64_t common;
  int compared;
  memcpy(&left_handle, left, sizeof left_handle);
  memcpy(&right_handle, right, sizeof right_handle);
  left_length = native_text_length(left_handle);
  right_length = native_text_length(right_handle);
  common = (left_length < right_length) ? left_length : right_length;
  if (common > (uint64_t)SIZE_MAX) {
    native_trap(NATIVE_TRAP_OVERFLOW);
  }
  compared = memcmp(native_text_bytes(left_handle), native_text_bytes(right_handle),
                    (size_t)common);
  if (compared < 0) {
    return INT64_C(-1);
  }
  if (compared > 0) {
    return INT64_C(1);
  }
  return native_value_order_u64(left_length, right_length);
}

static int64_t native_value_compare_bytes(const void *left, const void *right) {
  native_bytes left_bytes;
  native_bytes right_bytes;
  size_t common;
  int compared;
  memcpy(&left_bytes, left, sizeof left_bytes);
  memcpy(&right_bytes, right, sizeof right_bytes);
  if (((left_bytes.data == NULL) && (left_bytes.length != 0U)) ||
      ((right_bytes.data == NULL) && (right_bytes.length != 0U))) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  common = (left_bytes.length < right_bytes.length) ? left_bytes.length
                                                    : right_bytes.length;
  compared = (common == 0U) ? 0 : memcmp(left_bytes.data, right_bytes.data, common);
  if (compared < 0) {
    return INT64_C(-1);
  }
  if (compared > 0) {
    return INT64_C(1);
  }
  return (left_bytes.length < right_bytes.length)
             ? INT64_C(-1)
             : ((left_bytes.length > right_bytes.length) ? INT64_C(1)
                                                         : INT64_C(0));
}

static int64_t native_value_compare_inner(
    const native_value_descriptor *descriptor, const void *left,
    const void *right) {
  size_t index;
  if (!native_value_descriptor_valid(descriptor) || (left == NULL) ||
      (right == NULL)) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  switch (descriptor->kind) {
    case NATIVE_VALUE_BOOL: {
      bool left_boolean;
      bool right_boolean;
      if (descriptor->size != sizeof left_boolean) {
        native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
      }
      memcpy(&left_boolean, left, sizeof left_boolean);
      memcpy(&right_boolean, right, sizeof right_boolean);
      return native_value_order_u64(left_boolean ? UINT64_C(1) : UINT64_C(0),
                                    right_boolean ? UINT64_C(1) : UINT64_C(0));
    }

    case NATIVE_VALUE_SIGNED:
      return native_value_order_i64(
          native_value_semantic_signed(left, descriptor->size),
          native_value_semantic_signed(right, descriptor->size));

    case NATIVE_VALUE_UNSIGNED:
    case NATIVE_VALUE_KEYWORD:
      return native_value_order_u64(
          native_value_semantic_unsigned(left, descriptor->size),
          native_value_semantic_unsigned(right, descriptor->size));

    case NATIVE_VALUE_FLOAT:
      return native_value_compare_float(descriptor, left, right);

    case NATIVE_VALUE_TEXT:
      if (descriptor->size != sizeof(uint64_t)) {
        native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
      }
      return native_value_compare_text(left, right);

    case NATIVE_VALUE_BYTES:
      if (descriptor->size != sizeof(native_bytes)) {
        native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
      }
      return native_value_compare_bytes(left, right);

    case NATIVE_VALUE_RECORD:
      if ((descriptor->fields == NULL) && (descriptor->field_count != 0U)) {
        native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
      }
      for (index = 0U; index < descriptor->field_count; index++) {
        const native_value_field_descriptor *field = &descriptor->fields[index];
        int64_t compared = native_value_compare_inner(
            field->value, (const uint8_t *)left + field->offset,
            (const uint8_t *)right + field->offset);
        if (compared != INT64_C(0)) {
          return compared;
        }
      }
      return INT64_C(0);

    case NATIVE_VALUE_UNION: {
      int64_t left_tag;
      int64_t right_tag;
      const native_value_variant_descriptor *variant;
      memcpy(&left_tag, (const uint8_t *)left + descriptor->tag_offset,
             sizeof left_tag);
      memcpy(&right_tag, (const uint8_t *)right + descriptor->tag_offset,
             sizeof right_tag);
      if (left_tag != right_tag) {
        return native_value_order_i64(left_tag, right_tag);
      }
      variant = native_value_variant(descriptor, left_tag);
      if (variant->payload == NULL) {
        return INT64_C(0);
      }
      return native_value_compare_inner(
          variant->payload, (const uint8_t *)left + variant->payload_offset,
          (const uint8_t *)right + variant->payload_offset);
    }

    case NATIVE_VALUE_VECTOR: {
      const native_vec *left_vector;
      const native_vec *right_vector;
      size_t common;
      memcpy(&left_vector, left, sizeof left_vector);
      memcpy(&right_vector, right, sizeof right_vector);
      native_value_vector_validate(descriptor, left_vector);
      if (left_vector == right_vector) {
        return INT64_C(0);
      }
      native_value_vector_validate(descriptor, right_vector);
      common = (size_t)((left_vector->length < right_vector->length)
                            ? left_vector->length
                            : right_vector->length);
      for (index = 0U; index < common; index++) {
        int64_t compared = native_value_compare_inner(
            descriptor->element,
            (const uint8_t *)left_vector->elements +
                (index * descriptor->stride),
            (const uint8_t *)right_vector->elements +
                (index * descriptor->stride));
        if (compared != INT64_C(0)) {
          return compared;
        }
      }
      return native_value_order_i64(left_vector->length,
                                    right_vector->length);
    }

    case NATIVE_VALUE_REFERENCE: {
      const void *left_reference;
      const void *right_reference;
      if ((descriptor->size != sizeof left_reference) ||
          !native_value_descriptor_valid(descriptor->element)) {
        native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
      }
      memcpy(&left_reference, left, sizeof left_reference);
      memcpy(&right_reference, right, sizeof right_reference);
      if (left_reference == right_reference) {
        return INT64_C(0);
      }
      if (left_reference == NULL) {
        return INT64_C(-1);
      }
      if (right_reference == NULL) {
        return INT64_C(1);
      }
      return native_value_compare_inner(descriptor->element, left_reference,
                                        right_reference);
    }

    case NATIVE_VALUE_MAP:
      native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
}

int64_t native_value_compare(const native_value_descriptor *descriptor,
                             const void *left, const void *right) {
  return native_value_compare_inner(descriptor, left, right);
}

native_vec *native_vec_sort(native_arena *arena, const native_vec *source,
                            const native_value_descriptor *element,
                            int64_t stride, size_t alignment) {
  native_vec *result;
  void *held;
  int64_t position;
  if (!native_value_descriptor_valid(element) || (source == NULL) ||
      (stride <= INT64_C(0)) || ((size_t)stride < element->size) ||
      ((size_t)stride % element->alignment != 0U) ||
      (alignment < element->alignment) ||
      ((alignment & (alignment - 1U)) != 0U) ||
      (source->length < INT64_C(0)) ||
      (source->capacity < source->length) ||
      ((source->capacity == INT64_C(0)) && (source->elements != NULL)) ||
      ((source->capacity > INT64_C(0)) && (source->elements == NULL))) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  result = native_vec_slice(arena, source, INT64_C(0), source->length,
                            stride, alignment);
  if (result->length < INT64_C(2)) {
    return result;
  }
  held = native_arena_alloc(arena, (size_t)stride, alignment);
  for (position = INT64_C(1); position < result->length; ++position) {
    int64_t insertion = position;
    memcpy(held,
           (const uint8_t *)result->elements +
               native_vec_bytes(position, stride),
           (size_t)stride);
    while (insertion > INT64_C(0)) {
      const void *previous =
          (const uint8_t *)result->elements +
          native_vec_bytes(insertion - INT64_C(1), stride);
      if (native_value_compare(element, previous, held) <= INT64_C(0)) {
        break;
      }
      memmove((uint8_t *)result->elements +
                  native_vec_bytes(insertion, stride),
              previous, (size_t)stride);
      insertion -= INT64_C(1);
    }
    memcpy((uint8_t *)result->elements + native_vec_bytes(insertion, stride),
           held, (size_t)stride);
  }
  return result;
}

#define NATIVE_VALUE_TEXT_MAX_DEPTH 128U
#define NATIVE_VALUE_FLOAT_BUFFER 64U

typedef struct native_value_text_writer {
  uint8_t *bytes;
  size_t capacity;
  size_t length;
} native_value_text_writer;

static bool native_value_signed_size(size_t size) {
  return (size == sizeof(int8_t)) || (size == sizeof(int16_t)) ||
         (size == sizeof(int32_t)) || (size == sizeof(int64_t));
}

static void native_value_text_descriptor_inner(
    const native_value_descriptor *descriptor,
    const native_value_descriptor **stack, size_t depth) {
  size_t index;
  if (!native_value_descriptor_valid(descriptor) ||
      (depth >= NATIVE_VALUE_TEXT_MAX_DEPTH)) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  for (index = 0U; index < depth; index++) {
    if (stack[index] == descriptor) {
      native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
    }
  }
  stack[depth] = descriptor;
  switch (descriptor->kind) {
    case NATIVE_VALUE_BOOL:
      if (descriptor->size != sizeof(bool)) {
        native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
      }
      return;

    case NATIVE_VALUE_SIGNED:
      if (!native_value_signed_size(descriptor->size)) {
        native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
      }
      return;

    case NATIVE_VALUE_FLOAT:
      if ((descriptor->size != sizeof(float)) &&
          (descriptor->size != sizeof(double))) {
        native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
      }
      return;

    case NATIVE_VALUE_TEXT:
      if (descriptor->size != sizeof(uint64_t)) {
        native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
      }
      return;

    case NATIVE_VALUE_KEYWORD:
      if ((descriptor->size != sizeof(uint64_t)) ||
          (descriptor->keywords == NULL) ||
          (descriptor->keyword_count == 0U)) {
        native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
      }
      for (index = 0U; index < descriptor->keyword_count; index++) {
        if ((descriptor->keywords[index].bytes == NULL) &&
            (descriptor->keywords[index].length != 0U)) {
          native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
        }
      }
      return;

    case NATIVE_VALUE_UNION:
      if ((descriptor->variants == NULL) ||
          (descriptor->variant_count == 0U) ||
          (descriptor->tag_offset > descriptor->size) ||
          ((descriptor->size - descriptor->tag_offset) < sizeof(int64_t))) {
        native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
      }
      for (index = 0U; index < descriptor->variant_count; index++) {
        const native_value_variant_descriptor *variant =
            &descriptor->variants[index];
        size_t prior;
        for (prior = 0U; prior < index; prior++) {
          if (descriptor->variants[prior].tag == variant->tag) {
            native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
          }
        }
        if (variant->payload != NULL) {
          if (!native_value_descriptor_valid(variant->payload) ||
              (variant->payload_offset > descriptor->size) ||
              (variant->payload->size >
               (descriptor->size - variant->payload_offset)) ||
              ((variant->payload_offset % variant->payload->alignment) != 0U)) {
            native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
          }
          native_value_text_descriptor_inner(variant->payload, stack,
                                             depth + 1U);
        }
      }
      return;

    case NATIVE_VALUE_VECTOR:
      if ((descriptor->size != sizeof(native_vec *)) ||
          !native_value_descriptor_valid(descriptor->element) ||
          (descriptor->stride > (size_t)INT64_MAX) ||
          (descriptor->stride < descriptor->element->size) ||
          ((descriptor->stride % descriptor->element->alignment) != 0U)) {
        native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
      }
      native_value_text_descriptor_inner(descriptor->element, stack,
                                         depth + 1U);
      return;

    case NATIVE_VALUE_MAP:
      if ((descriptor->size != sizeof(native_map *)) ||
          !native_value_descriptor_valid(descriptor->map_key) ||
          !native_value_descriptor_valid(descriptor->map_value) ||
          (descriptor->map_key->size > (size_t)INT64_MAX) ||
          (descriptor->map_value->size > (size_t)INT64_MAX)) {
        native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
      }
      native_value_text_descriptor_inner(descriptor->map_key, stack,
                                         depth + 1U);
      native_value_text_descriptor_inner(descriptor->map_value, stack,
                                         depth + 1U);
      return;

    case NATIVE_VALUE_UNSIGNED:
    case NATIVE_VALUE_RECORD:
    case NATIVE_VALUE_REFERENCE:
    case NATIVE_VALUE_BYTES:
      native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
}

static void native_value_text_append(native_value_text_writer *writer,
                                     const void *bytes, size_t length) {
  if ((writer == NULL) || (writer->length > (SIZE_MAX - length)) ||
      ((bytes == NULL) && (length != 0U))) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  if (writer->bytes != NULL) {
    if ((writer->length > writer->capacity) ||
        (length > (writer->capacity - writer->length))) {
      native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
    }
    if (length != 0U) {
      memcpy(writer->bytes + writer->length, bytes, length);
    }
  }
  writer->length += length;
}

static void native_value_text_character(native_value_text_writer *writer,
                                        uint8_t byte) {
  native_value_text_append(writer, &byte, 1U);
}

static int64_t native_value_read_signed(const native_value_descriptor *descriptor,
                                        const void *value) {
  switch (descriptor->size) {
    case sizeof(int8_t): {
      int8_t result;
      memcpy(&result, value, sizeof result);
      return (int64_t)result;
    }
    case sizeof(int16_t): {
      int16_t result;
      memcpy(&result, value, sizeof result);
      return (int64_t)result;
    }
    case sizeof(int32_t): {
      int32_t result;
      memcpy(&result, value, sizeof result);
      return (int64_t)result;
    }
    case sizeof(int64_t): {
      int64_t result;
      memcpy(&result, value, sizeof result);
      return result;
    }
    default:
      native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
}

static size_t native_value_i64_text(int64_t value, char output[21]) {
  char reversed[20];
  uint64_t magnitude;
  size_t count = 0U;
  size_t position = 0U;
  if (value < INT64_C(0)) {
    magnitude = (uint64_t)(-(value + INT64_C(1))) + UINT64_C(1);
    output[position++] = '-';
  } else {
    magnitude = (uint64_t)value;
  }
  do {
    reversed[count++] = (char)('0' + (magnitude % UINT64_C(10)));
    magnitude /= UINT64_C(10);
  } while (magnitude != UINT64_C(0));
  while (count > 0U) {
    output[position++] = reversed[--count];
  }
  return position;
}

static bool native_value_float_roundtrips(const char *text, double value,
                                          bool single) {
  char *end = NULL;
  double parsed = strtod(text, &end);
  if ((end == NULL) || (*end != '\0')) {
    return false;
  }
  if (single) {
    float expected = (float)value;
    float actual = (float)parsed;
    uint32_t expected_bits;
    uint32_t actual_bits;
    memcpy(&expected_bits, &expected, sizeof expected_bits);
    memcpy(&actual_bits, &actual, sizeof actual_bits);
    return expected_bits == actual_bits;
  }
  {
    uint64_t expected_bits;
    uint64_t actual_bits;
    memcpy(&expected_bits, &value, sizeof expected_bits);
    memcpy(&actual_bits, &parsed, sizeof actual_bits);
    return expected_bits == actual_bits;
  }
}

static size_t native_value_exponent_text(int64_t exponent, char *output) {
  char reversed[8];
  uint64_t magnitude;
  size_t count = 0U;
  size_t position = 0U;
  if (exponent < INT64_C(0)) {
    output[position++] = '-';
    magnitude = (uint64_t)(-exponent);
  } else {
    magnitude = (uint64_t)exponent;
  }
  do {
    reversed[count++] = (char)('0' + (magnitude % UINT64_C(10)));
    magnitude /= UINT64_C(10);
  } while (magnitude != UINT64_C(0));
  while (count > 0U) {
    output[position++] = reversed[--count];
  }
  return position;
}

/* Precision search supplies the shortest round-tripping significand; the
   second step fixes spelling independently of libc's %g exponent policy. */
static size_t native_value_float_text(double value, bool single,
                                      char output[NATIVE_VALUE_FLOAT_BUFFER]) {
  char raw[NATIVE_VALUE_FLOAT_BUFFER];
  char digits[NATIVE_VALUE_FLOAT_BUFFER];
  int maximum = single ? 9 : 17;
  int precision;
  size_t raw_length;
  size_t index;
  size_t digit_count = 0U;
  size_t digits_before_decimal = 0U;
  size_t leading = 0U;
  size_t trailing;
  size_t position = 0U;
  int64_t exponent = INT64_C(0);
  int64_t decimal_position;
  bool decimal_seen = false;
  bool negative = signbit(value) != 0;

  if (isnan(value)) {
    memcpy(output, "NaN", 3U);
    return 3U;
  }
  if (isinf(value)) {
    if (negative) {
      memcpy(output, "-Infinity", 9U);
      return 9U;
    }
    memcpy(output, "Infinity", 8U);
    return 8U;
  }

  raw[0] = '\0';
  for (precision = 1; precision <= maximum; precision++) {
    int written = snprintf(raw, sizeof raw, "%.*g", precision, value);
    if ((written < 0) || ((size_t)written >= sizeof raw)) {
      native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
    }
    if (native_value_float_roundtrips(raw, value, single)) {
      break;
    }
  }
  if (precision > maximum) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }

  raw_length = strlen(raw);
  index = negative ? 1U : 0U;
  while ((index < raw_length) && (raw[index] != 'e') &&
         (raw[index] != 'E')) {
    uint8_t byte = (uint8_t)raw[index];
    if ((byte >= (uint8_t)'0') && (byte <= (uint8_t)'9')) {
      digits[digit_count++] = (char)byte;
      if (!decimal_seen) {
        digits_before_decimal += 1U;
      }
    } else {
      decimal_seen = true;
    }
    index += 1U;
  }
  if (index < raw_length) {
    bool exponent_negative = false;
    index += 1U;
    if ((index < raw_length) &&
        ((raw[index] == '+') || (raw[index] == '-'))) {
      exponent_negative = raw[index] == '-';
      index += 1U;
    }
    while (index < raw_length) {
      uint8_t byte = (uint8_t)raw[index++];
      if ((byte < (uint8_t)'0') || (byte > (uint8_t)'9') ||
          (exponent > INT64_C(10000))) {
        native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
      }
      exponent = (exponent * INT64_C(10)) +
                 (int64_t)(byte - (uint8_t)'0');
    }
    if (exponent_negative) {
      exponent = -exponent;
    }
  }
  if (digit_count == 0U) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  while ((leading + 1U < digit_count) && (digits[leading] == '0')) {
    leading += 1U;
  }
  trailing = digit_count;
  while ((trailing > leading + 1U) && (digits[trailing - 1U] == '0')) {
    trailing -= 1U;
  }
  decimal_position = (int64_t)digits_before_decimal + exponent -
                     (int64_t)leading;

  if (negative) {
    output[position++] = '-';
  }
  if ((decimal_position > INT64_C(-3)) &&
      (decimal_position <= INT64_C(7))) {
    if (decimal_position <= INT64_C(0)) {
      int64_t zeros;
      output[position++] = '0';
      output[position++] = '.';
      for (zeros = decimal_position; zeros < INT64_C(0); zeros++) {
        output[position++] = '0';
      }
      for (index = leading; index < trailing; index++) {
        output[position++] = digits[index];
      }
    } else {
      size_t significant = trailing - leading;
      size_t whole = (size_t)decimal_position;
      for (index = 0U; index < whole; index++) {
        output[position++] = (index < significant)
                                 ? digits[leading + index]
                                 : '0';
      }
      output[position++] = '.';
      if (whole >= significant) {
        output[position++] = '0';
      } else {
        for (index = whole; index < significant; index++) {
          output[position++] = digits[leading + index];
        }
      }
    }
  } else {
    output[position++] = digits[leading];
    output[position++] = '.';
    if ((leading + 1U) >= trailing) {
      output[position++] = '0';
    } else {
      for (index = leading + 1U; index < trailing; index++) {
        output[position++] = digits[index];
      }
    }
    output[position++] = 'E';
    position += native_value_exponent_text(decimal_position - INT64_C(1),
                                           output + position);
  }
  if (position >= NATIVE_VALUE_FLOAT_BUFFER) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  return position;
}

static void native_value_text_escaped(native_value_text_writer *writer,
                                      const uint8_t *bytes, size_t length) {
  size_t index;
  native_value_text_character(writer, (uint8_t)'"');
  for (index = 0U; index < length; index++) {
    const char *escape = NULL;
    switch (bytes[index]) {
      case (uint8_t)'"': escape = "\\\""; break;
      case (uint8_t)'\\': escape = "\\\\"; break;
      case (uint8_t)'\b': escape = "\\b"; break;
      case (uint8_t)'\f': escape = "\\f"; break;
      case (uint8_t)'\n': escape = "\\n"; break;
      case (uint8_t)'\r': escape = "\\r"; break;
      case (uint8_t)'\t': escape = "\\t"; break;
      default: break;
    }
    if (escape == NULL) {
      native_value_text_character(writer, bytes[index]);
    } else {
      native_value_text_append(writer, escape, 2U);
    }
  }
  native_value_text_character(writer, (uint8_t)'"');
}

static void native_value_text_inner(const native_value_descriptor *descriptor,
                                    const void *value, bool readable,
                                    size_t depth,
                                    native_value_text_writer *writer) {
  if ((value == NULL) || (depth >= NATIVE_VALUE_TEXT_MAX_DEPTH)) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  switch (descriptor->kind) {
    case NATIVE_VALUE_BOOL: {
      bool boolean;
      memcpy(&boolean, value, sizeof boolean);
      if (boolean) {
        native_value_text_append(writer, "true", 4U);
      } else {
        native_value_text_append(writer, "false", 5U);
      }
      return;
    }

    case NATIVE_VALUE_SIGNED: {
      char text[21];
      size_t length =
          native_value_i64_text(native_value_read_signed(descriptor, value), text);
      native_value_text_append(writer, text, length);
      return;
    }

    case NATIVE_VALUE_FLOAT: {
      double number;
      char text[NATIVE_VALUE_FLOAT_BUFFER];
      size_t length;
      bool single = descriptor->size == sizeof(float);
      if (single) {
        float narrow;
        memcpy(&narrow, value, sizeof narrow);
        number = (double)narrow;
      } else {
        memcpy(&number, value, sizeof number);
      }
      length = native_value_float_text(number, single, text);
      native_value_text_append(writer, text, length);
      return;
    }

    case NATIVE_VALUE_TEXT: {
      uint64_t handle;
      uint64_t length;
      size_t narrowed_length;
      const uint8_t *bytes;
      memcpy(&handle, value, sizeof handle);
      length = native_text_length(handle);
      narrowed_length = (size_t)length;
      if ((uint64_t)narrowed_length != length) {
        native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
      }
      bytes = native_text_bytes(handle);
      if (readable) {
        native_value_text_escaped(writer, bytes, narrowed_length);
      } else {
        native_value_text_append(writer, bytes, narrowed_length);
      }
      return;
    }

    case NATIVE_VALUE_KEYWORD: {
      uint64_t handle;
      const native_value_keyword_descriptor *keyword;
      memcpy(&handle, value, sizeof handle);
      if (handle >= (uint64_t)descriptor->keyword_count) {
        native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
      }
      keyword = &descriptor->keywords[(size_t)handle];
      native_value_text_character(writer, (uint8_t)':');
      native_value_text_append(writer, keyword->bytes, keyword->length);
      return;
    }

    case NATIVE_VALUE_UNION: {
      int64_t tag;
      const native_value_variant_descriptor *variant;
      memcpy(&tag, (const uint8_t *)value + descriptor->tag_offset,
             sizeof tag);
      variant = native_value_variant(descriptor, tag);
      if (variant->payload == NULL) {
        if (readable) {
          native_value_text_append(writer, "nil", 3U);
        }
        return;
      }
      native_value_text_inner(
          variant->payload,
          (const uint8_t *)value + variant->payload_offset,
          readable, depth + 1U, writer);
      return;
    }

    case NATIVE_VALUE_VECTOR: {
      const native_vec *vector;
      int64_t count;
      int64_t index;
      memcpy(&vector, value, sizeof vector);
      count = native_vec_length(vector);
      if ((count < INT64_C(0)) || (count > vector->capacity) ||
          ((count > INT64_C(0)) && (vector->elements == NULL)) ||
          ((vector->elements != NULL) &&
           (((uintptr_t)vector->elements % descriptor->element->alignment) !=
            0U))) {
        native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
      }
      native_value_text_character(writer, (uint8_t)'[');
      for (index = INT64_C(0); index < count; index++) {
        if (index != INT64_C(0)) {
          native_value_text_character(writer, (uint8_t)' ');
        }
        native_value_text_inner(
            descriptor->element,
            native_vec_at(vector, index, (int64_t)descriptor->stride),
            true, depth + 1U, writer);
      }
      native_value_text_character(writer, (uint8_t)']');
      return;
    }

    case NATIVE_VALUE_MAP: {
      const native_map *map;
      int64_t count;
      int64_t index;
      memcpy(&map, value, sizeof map);
      count = native_map_count(map);
      if ((map->key_stride < (int64_t)descriptor->map_key->size) ||
          (map->value_stride < (int64_t)descriptor->map_value->size) ||
          (((size_t)map->key_stride % descriptor->map_key->alignment) != 0U) ||
          (((size_t)map->value_stride % descriptor->map_value->alignment) !=
           0U) ||
          ((map->keys != NULL) &&
           (((uintptr_t)map->keys % descriptor->map_key->alignment) != 0U)) ||
          ((map->values != NULL) &&
           (((uintptr_t)map->values % descriptor->map_value->alignment) !=
            0U))) {
        native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
      }
      native_value_text_character(writer, (uint8_t)'{');
      for (index = INT64_C(0); index < count; index++) {
        if (index != INT64_C(0)) {
          native_value_text_append(writer, ", ", 2U);
        }
        native_value_text_inner(descriptor->map_key,
                                native_map_key_at(map, index), true,
                                depth + 1U, writer);
        native_value_text_character(writer, (uint8_t)' ');
        native_value_text_inner(descriptor->map_value,
                                native_map_value_at(map, index), true,
                                depth + 1U, writer);
      }
      native_value_text_character(writer, (uint8_t)'}');
      return;
    }

    case NATIVE_VALUE_UNSIGNED:
    case NATIVE_VALUE_RECORD:
    case NATIVE_VALUE_REFERENCE:
    case NATIVE_VALUE_BYTES:
      native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
}

uint64_t native_value_to_text(native_arena *arena,
                              const native_value_descriptor *descriptor,
                              const void *value,
                              native_value_text_mode mode) {
  const native_value_descriptor *stack[NATIVE_VALUE_TEXT_MAX_DEPTH];
  native_value_text_writer measured = { NULL, 0U, 0U };
  native_value_text_writer rendered;
  uint8_t *bytes = NULL;
  uint64_t handle;
  uint64_t output_length;
  bool readable;
  if ((mode != NATIVE_VALUE_STR) && (mode != NATIVE_VALUE_PR_STR)) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  native_value_text_descriptor_inner(descriptor, stack, 0U);
  readable = mode == NATIVE_VALUE_PR_STR;
  native_value_text_inner(descriptor, value, readable, 0U, &measured);
  output_length = (uint64_t)measured.length;
  if ((size_t)output_length != measured.length) {
    native_trap(NATIVE_TRAP_OVERFLOW);
  }
  handle = native_text_alloc(arena, output_length, &bytes);
  rendered.bytes = bytes;
  rendered.capacity = measured.length;
  rendered.length = 0U;
  native_value_text_inner(descriptor, value, readable, 0U, &rendered);
  if (rendered.length != measured.length) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  return handle;
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

static bool native_utf8_continuation(uint8_t byte) {
  return (byte >= UINT8_C(0x80)) && (byte <= UINT8_C(0xbf));
}

static bool native_utf8_valid(const uint8_t *bytes, uint64_t length) {
  uint64_t index = UINT64_C(0);
  if ((bytes == NULL) && (length != UINT64_C(0))) {
    return false;
  }
  while (index < length) {
    uint8_t first = bytes[index];
    if (first <= UINT8_C(0x7f)) {
      index += UINT64_C(1);
    } else if ((first >= UINT8_C(0xc2)) && (first <= UINT8_C(0xdf))) {
      if ((length - index < UINT64_C(2)) ||
          !native_utf8_continuation(bytes[index + UINT64_C(1)])) {
        return false;
      }
      index += UINT64_C(2);
    } else if ((first >= UINT8_C(0xe0)) && (first <= UINT8_C(0xef))) {
      uint8_t second;
      if (length - index < UINT64_C(3)) {
        return false;
      }
      second = bytes[index + UINT64_C(1)];
      if (!native_utf8_continuation(bytes[index + UINT64_C(2)]) ||
          ((first == UINT8_C(0xe0)) && (second < UINT8_C(0xa0))) ||
          ((first == UINT8_C(0xed)) && (second > UINT8_C(0x9f))) ||
          !native_utf8_continuation(second)) {
        return false;
      }
      index += UINT64_C(3);
    } else if ((first >= UINT8_C(0xf0)) && (first <= UINT8_C(0xf4))) {
      uint8_t second;
      if (length - index < UINT64_C(4)) {
        return false;
      }
      second = bytes[index + UINT64_C(1)];
      if (!native_utf8_continuation(second) ||
          !native_utf8_continuation(bytes[index + UINT64_C(2)]) ||
          !native_utf8_continuation(bytes[index + UINT64_C(3)]) ||
          ((first == UINT8_C(0xf0)) && (second < UINT8_C(0x90))) ||
          ((first == UINT8_C(0xf4)) && (second > UINT8_C(0x8f)))) {
        return false;
      }
      index += UINT64_C(4);
    } else {
      return false;
    }
  }
  return true;
}

native_vec *native_utf8_encode(native_arena *arena, uint64_t source) {
  uint64_t length = native_text_length(source);
  const uint8_t *bytes = native_text_bytes(source);
  native_vec *result;
  uint64_t index;
  if ((length > (uint64_t)INT64_MAX) || !native_utf8_valid(bytes, length)) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  result = native_vec_new(arena, (int64_t)length, INT64_C(8),
                          _Alignof(int64_t));
  for (index = UINT64_C(0); index < length; index++) {
    int64_t value = (int64_t)bytes[index];
    memcpy((uint8_t *)result->elements + (size_t)(index * UINT64_C(8)),
           &value, sizeof value);
  }
  result->length = (int64_t)length;
  return result;
}

static void native_byte_vector_check(const native_vec *source) {
  if ((source == NULL) || (source->length < INT64_C(0)) ||
      (source->capacity < source->length) ||
      ((source->capacity == INT64_C(0)) && (source->elements != NULL)) ||
      ((source->capacity > INT64_C(0)) && (source->elements == NULL))) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  if ((uint64_t)source->length > ((uint64_t)SIZE_MAX / sizeof(int64_t))) {
    native_trap(NATIVE_TRAP_OVERFLOW);
  }
}

static uint8_t native_vector_byte(const native_vec *source, int64_t index) {
  int64_t value;
  native_byte_vector_check(source);
  if ((index < INT64_C(0)) || (index >= source->length)) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  memcpy(&value, (const uint8_t *)source->elements + (size_t)(index * INT64_C(8)),
         sizeof value);
  if ((value < INT64_C(0)) || (value > INT64_C(255))) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  return (uint8_t)value;
}

uint64_t native_utf8_decode(native_arena *arena, const native_vec *source) {
  uint8_t *destination;
  uint64_t result;
  int64_t index;
  if ((source == NULL) || (source->length < INT64_C(0))) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  result = native_text_alloc(arena, (uint64_t)source->length, &destination);
  for (index = INT64_C(0); index < source->length; index++) {
    destination[index] = native_vector_byte(source, index);
  }
  if (!native_utf8_valid(destination, (uint64_t)source->length)) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  return result;
}

static uint32_t native_sha256_rotate_right(uint32_t value, uint32_t count) {
  return (value >> count) | (value << (UINT32_C(32) - count));
}

static uint32_t native_sha256_load_be32(const uint8_t *source) {
  return ((uint32_t)source[0] << UINT32_C(24)) |
         ((uint32_t)source[1] << UINT32_C(16)) |
         ((uint32_t)source[2] << UINT32_C(8)) | (uint32_t)source[3];
}

static void native_sha256_transform(uint32_t state[8],
                                    const uint8_t block[64]) {
  static const uint32_t constants[64] = {
      UINT32_C(0x428a2f98), UINT32_C(0x71374491), UINT32_C(0xb5c0fbcf),
      UINT32_C(0xe9b5dba5), UINT32_C(0x3956c25b), UINT32_C(0x59f111f1),
      UINT32_C(0x923f82a4), UINT32_C(0xab1c5ed5), UINT32_C(0xd807aa98),
      UINT32_C(0x12835b01), UINT32_C(0x243185be), UINT32_C(0x550c7dc3),
      UINT32_C(0x72be5d74), UINT32_C(0x80deb1fe), UINT32_C(0x9bdc06a7),
      UINT32_C(0xc19bf174), UINT32_C(0xe49b69c1), UINT32_C(0xefbe4786),
      UINT32_C(0x0fc19dc6), UINT32_C(0x240ca1cc), UINT32_C(0x2de92c6f),
      UINT32_C(0x4a7484aa), UINT32_C(0x5cb0a9dc), UINT32_C(0x76f988da),
      UINT32_C(0x983e5152), UINT32_C(0xa831c66d), UINT32_C(0xb00327c8),
      UINT32_C(0xbf597fc7), UINT32_C(0xc6e00bf3), UINT32_C(0xd5a79147),
      UINT32_C(0x06ca6351), UINT32_C(0x14292967), UINT32_C(0x27b70a85),
      UINT32_C(0x2e1b2138), UINT32_C(0x4d2c6dfc), UINT32_C(0x53380d13),
      UINT32_C(0x650a7354), UINT32_C(0x766a0abb), UINT32_C(0x81c2c92e),
      UINT32_C(0x92722c85), UINT32_C(0xa2bfe8a1), UINT32_C(0xa81a664b),
      UINT32_C(0xc24b8b70), UINT32_C(0xc76c51a3), UINT32_C(0xd192e819),
      UINT32_C(0xd6990624), UINT32_C(0xf40e3585), UINT32_C(0x106aa070),
      UINT32_C(0x19a4c116), UINT32_C(0x1e376c08), UINT32_C(0x2748774c),
      UINT32_C(0x34b0bcb5), UINT32_C(0x391c0cb3), UINT32_C(0x4ed8aa4a),
      UINT32_C(0x5b9cca4f), UINT32_C(0x682e6ff3), UINT32_C(0x748f82ee),
      UINT32_C(0x78a5636f), UINT32_C(0x84c87814), UINT32_C(0x8cc70208),
      UINT32_C(0x90befffa), UINT32_C(0xa4506ceb), UINT32_C(0xbef9a3f7),
      UINT32_C(0xc67178f2)};
  uint32_t words[64];
  uint32_t a = state[0];
  uint32_t b = state[1];
  uint32_t c = state[2];
  uint32_t d = state[3];
  uint32_t e = state[4];
  uint32_t f = state[5];
  uint32_t g = state[6];
  uint32_t h = state[7];
  uint32_t index;

  for (index = UINT32_C(0); index < UINT32_C(16); index++) {
    words[index] = native_sha256_load_be32(
        block + ((size_t)index * (size_t)4U));
  }
  for (index = UINT32_C(16); index < UINT32_C(64); index++) {
    uint32_t left = words[index - UINT32_C(15)];
    uint32_t right = words[index - UINT32_C(2)];
    uint32_t sigma0 = native_sha256_rotate_right(left, UINT32_C(7)) ^
                      native_sha256_rotate_right(left, UINT32_C(18)) ^
                      (left >> UINT32_C(3));
    uint32_t sigma1 = native_sha256_rotate_right(right, UINT32_C(17)) ^
                      native_sha256_rotate_right(right, UINT32_C(19)) ^
                      (right >> UINT32_C(10));
    words[index] = words[index - UINT32_C(16)] + sigma0 +
                   words[index - UINT32_C(7)] + sigma1;
  }

  for (index = UINT32_C(0); index < UINT32_C(64); index++) {
    uint32_t sum1 = native_sha256_rotate_right(e, UINT32_C(6)) ^
                    native_sha256_rotate_right(e, UINT32_C(11)) ^
                    native_sha256_rotate_right(e, UINT32_C(25));
    uint32_t choice = (e & f) ^ ((~e) & g);
    uint32_t temp1 = h + sum1 + choice + constants[index] + words[index];
    uint32_t sum0 = native_sha256_rotate_right(a, UINT32_C(2)) ^
                    native_sha256_rotate_right(a, UINT32_C(13)) ^
                    native_sha256_rotate_right(a, UINT32_C(22));
    uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
    uint32_t temp2 = sum0 + majority;
    h = g;
    g = f;
    f = e;
    e = d + temp1;
    d = c;
    c = b;
    b = a;
    a = temp1 + temp2;
  }

  state[0] += a;
  state[1] += b;
  state[2] += c;
  state[3] += d;
  state[4] += e;
  state[5] += f;
  state[6] += g;
  state[7] += h;
}

uint64_t native_sha256_bytes(native_arena *arena, const native_vec *source) {
  static const uint8_t hex[] = "0123456789abcdef";
  uint32_t state[8] = {UINT32_C(0x6a09e667), UINT32_C(0xbb67ae85),
                       UINT32_C(0x3c6ef372), UINT32_C(0xa54ff53a),
                       UINT32_C(0x510e527f), UINT32_C(0x9b05688c),
                       UINT32_C(0x1f83d9ab), UINT32_C(0x5be0cd19)};
  uint8_t block[64];
  uint8_t *destination;
  uint64_t result;
  uint64_t bit_length;
  int64_t offset = INT64_C(0);
  int64_t remaining;
  int64_t index;

  native_byte_vector_check(source);
  while ((source->length - offset) >= INT64_C(64)) {
    for (index = INT64_C(0); index < INT64_C(64); index++) {
      block[index] = native_vector_byte(source, offset + index);
    }
    native_sha256_transform(state, block);
    offset += INT64_C(64);
  }

  remaining = source->length - offset;
  memset(block, 0, sizeof block);
  for (index = INT64_C(0); index < remaining; index++) {
    block[index] = native_vector_byte(source, offset + index);
  }
  block[remaining] = UINT8_C(0x80);
  if (remaining >= INT64_C(56)) {
    native_sha256_transform(state, block);
    memset(block, 0, sizeof block);
  }
  bit_length = (uint64_t)source->length * UINT64_C(8);
  for (index = INT64_C(0); index < INT64_C(8); index++) {
    block[INT64_C(63) - index] =
        (uint8_t)(bit_length >> ((uint32_t)index * UINT32_C(8)));
  }
  native_sha256_transform(state, block);

  result = native_text_alloc(arena, UINT64_C(64), &destination);
  for (index = INT64_C(0); index < INT64_C(8); index++) {
    uint32_t word = state[index];
    int64_t digit;
    for (digit = INT64_C(0); digit < INT64_C(8); digit++) {
      uint32_t shift = UINT32_C(28) - ((uint32_t)digit * UINT32_C(4));
      destination[(index * INT64_C(8)) + digit] =
          hex[(word >> shift) & UINT32_C(0x0f)];
    }
  }
  return result;
}

int64_t native_float_to_bits(double source) {
  uint64_t bits;
  int64_t result;
  _Static_assert(sizeof(double) == sizeof(uint64_t),
                 "native binary64 requires an eight-byte double");
  if (isnan(source)) {
    bits = UINT64_C(0x7ff8000000000000);
  } else {
    memcpy(&bits, &source, sizeof bits);
  }
  memcpy(&result, &bits, sizeof result);
  return result;
}

double native_float_from_bits(int64_t source) {
  double result;
  _Static_assert(sizeof(double) == sizeof(int64_t),
                 "native binary64 requires an eight-byte double");
  memcpy(&result, &source, sizeof result);
  return result;
}

bool native_host_environment_lookup_v0(
    native_arena *arena, const native_capability *capability,
    uint64_t name, uint64_t *out) {
  uint64_t name_length;
  const uint8_t *name_bytes;
  char *key;
  const char *value;
  size_t value_length;
  uint8_t *destination;
  uint64_t handle;

  if ((arena == NULL) || (capability == NULL) ||
      (capability->token == UINT64_C(0)) || (out == NULL)) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  *out = UINT64_C(0);
  name_length = native_text_length(name);
  name_bytes = native_text_bytes(name);
  if (name_length > (uint64_t)(SIZE_MAX - (size_t)1U)) {
    native_trap(NATIVE_TRAP_OVERFLOW);
  }
  if (memchr(name_bytes, '\0', (size_t)name_length) != NULL) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  key = (char *)malloc((size_t)name_length + (size_t)1U);
  if (key == NULL) {
    native_trap(NATIVE_TRAP_ARENA_EXHAUSTED);
  }
  memcpy(key, name_bytes, (size_t)name_length);
  key[name_length] = '\0';
  value = getenv(key);
  free(key);
  if (value == NULL) {
    return false;
  }
  value_length = strlen(value);
  handle = native_text_alloc(arena, (uint64_t)value_length, &destination);
  if (value_length != (size_t)0U) {
    memcpy(destination, value, value_length);
  }
  *out = handle;
  return true;
}

void native_host_stdout_write_line_v0(
    const native_capability *capability, uint64_t text) {
  uint64_t length;
  if ((capability == NULL) || (capability->token == UINT64_C(0))) {
    native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
  }
  length = native_text_length(text);
  if (length > (uint64_t)SIZE_MAX) {
    native_trap(NATIVE_TRAP_OVERFLOW);
  }
  if (!native_byte_write(stdout, native_text_bytes(text), (size_t)length) ||
      (fputc('\n', stdout) == EOF)) {
    native_trap(NATIVE_TRAP_IO);
  }
}

static int32_t native_host_socket_check(
    const native_capability *capability, int64_t value, int *out) {
  if ((capability == NULL) || (capability->token == UINT64_C(0)) ||
      (out == NULL) || (value < INT64_C(0)) ||
      (value > (int64_t)INT_MAX)) {
    return EINVAL;
  }
  *out = (int)value;
  return NATIVE_HOST_SOCKET_OK;
}

static int32_t native_host_socket_errno(void) {
  return (errno == 0) ? EIO : (int32_t)errno;
}

static bool native_host_socket_peer_error(int error) {
  return (error == EPIPE) || (error == ECONNRESET) || (error == ENOTCONN);
}

int32_t native_host_socket_inherited_listener_v0(
    const native_capability *capability, int64_t fd, int64_t *out) {
  int descriptor;
  int accepting = 0;
  socklen_t accepting_size = (socklen_t)sizeof accepting;
  int32_t status = native_host_socket_check(capability, fd, &descriptor);
  if (out == NULL) {
    return EINVAL;
  }
  *out = INT64_C(-1);
  if (status != NATIVE_HOST_SOCKET_OK) {
    return status;
  }
  if (fd != NATIVE_HOST_SOCKET_INHERITED_FD) {
    return EINVAL;
  }
  if (fcntl(descriptor, F_GETFD) == -1) {
    return native_host_socket_errno();
  }
  if (getsockopt(descriptor, SOL_SOCKET, SO_ACCEPTCONN, &accepting,
                 &accepting_size) == -1) {
    return native_host_socket_errno();
  }
  if (accepting == 0) {
    return EINVAL;
  }
  *out = fd;
  return NATIVE_HOST_SOCKET_OK;
}

int32_t native_host_socket_accept_v0(
    const native_capability *capability, int64_t listener_fd, int64_t *out) {
  int listener;
  int peer;
  int flags;
  int32_t status = native_host_socket_check(capability, listener_fd, &listener);
  if (out == NULL) {
    return EINVAL;
  }
  *out = INT64_C(-1);
  if (status != NATIVE_HOST_SOCKET_OK) {
    return status;
  }
  do {
    peer = accept(listener, NULL, NULL);
  } while ((peer == -1) && (errno == EINTR));
  if (peer == -1) {
    return native_host_socket_errno();
  }
  flags = fcntl(peer, F_GETFD);
  if ((flags == -1) || (fcntl(peer, F_SETFD, flags | FD_CLOEXEC) == -1)) {
    int32_t error = native_host_socket_errno();
    (void)close(peer);
    return error;
  }
  *out = (int64_t)peer;
  return NATIVE_HOST_SOCKET_OK;
}

int32_t native_host_socket_read_bounded_v0(
    native_arena *arena, const native_capability *capability, int64_t peer_fd,
    int64_t max_bytes, native_bytes *out) {
  int peer;
  ssize_t received;
  uint8_t *destination;
  int32_t status = native_host_socket_check(capability, peer_fd, &peer);
  if (out == NULL) {
    return EINVAL;
  }
  out->data = NULL;
  out->length = (size_t)0U;
  if (status != NATIVE_HOST_SOCKET_OK) {
    return status;
  }
  if ((arena == NULL) || (max_bytes < INT64_C(0)) ||
      (max_bytes > NATIVE_HOST_SOCKET_MAX_IO) ||
      (arena->offset > arena->capacity)) {
    return EINVAL;
  }
  if ((size_t)max_bytes > (arena->capacity - arena->offset)) {
    return ENOBUFS;
  }
  if (max_bytes == INT64_C(0)) {
    return NATIVE_HOST_SOCKET_OK;
  }
  if (arena->bytes == NULL) {
    return EINVAL;
  }
  destination = arena->bytes + arena->offset;
  do {
    received = recv(peer, destination, (size_t)max_bytes, 0);
  } while ((received == (ssize_t)-1) && (errno == EINTR));
  if (received == (ssize_t)0) {
    return NATIVE_HOST_SOCKET_PEER_CLOSED;
  }
  if (received == (ssize_t)-1) {
    int error = errno;
    return native_host_socket_peer_error(error)
               ? NATIVE_HOST_SOCKET_PEER_CLOSED
               : ((error == 0) ? EIO : (int32_t)error);
  }
  arena->offset += (size_t)received;
  out->data = destination;
  out->length = (size_t)received;
  return NATIVE_HOST_SOCKET_OK;
}

int32_t native_host_socket_write_bounded_v0(
    const native_capability *capability, int64_t peer_fd, native_bytes bytes,
    int64_t max_bytes, int64_t *out) {
  int peer;
  size_t offset = (size_t)0U;
  int flags = 0;
  int32_t status = native_host_socket_check(capability, peer_fd, &peer);
  if (out == NULL) {
    return EINVAL;
  }
  *out = INT64_C(0);
  if (status != NATIVE_HOST_SOCKET_OK) {
    return status;
  }
  if ((max_bytes < INT64_C(0)) ||
      (max_bytes > NATIVE_HOST_SOCKET_MAX_IO) ||
      ((bytes.data == NULL) && (bytes.length != (size_t)0U))) {
    return EINVAL;
  }
  if (bytes.length > (size_t)max_bytes) {
    return EMSGSIZE;
  }
#ifdef MSG_NOSIGNAL
  flags = MSG_NOSIGNAL;
#endif
  while (offset < bytes.length) {
    ssize_t sent = send(peer, bytes.data + offset, bytes.length - offset, flags);
    if (sent > (ssize_t)0) {
      offset += (size_t)sent;
    } else if (sent == (ssize_t)0) {
      return NATIVE_HOST_SOCKET_PEER_CLOSED;
    } else if (errno == EINTR) {
      continue;
    } else {
      int error = errno;
      return native_host_socket_peer_error(error)
                 ? NATIVE_HOST_SOCKET_PEER_CLOSED
                 : ((error == 0) ? EIO : (int32_t)error);
    }
  }
  *out = (int64_t)offset;
  return NATIVE_HOST_SOCKET_OK;
}

int32_t native_host_socket_close_v0(
    const native_capability *capability, int64_t fd) {
  int descriptor;
  int32_t status = native_host_socket_check(capability, fd, &descriptor);
  if (status != NATIVE_HOST_SOCKET_OK) {
    return status;
  }
  if (close(descriptor) == -1) {
    return native_host_socket_errno();
  }
  return NATIVE_HOST_SOCKET_OK;
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
