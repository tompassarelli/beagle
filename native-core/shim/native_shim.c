#include "native_shim.h"

#include <stdatomic.h>
#include <string.h>
#include <stdlib.h>

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
  switch (equality) {
  case NATIVE_COLLECTION_EQ_BOOL:
  case NATIVE_COLLECTION_EQ_I64:
  case NATIVE_COLLECTION_EQ_F64:
  case NATIVE_COLLECTION_EQ_TEXT:
  case NATIVE_COLLECTION_EQ_KEYWORD:
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
  switch (equality) {
  case NATIVE_COLLECTION_EQ_BOOL: {
    bool left_value;
    bool right_value;
    memcpy(&left_value, left, sizeof left_value);
    memcpy(&right_value, right, sizeof right_value);
    return left_value == right_value;
  }
  case NATIVE_COLLECTION_EQ_I64: {
    int64_t left_value;
    int64_t right_value;
    memcpy(&left_value, left, sizeof left_value);
    memcpy(&right_value, right, sizeof right_value);
    return left_value == right_value;
  }
  case NATIVE_COLLECTION_EQ_F64: {
    double left_value;
    double right_value;
    memcpy(&left_value, left, sizeof left_value);
    memcpy(&right_value, right, sizeof right_value);
    return left_value == right_value;
  }
  case NATIVE_COLLECTION_EQ_TEXT: {
    uint64_t left_value;
    uint64_t right_value;
    memcpy(&left_value, left, sizeof left_value);
    memcpy(&right_value, right, sizeof right_value);
    return native_text_eq(left_value, right_value);
  }
  case NATIVE_COLLECTION_EQ_KEYWORD: {
    uint64_t left_value;
    uint64_t right_value;
    memcpy(&left_value, left, sizeof left_value);
    memcpy(&right_value, right, sizeof right_value);
    return left_value == right_value;
  }
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
         (descriptor->size > 0U) && (descriptor->alignment > 0U);
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
  }
  native_trap(NATIVE_TRAP_INVALID_ARGUMENT);
}

bool native_value_equal(const native_value_descriptor *descriptor,
                        const void *left, const void *right) {
  return native_value_equal_inner(descriptor, left, right);
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
