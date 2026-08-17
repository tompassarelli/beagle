// SPDX-License-Identifier: MIT OR Apache-2.0
#ifndef FRAM_SERVER_HOST_H
#define FRAM_SERVER_HOST_H

#include <stddef.h>
#include <stdint.h>

#define FRAM_SERVER_GENERATED_ABI 4u
#define FRAM_SERVER_HOST_ABI 1u
#define FRAM_SERVER_ERROR_CAPACITY 512u

typedef struct fram_server_store fram_server_store;
typedef struct fram_server_request fram_server_request;
typedef struct fram_server_response fram_server_response;

enum fram_server_status {
  FRAM_SERVER_OK = 0,
  FRAM_SERVER_PEER_CLOSED = 1,
  FRAM_SERVER_FATAL = 2,
  FRAM_SERVER_CLIENT_ERROR = 3,
  FRAM_SERVER_HOST_ERROR = 4,
  FRAM_SERVER_OUT_OF_MEMORY = 5
};

typedef int (*fram_server_clock_fn)(void *context, int64_t *milliseconds_out,
                                    char *error, size_t error_capacity);
typedef int (*fram_server_storage_size_fn)(void *context, uint64_t *size_out,
                                           char *error,
                                           size_t error_capacity);
typedef int (*fram_server_storage_read_fn)(void *context, uint64_t offset,
                                           uint8_t *destination, size_t length,
                                           char *error,
                                           size_t error_capacity);
typedef int (*fram_server_storage_truncate_fn)(void *context, uint64_t length,
                                               char *error,
                                               size_t error_capacity);
typedef int (*fram_server_storage_append_fn)(void *context,
                                             const uint8_t *bytes,
                                             size_t length, char *error,
                                             size_t error_capacity);
typedef int (*fram_server_storage_sync_fn)(void *context, char *error,
                                           size_t error_capacity);
typedef int (*fram_server_storage_close_fn)(void *context, char *error,
                                            size_t error_capacity);

/* snapshot_context is the second storage object served by the SAME seven
   storage callbacks; NULL means this host offers no snapshot object.
   memory_budget_bytes of zero means the host named no budget. */
typedef struct fram_server_host_v1 {
  uint32_t abi_version;
  uint32_t struct_size;
  void *context;
  void *snapshot_context;
  uint64_t memory_budget_bytes;
  fram_server_clock_fn clock_milliseconds;
  fram_server_storage_size_fn storage_size;
  fram_server_storage_read_fn storage_read;
  fram_server_storage_truncate_fn storage_truncate;
  fram_server_storage_append_fn storage_append;
  fram_server_storage_sync_fn storage_sync;
  fram_server_storage_close_fn storage_close;
} fram_server_host_v1;

/* The adapter verifies and invokes the eight generated-module hooks. */
uint32_t fram_server_generated_abi(void);

/* SPACE_ID is NULL when the deployed flat-log service did not configure one.
   The snapshot image is opened beside the log as CANONICAL_LOG_PATH.snapshot. */
int fram_server_store_boot(const char *canonical_log_path,
                           const char *space_id,
                           uint64_t memory_budget_bytes,
                           fram_server_store **store_out, char *error,
                           size_t error_capacity);

int fram_server_store_boot_with_host(const char *canonical_log_path,
                                     const char *space_id,
                                     const fram_server_host_v1 *host,
                                     fram_server_store **store_out,
                                     char *error, size_t error_capacity);

int fram_server_store_dispatch(fram_server_store *store,
                               const fram_server_request *request,
                               fram_server_response **response_out,
                               char *error, size_t error_capacity);

int fram_server_store_shutdown(fram_server_store *store,
                               char *error, size_t error_capacity);

/* Compacts only when writes have accumulated since the last compaction, so a
   caller may offer every quiet moment without ever repeating the replay.
   COMPACTED_OUT (optional) reports whether this call did the work. */
int fram_server_store_compact_idle(fram_server_store *store,
                                   int *compacted_out, char *error,
                                   size_t error_capacity);

int fram_server_codec_decode_request(const uint8_t *bytes, size_t length,
                                     fram_server_request **request_out,
                                     char *error, size_t error_capacity);

int fram_server_codec_encode_response(const fram_server_response *response,
                                      uint8_t **bytes_out,
                                      size_t *length_out, char *error,
                                      size_t error_capacity);

void fram_server_codec_release_bytes(uint8_t *bytes);

int fram_server_codec_read_request(int client_fd,
                                   fram_server_request **request_out,
                                   char *error, size_t error_capacity);

int fram_server_codec_write_response(
    int client_fd,
    const fram_server_response *response,
    char *error,
    size_t error_capacity);

void fram_server_codec_release_request(fram_server_request *request);
void fram_server_codec_release_response(fram_server_response *response);

#endif
