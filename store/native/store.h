// SPDX-License-Identifier: MIT OR Apache-2.0
#ifndef BEAGLE_STORE_H
#define BEAGLE_STORE_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32) && defined(BEAGLE_STORE_SHARED)
#if defined(BEAGLE_STORE_BUILDING_SHARED)
#define BEAGLE_STORE_API __declspec(dllexport)
#else
#define BEAGLE_STORE_API __declspec(dllimport)
#endif
#elif defined(__GNUC__) || defined(__clang__)
#define BEAGLE_STORE_API __attribute__((visibility("default")))
#else
#define BEAGLE_STORE_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define BEAGLE_STORE_ABI_VERSION 1u
#define BEAGLE_STORE_ERROR_MESSAGE_CAPACITY 512u

typedef struct store_database store_database;

typedef enum store_status {
  BEAGLE_STORE_OK = 0,
  BEAGLE_STORE_INVALID_ARGUMENT = 1,
  BEAGLE_STORE_CLIENT_ERROR = 2,
  BEAGLE_STORE_ENGINE_ERROR = 3,
  BEAGLE_STORE_HOST_ERROR = 4,
  BEAGLE_STORE_OUT_OF_MEMORY = 5
} store_status;

typedef struct store_slice {
  const uint8_t *data;
  size_t length;
} store_slice;

typedef void *(*store_allocate_fn)(void *context, size_t size);
typedef void (*store_deallocate_fn)(void *context, void *allocation);

typedef struct store_buffer {
  uint8_t *data;
  size_t length;
  void *release_context;
  store_deallocate_fn release;
} store_buffer;

/* A direct compile request is the immutable compiler query identity and its
 * canonical ordered query-fact closure. The digest is the raw SHA-256 bytes;
 * Store revalidates the closure before it is read or persisted. */
typedef struct store_compile_request {
  uint8_t query_digest[32];
  store_slice query_facts;
} store_compile_request;

typedef enum store_compile_outcome {
  BEAGLE_STORE_COMPILE_COLD = 0,
  BEAGLE_STORE_COMPILE_FOUND = 1,
  BEAGLE_STORE_COMPILE_APPENDED = 2,
  BEAGLE_STORE_COMPILE_RETAINED = 3
} store_compile_outcome;

typedef struct store_error {
  int32_t code;
  char message[BEAGLE_STORE_ERROR_MESSAGE_CAPACITY];
} store_error;

/*
 * Host callbacks return zero on success and nonzero on failure. A custom
 * storage context must already own exclusive writer authority for its entire
 * open-to-close lifetime.
 */
typedef int (*store_clock_milliseconds_fn)(void *context,
                                          int64_t *milliseconds_out);
typedef int (*store_storage_size_fn)(void *context, uint64_t *size_out);
typedef int (*store_storage_read_fn)(void *context, uint64_t offset,
                                    uint8_t *destination, size_t length);
typedef int (*store_storage_truncate_fn)(void *context, uint64_t length);
typedef int (*store_storage_append_fn)(void *context, const uint8_t *bytes,
                                      size_t length);
typedef int (*store_storage_sync_fn)(void *context);
typedef int (*store_storage_close_fn)(void *context);

/* snapshot_storage_context names a SECOND storage object served by the same
   seven storage callbacks; NULL means this host offers no snapshot image. */
typedef struct store_host_v1 {
  uint32_t abi_version;
  uint32_t struct_size;
  void *allocation_context;
  void *clock_context;
  void *storage_context;
  void *snapshot_storage_context;
  store_allocate_fn allocate;
  store_deallocate_fn deallocate;
  store_clock_milliseconds_fn clock_milliseconds;
  store_storage_size_fn storage_size;
  store_storage_read_fn storage_read;
  store_storage_truncate_fn storage_truncate;
  store_storage_append_fn storage_append;
  store_storage_sync_fn storage_sync;
  store_storage_close_fn storage_close;
} store_host_v1;

/* memory_budget_bytes of zero leaves every engine memory limit at its default. */
typedef struct store_open_options_v1 {
  uint32_t abi_version;
  uint32_t struct_size;
  const char *space_id;
  const char *log_path;
  const store_host_v1 *host;
  uint64_t memory_budget_bytes;
} store_open_options_v1;

BEAGLE_STORE_API uint32_t store_abi_version(void);

/*
 * With HOST == NULL, LOG_PATH is opened as the canonical local Store
 * transaction log; Beagle Store supplies libc allocation, realtime clock, and
 * POSIX durability. With a host, every callback is required; LOG_PATH is then
 * only a stable diagnostic label. A successful open transfers storage-close
 * responsibility to Beagle Store. Allocation context must remain valid until
 * every returned buffer is freed.
 * A wasi build cannot flock, so there the embedder owns Store transaction log
 * exclusivity.
 */
BEAGLE_STORE_API store_status store_open(const store_open_options_v1 *options,
                               store_database **database_out,
                               store_error *error);

/*
 * Each call consumes exactly one canonical Store RPC v2 request packet and
 * returns exactly one canonical Store RPC v2 response packet. The three entry
 * points name host intent; the typed Beagle Store dispatcher remains the sole
 * authority for operation validity and returns protocol errors in RESPONSE.
 */
BEAGLE_STORE_API store_status store_transact(store_database *database,
                                   store_slice request,
                                   store_buffer *response,
                                   store_error *error);
BEAGLE_STORE_API store_status store_query(store_database *database, store_slice request,
                                store_buffer *response, store_error *error);
BEAGLE_STORE_API store_status store_snapshot(store_database *database,
                                   store_slice request,
                                   store_buffer *response,
                                   store_error *error);
/* rpc/checkpoint writes the image to the snapshot storage object and answers
   with its sequence, watermark, stamp, fingerprint, and byte count. */

/* Direct compile operations do not construct Store RPC packets. Query writes
 * an owned canonical result-fact closure to RESULT_FACTS; append accepts one.
 * Both revalidate REQUEST's digest and query-fact closure. */
BEAGLE_STORE_API store_status store_compile_query(
    store_database *database, const store_compile_request *request,
    store_buffer *result_facts, store_compile_outcome *outcome,
    store_error *error);
BEAGLE_STORE_API store_status store_compile_append(
    store_database *database, const store_compile_request *request,
    store_slice result_facts, store_compile_outcome *outcome,
    store_error *error);

/* BUFFER remains owned until this function; it may outlive DATABASE. */
BEAGLE_STORE_API void store_buffer_release(store_buffer *buffer);

/* CLOSE always consumes DATABASE, including when durability close fails. */
BEAGLE_STORE_API store_status store_close(store_database *database, store_error *error);

#if defined(BEAGLE_STORE_WASM_HOST_IMPORTS)
/*
 * This build has no POSIX storage: HOST == NULL selects nine named imports of
 * wasm module "store_host_v1", one per store_host_v1 callback, each named for
 * its field and typed by the wasm32 lowering of the prototype above. The
 * import host passes storage context 0 for the Store transaction log and 1 for
 * the snapshot image, so both objects ride those same nine imports. LOG_PATH
 * is then a diagnostic label, host contexts are 0, and the embedder owns Store
 * transaction log exclusivity. An import reports failure by returning nonzero;
 * a trapping import unwinds the guest uncleaned, so a trap is instance-fatal.
 * A response buffer is released only by store_buffer_release, its release field
 * being a guest table index. store_wasm_alloc/store_wasm_free stage embedder
 * requests, options, and error structs; they never free a response. The module
 * still imports wasi_snapshot_preview1 clock_time_get (the engine's monotonic
 * clock) and environ_sizes_get/environ_get, which an embedder answers with an
 * empty environment; native/wasm-embed.seams pins the whole seam.
 */
BEAGLE_STORE_API void *store_wasm_alloc(size_t size);
BEAGLE_STORE_API void store_wasm_free(void *allocation);

/* The import-backed vtable, internal to this build and never exported. */
const store_host_v1 *store_wasm_host_v1(void);
#endif

#ifdef __cplusplus
}
#endif

#endif
