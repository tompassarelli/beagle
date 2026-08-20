#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
host_pid=""
stall_pid=""
cleanup() {
  if [[ -n "${stall_pid:-}" ]] && kill -0 "$stall_pid" 2>/dev/null; then
    kill -TERM "$stall_pid" 2>/dev/null || true
    wait "$stall_pid" 2>/dev/null || true
  fi
  if [[ -n "${host_pid:-}" ]] && kill -0 "$host_pid" 2>/dev/null; then
    kill -TERM "$host_pid" 2>/dev/null || true
    wait "$host_pid" 2>/dev/null || true
  fi
  rm -rf "${scratch:?}"
}
trap cleanup EXIT INT TERM
cc="${CC:-cc}"

for command in "$cc" awk cmp grep nm sed sleep sort; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "store native generated adapter smoke: missing $command" >&2
    exit 1
  }
done

cat >"$scratch/native_shim.h" <<'HEADER'
#ifndef NATIVE_SHIM_H
#define NATIVE_SHIM_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct native_arena_chunk native_arena_chunk;

typedef struct native_arena {
  uint8_t *bytes;
  size_t capacity;
  size_t offset;
  native_arena_chunk *chunks;
  size_t growth_floor;
  bool growable;
} native_arena;

typedef struct native_capability {
  uint64_t token;
} native_capability;

/* Mirrors the shim header: `watermark` is the count of element slots handed
   out from `elements`, NULL for storage the shim did not allocate. */
typedef struct native_vec {
  void *elements;
  int64_t length;
  int64_t capacity;
  int64_t *watermark;
} native_vec;

/* Mirrors the shim header: borrowed octets the shim neither owns nor copies. */
typedef struct native_byte_source {
  const uint8_t *data;
  int64_t length;
} native_byte_source;

void native_arena_init(native_arena *arena, uint8_t *storage, size_t capacity);
bool native_arena_init_growable(native_arena *arena, size_t growth_floor);
void native_arena_destroy(native_arena *arena);
size_t native_arena_reserved_bytes(const native_arena *arena);
void *native_arena_alloc(native_arena *arena, size_t size, size_t alignment);
uint64_t native_text_alloc(native_arena *arena, uint64_t length, uint8_t **out);
uint64_t native_text_length(uint64_t handle);
const uint8_t *native_text_bytes(uint64_t handle);
native_vec *native_vec_new(native_arena *arena, int64_t capacity,
                           int64_t stride, size_t alignment);
int64_t native_vec_length(const native_vec *vector);
const void *native_vec_at(const native_vec *vector, int64_t index,
                          int64_t stride);
native_vec *native_vec_push(native_arena *arena, native_vec *vector,
                            const void *value, int64_t stride,
                            size_t alignment);
native_byte_source *native_byte_source_borrow(native_arena *arena,
                                              const uint8_t *data,
                                              int64_t length);
int64_t native_byte_source_length(const native_byte_source *source);
int64_t native_byte_source_at(const native_byte_source *source, int64_t index);

#define NATIVE_TRAP_INVALID_ARGUMENT UINT32_C(1)
#define NATIVE_TRAP_OVERFLOW UINT32_C(2)
#define NATIVE_TRAP_ARENA_EXHAUSTED UINT32_C(3)
#define NATIVE_TRAP_OUT_OF_RANGE UINT32_C(4)
#define NATIVE_TRAP_IO UINT32_C(5)

typedef void (*native_trap_reporter)(uint32_t code);
void native_set_trap_reporter(native_trap_reporter reporter);
#endif
HEADER

cat >"$scratch/module_0.h" <<'HEADER'
#ifndef NATIVE_MODULE_0_ABI_H
#define NATIVE_MODULE_0_ABI_H
#include "native_shim.h"
#include <stdbool.h>

typedef int64_t native_m0_type_0;
typedef uint64_t native_m0_type_1;
typedef native_vec *native_m0_type_2;
typedef uint64_t native_m0_type_3;
typedef native_byte_source *native_m0_type_9;

typedef struct native_m0_type_4 {
  native_m0_type_0 field_0;
  native_m0_type_3 field_1;
  native_m0_type_3 field_2;
  native_m0_type_0 field_3;
  native_m0_type_2 field_4;
  native_m0_type_3 field_5;
} native_m0_type_4;

typedef struct native_m0_type_5 {
  native_m0_type_0 field_0;
  native_m0_type_3 field_1;
  native_m0_type_3 field_2;
} native_m0_type_5;

typedef struct native_m0_type_6 {
  native_m0_type_0 field_0;
  native_m0_type_3 field_1;
  native_m0_type_3 field_2;
  native_m0_type_2 field_3;
  native_m0_type_4 field_4;
  bool field_5;
  native_m0_type_2 field_6;
} native_m0_type_6;

typedef struct native_m0_type_7 {
  native_m0_type_0 field_0;
  native_m0_type_2 field_1;
} native_m0_type_7;

typedef struct native_m0_type_8 {
  native_m0_type_0 field_0;
  native_m0_type_3 field_1;
} native_m0_type_8;

native_m0_type_0 store_stub_generated_abi(void);
native_m0_type_4 store_stub_store_boot(
    native_arena *arena, const native_capability *capability,
    native_m0_type_1 canonical_log_path, native_m0_type_1 space_id,
    native_m0_type_9 log_bytes, native_m0_type_9 snapshot_bytes);
native_m0_type_6 store_stub_store_dispatch(
    native_arena *arena, const native_capability *capability,
    native_m0_type_4 store, native_m0_type_5 request,
    native_m0_type_0 now_milliseconds);
native_m0_type_8 store_stub_store_shutdown(native_m0_type_4 store);
native_m0_type_5 store_stub_codec_read_request(native_arena *arena,
                                               native_m0_type_9 record);
native_m0_type_7 store_stub_codec_write_response(
    native_arena *arena, const native_capability *capability,
    native_m0_type_6 response);
native_m0_type_3 store_stub_codec_release_request(native_m0_type_5 request);
native_m0_type_3 store_stub_codec_release_response(
    const native_capability *capability, native_m0_type_6 response);
#endif
HEADER

cat >"$scratch/server_symbols.h" <<'HEADER'
#ifndef BEAGLE_STORE_SERVER_SYMBOLS_H
#define BEAGLE_STORE_SERVER_SYMBOLS_H
#include "module_0.h"

#define BEAGLE_STORE_SERVER_SYMBOL_GENERATED_ABI store_stub_generated_abi
#define BEAGLE_STORE_SERVER_SYMBOL_STORE_BOOT store_stub_store_boot
#define BEAGLE_STORE_SERVER_SYMBOL_STORE_DISPATCH store_stub_store_dispatch
#define BEAGLE_STORE_SERVER_SYMBOL_STORE_SHUTDOWN store_stub_store_shutdown
#define BEAGLE_STORE_SERVER_SYMBOL_CODEC_READ_REQUEST store_stub_codec_read_request
#define BEAGLE_STORE_SERVER_SYMBOL_CODEC_WRITE_RESPONSE store_stub_codec_write_response
#define BEAGLE_STORE_SERVER_SYMBOL_CODEC_RELEASE_REQUEST                         \
  store_stub_codec_release_request
#define BEAGLE_STORE_SERVER_SYMBOL_CODEC_RELEASE_RESPONSE                        \
  store_stub_codec_release_response

typedef native_m0_type_0 store_server_generated_abi_return;
typedef native_m0_type_4 store_server_store_boot_return;
typedef native_m0_type_1 store_server_store_boot_arg_0;
typedef native_m0_type_1 store_server_store_boot_arg_1;
typedef native_m0_type_9 store_server_store_boot_arg_2;
typedef native_m0_type_9 store_server_store_boot_arg_3;
typedef native_m0_type_6 store_server_store_dispatch_return;
typedef native_m0_type_4 store_server_store_dispatch_arg_0;
typedef native_m0_type_5 store_server_store_dispatch_arg_1;
typedef native_m0_type_0 store_server_store_dispatch_arg_2;
typedef native_m0_type_8 store_server_store_shutdown_return;
typedef native_m0_type_4 store_server_store_shutdown_arg_0;
typedef native_m0_type_5 store_server_codec_read_request_return;
typedef native_m0_type_9 store_server_codec_read_request_arg_0;
typedef native_m0_type_7 store_server_codec_write_response_return;
typedef native_m0_type_6 store_server_codec_write_response_arg_0;
typedef native_m0_type_3 store_server_codec_release_request_return;
typedef native_m0_type_5 store_server_codec_release_request_arg_0;
typedef native_m0_type_3 store_server_codec_release_response_return;
typedef native_m0_type_6 store_server_codec_release_response_arg_0;

#define BEAGLE_STORE_SERVER_CALL_GENERATED_ABI(arena, capability)                \
  BEAGLE_STORE_SERVER_SYMBOL_GENERATED_ABI()
#define BEAGLE_STORE_SERVER_CALL_STORE_BOOT(arena, capability, arg_0, arg_1,     \
                                    arg_2, arg_3)                         \
  BEAGLE_STORE_SERVER_SYMBOL_STORE_BOOT((arena), (capability), (arg_0), (arg_1), \
                                (arg_2), (arg_3))
#define BEAGLE_STORE_SERVER_CALL_STORE_DISPATCH(                                 \
    arena, capability, arg_0, arg_1, arg_2)                                  \
  BEAGLE_STORE_SERVER_SYMBOL_STORE_DISPATCH((arena), (capability), (arg_0),      \
                                        (arg_1), (arg_2))
#define BEAGLE_STORE_SERVER_CALL_STORE_SHUTDOWN(arena, capability, arg_0)        \
  BEAGLE_STORE_SERVER_SYMBOL_STORE_SHUTDOWN((arg_0))
#define BEAGLE_STORE_SERVER_CALL_CODEC_READ_REQUEST(arena, capability, arg_0)    \
  BEAGLE_STORE_SERVER_SYMBOL_CODEC_READ_REQUEST((arena), (arg_0))
#define BEAGLE_STORE_SERVER_CALL_CODEC_WRITE_RESPONSE(arena, capability, arg_0)  \
  BEAGLE_STORE_SERVER_SYMBOL_CODEC_WRITE_RESPONSE((arena), (capability), (arg_0))
#define BEAGLE_STORE_SERVER_CALL_CODEC_RELEASE_REQUEST(arena, capability, arg_0) \
  BEAGLE_STORE_SERVER_SYMBOL_CODEC_RELEASE_REQUEST((arg_0))
#define BEAGLE_STORE_SERVER_CALL_CODEC_RELEASE_RESPONSE(arena, capability,       \
                                                    arg_0)                   \
  BEAGLE_STORE_SERVER_SYMBOL_CODEC_RELEASE_RESPONSE((capability), (arg_0))
#endif
HEADER

cat >"$scratch/native_shim.c" <<'C'
#include "native_shim.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

struct native_arena_chunk {
  struct native_arena_chunk *next;
  size_t capacity;
  max_align_t alignment;
  uint8_t bytes[];
};

void native_arena_init(native_arena *arena, uint8_t *storage, size_t capacity) {
  arena->bytes = storage;
  arena->capacity = capacity;
  arena->offset = 0u;
  arena->chunks = NULL;
  arena->growth_floor = 0u;
  arena->growable = false;
}

bool native_arena_init_growable(native_arena *arena, size_t growth_floor) {
  if (growth_floor == 0u) {
    return false;
  }
  native_arena_init(arena, NULL, 0u);
  arena->growth_floor = growth_floor;
  arena->growable = true;
  return true;
}

void native_arena_destroy(native_arena *arena) {
  native_arena_chunk *chunk = arena->chunks;

  while (chunk != NULL) {
    native_arena_chunk *next = chunk->next;
    free(chunk);
    chunk = next;
  }
  native_arena_init(arena, NULL, 0u);
}

size_t native_arena_reserved_bytes(const native_arena *arena) {
  const native_arena_chunk *chunk;
  size_t total = arena->growable ? 0u : arena->capacity;

  for (chunk = arena->chunks; chunk != NULL; chunk = chunk->next) {
    if (total > SIZE_MAX - chunk->capacity) {
      abort();
    }
    total += chunk->capacity;
  }
  return total;
}

void *native_arena_alloc(native_arena *arena, size_t size, size_t alignment) {
  native_arena_chunk *chunk;
  uintptr_t current;
  uintptr_t aligned;
  size_t offset;

  if (alignment == 0u || (alignment & (alignment - 1u)) != 0u) {
    abort();
  }
  if (arena->growable) {
    size_t capacity = size > arena->growth_floor ? size : arena->growth_floor;

    if (alignment > _Alignof(max_align_t) ||
        capacity > SIZE_MAX - sizeof(*chunk)) {
      abort();
    }
    chunk = malloc(sizeof(*chunk) + capacity);
    if (chunk == NULL) {
      abort();
    }
    chunk->next = arena->chunks;
    chunk->capacity = capacity;
    arena->chunks = chunk;
    return chunk->bytes;
  }
  current = (uintptr_t)(arena->bytes + arena->offset);
  aligned = (current + alignment - 1u) & ~(uintptr_t)(alignment - 1u);
  offset = (size_t)(aligned - (uintptr_t)arena->bytes);
  if (offset > arena->capacity || size > arena->capacity - offset) {
    abort();
  }
  arena->offset = offset + size;
  return arena->bytes + offset;
}

uint64_t native_text_alloc(native_arena *arena, uint64_t length, uint8_t **out) {
  uint8_t *storage = native_arena_alloc(
      arena, sizeof(length) + (size_t)length, _Alignof(uint64_t));

  memcpy(storage, &length, sizeof(length));
  *out = storage + sizeof(length);
  return (uint64_t)(uintptr_t)storage;
}

uint64_t native_text_length(uint64_t handle) {
  uint64_t length;
  memcpy(&length, (const void *)(uintptr_t)handle, sizeof(length));
  return length;
}

const uint8_t *native_text_bytes(uint64_t handle) {
  return (const uint8_t *)(uintptr_t)handle + sizeof(uint64_t);
}

native_vec *native_vec_new(native_arena *arena, int64_t capacity,
                           int64_t stride, size_t alignment) {
  native_vec *vector = native_arena_alloc(arena, sizeof(*vector),
                                           _Alignof(native_vec));
  size_t bytes;

  if (capacity < INT64_C(0) || stride <= INT64_C(0) ||
      capacity > INT64_MAX / stride) {
    abort();
  }
  bytes = (size_t)(capacity * stride);
  vector->elements = bytes == 0u ? NULL
                                 : native_arena_alloc(arena, bytes, alignment);
  vector->length = INT64_C(0);
  vector->capacity = capacity;
  vector->watermark = NULL;
  if (bytes != 0u) {
    vector->watermark = native_arena_alloc(arena, sizeof(int64_t),
                                            _Alignof(int64_t));
    *vector->watermark = INT64_C(0);
  }
  return vector;
}

int64_t native_vec_length(const native_vec *vector) { return vector->length; }

const void *native_vec_at(const native_vec *vector, int64_t index,
                          int64_t stride) {
  if (index < INT64_C(0) || index >= vector->length) {
    abort();
  }
  return (const uint8_t *)vector->elements + (size_t)(index * stride);
}

void native_set_trap_reporter(native_trap_reporter reporter) {
  (void)reporter;
}

native_byte_source *native_byte_source_borrow(native_arena *arena,
                                              const uint8_t *data,
                                              int64_t length) {
  native_byte_source *source = native_arena_alloc(
      arena, sizeof(*source), _Alignof(native_byte_source));

  if (length < INT64_C(0) || (length > INT64_C(0) && data == NULL)) {
    abort();
  }
  source->data = data;
  source->length = length;
  return source;
}

int64_t native_byte_source_length(const native_byte_source *source) {
  return source->length;
}

int64_t native_byte_source_at(const native_byte_source *source, int64_t index) {
  if (index < INT64_C(0) || index >= source->length) {
    abort();
  }
  return (int64_t)(uint64_t)source->data[index];
}

/* Persistent, on the shim's rule: a push writes into existing storage only at
   the watermark, and otherwise forks onto a private copy. */
native_vec *native_vec_push(native_arena *arena, native_vec *vector,
                            const void *value, int64_t stride,
                            size_t alignment) {
  native_vec *fresh;

  if (vector->watermark != NULL && vector->length < vector->capacity &&
      *vector->watermark == vector->length) {
    native_vec *header = native_arena_alloc(arena, sizeof(*header),
                                             _Alignof(native_vec));
    memcpy((uint8_t *)vector->elements + (size_t)(vector->length * stride),
           value, (size_t)stride);
    *vector->watermark = vector->length + INT64_C(1);
    header->elements = vector->elements;
    header->length = vector->length + INT64_C(1);
    header->capacity = vector->capacity;
    header->watermark = vector->watermark;
    return header;
  }
  fresh = native_vec_new(arena, vector->length + INT64_C(1), stride, alignment);
  if (vector->length > INT64_C(0)) {
    memcpy(fresh->elements, vector->elements,
           (size_t)(vector->length * stride));
  }
  memcpy((uint8_t *)fresh->elements + (size_t)(vector->length * stride),
         value, (size_t)stride);
  fresh->length = vector->length + INT64_C(1);
  *fresh->watermark = fresh->length;
  return fresh;
}
C

cat >"$scratch/generated_stub.c" <<'C'
#include "module_0.h"

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

enum { OK = 0, FATAL = 2 };

static unsigned int boot_calls;
static unsigned int dispatch_calls;
static unsigned int shutdown_calls;
static unsigned int read_calls;
static unsigned int write_calls;
static unsigned int release_request_calls;
static unsigned int release_response_calls;

static int64_t tail_items[] = {'T', 'A', 'I', 'L'};
static native_vec tail_append = {tail_items, INT64_C(4), INT64_C(4), NULL};

static const uint8_t response_record[] = {
    0x46, 0x52, 0x41, 0x4d, 0x52, 0x50, 0x43, 0x00, 0x01, 0x00,
    0x00, 0x00, 0x02, 0x00, 0x02, 0x00, 0x00, 0x00, 0x07, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xdd, 0xee};

static bool text_is(uint64_t text, const char *expected) {
  size_t length = strlen(expected);
  return native_text_length(text) == (uint64_t)length &&
         memcmp(native_text_bytes(text), expected, length) == 0;
}

static bool source_is(const native_byte_source *source,
                      const uint8_t *expected, size_t count) {
  size_t index;

  if (source == NULL || native_byte_source_length(source) != (int64_t)count) {
    return false;
  }
  for (index = 0u; index < count; index += 1u) {
    if (native_byte_source_at(source, (int64_t)index) !=
        (int64_t)expected[index]) {
      return false;
    }
  }
  return true;
}

static native_vec *make_vector(native_arena *arena, const uint8_t *bytes,
                               size_t count) {
  native_vec *vector = native_vec_new(arena, (int64_t)count, INT64_C(8),
                                      _Alignof(int64_t));
  size_t index;

  for (index = 0u; index < count; index += 1u) {
    int64_t value = (int64_t)bytes[index];
    vector = native_vec_push(arena, vector, &value, INT64_C(8),
                             _Alignof(int64_t));
  }
  return vector;
}

native_m0_type_0 store_stub_generated_abi(void) { return INT64_C(4); }

native_m0_type_4 store_stub_store_boot(
    native_arena *arena, const native_capability *capability,
    native_m0_type_1 canonical_log_path, native_m0_type_1 space_id,
    native_m0_type_9 log_bytes, native_m0_type_9 snapshot_bytes) {
  static const uint8_t old_log[] = {'O', 'L', 'D', '!', 'x'};
  static const uint8_t old_image[] = {'I', 'M', 'G'};
  static const uint8_t boot_bytes[] = {'B', 'O', 'O', 'T'};
  static const char report[] = "smoke: snapshot boot degraded to full fold";
  native_m0_type_4 result = {FATAL, UINT64_C(0), UINT64_C(0),
                             INT64_C(0), NULL, UINT64_C(0)};
  uint8_t *report_bytes = NULL;

  boot_calls += 1u;
  if (capability->token == UINT64_C(1) &&
      text_is(canonical_log_path, "SMOKE_LOG_PATH") &&
      text_is(space_id, "smoke-space") &&
      source_is(log_bytes, old_log, sizeof(old_log)) &&
      source_is(snapshot_bytes, old_image, sizeof(old_image))) {
    result.field_0 = OK;
    result.field_1 = UINT64_C(11);
    result.field_3 = INT64_C(4);
    result.field_4 = make_vector(arena, boot_bytes, sizeof(boot_bytes));
    result.field_5 = native_text_alloc(arena, (uint64_t)(sizeof(report) - 1u),
                                       &report_bytes);
    memcpy(report_bytes, report, sizeof(report) - 1u);
  }
  return result;
}

native_m0_type_6 store_stub_store_dispatch(
    native_arena *arena, const native_capability *capability,
    native_m0_type_4 store, native_m0_type_5 request,
    native_m0_type_0 now_milliseconds) {
  static int64_t image_items[] = {'I', 'M', 'G', '2'};
  static native_vec image_write = {image_items, INT64_C(4), INT64_C(4),
                                   NULL};
  native_m0_type_6 result = {FATAL,
                             UINT64_C(0),
                             UINT64_C(0),
                             NULL,
                             {FATAL, UINT64_C(0), UINT64_C(0),
                              INT64_C(0), NULL, UINT64_C(0)},
                             false,
                             NULL};
  (void)arena;

  dispatch_calls += 1u;
  if (capability->token == UINT64_C(1) && store.field_0 == OK &&
      store.field_1 == UINT64_C(11) && request.field_0 == OK &&
      request.field_1 != UINT64_C(0) && now_milliseconds > INT64_C(0)) {
    result.field_0 = OK;
    result.field_1 = request.field_1;
    result.field_3 = &tail_append;
    result.field_4 = store;
    result.field_5 = true;
    result.field_6 = &image_write;
  }
  return result;
}

native_m0_type_8 store_stub_store_shutdown(native_m0_type_4 store) {
  native_m0_type_8 result = {FATAL, UINT64_C(0)};
  shutdown_calls += 1u;
  if (store.field_0 == OK && store.field_1 == UINT64_C(11)) {
    result.field_0 = OK;
  }
  return result;
}

native_m0_type_5 store_stub_codec_read_request(native_arena *arena,
                                               native_m0_type_9 record) {
  native_m0_type_5 result = {FATAL, UINT64_C(0), UINT64_C(0)};

  read_calls += 1u;
  if (record != NULL && native_byte_source_length(record) == INT64_C(29) &&
      native_byte_source_at(record, INT64_C(26)) == INT64_C(0xaa)) {
    native_vec *copy = native_vec_new(arena, native_byte_source_length(record),
                                      INT64_C(8), _Alignof(int64_t));
    int64_t index;

    result.field_0 = OK;
    for (index = INT64_C(0); index < native_byte_source_length(record);
         index += INT64_C(1)) {
      int64_t value = native_byte_source_at(record, index);
      copy = native_vec_push(arena, copy, &value, INT64_C(8),
                             _Alignof(int64_t));
    }
    result.field_1 = (uint64_t)(uintptr_t)copy;
  }
  return result;
}

native_m0_type_7 store_stub_codec_write_response(
    native_arena *arena, const native_capability *capability,
    native_m0_type_6 response) {
  native_m0_type_7 result = {FATAL, NULL};

  write_calls += 1u;
  if (capability->token == UINT64_C(1) && response.field_0 == OK &&
      response.field_1 != UINT64_C(0)) {
    const native_vec *borrowed = (const native_vec *)(uintptr_t)response.field_1;
    const int64_t *body = native_vec_at(borrowed, INT64_C(26), INT64_C(8));
    if (*body == INT64_C(0xaa)) {
      result.field_0 = OK;
      result.field_1 = make_vector(arena, response_record,
                                   sizeof(response_record));
    }
  }
  return result;
}

native_m0_type_3 store_stub_codec_release_request(native_m0_type_5 request) {
  if (request.field_0 == OK || request.field_0 == FATAL) {
    release_request_calls += 1u;
  }
  return UINT64_C(0);
}

native_m0_type_3 store_stub_codec_release_response(
    const native_capability *capability, native_m0_type_6 response) {
  if (capability->token == UINT64_C(1) && response.field_0 == OK) {
    release_response_calls += 1u;
  }
  return UINT64_C(0);
}

bool generated_stub_observed_exact_calls(void) {
  return boot_calls == 1u && dispatch_calls == 1u &&
         shutdown_calls == 1u && read_calls == 2u &&
         write_calls == 1u &&
         release_request_calls == 2u && release_response_calls == 1u;
}
C

sed -i "s|SMOKE_LOG_PATH|$scratch/store.log|" "$scratch/generated_stub.c"

cat >"$scratch/main.c" <<'C'
#include "server_host.h"

#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

bool generated_stub_observed_exact_calls(void);

static const uint8_t request_record[] = {
    0x46, 0x52, 0x41, 0x4d, 0x52, 0x50, 0x43, 0x00, 0x01, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x03, 0x00, 0x00, 0x00, 0x07, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xaa, 0xbb, 0xcc};

static const uint8_t response_record[] = {
    0x46, 0x52, 0x41, 0x4d, 0x52, 0x50, 0x43, 0x00, 0x01, 0x00,
    0x00, 0x00, 0x02, 0x00, 0x02, 0x00, 0x00, 0x00, 0x07, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xdd, 0xee};

static bool write_all(int fd, const uint8_t *bytes, size_t length) {
  size_t position = 0u;
  while (position < length) {
    ssize_t count = write(fd, bytes + position, length - position);
    if (count <= 0) {
      return false;
    }
    position += (size_t)count;
  }
  return true;
}

static bool read_all(int fd, uint8_t *bytes, size_t length) {
  size_t position = 0u;
  while (position < length) {
    ssize_t count = read(fd, bytes + position, length - position);
    if (count <= 0) {
      return false;
    }
    position += (size_t)count;
  }
  return true;
}

static bool file_is(const char *path, const char *expected) {
  uint8_t bytes[64];
  size_t length = strlen(expected);
  int fd = open(path, O_RDONLY);
  ssize_t extra;

  if (fd < 0 || length > sizeof(bytes) || !read_all(fd, bytes, length)) {
    if (fd >= 0) {
      (void)close(fd);
    }
    return false;
  }
  extra = read(fd, bytes + length, 1u);
  (void)close(fd);
  return extra == 0 && memcmp(bytes, expected, length) == 0;
}

static int request_from_bytes(const uint8_t *bytes, size_t length,
                              store_server_request **request, char *error,
                              size_t error_capacity) {
  int pair[2];
  int status;

  if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0 ||
      !write_all(pair[1], bytes, length) || shutdown(pair[1], SHUT_WR) != 0) {
    return -1;
  }
  status = store_server_codec_read_request(pair[0], request, error,
                                               error_capacity);
  (void)close(pair[0]);
  (void)close(pair[1]);
  return status;
}

static bool image_path_is(const char *log_path, const char *expected) {
  char path[512];
  size_t length = strlen(log_path);

  if (length + strlen(".snapshot") + 1u > sizeof(path)) {
    return false;
  }
  memcpy(path, log_path, length);
  memcpy(path + length, ".snapshot", strlen(".snapshot") + 1u);
  return file_is(path, expected);
}

int main(int argc, char **argv) {
  store_server_store *store = NULL;
  store_server_request *request = NULL;
  store_server_request *failed = NULL;
  store_server_response *response = NULL;
  uint8_t bad_record[sizeof(request_record)];
  uint8_t oversized_header[26];
  uint8_t received[sizeof(response_record)];
  char error[BEAGLE_STORE_SERVER_ERROR_CAPACITY];
  int pair[2];

  if (argc != 2 ||
      store_server_generated_abi() != BEAGLE_STORE_SERVER_GENERATED_ABI ||
      store_server_store_boot(argv[1], "smoke-space", UINT64_C(0), &store,
                                 error, sizeof(error)) != BEAGLE_STORE_SERVER_OK ||
      store == NULL || error[0] != '\0' || !file_is(argv[1], "OLD!BOOT") ||
      !image_path_is(argv[1], "IMG")) {
    return 1;
  }

  if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) {
    return 2;
  }
  (void)close(pair[1]);
  if (store_server_codec_read_request(pair[0], &failed, error,
                                          sizeof(error)) !=
          BEAGLE_STORE_SERVER_PEER_CLOSED ||
      failed != NULL || error[0] != '\0') {
    return 3;
  }
  (void)close(pair[0]);

  if (request_from_bytes(request_record, 3u, &failed, error, sizeof(error)) !=
          BEAGLE_STORE_SERVER_CLIENT_ERROR ||
      failed != NULL ||
      strcmp(error, "generated request record ended inside its header") != 0) {
    return 4;
  }

  memcpy(oversized_header, request_record, sizeof(oversized_header));
  oversized_header[14] = 0x01;
  oversized_header[15] = 0x00;
  oversized_header[16] = 0x10;
  oversized_header[17] = 0x00;
  if (request_from_bytes(oversized_header, sizeof(oversized_header), &failed,
                         error, sizeof(error)) !=
          BEAGLE_STORE_SERVER_CLIENT_ERROR ||
      failed != NULL ||
      strcmp(error, "generated request record exceeds the body limit") != 0) {
    return 5;
  }

  memcpy(bad_record, request_record, sizeof(bad_record));
  bad_record[26] = 0xee;
  if (request_from_bytes(bad_record, sizeof(bad_record), &failed, error,
                         sizeof(error)) != BEAGLE_STORE_SERVER_CLIENT_ERROR ||
      failed != NULL ||
      strcmp(error, "generated request decode failed") != 0) {
    return 6;
  }

  if (request_from_bytes(request_record, sizeof(request_record), &request, error,
                         sizeof(error)) != BEAGLE_STORE_SERVER_OK ||
      request == NULL ||
      store_server_store_dispatch(store, request, &response, error,
                                     sizeof(error)) != BEAGLE_STORE_SERVER_OK ||
      response == NULL || !file_is(argv[1], "OLD!BOOTTAIL") ||
      !image_path_is(argv[1], "IMG2")) {
    return 7;
  }
  store_server_codec_release_request(request);

  if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0 ||
      store_server_codec_write_response(pair[0], response, error,
                                           sizeof(error)) !=
          BEAGLE_STORE_SERVER_OK ||
      !read_all(pair[1], received, sizeof(received)) ||
      memcmp(received, response_record, sizeof(received)) != 0) {
    return 8;
  }
  (void)close(pair[0]);
  (void)close(pair[1]);
  store_server_codec_release_response(response);

  if (store_server_store_shutdown(store, error, sizeof(error)) !=
          BEAGLE_STORE_SERVER_OK ||
      !file_is(argv[1], "OLD!BOOTTAIL") ||
      !generated_stub_observed_exact_calls()) {
    return 9;
  }
  return 0;
}
C

cat >"$scratch/embed_main.c" <<'C'
#include "store.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct memory_host {
  uint8_t bytes[128];
  size_t length;
  size_t allocations;
  size_t deallocations;
  size_t syncs;
  size_t closes;
} memory_host;

static const uint8_t request_record[] = {
    0x46, 0x52, 0x41, 0x4d, 0x52, 0x50, 0x43, 0x00, 0x01, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x03, 0x00, 0x00, 0x00, 0x07, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xaa, 0xbb, 0xcc};

static const uint8_t response_record[] = {
    0x46, 0x52, 0x41, 0x4d, 0x52, 0x50, 0x43, 0x00, 0x01, 0x00,
    0x00, 0x00, 0x02, 0x00, 0x02, 0x00, 0x00, 0x00, 0x07, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xdd, 0xee};

static void *host_allocate(void *context, size_t size) {
  memory_host *host = context;
  void *allocation = malloc(size);

  if (allocation != NULL) {
    host->allocations += 1u;
  }
  return allocation;
}

static void host_deallocate(void *context, void *allocation) {
  memory_host *host = context;

  if (allocation != NULL) {
    host->deallocations += 1u;
  }
  free(allocation);
}

static int host_clock(void *context, int64_t *milliseconds_out) {
  (void)context;
  *milliseconds_out = INT64_C(1234);
  return 0;
}

static int storage_size(void *context, uint64_t *size_out) {
  memory_host *host = context;

  *size_out = (uint64_t)host->length;
  return 0;
}

static int storage_read(void *context, uint64_t offset, uint8_t *destination,
                        size_t length) {
  memory_host *host = context;

  if (offset > (uint64_t)host->length ||
      length > host->length - (size_t)offset) {
    return 1;
  }
  memcpy(destination, host->bytes + (size_t)offset, length);
  return 0;
}

static int storage_truncate(void *context, uint64_t length) {
  memory_host *host = context;

  if (length > (uint64_t)host->length) {
    return 1;
  }
  host->length = (size_t)length;
  return 0;
}

static int storage_append(void *context, const uint8_t *bytes, size_t length) {
  memory_host *host = context;

  if (length > sizeof(host->bytes) - host->length) {
    return 1;
  }
  memcpy(host->bytes + host->length, bytes, length);
  host->length += length;
  return 0;
}

static int storage_sync(void *context) {
  memory_host *host = context;

  host->syncs += 1u;
  return 0;
}

static int storage_close(void *context) {
  memory_host *host = context;

  host->closes += 1u;
  return 0;
}

static bool response_is(const store_buffer *response) {
  return response->length == sizeof(response_record) &&
         memcmp(response->data, response_record, sizeof(response_record)) == 0;
}

int main(int argc, char **argv) {
  memory_host storage = {.bytes = {'O', 'L', 'D', '!', 'x'}, .length = 5u};
  memory_host image = {.bytes = {'I', 'M', 'G'}, .length = 3u};
  store_host_v1 host = {
      .abi_version = BEAGLE_STORE_ABI_VERSION,
      .struct_size = (uint32_t)sizeof(host),
      .allocation_context = &storage,
      .clock_context = &storage,
      .storage_context = &storage,
      .snapshot_storage_context = &image,
      .allocate = host_allocate,
      .deallocate = host_deallocate,
      .clock_milliseconds = host_clock,
      .storage_size = storage_size,
      .storage_read = storage_read,
      .storage_truncate = storage_truncate,
      .storage_append = storage_append,
      .storage_sync = storage_sync,
      .storage_close = storage_close,
  };
  store_open_options_v1 options = {
      .abi_version = BEAGLE_STORE_ABI_VERSION,
      .struct_size = (uint32_t)sizeof(options),
      .space_id = "smoke-space",
      .log_path = argc == 2 ? argv[1] : NULL,
      .host = &host,
  };
  store_slice request = {request_record, sizeof(request_record)};
  store_database *database = NULL;
  store_buffer response = {0};
  store_error error;

  if (argc != 2 || store_abi_version() != BEAGLE_STORE_ABI_VERSION ||
      store_open(&options, &database, &error) != BEAGLE_STORE_OK || database == NULL ||
      error.code != BEAGLE_STORE_OK || storage.length != 8u ||
      memcmp(storage.bytes, "OLD!BOOT", 8u) != 0) {
    return 1;
  }
  if (store_transact(database, request, &response, &error) != BEAGLE_STORE_OK ||
      !response_is(&response)) {
    return 2;
  }
  store_buffer_release(&response);
  if (store_query(database, request, &response, &error) != BEAGLE_STORE_OK ||
      !response_is(&response)) {
    return 3;
  }
  store_buffer_release(&response);
  if (store_snapshot(database, request, &response, &error) != BEAGLE_STORE_OK ||
      !response_is(&response)) {
    return 4;
  }
  if (store_close(database, &error) != BEAGLE_STORE_OK || storage.closes != 1u ||
      storage.syncs != 5u || storage.length != 20u ||
      memcmp(storage.bytes, "OLD!BOOTTAILTAILTAIL", 20u) != 0) {
    return 5;
  }
  if (image.closes != 1u || image.syncs != 3u || image.length != 4u ||
      memcmp(image.bytes, "IMG2", 4u) != 0) {
    return 7;
  }
  store_buffer_release(&response);
  if (storage.allocations != 4u || storage.deallocations != 4u) {
    return 6;
  }
  return 0;
}
C

cat >"$scratch/host_client.c" <<'C'
#define _POSIX_C_SOURCE 200809L

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static const uint8_t request_record[] = {
    0x46, 0x52, 0x41, 0x4d, 0x52, 0x50, 0x43, 0x00, 0x01, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x03, 0x00, 0x00, 0x00, 0x07, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xaa, 0xbb, 0xcc};

static const uint8_t response_record[] = {
    0x46, 0x52, 0x41, 0x4d, 0x52, 0x50, 0x43, 0x00, 0x01, 0x00,
    0x00, 0x00, 0x02, 0x00, 0x02, 0x00, 0x00, 0x00, 0x07, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xdd, 0xee};

static bool parse_port(const char *text, uint16_t *port_out) {
  char *end = NULL;
  long value;

  errno = 0;
  value = strtol(text, &end, 10);
  if (errno != 0 || end == text || *end != '\0' || value < 1 ||
      value > 65535) {
    return false;
  }
  *port_out = (uint16_t)value;
  return true;
}

static bool write_all(int fd, const uint8_t *bytes, size_t length) {
  size_t position = 0u;

  while (position < length) {
    ssize_t count = write(fd, bytes + position, length - position);
    if (count > 0) {
      position += (size_t)count;
    } else if (count < 0 && errno == EINTR) {
      continue;
    } else {
      return false;
    }
  }
  return true;
}

static bool read_all(int fd, uint8_t *bytes, size_t length) {
  size_t position = 0u;

  while (position < length) {
    ssize_t count = read(fd, bytes + position, length - position);
    if (count > 0) {
      position += (size_t)count;
    } else if (count < 0 && errno == EINTR) {
      continue;
    } else {
      return false;
    }
  }
  return true;
}

static int free_port(void) {
  struct sockaddr_in address;
  socklen_t address_length = sizeof(address);
  int fd = socket(AF_INET, SOCK_STREAM, 0);

  if (fd < 0) {
    return 1;
  }
  memset(&address, 0, sizeof(address));
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_ANY);
  address.sin_port = 0;
  if (bind(fd, (const struct sockaddr *)&address, sizeof(address)) != 0 ||
      getsockname(fd, (struct sockaddr *)&address, &address_length) != 0 ||
      close(fd) != 0) {
    return 2;
  }
  printf("%u\n", (unsigned int)ntohs(address.sin_port));
  return 0;
}

static int connect_retry(const char *address_text, uint16_t port) {
  struct sockaddr_in address;
  struct timespec delay = {.tv_sec = 0, .tv_nsec = 20000000L};
  unsigned int attempt;

  memset(&address, 0, sizeof(address));
  address.sin_family = AF_INET;
  address.sin_port = htons(port);
  if (inet_pton(AF_INET, address_text, &address.sin_addr) != 1) {
    return -1;
  }
  for (attempt = 0u; attempt < 100u; attempt += 1u) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);

    if (fd < 0) {
      return -1;
    }
    if (connect(fd, (const struct sockaddr *)&address, sizeof(address)) == 0) {
      return fd;
    }
    (void)close(fd);
    (void)nanosleep(&delay, NULL);
  }
  return -1;
}

static int malformed_or_stall(const char *address, uint16_t port, bool stall) {
  struct timespec hold = {.tv_sec = 5, .tv_nsec = 0};
  uint8_t unexpected;
  int fd = connect_retry(address, port);
  ssize_t count;

  if (fd < 0 || !write_all(fd, request_record, 3u)) {
    return 3;
  }
  if (stall) {
    puts("READY");
    if (fflush(stdout) != 0) {
      return 4;
    }
    (void)nanosleep(&hold, NULL);
  }
  if (shutdown(fd, SHUT_WR) != 0) {
    return 5;
  }
  do {
    count = read(fd, &unexpected, sizeof(unexpected));
  } while (count < 0 && errno == EINTR);
  (void)close(fd);
  return count == 0 ? 0 : 6;
}

static int valid(const char *address, uint16_t port) {
  uint8_t received[sizeof(response_record)];
  uint8_t extra;
  int fd = connect_retry(address, port);
  ssize_t count;

  if (fd < 0 || !write_all(fd, request_record, sizeof(request_record)) ||
      shutdown(fd, SHUT_WR) != 0 ||
      !read_all(fd, received, sizeof(received)) ||
      memcmp(received, response_record, sizeof(received)) != 0) {
    return 7;
  }
  do {
    count = read(fd, &extra, sizeof(extra));
  } while (count < 0 && errno == EINTR);
  (void)close(fd);
  return count == 0 ? 0 : 8;
}

int main(int argc, char **argv) {
  uint16_t port;

  if (argc == 2 && strcmp(argv[1], "free-port") == 0) {
    return free_port();
  }
  if (argc != 4 || !parse_port(argv[3], &port)) {
    return 9;
  }
  (void)alarm(10u);
  if (strcmp(argv[1], "malformed") == 0) {
    return malformed_or_stall(argv[2], port, false);
  }
  if (strcmp(argv[1], "stall") == 0) {
    return malformed_or_stall(argv[2], port, true);
  }
  if (strcmp(argv[1], "valid") == 0) {
    return valid(argv[2], port);
  }
  return 10;
}
C

common_flags=(-std=c17 -pedantic -Wall -Wextra -Werror -pthread \
  -I "$scratch" -I "$repo/native")
"$cc" "${common_flags[@]}" -c "$repo/native/server_generated.c" \
  -o "$scratch/adapter.o"

nm -u "$scratch/adapter.o" \
  | awk '{print $NF}' \
  | sed -n '/^store_stub_/p' \
  | sort >"$scratch/actual-exports"
cat >"$scratch/expected-exports" <<'EXPORTS'
store_stub_codec_read_request
store_stub_codec_release_request
store_stub_codec_release_response
store_stub_codec_write_response
store_stub_generated_abi
store_stub_store_boot
store_stub_store_dispatch
store_stub_store_shutdown
EXPORTS
cmp "$scratch/expected-exports" "$scratch/actual-exports"

"$cc" "${common_flags[@]}" "$scratch/adapter.o" \
  "$scratch/native_shim.c" "$scratch/generated_stub.c" "$scratch/main.c" \
  -o "$scratch/smoke"
printf 'OLD!x' >"$scratch/store.log"
printf 'IMG' >"$scratch/store.log.snapshot"
"$scratch/smoke" "$scratch/store.log"

"$cc" "${common_flags[@]}" "$repo/native/store_embed.c" \
  "$scratch/adapter.o" "$scratch/native_shim.c" \
  "$scratch/generated_stub.c" "$scratch/embed_main.c" \
  -o "$scratch/embed-smoke"
"$scratch/embed-smoke" "$scratch/store.log"

"$cc" "${common_flags[@]}" "$repo/native/server_host.c" \
  "$scratch/adapter.o" "$scratch/native_shim.c" \
  "$scratch/generated_stub.c" -o "$scratch/host-smoke"
"$cc" "${common_flags[@]}" "$scratch/host_client.c" \
  -o "$scratch/host-client"

stop_host() {
  local error_log="$1"

  if ! kill -0 "$host_pid" 2>/dev/null; then
    echo "store native generated adapter smoke: host exited early" >&2
    cat "$error_log" >&2
    return 1
  fi
  kill -TERM "$host_pid"
  if ! wait "$host_pid"; then
    echo "store native generated adapter smoke: host shutdown failed" >&2
    cat "$error_log" >&2
    host_pid=""
    return 1
  fi
  host_pid=""
}

printf 'OLD!x' >"$scratch/store.log"
printf 'IMG' >"$scratch/store.log.snapshot"
any_port="$("$scratch/host-client" free-port)"
(
  unset BEAGLE_STORE_BIND BEAGLE_STORE_SERVER_ROLE BEAGLE_STORE_LISTEN_FD BEAGLE_STORE_LOG BEAGLE_STORE_SERVER_PORT \
    BEAGLE_STORE_SPACE_ID BEAGLE_STORE_TLS_KEYSTORE BEAGLE_STORE_TLS_PASS BEAGLE_STORE_TLS_PASS_FILE \
    BEAGLE_STORE_TLS_TRUSTSTORE
  export BEAGLE_STORE_BIND=0.0.0.0
  exec "$scratch/host-smoke" serve "$any_port" "$scratch/store.log" \
    smoke-space
) >"$scratch/any.out" 2>"$scratch/any.err" &
host_pid=$!

"$scratch/host-client" stall 127.0.0.1 "$any_port" \
  >"$scratch/stall.ready" &
stall_pid=$!
for _ in {1..100}; do
  [[ -s "$scratch/stall.ready" ]] && break
  kill -0 "$stall_pid" 2>/dev/null || break
  sleep 0.02
done
if [[ ! -s "$scratch/stall.ready" ]]; then
  echo "store native generated adapter smoke: stalled client did not connect" >&2
  cat "$scratch/any.err" >&2
  exit 1
fi
"$scratch/host-client" valid 127.0.0.2 "$any_port" || {
  cat "$scratch/any.err" >&2
  exit 1
}
if kill -0 "$stall_pid" 2>/dev/null; then
  kill -TERM "$stall_pid"
fi
wait "$stall_pid" 2>/dev/null || true
stall_pid=""
for _ in {1..100}; do
  grep -Fq 'generated request record ended inside its header' \
    "$scratch/any.err" && break
  sleep 0.02
done
grep -Fq 'generated request record ended inside its header' "$scratch/any.err"
"$scratch/host-client" valid 127.0.0.2 "$any_port" || {
  cat "$scratch/any.err" >&2
  exit 1
}
stop_host "$scratch/any.err"
grep -Fq "listening on 0.0.0.0:$any_port" "$scratch/any.err"
printf 'OLD!BOOTTAILTAIL' >"$scratch/any.expected"
cmp "$scratch/any.expected" "$scratch/store.log"
printf 'IMG2' >"$scratch/any.image.expected"
cmp "$scratch/any.image.expected" "$scratch/store.log.snapshot"

printf 'OLD!x' >"$scratch/store.log"
printf 'IMG' >"$scratch/store.log.snapshot"
loopback_port="$("$scratch/host-client" free-port)"
(
  unset BEAGLE_STORE_BIND BEAGLE_STORE_SERVER_ROLE BEAGLE_STORE_LISTEN_FD BEAGLE_STORE_LOG BEAGLE_STORE_SERVER_PORT \
    BEAGLE_STORE_SPACE_ID BEAGLE_STORE_TLS_KEYSTORE BEAGLE_STORE_TLS_PASS BEAGLE_STORE_TLS_PASS_FILE \
    BEAGLE_STORE_TLS_TRUSTSTORE
  exec "$scratch/host-smoke" serve "$loopback_port" "$scratch/store.log" \
    smoke-space
) >"$scratch/loopback.out" 2>"$scratch/loopback.err" &
host_pid=$!
"$scratch/host-client" valid 127.0.0.1 "$loopback_port" || {
  cat "$scratch/loopback.err" >&2
  exit 1
}
stop_host "$scratch/loopback.err"
grep -Fq "listening on 127.0.0.1:$loopback_port" \
  "$scratch/loopback.err"
printf 'OLD!BOOTTAIL' >"$scratch/loopback.expected"
cmp "$scratch/loopback.expected" "$scratch/store.log"

invalid_port="$("$scratch/host-client" free-port)"
if (
  unset BEAGLE_STORE_BIND BEAGLE_STORE_SERVER_ROLE BEAGLE_STORE_LISTEN_FD BEAGLE_STORE_LOG BEAGLE_STORE_SERVER_PORT \
    BEAGLE_STORE_SPACE_ID BEAGLE_STORE_TLS_KEYSTORE BEAGLE_STORE_TLS_PASS BEAGLE_STORE_TLS_PASS_FILE \
    BEAGLE_STORE_TLS_TRUSTSTORE
  export BEAGLE_STORE_BIND=192.0.2.1
  exec "$scratch/host-smoke" serve "$invalid_port" "$scratch/invalid.log" \
    smoke-space
) >"$scratch/invalid.out" 2>"$scratch/invalid.err"; then
  echo "store native generated adapter smoke: invalid bind was accepted" >&2
  exit 1
fi
grep -Fq \
  'BEAGLE_STORE_BIND=192.0.2.1 is unsupported; expected loopback, 127.0.0.1, or 0.0.0.0' \
  "$scratch/invalid.err"

echo "store native generated adapter smoke: PASS"
