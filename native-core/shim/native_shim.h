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
#define NATIVE_TRAP_IO UINT32_C(5)
#define NATIVE_TRAP_PARALLEL UINT32_C(6)

#define NATIVE_HOST_SOCKET_OK INT32_C(0)
#define NATIVE_HOST_SOCKET_PEER_CLOSED INT32_C(-1)
#define NATIVE_HOST_STDIN_OVERFLOW INT32_C(-2)
#define NATIVE_HOST_SOCKET_INHERITED_FD INT64_C(3)
#define NATIVE_HOST_SOCKET_MAX_IO INT64_C(1048576)
#define NATIVE_HOST_PROCESS_MAX_LINE_BYTES INT64_C(16777216)

typedef struct native_arena_chunk native_arena_chunk;
typedef struct native_buffer_registry native_buffer_registry;

typedef struct native_arena {
  uint8_t *bytes;
  size_t capacity;
  size_t offset;
  native_arena_chunk *chunks;
  /* Heap-stable identity, registrations, and allocation generation for this
     arena's Buffers. Metadata retains this registry, never a raw native_arena
     pointer that can dangle. It is allocated lazily on the first Buffer. */
  native_buffer_registry *buffer_registry;
  size_t growth_floor;
  bool growable;
  /* Arena-local instrumentation avoids cross-arena races. Counts and current
     Buffer bytes cover the current allocation epoch; high-water survives reset
     and is cleared by init/destroy. */
  uint64_t allocation_count;
  uint64_t buffer_storage_allocation_count;
  size_t buffer_storage_current_bytes;
  size_t buffer_storage_high_water_bytes;
} native_arena;

typedef struct native_buffer native_buffer;

typedef struct native_capability {
  uint64_t token;
} native_capability;

#define NATIVE_PARALLEL_PERMISSION_READ_CURRENT UINT32_C(1)
#define NATIVE_PARALLEL_PERMISSION_WRITE_NEXT UINT32_C(2)

typedef struct native_parallel_access_v0 {
  const native_buffer *current;
  const native_buffer *next;
  const native_buffer *shadow;
  uint64_t generation;
  int64_t partition_id;
  int64_t read_lo_0;
  int64_t read_hi_0;
  int64_t read_lo_1;
  int64_t read_hi_1;
  int64_t write_lo;
  int64_t write_hi;
  uint8_t *write_coverage;
  uint32_t permissions;
} native_parallel_access_v0;

/* Set only around one generated tile callback. A TLS scope keeps ordinary
   native_capability ABI values one word wide and gives every worker its own
   exact buffer/range proof. */
extern _Thread_local const native_parallel_access_v0
    *native_parallel_access_current;

/* Atom storage is opaque: generated programs can only access a cell while
   presenting the dedicated state capability. */
typedef struct native_atom native_atom;

typedef struct native_bytes {
  uint8_t *data;
  size_t length;
} native_bytes;

typedef struct native_host_process_capture_v0 {
  int64_t status;
  uint64_t stdout_text;
  uint64_t stderr_text;
} native_host_process_capture_v0;

typedef struct native_host_process_spawned_stdout_v0 {
  int64_t pid;
  int64_t stdout_fd;
} native_host_process_spawned_stdout_v0;

typedef struct native_host_process_line_v0 {
  uint64_t line_text;
  bool eof;
} native_host_process_line_v0;

/* The native representation of a (Vec T) value is a POINTER to this header,
   never the header by value: a vector-valued record field is therefore one
   8-byte reference, and the element storage lives in the arena beside it.
   `elements` is NULL exactly when capacity is 0.

   `watermark` is the single count of element slots ever handed out from
   `elements`, shared by every header over that storage. A push may write into
   existing storage only at index *watermark, and *watermark only increases, so
   no index below any live header's length is ever written again: conj is
   persistent under arbitrary aliasing by one thread. The read-modify-write of
   *watermark is not atomic, so concurrent pushes over one storage need an
   external lock or they take the same slot twice.
   `watermark == NULL` means foreign storage this shim did not allocate, and a
   push over it always copies. */
typedef struct native_vec {
  void *elements;
  int64_t length;
  int64_t capacity;
  int64_t *watermark;
} native_vec;

typedef struct native_transient_vec native_transient_vec;

/* Durable handle for fixed-length mutable dense storage owned by an arena.
   The public fields mirror immutable registration facts and are checked on
   every access; the backing span is invalidated by arena reset. This is
   deliberately not native_vec: length never changes, reads and writes are
   checked, and updates mutate the shared buffer identity in place. */
struct native_buffer {
  void *elements;
  int64_t length;
  int64_t stride;
  size_t alignment;
  /* Every read/write capability may be a distinct IR capability definition,
     but the host token identifies the one authority that created this Buffer. */
  uint64_t owner_capability_token;
};

/* native_buffer is a public runtime handle shared with generated C17. Pin its
   field sequence generically and for native64, wasm32, and i386 profiles. */
#define NATIVE_ABI_ALIGN_UP(value, alignment) \
  (((value) + (alignment) - (size_t)1U) & ~((alignment) - (size_t)1U))
#define NATIVE_ABI_MAX_ALIGN(left, right) \
  ((left) > (right) ? (left) : (right))
enum {
  NATIVE_BUFFER_ABI_ALIGNMENT = NATIVE_ABI_MAX_ALIGN(
      NATIVE_ABI_MAX_ALIGN(_Alignof(void *), _Alignof(int64_t)),
      NATIVE_ABI_MAX_ALIGN(_Alignof(size_t), _Alignof(uint64_t))),
  NATIVE_BUFFER_ABI_ELEMENTS_OFFSET = 0,
  NATIVE_BUFFER_ABI_LENGTH_OFFSET =
      NATIVE_ABI_ALIGN_UP(sizeof(void *), _Alignof(int64_t)),
  NATIVE_BUFFER_ABI_STRIDE_OFFSET = NATIVE_ABI_ALIGN_UP(
      NATIVE_BUFFER_ABI_LENGTH_OFFSET + sizeof(int64_t), _Alignof(int64_t)),
  NATIVE_BUFFER_ABI_ALIGNMENT_OFFSET = NATIVE_ABI_ALIGN_UP(
      NATIVE_BUFFER_ABI_STRIDE_OFFSET + sizeof(int64_t), _Alignof(size_t)),
  NATIVE_BUFFER_ABI_OWNER_TOKEN_OFFSET = NATIVE_ABI_ALIGN_UP(
      NATIVE_BUFFER_ABI_ALIGNMENT_OFFSET + sizeof(size_t), _Alignof(uint64_t)),
  NATIVE_BUFFER_ABI_SIZE = NATIVE_ABI_ALIGN_UP(
      NATIVE_BUFFER_ABI_OWNER_TOKEN_OFFSET + sizeof(uint64_t),
      NATIVE_BUFFER_ABI_ALIGNMENT)
};
_Static_assert(_Alignof(native_buffer) == NATIVE_BUFFER_ABI_ALIGNMENT,
               "native_buffer target ABI alignment");
_Static_assert(offsetof(native_buffer, elements) ==
                   NATIVE_BUFFER_ABI_ELEMENTS_OFFSET,
               "native_buffer elements ABI offset");
_Static_assert(offsetof(native_buffer, length) ==
                   NATIVE_BUFFER_ABI_LENGTH_OFFSET,
               "native_buffer length ABI offset");
_Static_assert(offsetof(native_buffer, stride) ==
                   NATIVE_BUFFER_ABI_STRIDE_OFFSET,
               "native_buffer stride ABI offset");
_Static_assert(offsetof(native_buffer, alignment) ==
                   NATIVE_BUFFER_ABI_ALIGNMENT_OFFSET,
               "native_buffer alignment ABI offset");
_Static_assert(offsetof(native_buffer, owner_capability_token) ==
                   NATIVE_BUFFER_ABI_OWNER_TOKEN_OFFSET,
               "native_buffer owner token ABI offset");
_Static_assert(sizeof(native_buffer) == NATIVE_BUFFER_ABI_SIZE,
               "native_buffer target ABI size");
#if UINTPTR_MAX == UINT64_MAX && SIZE_MAX == UINT64_MAX
_Static_assert(sizeof(native_buffer) == 40U,
               "native_buffer supported 64-bit C ABI size");
_Static_assert(_Alignof(native_buffer) == 8U,
               "native_buffer supported 64-bit C ABI alignment");
_Static_assert(offsetof(native_buffer, elements) == 0U &&
                   offsetof(native_buffer, length) == 8U &&
                   offsetof(native_buffer, stride) == 16U &&
                   offsetof(native_buffer, alignment) == 24U &&
                   offsetof(native_buffer, owner_capability_token) == 32U,
               "native_buffer supported 64-bit C ABI offsets");
#endif
#if defined(__wasm32__)
_Static_assert(sizeof(void *) == 4U && sizeof(size_t) == 4U &&
                   _Alignof(int64_t) == 8U,
               "native_buffer wasm32 scalar ABI");
_Static_assert(sizeof(native_buffer) == 40U, "native_buffer wasm32 ABI size");
_Static_assert(_Alignof(native_buffer) == 8U,
               "native_buffer wasm32 ABI alignment");
_Static_assert(offsetof(native_buffer, elements) == 0U &&
                   offsetof(native_buffer, length) == 8U &&
                   offsetof(native_buffer, stride) == 16U &&
                   offsetof(native_buffer, alignment) == 24U &&
                   offsetof(native_buffer, owner_capability_token) == 32U,
               "native_buffer wasm32 ABI offsets");
#endif
#if defined(__i386__)
_Static_assert(sizeof(void *) == 4U && sizeof(size_t) == 4U &&
                   _Alignof(int64_t) == 4U && _Alignof(uint64_t) == 4U,
               "native_buffer i386 scalar ABI");
_Static_assert(sizeof(native_buffer) == 32U, "native_buffer i386 ABI size");
_Static_assert(_Alignof(native_buffer) == 4U,
               "native_buffer i386 ABI alignment");
_Static_assert(offsetof(native_buffer, elements) == 0U &&
                   offsetof(native_buffer, length) == 4U &&
                   offsetof(native_buffer, stride) == 12U &&
                   offsetof(native_buffer, alignment) == 20U &&
                   offsetof(native_buffer, owner_capability_token) == 24U,
               "native_buffer i386 ABI offsets");
#endif
#undef NATIVE_ABI_MAX_ALIGN
#undef NATIVE_ABI_ALIGN_UP

/* Borrowed octets. Distinct from native_bytes because nothing here owns or may
   free `data`, and distinct from a Text handle because the octets are arbitrary
   binary with no encoding obligation. */
typedef struct native_byte_source {
  const uint8_t *data;
  int64_t length;
} native_byte_source;

typedef struct native_value_descriptor native_value_descriptor;

typedef enum native_collection_equality_kind {
  NATIVE_COLLECTION_EQ_KIND_BOOL = 1,
  NATIVE_COLLECTION_EQ_KIND_I64 = 2,
  NATIVE_COLLECTION_EQ_KIND_F64 = 3,
  NATIVE_COLLECTION_EQ_KIND_TEXT = 4,
  NATIVE_COLLECTION_EQ_KIND_KEYWORD = 5,
  NATIVE_COLLECTION_EQ_KIND_STRUCTURAL = 6,
  NATIVE_COLLECTION_EQ_KIND_DYNAMIC_STRUCTURAL = 7
} native_collection_equality_kind;

typedef struct native_collection_equality {
  native_collection_equality_kind kind;
  const native_value_descriptor *descriptor;
} native_collection_equality;

#define NATIVE_COLLECTION_EQ_BOOL                                             \
  ((native_collection_equality){NATIVE_COLLECTION_EQ_KIND_BOOL, NULL})
#define NATIVE_COLLECTION_EQ_I64                                              \
  ((native_collection_equality){NATIVE_COLLECTION_EQ_KIND_I64, NULL})
#define NATIVE_COLLECTION_EQ_F64                                              \
  ((native_collection_equality){NATIVE_COLLECTION_EQ_KIND_F64, NULL})
#define NATIVE_COLLECTION_EQ_TEXT                                             \
  ((native_collection_equality){NATIVE_COLLECTION_EQ_KIND_TEXT, NULL})
#define NATIVE_COLLECTION_EQ_KEYWORD                                          \
  ((native_collection_equality){NATIVE_COLLECTION_EQ_KIND_KEYWORD, NULL})
#define NATIVE_COLLECTION_EQ_STRUCTURAL(value_descriptor)                     \
  ((native_collection_equality){NATIVE_COLLECTION_EQ_KIND_STRUCTURAL,         \
                                (value_descriptor)})
#define NATIVE_COLLECTION_EQ_DYNAMIC_STRUCTURAL(value_descriptor)             \
  ((native_collection_equality){                                              \
      NATIVE_COLLECTION_EQ_KIND_DYNAMIC_STRUCTURAL, (value_descriptor)})

typedef enum native_collection_state {
  NATIVE_COLLECTION_PERSISTENT = 1,
  NATIVE_COLLECTION_TRANSIENT = 2,
  NATIVE_COLLECTION_RETIRED = 3
} native_collection_state;

/* Insertion order stays the map's identity: the index is a side table from key
   hash to entry position, never a reordering of the parallel arrays. It is
   absent (NULL) whenever a scan is the faster or the only correct answer. */
typedef struct native_map_index native_map_index;

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
  native_collection_state state;
  native_arena *edit_arena;
  native_map_index *index;
} native_map;

typedef struct native_set {
  void *elements;
  int64_t length;
  int64_t capacity;
  int64_t stride;
  native_collection_state state;
  native_arena *edit_arena;
} native_set;

#define NATIVE_VALUE_ABI_VERSION UINT32_C(2)

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
  NATIVE_VALUE_REFERENCE = 10,
  NATIVE_VALUE_MAP = 11,
  NATIVE_VALUE_BYTES = 12
} native_value_kind;

typedef enum native_value_text_mode {
  NATIVE_VALUE_STR = 1,
  NATIVE_VALUE_PR_STR = 2
} native_value_text_mode;

typedef struct native_value_keyword_descriptor {
  const uint8_t *bytes;
  size_t length;
} native_value_keyword_descriptor;

typedef struct native_value_field_descriptor {
  size_t offset;
  const native_value_descriptor *value;
} native_value_field_descriptor;

typedef struct native_value_variant_descriptor {
  int64_t tag;
  size_t payload_offset;
  const native_value_descriptor *payload;
} native_value_variant_descriptor;

/* A frozen native program emits one immutable descriptor graph. Descriptors are
   program-local ABI metadata: values never carry host function pointers or tags
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
  const native_value_descriptor *map_key;
  const native_value_descriptor *map_value;
  const native_value_keyword_descriptor *keywords;
  size_t keyword_count;
};

/* Counts ELEMENT-STORAGE allocations only (header allocations excluded), so a
   push sequence's reallocation count is observable from a test. */
extern uint64_t native_vec_storage_allocations;

/* Text and Keyword handles are addresses of length-prefixed strict-UTF-8 blobs:
   an 8-byte native-endian uint64_t length, then exactly that many bytes.
   Handles are program-local addresses and never cross a program boundary. */
#define NATIVE_TEXT_HEADER_BYTES ((uint64_t)sizeof(uint64_t))

void native_arena_init(native_arena *arena, uint8_t *storage, size_t capacity);
bool native_arena_init_growable(native_arena *arena, size_t growth_floor);
void *native_arena_alloc(native_arena *arena, size_t size, size_t alignment);
void native_arena_reset(native_arena *arena);
void native_arena_destroy(native_arena *arena);
size_t native_arena_reserved_bytes(const native_arena *arena);
/* Ordered, generation-checked view of the arena's live Buffer registrations,
   index 0 oldest. Registration order is allocation order, so a deterministic
   program makes the index a stable external handle; the Wasm adapter exports
   exactly this surface for host-side state readback. */
int64_t native_arena_buffer_registration_count(const native_arena *arena);
const native_buffer *native_arena_buffer_registration_at(
    const native_arena *arena, int64_t index);
/* Report-only: a trap still aborts, and nothing here resumes a trapped program. */
extern uint32_t native_last_trap_code;

typedef void (*native_trap_reporter)(uint32_t code);

/* NULL clears. The reporter is deregistered before it runs, so one that itself
   traps cannot recurse. */
void native_set_trap_reporter(native_trap_reporter reporter);

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
bool native_atom_compare_exchange(native_atom *atom,
                                  const native_capability *capability,
                                  const void *expected,
                                  const void *replacement, size_t size);

native_vec *native_vec_new(native_arena *arena, int64_t capacity, int64_t stride,
                           size_t alignment);
int64_t native_vec_length(const native_vec *vector);
/* Traps NATIVE_TRAP_OUT_OF_RANGE unless 0 <= index < length. */
const void *native_vec_at(const native_vec *vector, int64_t index, int64_t stride);
native_vec *native_vec_assoc(native_arena *arena, const native_vec *vector,
                             int64_t index, const void *value, int64_t stride,
                             size_t alignment);
/* Push is linear once storage exists. A reusable zero-capacity value produces
   a fresh header; subsequent growth moves that owned header and doubles. */
native_vec *native_vec_push(native_arena *arena, native_vec *vector,
                            const void *value, int64_t stride, size_t alignment);
native_transient_vec *native_transient_vec_new(native_arena *arena,
                                               const native_vec *source,
                                               int64_t stride,
                                               size_t alignment);
/* Returns the same active handle after appending. A frozen handle traps. */
native_transient_vec *native_transient_vec_push(
    native_transient_vec *builder, const void *value);
/* Freezes exactly once into the persistent native_vec representation. */
native_vec *native_transient_vec_freeze(native_transient_vec *builder);
native_vec *native_vec_concat(native_arena *arena, const native_vec *left,
                              const native_vec *right, int64_t stride,
                              size_t alignment);
native_vec *native_vec_slice(native_arena *arena, const native_vec *source,
                             int64_t start, int64_t end, int64_t stride,
                             size_t alignment);
native_vec *native_vec_reverse(native_arena *arena, const native_vec *source,
                               int64_t stride, size_t alignment);
native_vec *native_vec_sort(native_arena *arena, const native_vec *source,
                            const native_value_descriptor *element,
                            int64_t stride, size_t alignment);

native_buffer *native_buffer_new(native_arena *arena,
                                 const native_capability *capability,
                                 int64_t length, int64_t stride,
                                 size_t alignment);
int64_t native_buffer_length(const native_arena *arena,
                             const native_buffer *buffer,
                             const native_capability *capability);
/* Both accessors trap NATIVE_TRAP_OUT_OF_RANGE unless 0 <= index < length. */
const void *native_buffer_at(const native_arena *arena,
                             const native_buffer *buffer,
                             const native_capability *capability,
                             int64_t index, int64_t stride,
                             size_t alignment);
void native_buffer_set(const native_arena *arena, native_buffer *buffer,
                       const native_capability *capability,
                       int64_t index, const void *value, int64_t stride,
                       size_t alignment);
/* Nontrapping SIMD preflight. These expose an F64 view only after exact
   capability, stride, eight-byte alignment, range, and address-overflow
   checks. Arithmetic callers request a finite scan before any write. */
bool native_buffer_simd_f64_input_view(
    const native_arena *arena, const native_buffer *buffer,
    const native_capability *capability,
    int64_t start, int64_t end, bool require_finite, const double **out);
bool native_buffer_simd_f64_output_view(
    const native_arena *arena, native_buffer *buffer,
    const native_capability *capability,
    int64_t start, int64_t end, double **out);
/* Read-only inputs may alias each other. A destination/source pair is safe
   only when the exact accessed spans are disjoint; every overlap falls back
   to the authoritative scalar loop. */
bool native_buffer_simd_f64_alias_safe(const double *destination,
                                       const double *source,
                                       int64_t start, int64_t end);

/* A read-only alias of octets this shim did not allocate: one header, never a
   copy of the data. The caller keeps `data` live and unmodified for as long as
   any handle derived from it is reachable. */
native_byte_source *native_byte_source_borrow(native_arena *arena,
                                              const uint8_t *data,
                                              int64_t length);
int64_t native_byte_source_length(const native_byte_source *source);
/* Zero-extends: every octet reads back in [0, 255]. Traps
   NATIVE_TRAP_OUT_OF_RANGE unless 0 <= index < length. */
int64_t native_byte_source_at(const native_byte_source *source, int64_t index);
native_byte_source *native_byte_source_slice(native_arena *arena,
                                             const native_byte_source *source,
                                             int64_t start, int64_t end);
int64_t native_bit_and_i64(int64_t left, int64_t right);
int64_t native_bit_or_i64(int64_t left, int64_t right);
int64_t native_bit_xor_i64(int64_t left, int64_t right);
int64_t native_bit_shift_left_i64(int64_t value, int64_t distance);
int64_t native_unsigned_bit_shift_right_i64(int64_t value, int64_t distance);
native_map *native_map_from_arrays(
    native_arena *arena, const void *keys, const void *values, int64_t count,
    int64_t key_stride, size_t key_alignment, int64_t value_stride,
    size_t value_alignment, native_collection_equality equality);
native_map *native_map_transient_open(native_arena *arena,
                                      const native_map *source,
                                      size_t key_alignment,
                                      size_t value_alignment);
native_map *native_map_persistent_close(native_arena *arena,
                                        native_map *source);
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
native_map *native_map_assoc_transient(
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
native_set *native_set_transient_open(native_arena *arena,
                                      const native_set *source,
                                      size_t alignment);
native_set *native_set_persistent_close(native_arena *arena,
                                        native_set *source);
int64_t native_set_count(const native_set *set);
const void *native_set_item_at(const native_set *set, int64_t index);
bool native_set_contains(const native_set *set, const void *value,
                         native_collection_equality equality);
native_set *native_set_conj(native_arena *arena, native_set *set,
                            const void *value, int64_t stride, size_t alignment,
                            native_collection_equality equality);
native_set *native_set_conj_transient(
    native_arena *arena, native_set *set, const void *value, int64_t stride,
    size_t alignment, native_collection_equality equality);
native_set *native_set_disj(native_arena *arena, native_set *set,
                            const void *value, int64_t stride, size_t alignment,
                            native_collection_equality equality);
native_vec *native_set_vector(native_arena *arena, const native_set *set,
                              size_t alignment);

/* Value semantics recurse through the frozen descriptor graph. Hash is a
   nonnegative 63-bit FNV-1a digest over a kind-separated, low-byte-first
   structural stream. Compare returns only -1, 0, or 1: records and vectors are
   lexicographic, unions compare tag then payload, and Text/Keyword compare
   UTF-8 bytes. Float zeros coalesce; NaNs hash canonically and sort after
   numbers, ordered among themselves by representation. */
bool native_value_equal(const native_value_descriptor *descriptor,
                        const void *left, const void *right);
int64_t native_value_hash(const native_value_descriptor *descriptor,
                          const void *value);
int64_t native_value_compare(const native_value_descriptor *descriptor,
                             const void *left, const void *right);
void native_dynamic_value_validate(const native_value_descriptor *descriptor,
                                   const void *value);
bool native_dynamic_value_equal(const native_value_descriptor *descriptor,
                                const void *left, const void *right);
int64_t native_dynamic_value_hash(const native_value_descriptor *descriptor,
                                  const void *value);
int64_t native_dynamic_value_compare(const native_value_descriptor *descriptor,
                                     const void *left, const void *right);
uint64_t native_value_to_text(native_arena *arena,
                              const native_value_descriptor *descriptor,
                              const void *value,
                              native_value_text_mode mode);
/* Copies `value` into `destination`, an arena that outlives the one the value
   currently lives in — the single young-to-old edge the epoch model licenses.
   The walk is the equality walk with allocation where equality compares: every
   reachable handle is reallocated in `destination`, so the result shares no
   storage with the source and survives the source epoch's close. The result is
   written through `out`, which the caller sizes from the same descriptor
   (a value of arbitrary size cannot be returned generically in C). Aliasing is
   not preserved: promote copies, exactly as assoc/conj already do. */
void native_value_promote(native_arena *destination,
                          const native_value_descriptor *descriptor,
                          const void *value, void *out);
bool native_byte_read(FILE *stream, uint8_t *destination, size_t length);
bool native_byte_write(FILE *stream, const uint8_t *source, size_t length);

uint64_t native_text_length(uint64_t handle);
const uint8_t *native_text_bytes(uint64_t handle);
bool native_text_eq(uint64_t left, uint64_t right);
bool native_text_index_of(uint64_t source, uint64_t needle, int64_t *out);
bool native_text_last_index_of(uint64_t source, uint64_t needle, int64_t *out);
bool native_text_is_blank(uint64_t handle);
bool native_text_parse_i64(uint64_t handle, int64_t *out);
bool native_text_parse_f64(uint64_t handle, double *out);
uint64_t native_text_alloc(native_arena *arena, uint64_t length, uint8_t **out);
uint64_t native_text_slice(native_arena *arena, uint64_t handle, uint64_t start,
                           uint64_t end);
uint64_t native_text_from_int(native_arena *arena, int64_t value);
uint64_t native_text_from_codepoint(native_arena *arena, int64_t value);
uint64_t native_text_concat(native_arena *arena, const uint64_t *parts,
                            uint64_t count);
int64_t native_text_compare(uint64_t left, uint64_t right);
uint64_t native_text_trim(native_arena *arena, uint64_t source);
uint64_t native_text_lower_root(native_arena *arena, uint64_t source);
native_vec *native_text_letter_decimal_runs(native_arena *arena,
                                            uint64_t source,
                                            uint64_t pattern);
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
native_vec *native_utf8_encode(native_arena *arena, uint64_t source);
uint64_t native_utf8_decode(native_arena *arena, const native_vec *source);
uint64_t native_utf8_decode_source(native_arena *arena,
                                   const native_byte_source *source);
/* Copies exactly source->length octets. Traps OUT_OF_RANGE when that length
   exceeds max_bytes and INVALID_ARGUMENT for a negative bound or non-octet. */
native_bytes native_bytes_from_ints_bounded(native_arena *arena,
                                            const native_vec *source,
                                            int64_t max_bytes);
uint64_t native_sha256_bytes(native_arena *arena, const native_vec *source);
int64_t native_float_to_bits(double source);
double native_float_from_bits(int64_t source);

bool native_host_environment_lookup_v0(
    native_arena *arena, const native_capability *capability,
    uint64_t name, uint64_t *out);
int64_t native_host_clock_monotonic_nanoseconds_v0(
    const native_capability *capability);
int64_t native_host_clock_wall_nanoseconds_v0(
    const native_capability *capability);
int32_t native_host_clock_format_iso8601_v0(
    native_arena *arena, const native_capability *capability,
    int64_t epoch_nanoseconds, uint64_t *out);
/* Sleeps for a nonnegative, time_t-representable interval, resuming the
   remaining interval after EINTR. Result is 0 or -errno. WASI is ENOTSUP. */
int64_t native_host_time_sleep_milliseconds_v0(
    const native_capability *capability, int64_t milliseconds);
int32_t native_host_system_hostname_v0(
    native_arena *arena, const native_capability *capability, uint64_t *out);
/* Returns a process-lifetime Text handle naming linux, darwin, wasi, or
   unknown. */
uint64_t native_host_system_platform_v0(
    const native_capability *capability);
bool native_host_terminal_stdout_tty_v0(
    const native_capability *capability);
void native_host_stdout_write_line_v0(
    const native_capability *capability, uint64_t text);
void native_host_stdout_write_v0(
    const native_capability *capability, uint64_t text);
void native_host_stderr_write_v0(
    const native_capability *capability, uint64_t text);
void native_host_stderr_write_line_v0(
    const native_capability *capability, uint64_t text);
bool native_host_filesystem_file_exists_v0(
    const native_capability *capability, uint64_t path);
/* Returns the process working-directory-prefixed path without filesystem
   canonicalization, matching java.io.File.getAbsolutePath. */
uint64_t native_host_filesystem_abs_path_v0(
    native_arena *arena, const native_capability *capability, uint64_t path);
/* Path kind result: 1 regular file, 2 directory, 3 symbolic link, 4 other. */
int32_t native_host_filesystem_path_kind_v0(
    const native_capability *capability, uint64_t path, int64_t *out);
/* Resolves symbolic links and dot components to an existing canonical path.
   The returned Text is arena-owned. WASI returns ENOTSUP. */
int32_t native_host_filesystem_real_path_v0(
    native_arena *arena, const native_capability *capability, uint64_t path,
    uint64_t *out);
int32_t native_host_filesystem_read_text_bounded_v0(
    native_arena *arena, const native_capability *capability, uint64_t path,
    int64_t max_bytes, uint64_t *out);
int32_t native_host_stdin_read_text_bounded_v0(
    native_arena *arena, const native_capability *capability,
    int64_t max_bytes, uint64_t *out);
/* Compiler whole-input adapters fail loudly with a structured diagnostic on
   any host error or bound overflow; they never return a truncated Text. */
uint64_t native_host_filesystem_read_text_bounded_or_die_v0(
    native_arena *arena, const native_capability *capability, uint64_t path,
    int64_t max_bytes);
uint64_t native_host_stdin_read_text_bounded_or_die_v0(
    native_arena *arena, const native_capability *capability,
    int64_t max_bytes);
/* Entries exclude . and .. and are returned in bytewise ascending order. */
int32_t native_host_filesystem_list_directory_bounded_v0(
    native_arena *arena, const native_capability *capability, uint64_t path,
    int64_t max_entries, native_vec **out);
/* Waits until one watched path changes. On success, out receives that input
   path's Text handle; host failures return errno and leave out zero. */
int32_t native_host_filesystem_wait_for_change_v0(
    native_arena *arena, const native_capability *capability,
    const native_vec *paths, uint64_t *out);
int32_t native_host_filesystem_write_text_atomic_v0(
    const native_capability *capability, uint64_t path, uint64_t text);
int32_t native_host_filesystem_make_parent_directories_v0(
    const native_capability *capability, uint64_t path);
int32_t native_host_filesystem_append_text_v0(
    const native_capability *capability, uint64_t path, uint64_t text);
/* Follows the path and returns its modification time as Unix-epoch
   nanoseconds, or EOVERFLOW when the host timestamp cannot fit Int. */
int32_t native_host_filesystem_mtime_nanoseconds_v0(
    const native_capability *capability, uint64_t path, int64_t *out);
/* Creates an empty mode-0600 sibling of path and returns its owned path. The
   caller must finish the lifecycle with rename-file or remove-file. */
int32_t native_host_filesystem_create_temporary_sibling_v0(
    native_arena *arena, const native_capability *capability, uint64_t path,
    uint64_t *out);
/* Atomically replaces destination when the two paths share a filesystem. */
int32_t native_host_filesystem_rename_file_v0(
    const native_capability *capability, uint64_t source,
    uint64_t destination);
/* Removes a non-directory filesystem entry. */
int32_t native_host_filesystem_remove_file_v0(
    const native_capability *capability, uint64_t path);
/* Non-blocking exclusive lease on the path's open file description. The caller
   owns the returned descriptor: unlock consumes it, and the kernel releases the
   lease on close or on process death. A lease held elsewhere returns EAGAIN. */
int32_t native_host_filesystem_lock_exclusive_v0(
    const native_capability *capability, uint64_t path, int64_t *out);
int32_t native_host_filesystem_unlock_v0(
    const native_capability *capability, int64_t descriptor);
/* Runs argv directly through PATH with inherited environment and stdio.
   Result: normal exit 0..255, signal 256+signal, spawn/wait failure -errno. */
int64_t native_host_process_run_inherit_v0(
    const native_capability *capability, const native_vec *argv);
/* Replaces the current process through PATH. Success never returns; failures
   are negative errno. Environment and all standard descriptors are inherited. */
int64_t native_host_process_exec_replace_v0(
    const native_capability *capability, const native_vec *argv);
/* Captures each output stream up to max_output_bytes while draining both
   concurrently. Normal exits and signals are CaptureOk; host failures return
   positive errno and leave out NULL. */
int32_t native_host_process_run_capture_v0(
    native_arena *arena, const native_capability *capability,
    const native_vec *argv, uint64_t stdin_text, int64_t max_output_bytes,
    void **out);
/* Spawns tokenized argv with inherited stdin, stderr, and environment. The
   caller owns both returned values: wait consumes pid's child relationship,
   and close consumes stdout_fd. Host failures are positive errno/out NULL. */
int32_t native_host_process_spawn_stdout_v0(
    native_arena *arena, const native_capability *capability,
    const native_vec *argv, void **out);
/* Borrows stdout_fd and reads through one LF (stripping LF and one preceding
   CR). eof is 1 only when no bytes remain. The content bound is in bytes;
   overflow drains that line and returns EFBIG. */
int32_t native_host_process_read_line_bounded_v0(
    native_arena *arena, const native_capability *capability,
    int64_t stdout_fd, int64_t max_line_bytes, void **out);
/* The timeout is relative milliseconds measured once against CLOCK_MONOTONIC.
   ETIMEDOUT means no byte was consumed; EPROTO means a partial line was
   consumed and the caller must close/reopen the descriptor. */
int32_t native_host_process_read_line_deadline_v0(
    native_arena *arena, const native_capability *capability,
    int64_t fd, int64_t max_line_bytes, int64_t timeout_ms, void **out);
int64_t native_host_process_fifo_create_v0(
    const native_capability *capability, uint64_t path);
/* Returns one caller-owned nonblocking close-on-exec FIFO reader descriptor. */
int64_t native_host_process_fifo_open_read_v0(
    const native_capability *capability, uint64_t path);
/* Opens, atomically writes the exact Text bytes, and closes one temporary FIFO
   writer within a monotonic relative timeout. */
int64_t native_host_process_fifo_write_deadline_v0(
    const native_capability *capability, uint64_t path, uint64_t text,
    int64_t timeout_ms);
/* Borrows an ordered nonempty Int descriptor vector and returns its first ready
   descriptor. HUP/ERR are readiness; invalid is -EBADF; expiry -ETIMEDOUT. */
int64_t native_host_process_poll_readable_v0(
    const native_capability *capability, const native_vec *fds,
    int64_t timeout_ms);
int64_t native_host_process_current_pid_v0(
    const native_capability *capability);
bool native_host_process_alive_v0(
    const native_capability *capability, int64_t pid);
int64_t native_host_process_signal_v0(
    const native_capability *capability, int64_t pid, int64_t signal_number);
/* Observes arbitrary PID death without waitpid and therefore never reaps. */
int64_t native_host_process_wait_not_alive_v0(
    const native_capability *capability, int64_t pid, int64_t timeout_ms);
/* wait consumes the caller-owned child relationship. Result is exit 0..255,
   signal 256+signal, or -errno; EINTR is retried. */
int64_t native_host_process_wait_v0(
    const native_capability *capability, int64_t pid);
/* close consumes the caller-owned descriptor. It deliberately does not retry
   EINTR because the descriptor number may already have been released/reused. */
int64_t native_host_process_close_v0(
    const native_capability *capability, int64_t fd);
/* Listener ownership is inherited at FD 3; this ABI never creates a socket. */
int32_t native_host_socket_inherited_listener_v0(
    const native_capability *capability, int64_t fd, int64_t *out);
int32_t native_host_socket_accept_v0(
    const native_capability *capability, int64_t listener_fd, int64_t *out);
int32_t native_host_socket_read_bounded_v0(
    native_arena *arena, const native_capability *capability, int64_t peer_fd,
    int64_t max_bytes, native_bytes *out);
int32_t native_host_socket_write_bounded_v0(
    const native_capability *capability, int64_t peer_fd, native_bytes bytes,
    int64_t max_bytes, int64_t *out);
int32_t native_host_socket_close_v0(
    const native_capability *capability, int64_t fd);

#endif
