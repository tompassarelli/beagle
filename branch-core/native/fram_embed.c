// SPDX-License-Identifier: MIT OR Apache-2.0
#define _POSIX_C_SOURCE 200809L

#include "fram.h"
#include "native_shim.h"
#include "server_host.h"

#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* One seam per storage object: the adapter passes a seam back as its context,
   so the same seven embedder callbacks serve the log and the image. */
typedef struct storage_seam {
  struct fram_database *database;
  void *context;
} storage_seam;

struct fram_database {
  fram_server_store *store;
  fram_host_v1 host;
  pthread_mutex_t mutex;
  storage_seam log_seam;
  storage_seam snapshot_seam;
};

static void clear_error(fram_error *error) {
  if (error != NULL) {
    error->code = (int32_t)FRAM_OK;
    error->message[0] = '\0';
  }
}

static void set_error(fram_error *error, fram_status status,
                      const char *message) {
  size_t length;
  size_t copied;

  if (error == NULL) {
    return;
  }
  error->code = (int32_t)status;
  length = strlen(message);
  copied = length < sizeof(error->message) - 1u
               ? length
               : sizeof(error->message) - 1u;
  if (copied != 0u) {
    memcpy(error->message, message, copied);
  }
  error->message[copied] = '\0';
}

static void set_internal_error(char *error, size_t capacity,
                               const char *message) {
  size_t length;
  size_t copied;

  if (error == NULL || capacity == 0u) {
    return;
  }
  length = strlen(message);
  copied = length < capacity - 1u ? length : capacity - 1u;
  if (copied != 0u) {
    memcpy(error, message, copied);
  }
  error[copied] = '\0';
}

static fram_status public_status(int status) {
  switch (status) {
  case FRAM_SERVER_OK:
    return FRAM_OK;
  case FRAM_SERVER_CLIENT_ERROR:
    return FRAM_CLIENT_ERROR;
  case FRAM_SERVER_HOST_ERROR:
    return FRAM_HOST_ERROR;
  case FRAM_SERVER_OUT_OF_MEMORY:
    return FRAM_OUT_OF_MEMORY;
  default:
    return FRAM_ENGINE_ERROR;
  }
}

static fram_status trap_public_status(uint32_t code) {
  switch (code) {
  case NATIVE_TRAP_ARENA_EXHAUSTED:
    return FRAM_OUT_OF_MEMORY;
  case NATIVE_TRAP_IO:
    return FRAM_HOST_ERROR;
  default:
    return FRAM_ENGINE_ERROR;
  }
}

/* Formats into a buffer and writes the fd directly: a stdio stream would ask
   the wasm host for fd_fdstat_get, a capability the seam ledger does not pin. */
static void report_trap(uint32_t code) {
  char line[96];
  int length = snprintf(line, sizeof(line),
                        "fram: engine trap code=%lu status=%d\n",
                        (unsigned long)code, (int)trap_public_status(code));

  if (length > 0) {
    (void)!write(2, line, (size_t)length < sizeof(line) ? (size_t)length
                                                        : sizeof(line) - 1u);
  }
}

static fram_status fail_from_server(int status, const char *detail,
                                    fram_error *error) {
  fram_status result = public_status(status);

  set_error(error, result,
            detail != NULL && detail[0] != '\0'
                ? detail
                : "native Fram operation failed without detail");
  return result;
}

static void *libc_allocate(void *context, size_t size) {
  (void)context;
  return malloc(size);
}

static void libc_deallocate(void *context, void *allocation) {
  (void)context;
  free(allocation);
}

static bool valid_host(const fram_host_v1 *host) {
  return host != NULL && host->abi_version == FRAM_ABI_VERSION &&
         host->struct_size >= (uint32_t)sizeof(*host) &&
         host->allocate != NULL && host->deallocate != NULL &&
         host->clock_milliseconds != NULL && host->storage_size != NULL &&
         host->storage_read != NULL && host->storage_truncate != NULL &&
         host->storage_append != NULL && host->storage_sync != NULL &&
         host->storage_close != NULL;
}

static int embedded_clock(void *context, int64_t *milliseconds_out,
                          char *error, size_t error_capacity) {
  storage_seam *seam = context;
  fram_database *database = seam->database;

  if (database->host.clock_milliseconds(database->host.clock_context,
                                         milliseconds_out) != 0 ||
      *milliseconds_out < INT64_C(0)) {
    set_internal_error(error, error_capacity,
                       "embedded host clock failed");
    return FRAM_SERVER_HOST_ERROR;
  }
  return FRAM_SERVER_OK;
}

static int embedded_storage_size(void *context, uint64_t *size_out,
                                 char *error, size_t error_capacity) {
  storage_seam *seam = context;

  if (seam->database->host.storage_size(seam->context, size_out) != 0) {
    set_internal_error(error, error_capacity,
                       "embedded host storage-size failed");
    return FRAM_SERVER_HOST_ERROR;
  }
  return FRAM_SERVER_OK;
}

static int embedded_storage_read(void *context, uint64_t offset,
                                 uint8_t *destination, size_t length,
                                 char *error, size_t error_capacity) {
  storage_seam *seam = context;

  if (length != 0u &&
      seam->database->host.storage_read(seam->context, offset, destination,
                                        length) != 0) {
    set_internal_error(error, error_capacity,
                       "embedded host storage-read failed");
    return FRAM_SERVER_HOST_ERROR;
  }
  return FRAM_SERVER_OK;
}

static int embedded_storage_truncate(void *context, uint64_t length,
                                     char *error, size_t error_capacity) {
  storage_seam *seam = context;

  if (seam->database->host.storage_truncate(seam->context, length) != 0) {
    set_internal_error(error, error_capacity,
                       "embedded host storage-truncate failed");
    return FRAM_SERVER_HOST_ERROR;
  }
  return FRAM_SERVER_OK;
}

static int embedded_storage_append(void *context, const uint8_t *bytes,
                                   size_t length, char *error,
                                   size_t error_capacity) {
  storage_seam *seam = context;

  if (length != 0u &&
      seam->database->host.storage_append(seam->context, bytes, length) != 0) {
    set_internal_error(error, error_capacity,
                       "embedded host storage-append failed");
    return FRAM_SERVER_HOST_ERROR;
  }
  return FRAM_SERVER_OK;
}

static int embedded_storage_sync(void *context, char *error,
                                 size_t error_capacity) {
  storage_seam *seam = context;

  if (seam->database->host.storage_sync(seam->context) != 0) {
    set_internal_error(error, error_capacity,
                       "embedded host storage-sync failed");
    return FRAM_SERVER_HOST_ERROR;
  }
  return FRAM_SERVER_OK;
}

static int embedded_storage_close(void *context, char *error,
                                  size_t error_capacity) {
  storage_seam *seam = context;

  if (seam->database->host.storage_close(seam->context) != 0) {
    set_internal_error(error, error_capacity,
                       "embedded host storage-close failed");
    return FRAM_SERVER_HOST_ERROR;
  }
  return FRAM_SERVER_OK;
}

static fram_status call(fram_database *database, fram_slice request,
                        fram_buffer *response, fram_error *error) {
  fram_server_request *decoded = NULL;
  fram_server_response *dispatched = NULL;
  uint8_t *encoded = NULL;
  uint8_t *public_bytes = NULL;
  size_t encoded_length = 0u;
  char detail[FRAM_SERVER_ERROR_CAPACITY];
  int lock_status;
  int status;

  clear_error(error);
  if (response != NULL) {
    *response = (fram_buffer){0};
  }
  if (database == NULL || response == NULL ||
      (request.data == NULL && request.length != 0u)) {
    set_error(error, FRAM_INVALID_ARGUMENT,
              "Fram call requires a database, request bytes, and response owner");
    return FRAM_INVALID_ARGUMENT;
  }
  lock_status = pthread_mutex_lock(&database->mutex);
  if (lock_status != 0) {
    set_error(error, FRAM_ENGINE_ERROR,
              "cannot enter the embedded Fram database");
    return FRAM_ENGINE_ERROR;
  }
  status = fram_server_codec_decode_request(
      request.data, request.length, &decoded, detail, sizeof(detail));
  if (status == FRAM_SERVER_OK) {
    status = fram_server_store_dispatch(database->store, decoded, &dispatched,
                                        detail, sizeof(detail));
  }
  if (status == FRAM_SERVER_OK) {
    status = fram_server_codec_encode_response(
        dispatched, &encoded, &encoded_length, detail, sizeof(detail));
  }
  if (status == FRAM_SERVER_OK) {
    public_bytes = database->host.allocate(database->host.allocation_context,
                                           encoded_length);
    if (public_bytes == NULL) {
      set_internal_error(detail, sizeof(detail),
                         "embedded host could not allocate the response");
      status = FRAM_SERVER_OUT_OF_MEMORY;
    } else {
      memcpy(public_bytes, encoded, encoded_length);
    }
  }
  fram_server_codec_release_bytes(encoded);
  fram_server_codec_release_response(dispatched);
  fram_server_codec_release_request(decoded);
  (void)pthread_mutex_unlock(&database->mutex);
  if (status != FRAM_SERVER_OK) {
    if (public_bytes != NULL) {
      database->host.deallocate(database->host.allocation_context,
                                public_bytes);
    }
    return fail_from_server(status, detail, error);
  }
  response->data = public_bytes;
  response->length = encoded_length;
  response->release_context = database->host.allocation_context;
  response->release = database->host.deallocate;
  return FRAM_OK;
}

uint32_t fram_abi_version(void) { return FRAM_ABI_VERSION; }

fram_status fram_open(const fram_open_options_v1 *options,
                      fram_database **database_out, fram_error *error) {
  fram_database *database;
  fram_server_host_v1 server_host;
  fram_host_v1 allocation_host;
  const fram_host_v1 *host;
  char detail[FRAM_SERVER_ERROR_CAPACITY];
  const char *log_label;
  int status;

  clear_error(error);
  if (database_out != NULL) {
    *database_out = NULL;
  }
  if (options == NULL || database_out == NULL ||
      options->abi_version != FRAM_ABI_VERSION ||
      options->struct_size < (uint32_t)sizeof(*options) ||
      options->space_id == NULL || options->space_id[0] == '\0') {
    set_error(error, FRAM_INVALID_ARGUMENT,
              "Fram open options or host ABI are invalid");
    return FRAM_INVALID_ARGUMENT;
  }
  host = options->host;
#ifdef FRAM_WASM_HOST_IMPORTS
  /* No POSIX regime is compiled in to fall through to: the named imports are
     this build's only storage, clock, and allocation seam. */
  if (host == NULL) {
    host = fram_wasm_host_v1();
  }
#endif
  if ((host == NULL &&
       (options->log_path == NULL || options->log_path[0] == '\0')) ||
      (host != NULL && !valid_host(host))) {
    set_error(error, FRAM_INVALID_ARGUMENT,
              "Fram open options or host ABI are invalid");
    return FRAM_INVALID_ARGUMENT;
  }
  native_set_trap_reporter(report_trap);
  if (fram_server_generated_abi() != FRAM_SERVER_GENERATED_ABI) {
    set_error(error, FRAM_ENGINE_ERROR,
              "generated Fram engine ABI does not match the embedding host");
    return FRAM_ENGINE_ERROR;
  }
  if (host != NULL) {
    allocation_host = *host;
  } else {
    allocation_host = (fram_host_v1){
        .abi_version = FRAM_ABI_VERSION,
        .struct_size = (uint32_t)sizeof(allocation_host),
        .allocation_context = NULL,
        .clock_context = NULL,
        .storage_context = NULL,
        .allocate = libc_allocate,
        .deallocate = libc_deallocate,
    };
  }
  database = allocation_host.allocate(allocation_host.allocation_context,
                                      sizeof(*database));
  if (database == NULL) {
    set_error(error, FRAM_OUT_OF_MEMORY,
              "embedded host could not allocate the database handle");
    return FRAM_OUT_OF_MEMORY;
  }
  memset(database, 0, sizeof(*database));
  database->host = allocation_host;
  database->log_seam.database = database;
  database->log_seam.context = allocation_host.storage_context;
  database->snapshot_seam.database = database;
  database->snapshot_seam.context = allocation_host.snapshot_storage_context;
  if (pthread_mutex_init(&database->mutex, NULL) != 0) {
    allocation_host.deallocate(allocation_host.allocation_context, database);
    set_error(error, FRAM_ENGINE_ERROR,
              "cannot initialize the embedded Fram database mutex");
    return FRAM_ENGINE_ERROR;
  }
  log_label = options->log_path != NULL ? options->log_path : "embedded";
  // The wasm regime compiles the POSIX boot out, so its call site goes too.
#ifndef FRAM_WASM_HOST_IMPORTS
  if (host == NULL) {
    status = fram_server_store_boot(log_label, options->space_id,
                                    options->memory_budget_bytes,
                                    &database->store, detail, sizeof(detail));
  } else
#endif
  {
    server_host = (fram_server_host_v1){
        .abi_version = FRAM_SERVER_HOST_ABI,
        .struct_size = (uint32_t)sizeof(server_host),
        .context = &database->log_seam,
        .snapshot_context = allocation_host.snapshot_storage_context != NULL
                                ? &database->snapshot_seam
                                : NULL,
        .memory_budget_bytes = options->memory_budget_bytes,
        .clock_milliseconds = embedded_clock,
        .storage_size = embedded_storage_size,
        .storage_read = embedded_storage_read,
        .storage_truncate = embedded_storage_truncate,
        .storage_append = embedded_storage_append,
        .storage_sync = embedded_storage_sync,
        .storage_close = embedded_storage_close,
    };
    status = fram_server_store_boot_with_host(
        log_label, options->space_id, &server_host, &database->store, detail,
        sizeof(detail));
  }
  if (status != FRAM_SERVER_OK) {
    (void)pthread_mutex_destroy(&database->mutex);
    allocation_host.deallocate(allocation_host.allocation_context, database);
    return fail_from_server(status, detail, error);
  }
  *database_out = database;
  return FRAM_OK;
}

fram_status fram_transact(fram_database *database, fram_slice request,
                          fram_buffer *response, fram_error *error) {
  return call(database, request, response, error);
}

fram_status fram_query(fram_database *database, fram_slice request,
                       fram_buffer *response, fram_error *error) {
  return call(database, request, response, error);
}

fram_status fram_snapshot(fram_database *database, fram_slice request,
                          fram_buffer *response, fram_error *error) {
  return call(database, request, response, error);
}

void fram_buffer_release(fram_buffer *buffer) {
  void *context;
  fram_deallocate_fn release;
  uint8_t *data;

  if (buffer == NULL) {
    return;
  }
  context = buffer->release_context;
  release = buffer->release;
  data = buffer->data;
  *buffer = (fram_buffer){0};
  if (release != NULL && data != NULL) {
    release(context, data);
  }
}

fram_status fram_close(fram_database *database, fram_error *error) {
  fram_host_v1 host;
  char detail[FRAM_SERVER_ERROR_CAPACITY];
  int status;

  clear_error(error);
  if (database == NULL) {
    set_error(error, FRAM_INVALID_ARGUMENT,
              "Fram close requires a database handle");
    return FRAM_INVALID_ARGUMENT;
  }
  host = database->host;
  if (pthread_mutex_lock(&database->mutex) != 0) {
    set_error(error, FRAM_ENGINE_ERROR,
              "cannot close the embedded Fram database mutex");
    return FRAM_ENGINE_ERROR;
  }
  status = fram_server_store_shutdown(database->store, detail, sizeof(detail));
  database->store = NULL;
  (void)pthread_mutex_unlock(&database->mutex);
  (void)pthread_mutex_destroy(&database->mutex);
  host.deallocate(host.allocation_context, database);
  if (status != FRAM_SERVER_OK) {
    return fail_from_server(status, detail, error);
  }
  return FRAM_OK;
}
