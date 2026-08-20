// SPDX-License-Identifier: MIT OR Apache-2.0
#ifndef BEAGLE_STORE_SERVER_HOST_H
#define BEAGLE_STORE_SERVER_HOST_H

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

#define BEAGLE_STORE_SERVER_GENERATED_ABI 4u
#define BEAGLE_STORE_SERVER_HOST_ABI 1u
#define BEAGLE_STORE_SERVER_ERROR_CAPACITY 512u

typedef struct store_server_store store_server_store;
typedef struct store_server_request store_server_request;
typedef struct store_server_response store_server_response;

enum store_server_status {
  BEAGLE_STORE_SERVER_OK = 0,
  BEAGLE_STORE_SERVER_PEER_CLOSED = 1,
  BEAGLE_STORE_SERVER_FATAL = 2,
  BEAGLE_STORE_SERVER_CLIENT_ERROR = 3,
  BEAGLE_STORE_SERVER_HOST_ERROR = 4,
  BEAGLE_STORE_SERVER_OUT_OF_MEMORY = 5
};

typedef struct store_server_compile_slice {
  const uint8_t *data;
  size_t length;
} store_server_compile_slice;

typedef void (*store_server_compile_release_fn)(void *context,
                                                void *allocation);

typedef struct store_server_compile_buffer {
  uint8_t *data;
  size_t length;
  void *release_context;
  store_server_compile_release_fn release;
} store_server_compile_buffer;

typedef struct store_server_compile_key {
  store_server_compile_slice source;
  store_server_compile_slice compiler;
  store_server_compile_slice profile;
  const store_server_compile_slice *targets;
  size_t target_count;
  store_server_compile_slice rules;
  store_server_compile_slice schema;
  store_server_compile_slice expected_query_digest;
} store_server_compile_key;

/* PAYLOAD owns one contiguous allocation backing itself and every slice. */
typedef struct store_server_compile_value {
  store_server_compile_slice target;
  store_server_compile_slice materializer;
  store_server_compile_slice status;
  store_server_compile_slice claimed_id;
  store_server_compile_buffer payload;
} store_server_compile_value;

typedef enum store_server_compile_outcome {
  BEAGLE_STORE_SERVER_COMPILE_COLD = 0,
  BEAGLE_STORE_SERVER_COMPILE_FOUND = 1,
  BEAGLE_STORE_SERVER_COMPILE_APPENDED = 2,
  BEAGLE_STORE_SERVER_COMPILE_RETAINED = 3
} store_server_compile_outcome;

typedef struct store_server_compile_query_result {
  int status;
  bool found;
  store_server_compile_outcome outcome;
} store_server_compile_query_result;

typedef int (*store_server_clock_fn)(void *context, int64_t *milliseconds_out,
                                    char *error, size_t error_capacity);
typedef int (*store_server_storage_size_fn)(void *context, uint64_t *size_out,
                                           char *error,
                                           size_t error_capacity);
typedef int (*store_server_storage_read_fn)(void *context, uint64_t offset,
                                           uint8_t *destination, size_t length,
                                           char *error,
                                           size_t error_capacity);
typedef int (*store_server_storage_truncate_fn)(void *context, uint64_t length,
                                               char *error,
                                               size_t error_capacity);
typedef int (*store_server_storage_append_fn)(void *context,
                                             const uint8_t *bytes,
                                             size_t length, char *error,
                                             size_t error_capacity);
typedef int (*store_server_storage_sync_fn)(void *context, char *error,
                                           size_t error_capacity);
typedef int (*store_server_storage_close_fn)(void *context, char *error,
                                            size_t error_capacity);

/* snapshot_context is the second storage object served by the SAME seven
   storage callbacks; NULL means this host offers no snapshot object.
   memory_budget_bytes of zero means the host named no budget. */
typedef struct store_server_host_v1 {
  uint32_t abi_version;
  uint32_t struct_size;
  void *context;
  void *snapshot_context;
  uint64_t memory_budget_bytes;
  store_server_clock_fn clock_milliseconds;
  store_server_storage_size_fn storage_size;
  store_server_storage_read_fn storage_read;
  store_server_storage_truncate_fn storage_truncate;
  store_server_storage_append_fn storage_append;
  store_server_storage_sync_fn storage_sync;
  store_server_storage_close_fn storage_close;
} store_server_host_v1;

/* The adapter verifies and invokes the ten generated-module hooks. */
uint32_t store_server_generated_abi(void);

/* SPACE_ID is NULL when the deployed flat-log service did not configure one.
   The snapshot image is opened beside the log as CANONICAL_LOG_PATH.snapshot. */
int store_server_store_boot(const char *canonical_log_path,
                           const char *space_id,
                           uint64_t memory_budget_bytes,
                           store_server_store **store_out, char *error,
                           size_t error_capacity);

int store_server_store_boot_with_host(const char *canonical_log_path,
                                     const char *space_id,
                                     const store_server_host_v1 *host,
                                     store_server_store **store_out,
                                     char *error, size_t error_capacity);

int store_server_store_dispatch(store_server_store *store,
                               const store_server_request *request,
                               store_server_response **response_out,
                               char *error, size_t error_capacity);

int store_server_compile_query(
    store_server_store *store, const store_server_compile_key *key,
    store_server_compile_value *value,
    store_server_compile_query_result *result, char *error,
    size_t error_capacity);

int store_server_compile_append(
    store_server_store *store, const store_server_compile_key *key,
    const store_server_compile_value *value,
    store_server_compile_query_result *result, char *error,
    size_t error_capacity);

void store_server_compile_value_release(store_server_compile_value *value);

int store_server_store_shutdown(store_server_store *store,
                               char *error, size_t error_capacity);

/* Compacts only when writes have accumulated since the last compaction, so a
   caller may offer every quiet moment without ever repeating the replay.
   COMPACTED_OUT (optional) reports whether this call did the work. */
int store_server_store_compact_idle(store_server_store *store,
                                   int *compacted_out, char *error,
                                   size_t error_capacity);

int store_server_codec_decode_request(const uint8_t *bytes, size_t length,
                                     store_server_request **request_out,
                                     char *error, size_t error_capacity);

int store_server_codec_encode_response(const store_server_response *response,
                                      uint8_t **bytes_out,
                                      size_t *length_out, char *error,
                                      size_t error_capacity);

void store_server_codec_release_bytes(uint8_t *bytes);

int store_server_codec_read_request(int client_fd,
                                   store_server_request **request_out,
                                   char *error, size_t error_capacity);

int store_server_codec_write_response(
    int client_fd,
    const store_server_response *response,
    char *error,
    size_t error_capacity);

void store_server_codec_release_request(store_server_request *request);
void store_server_codec_release_response(store_server_response *response);

#endif
