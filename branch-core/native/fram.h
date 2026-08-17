// SPDX-License-Identifier: MIT OR Apache-2.0
#ifndef FRAM_H
#define FRAM_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32) && defined(FRAM_SHARED)
#if defined(FRAM_BUILDING_SHARED)
#define FRAM_API __declspec(dllexport)
#else
#define FRAM_API __declspec(dllimport)
#endif
#elif defined(__GNUC__) || defined(__clang__)
#define FRAM_API __attribute__((visibility("default")))
#else
#define FRAM_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define FRAM_ABI_VERSION 1u
#define FRAM_ERROR_MESSAGE_CAPACITY 512u

typedef struct fram_database fram_database;

typedef enum fram_status {
  FRAM_OK = 0,
  FRAM_INVALID_ARGUMENT = 1,
  FRAM_CLIENT_ERROR = 2,
  FRAM_ENGINE_ERROR = 3,
  FRAM_HOST_ERROR = 4,
  FRAM_OUT_OF_MEMORY = 5
} fram_status;

typedef struct fram_slice {
  const uint8_t *data;
  size_t length;
} fram_slice;

typedef void *(*fram_allocate_fn)(void *context, size_t size);
typedef void (*fram_deallocate_fn)(void *context, void *allocation);

typedef struct fram_buffer {
  uint8_t *data;
  size_t length;
  void *release_context;
  fram_deallocate_fn release;
} fram_buffer;

typedef struct fram_error {
  int32_t code;
  char message[FRAM_ERROR_MESSAGE_CAPACITY];
} fram_error;

/*
 * Host callbacks return zero on success and nonzero on failure. A custom
 * storage context must already own exclusive writer authority for its entire
 * open-to-close lifetime.
 */
typedef int (*fram_clock_milliseconds_fn)(void *context,
                                          int64_t *milliseconds_out);
typedef int (*fram_storage_size_fn)(void *context, uint64_t *size_out);
typedef int (*fram_storage_read_fn)(void *context, uint64_t offset,
                                    uint8_t *destination, size_t length);
typedef int (*fram_storage_truncate_fn)(void *context, uint64_t length);
typedef int (*fram_storage_append_fn)(void *context, const uint8_t *bytes,
                                      size_t length);
typedef int (*fram_storage_sync_fn)(void *context);
typedef int (*fram_storage_close_fn)(void *context);

/* snapshot_storage_context names a SECOND storage object served by the same
   seven storage callbacks; NULL means this host offers no snapshot image. */
typedef struct fram_host_v1 {
  uint32_t abi_version;
  uint32_t struct_size;
  void *allocation_context;
  void *clock_context;
  void *storage_context;
  void *snapshot_storage_context;
  fram_allocate_fn allocate;
  fram_deallocate_fn deallocate;
  fram_clock_milliseconds_fn clock_milliseconds;
  fram_storage_size_fn storage_size;
  fram_storage_read_fn storage_read;
  fram_storage_truncate_fn storage_truncate;
  fram_storage_append_fn storage_append;
  fram_storage_sync_fn storage_sync;
  fram_storage_close_fn storage_close;
} fram_host_v1;

/* memory_budget_bytes of zero leaves every engine memory limit at its default. */
typedef struct fram_open_options_v1 {
  uint32_t abi_version;
  uint32_t struct_size;
  const char *space_id;
  const char *log_path;
  const fram_host_v1 *host;
  uint64_t memory_budget_bytes;
} fram_open_options_v1;

FRAM_API uint32_t fram_abi_version(void);

/*
 * With HOST == NULL, LOG_PATH is opened as the canonical local FRAMLOG and
 * Fram supplies libc allocation, realtime clock, and POSIX durability. With a
 * host, every callback is required; LOG_PATH is then only a stable diagnostic
 * label. A successful open transfers storage-close responsibility to Fram.
 * Allocation context must remain valid until every returned buffer is freed.
 * A wasi build cannot flock, so there the embedder owns FRAMLOG exclusivity.
 */
FRAM_API fram_status fram_open(const fram_open_options_v1 *options,
                               fram_database **database_out,
                               fram_error *error);

/*
 * Each call consumes exactly one canonical FRAMRPC v2 request frame and
 * returns exactly one canonical FRAMRPC v2 response frame. The three entry
 * points name host intent; the typed Fram dispatcher remains the sole
 * authority for operation validity and returns protocol errors in RESPONSE.
 */
FRAM_API fram_status fram_transact(fram_database *database,
                                   fram_slice request,
                                   fram_buffer *response,
                                   fram_error *error);
FRAM_API fram_status fram_query(fram_database *database, fram_slice request,
                                fram_buffer *response, fram_error *error);
FRAM_API fram_status fram_snapshot(fram_database *database,
                                   fram_slice request,
                                   fram_buffer *response,
                                   fram_error *error);
/* rpc/checkpoint writes the image to the snapshot storage object and answers
   with its sequence, watermark, stamp, fingerprint, and byte count. */

/* BUFFER remains owned until this function; it may outlive DATABASE. */
FRAM_API void fram_buffer_release(fram_buffer *buffer);

/* CLOSE always consumes DATABASE, including when durability close fails. */
FRAM_API fram_status fram_close(fram_database *database, fram_error *error);

#if defined(FRAM_WASM_HOST_IMPORTS)
/*
 * This build has no POSIX storage: HOST == NULL selects nine named imports of
 * wasm module "fram_host_v1", one per fram_host_v1 callback, each named for
 * its field and typed by the wasm32 lowering of the prototype above. The
 * import host passes storage context 0 for the FRAMLOG and 1 for the snapshot
 * image, so both objects ride those same nine imports. LOG_PATH
 * is then a diagnostic label, host contexts are 0, and the embedder owns
 * FRAMLOG exclusivity. An import reports failure by returning nonzero; a
 * trapping import unwinds the guest uncleaned, so a trap is instance-fatal.
 * A response buffer is released only by fram_buffer_release, its release field
 * being a guest table index. fram_wasm_alloc/fram_wasm_free stage embedder
 * requests, options, and error structs; they never free a response. The module
 * still imports wasi_snapshot_preview1 clock_time_get (the engine's monotonic
 * clock) and environ_sizes_get/environ_get, which an embedder answers with an
 * empty environment; native/wasm-embed.seams pins the whole seam.
 */
FRAM_API void *fram_wasm_alloc(size_t size);
FRAM_API void fram_wasm_free(void *allocation);

/* The import-backed vtable, internal to this build and never exported. */
const fram_host_v1 *fram_wasm_host_v1(void);
#endif

#ifdef __cplusplus
}
#endif

#endif
