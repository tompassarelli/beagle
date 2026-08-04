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

/* Atom storage is opaque: generated programs can only access a cell while
   presenting the dedicated state capability. */
typedef struct native_atom native_atom;

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

typedef enum native_collection_equality {
  NATIVE_COLLECTION_EQ_BOOL = 1,
  NATIVE_COLLECTION_EQ_I64 = 2,
  NATIVE_COLLECTION_EQ_F64 = 3,
  NATIVE_COLLECTION_EQ_TEXT = 4,
  NATIVE_COLLECTION_EQ_KEYWORD = 5
} native_collection_equality;

/* Map/Set headers own parallel insertion-order storage in the arena. The
   headers are opaque to generated modules; descriptor code reads through the
   checked address accessors below. */
typedef struct native_map {
  void *keys;
  void *values;
  int64_t length;
  int64_t capacity;
  int64_t key_stride;
  int64_t value_stride;
} native_map;

typedef struct native_set {
  void *elements;
  int64_t length;
  int64_t capacity;
  int64_t stride;
} native_set;

#define NATIVE_VALUE_ABI_VERSION UINT32_C(1)

typedef enum native_value_kind {
  NATIVE_VALUE_BOOL = 1,
  NATIVE_VALUE_SIGNED = 2,
  NATIVE_VALUE_UNSIGNED = 3,
  NATIVE_VALUE_FLOAT = 4,
  NATIVE_VALUE_TEXT = 5,
  NATIVE_VALUE_KEYWORD = 6,
  NATIVE_VALUE_RECORD = 7,
  NATIVE_VALUE_UNION = 8,
  NATIVE_VALUE_VECTOR = 9,
  NATIVE_VALUE_REFERENCE = 10
} native_value_kind;

typedef struct native_value_descriptor native_value_descriptor;

typedef struct native_value_field_descriptor {
  size_t offset;
  const native_value_descriptor *value;
} native_value_field_descriptor;

typedef struct native_value_variant_descriptor {
  int64_t tag;
  size_t payload_offset;
  const native_value_descriptor *payload;
} native_value_variant_descriptor;

/* A sealed Native World emits one immutable descriptor graph. Descriptors are
   world-local ABI metadata: values never carry host function pointers or tags
   not already present in their TypeDef/LayoutDef. */
struct native_value_descriptor {
  uint32_t abi_version;
  native_value_kind kind;
  size_t size;
  size_t alignment;
  size_t tag_offset;
  const native_value_field_descriptor *fields;
  size_t field_count;
  const native_value_variant_descriptor *variants;
  size_t variant_count;
  const native_value_descriptor *element;
  size_t stride;
};

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

native_atom *native_atom_new(native_arena *arena,
                             const native_capability *capability,
                             const void *initial, size_t size,
                             size_t alignment);
void native_atom_deref(native_atom *atom,
                       const native_capability *capability, void *out,
                       size_t size);
void native_atom_lock(native_atom *atom,
                      const native_capability *capability, void *out,
                      size_t size);
void native_atom_store_unlock(native_atom *atom,
                              const native_capability *capability,
                              const void *value, size_t size);

native_vec *native_vec_new(native_arena *arena, int64_t capacity, int64_t stride,
                           size_t alignment);
int64_t native_vec_length(const native_vec *vector);
/* Traps NATIVE_TRAP_OUT_OF_RANGE unless 0 <= index < length. */
const void *native_vec_at(const native_vec *vector, int64_t index, int64_t stride);
/* Push is linear once storage exists. A reusable zero-capacity value produces
   a fresh header; subsequent growth moves that owned header and doubles. */
native_vec *native_vec_push(native_arena *arena, native_vec *vector,
                            const void *value, int64_t stride, size_t alignment);
native_vec *native_vec_concat(native_arena *arena, const native_vec *left,
                              const native_vec *right, int64_t stride,
                              size_t alignment);
native_map *native_map_from_arrays(
    native_arena *arena, const void *keys, const void *values, int64_t count,
    int64_t key_stride, size_t key_alignment, int64_t value_stride,
    size_t value_alignment, native_collection_equality equality);
int64_t native_map_count(const native_map *map);
const void *native_map_key_at(const native_map *map, int64_t index);
const void *native_map_value_at(const native_map *map, int64_t index);
const void *native_map_get(const native_map *map, const void *key,
                           native_collection_equality equality);
bool native_map_contains(const native_map *map, const void *key,
                         native_collection_equality equality);
native_map *native_map_assoc(
    native_arena *arena, native_map *map, const void *key,
    const void *value, int64_t key_stride, size_t key_alignment,
    int64_t value_stride, size_t value_alignment,
    native_collection_equality equality);
native_map *native_map_dissoc(
    native_arena *arena, native_map *map, const void *key,
    int64_t key_stride, size_t key_alignment, int64_t value_stride,
    size_t value_alignment, native_collection_equality equality);
native_vec *native_map_keys(native_arena *arena, const native_map *map,
                            size_t key_alignment);
native_vec *native_map_values(native_arena *arena, const native_map *map,
                              size_t value_alignment);

native_set *native_set_from_array(
    native_arena *arena, const void *values, int64_t count, int64_t stride,
    size_t alignment, native_collection_equality equality);
int64_t native_set_count(const native_set *set);
const void *native_set_item_at(const native_set *set, int64_t index);
bool native_set_contains(const native_set *set, const void *value,
                         native_collection_equality equality);
native_set *native_set_conj(native_arena *arena, native_set *set,
                            const void *value, int64_t stride, size_t alignment,
                            native_collection_equality equality);
native_set *native_set_disj(native_arena *arena, native_set *set,
                            const void *value, int64_t stride, size_t alignment,
                            native_collection_equality equality);
native_vec *native_set_vector(native_arena *arena, const native_set *set,
                              size_t alignment);

bool native_value_equal(const native_value_descriptor *descriptor,
                        const void *left, const void *right);
bool native_byte_read(FILE *stream, uint8_t *destination, size_t length);
bool native_byte_write(FILE *stream, const uint8_t *source, size_t length);

uint64_t native_text_length(uint64_t handle);
const uint8_t *native_text_bytes(uint64_t handle);
bool native_text_eq(uint64_t left, uint64_t right);
bool native_text_index_of(uint64_t source, uint64_t needle, int64_t *out);
bool native_text_is_blank(uint64_t handle);
bool native_text_parse_i64(uint64_t handle, int64_t *out);
uint64_t native_text_alloc(native_arena *arena, uint64_t length, uint8_t **out);
uint64_t native_text_slice(native_arena *arena, uint64_t handle, uint64_t start,
                           uint64_t end);
uint64_t native_text_from_int(native_arena *arena, int64_t value);
uint64_t native_text_concat(native_arena *arena, const uint64_t *parts,
                            uint64_t count);
int64_t native_text_compare(uint64_t left, uint64_t right);
uint64_t native_text_trim(native_arena *arena, uint64_t source);
uint64_t native_text_lower_ascii(native_arena *arena, uint64_t source);
bool native_text_regex_matches(uint64_t source, uint64_t pattern);
uint64_t native_text_regex_replace(native_arena *arena, uint64_t source,
                                   uint64_t pattern, uint64_t replacement);
native_vec *native_text_regex_find(native_arena *arena, uint64_t source,
                                   uint64_t pattern);
native_vec *native_text_regex_split(native_arena *arena, uint64_t source,
                                    uint64_t pattern);
native_vec *native_text_vector_trim(native_arena *arena,
                                    const native_vec *source);
native_vec *native_text_vector_remove_blank(native_arena *arena,
                                            const native_vec *source);
uint64_t native_text_join(native_arena *arena, uint64_t separator,
                          const native_vec *source);
uint64_t native_text_repeat(native_arena *arena, uint64_t source,
                            int64_t count);

#endif
