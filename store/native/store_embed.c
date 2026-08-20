// SPDX-License-Identifier: MIT OR Apache-2.0
#define _POSIX_C_SOURCE 200809L

#include "store.h"
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
  struct store_database *database;
  void *context;
} storage_seam;

struct store_database {
  store_server_store *store;
  store_host_v1 host;
  pthread_mutex_t mutex;
  storage_seam log_seam;
  storage_seam snapshot_seam;
};

static void clear_error(store_error *error) {
  if (error != NULL) {
    error->code = (int32_t)BEAGLE_STORE_OK;
    error->message[0] = '\0';
  }
}

static void set_error(store_error *error, store_status status,
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

static store_status public_status(int status) {
  switch (status) {
  case BEAGLE_STORE_SERVER_OK:
    return BEAGLE_STORE_OK;
  case BEAGLE_STORE_SERVER_CLIENT_ERROR:
    return BEAGLE_STORE_CLIENT_ERROR;
  case BEAGLE_STORE_SERVER_HOST_ERROR:
    return BEAGLE_STORE_HOST_ERROR;
  case BEAGLE_STORE_SERVER_OUT_OF_MEMORY:
    return BEAGLE_STORE_OUT_OF_MEMORY;
  default:
    return BEAGLE_STORE_ENGINE_ERROR;
  }
}

static store_status trap_public_status(uint32_t code) {
  switch (code) {
  case NATIVE_TRAP_ARENA_EXHAUSTED:
    return BEAGLE_STORE_OUT_OF_MEMORY;
  case NATIVE_TRAP_IO:
    return BEAGLE_STORE_HOST_ERROR;
  default:
    return BEAGLE_STORE_ENGINE_ERROR;
  }
}

/* Formats into a buffer and writes the fd directly: a stdio stream would ask
   the wasm host for fd_fdstat_get, a capability the seam ledger does not pin. */
static void report_trap(uint32_t code) {
  char line[96];
  int length = snprintf(line, sizeof(line),
                        "store: engine trap code=%lu status=%d\n",
                        (unsigned long)code, (int)trap_public_status(code));

  if (length > 0) {
    (void)!write(2, line, (size_t)length < sizeof(line) ? (size_t)length
                                                        : sizeof(line) - 1u);
  }
}

static store_status fail_from_server(int status, const char *detail,
                                    store_error *error) {
  store_status result = public_status(status);

  set_error(error, result,
            detail != NULL && detail[0] != '\0'
                ? detail
                : "native Beagle Store operation failed without detail");
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

static bool valid_host(const store_host_v1 *host) {
  return host != NULL && host->abi_version == BEAGLE_STORE_ABI_VERSION &&
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
  store_database *database = seam->database;

  if (database->host.clock_milliseconds(database->host.clock_context,
                                         milliseconds_out) != 0 ||
      *milliseconds_out < INT64_C(0)) {
    set_internal_error(error, error_capacity,
                       "embedded host clock failed");
    return BEAGLE_STORE_SERVER_HOST_ERROR;
  }
  return BEAGLE_STORE_SERVER_OK;
}

static int embedded_storage_size(void *context, uint64_t *size_out,
                                 char *error, size_t error_capacity) {
  storage_seam *seam = context;

  if (seam->database->host.storage_size(seam->context, size_out) != 0) {
    set_internal_error(error, error_capacity,
                       "embedded host storage-size failed");
    return BEAGLE_STORE_SERVER_HOST_ERROR;
  }
  return BEAGLE_STORE_SERVER_OK;
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
    return BEAGLE_STORE_SERVER_HOST_ERROR;
  }
  return BEAGLE_STORE_SERVER_OK;
}

static int embedded_storage_truncate(void *context, uint64_t length,
                                     char *error, size_t error_capacity) {
  storage_seam *seam = context;

  if (seam->database->host.storage_truncate(seam->context, length) != 0) {
    set_internal_error(error, error_capacity,
                       "embedded host storage-truncate failed");
    return BEAGLE_STORE_SERVER_HOST_ERROR;
  }
  return BEAGLE_STORE_SERVER_OK;
}

static int embedded_storage_append(void *context, const uint8_t *bytes,
                                   size_t length, char *error,
                                   size_t error_capacity) {
  storage_seam *seam = context;

  if (length != 0u &&
      seam->database->host.storage_append(seam->context, bytes, length) != 0) {
    set_internal_error(error, error_capacity,
                       "embedded host storage-append failed");
    return BEAGLE_STORE_SERVER_HOST_ERROR;
  }
  return BEAGLE_STORE_SERVER_OK;
}

static int embedded_storage_sync(void *context, char *error,
                                 size_t error_capacity) {
  storage_seam *seam = context;

  if (seam->database->host.storage_sync(seam->context) != 0) {
    set_internal_error(error, error_capacity,
                       "embedded host storage-sync failed");
    return BEAGLE_STORE_SERVER_HOST_ERROR;
  }
  return BEAGLE_STORE_SERVER_OK;
}

static int embedded_storage_close(void *context, char *error,
                                  size_t error_capacity) {
  storage_seam *seam = context;

  if (seam->database->host.storage_close(seam->context) != 0) {
    set_internal_error(error, error_capacity,
                       "embedded host storage-close failed");
    return BEAGLE_STORE_SERVER_HOST_ERROR;
  }
  return BEAGLE_STORE_SERVER_OK;
}

static store_status call(store_database *database, store_slice request,
                        store_buffer *response, store_error *error) {
  store_server_request *decoded = NULL;
  store_server_response *dispatched = NULL;
  uint8_t *encoded = NULL;
  uint8_t *public_bytes = NULL;
  size_t encoded_length = 0u;
  char detail[BEAGLE_STORE_SERVER_ERROR_CAPACITY];
  int lock_status;
  int status;

  clear_error(error);
  if (response != NULL) {
    *response = (store_buffer){0};
  }
  if (database == NULL || response == NULL ||
      (request.data == NULL && request.length != 0u)) {
    set_error(error, BEAGLE_STORE_INVALID_ARGUMENT,
              "Beagle Store call requires a database, request bytes, and response owner");
    return BEAGLE_STORE_INVALID_ARGUMENT;
  }
  lock_status = pthread_mutex_lock(&database->mutex);
  if (lock_status != 0) {
    set_error(error, BEAGLE_STORE_ENGINE_ERROR,
              "cannot enter the embedded Beagle Store database");
    return BEAGLE_STORE_ENGINE_ERROR;
  }
  status = store_server_codec_decode_request(
      request.data, request.length, &decoded, detail, sizeof(detail));
  if (status == BEAGLE_STORE_SERVER_OK) {
    status = store_server_store_dispatch(database->store, decoded, &dispatched,
                                        detail, sizeof(detail));
  }
  if (status == BEAGLE_STORE_SERVER_OK) {
    status = store_server_codec_encode_response(
        dispatched, &encoded, &encoded_length, detail, sizeof(detail));
  }
  if (status == BEAGLE_STORE_SERVER_OK) {
    public_bytes = database->host.allocate(database->host.allocation_context,
                                           encoded_length);
    if (public_bytes == NULL) {
      set_internal_error(detail, sizeof(detail),
                         "embedded host could not allocate the response");
      status = BEAGLE_STORE_SERVER_OUT_OF_MEMORY;
    } else {
      memcpy(public_bytes, encoded, encoded_length);
    }
  }
  store_server_codec_release_bytes(encoded);
  store_server_codec_release_response(dispatched);
  store_server_codec_release_request(decoded);
  (void)pthread_mutex_unlock(&database->mutex);
  if (status != BEAGLE_STORE_SERVER_OK) {
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
  return BEAGLE_STORE_OK;
}

static bool valid_slice(store_slice slice) {
  return slice.data != NULL || slice.length == 0u;
}

static bool valid_compile_key(const store_compile_key *key) {
  size_t index;

  if (key == NULL || !valid_slice(key->source) ||
      !valid_slice(key->compiler) || !valid_slice(key->profile) ||
      !valid_slice(key->rules) || !valid_slice(key->schema) ||
      !valid_slice(key->expected_query_digest) ||
      (key->targets == NULL && key->target_count != 0u)) {
    return false;
  }
  for (index = 0u; index < key->target_count; index += 1u) {
    if (!valid_slice(key->targets[index])) {
      return false;
    }
  }
  return true;
}

static bool valid_compile_value(const store_compile_value *value) {
  return value != NULL && valid_slice(value->target) &&
         valid_slice(value->materializer) && valid_slice(value->status) &&
         valid_slice(value->claimed_id) &&
         (value->payload.data != NULL || value->payload.length == 0u);
}

static store_server_compile_slice server_compile_slice(store_slice slice) {
  return (store_server_compile_slice){slice.data, slice.length};
}

static int add_compile_value_length(size_t *total, size_t length) {
  if (*total > SIZE_MAX - length) {
    return 0;
  }
  *total += length;
  return 1;
}

/* The generated adapter owns query values with libc allocation. Copy the
   whole value into the embedder's allocation regime before dropping it. */
static store_status copy_compile_value(
    store_database *database, store_compile_value *destination,
    const store_server_compile_value *source, store_error *error) {
  const uint8_t *sources[5] = {
      source->payload.data,
      source->target.data,
      source->materializer.data,
      source->status.data,
      source->claimed_id.data,
  };
  size_t lengths[5] = {
      source->payload.length,
      source->target.length,
      source->materializer.length,
      source->status.length,
      source->claimed_id.length,
  };
  uint8_t *allocation;
  size_t total = 0u;
  size_t offset = 0u;
  size_t index;

  for (index = 0u; index < 5u; index += 1u) {
    if ((sources[index] == NULL && lengths[index] != 0u) ||
        !add_compile_value_length(&total, lengths[index])) {
      set_error(error, BEAGLE_STORE_ENGINE_ERROR,
                "generated compiler value has an invalid representation");
      return BEAGLE_STORE_ENGINE_ERROR;
    }
  }
  allocation = database->host.allocate(database->host.allocation_context,
                                        total == 0u ? 1u : total);
  if (allocation == NULL) {
    set_error(error, BEAGLE_STORE_OUT_OF_MEMORY,
              "embedded host could not allocate a compiler value");
    return BEAGLE_STORE_OUT_OF_MEMORY;
  }
  for (index = 0u; index < 5u; index += 1u) {
    if (lengths[index] != 0u) {
      memcpy(allocation + offset, sources[index], lengths[index]);
    }
    if (index == 0u) {
      destination->payload.data = allocation + offset;
      destination->payload.length = lengths[index];
    } else {
      store_slice *slice = index == 1u   ? &destination->target
                           : index == 2u ? &destination->materializer
                           : index == 3u ? &destination->status
                                         : &destination->claimed_id;

      slice->data = allocation + offset;
      slice->length = lengths[index];
    }
    offset += lengths[index];
  }
  destination->payload.release_context = database->host.allocation_context;
  destination->payload.release = database->host.deallocate;
  return BEAGLE_STORE_OK;
}

static store_status compile_call(store_database *database,
                                 const store_compile_key *key,
                                 const store_compile_value *append_value,
                                 store_compile_value *query_value,
                                 store_compile_query_result *result,
                                 store_error *error) {
  store_server_compile_slice *targets = NULL;
  store_server_compile_key server_key;
  store_server_compile_value server_input;
  store_server_compile_value server_value = {0};
  store_server_compile_query_result server_result;
  char detail[BEAGLE_STORE_SERVER_ERROR_CAPACITY];
  store_status public_result = BEAGLE_STORE_OK;
  size_t target_bytes;
  size_t index;
  int lock_status;
  int status;

  clear_error(error);
  if (query_value != NULL) {
    *query_value = (store_compile_value){0};
  }
  if (result != NULL) {
    *result = (store_compile_query_result){
        .status = BEAGLE_STORE_INVALID_ARGUMENT,
        .found = false,
        .outcome = append_value == NULL ? BEAGLE_STORE_COMPILE_COLD
                                        : BEAGLE_STORE_COMPILE_RETAINED,
    };
  }
  if (database == NULL || result == NULL || !valid_compile_key(key) ||
      (append_value != NULL && !valid_compile_value(append_value)) ||
      (append_value == NULL && query_value == NULL) ||
      key->target_count > SIZE_MAX / sizeof(*targets)) {
    set_error(error, BEAGLE_STORE_INVALID_ARGUMENT,
              "compiler call requires a database, complete key, value owner, and valid text slices");
    return BEAGLE_STORE_INVALID_ARGUMENT;
  }
  target_bytes = key->target_count * sizeof(*targets);
  if (target_bytes != 0u) {
    targets = database->host.allocate(database->host.allocation_context,
                                      target_bytes);
    if (targets == NULL) {
      set_error(error, BEAGLE_STORE_OUT_OF_MEMORY,
                "embedded host could not allocate compiler targets");
      result->status = BEAGLE_STORE_OUT_OF_MEMORY;
      return BEAGLE_STORE_OUT_OF_MEMORY;
    }
  }
  for (index = 0u; index < key->target_count; index += 1u) {
    targets[index] = server_compile_slice(key->targets[index]);
  }
  server_key = (store_server_compile_key){
      .source = server_compile_slice(key->source),
      .compiler = server_compile_slice(key->compiler),
      .profile = server_compile_slice(key->profile),
      .targets = targets,
      .target_count = key->target_count,
      .rules = server_compile_slice(key->rules),
      .schema = server_compile_slice(key->schema),
      .expected_query_digest =
          server_compile_slice(key->expected_query_digest),
  };
  if (append_value != NULL) {
    server_input = (store_server_compile_value){
        .target = server_compile_slice(append_value->target),
        .materializer = server_compile_slice(append_value->materializer),
        .status = server_compile_slice(append_value->status),
        .claimed_id = server_compile_slice(append_value->claimed_id),
        .payload =
            (store_server_compile_buffer){
                .data = append_value->payload.data,
                .length = append_value->payload.length,
                .release_context = NULL,
                .release = NULL,
            },
    };
  }
  lock_status = pthread_mutex_lock(&database->mutex);
  if (lock_status != 0) {
    if (targets != NULL) {
      database->host.deallocate(database->host.allocation_context, targets);
    }
    set_error(error, BEAGLE_STORE_ENGINE_ERROR,
              "cannot enter the embedded Beagle Store database");
    result->status = BEAGLE_STORE_ENGINE_ERROR;
    return BEAGLE_STORE_ENGINE_ERROR;
  }
  if (append_value == NULL) {
    status = store_server_compile_query(
        database->store, &server_key, &server_value, &server_result, detail,
        sizeof(detail));
  } else {
    status = store_server_compile_append(
        database->store, &server_key, &server_input, &server_result, detail,
        sizeof(detail));
  }
  if (status == BEAGLE_STORE_SERVER_OK && append_value == NULL &&
      server_result.found) {
    public_result =
        copy_compile_value(database, query_value, &server_value, error);
    if (public_result != BEAGLE_STORE_OK) {
      status = public_result == BEAGLE_STORE_OUT_OF_MEMORY
                   ? BEAGLE_STORE_SERVER_OUT_OF_MEMORY
                   : BEAGLE_STORE_SERVER_FATAL;
    }
  }
  store_server_compile_value_release(&server_value);
  (void)pthread_mutex_unlock(&database->mutex);
  if (targets != NULL) {
    database->host.deallocate(database->host.allocation_context, targets);
  }
  if (status != BEAGLE_STORE_SERVER_OK) {
    if (query_value != NULL) {
      store_compile_value_release(query_value);
    }
    if (public_result == BEAGLE_STORE_OK) {
      public_result = fail_from_server(status, detail, error);
    }
    result->status = public_result;
    return public_result;
  }
  if ((append_value == NULL &&
       (server_result.outcome < BEAGLE_STORE_SERVER_COMPILE_COLD ||
        server_result.outcome > BEAGLE_STORE_SERVER_COMPILE_FOUND)) ||
      (append_value != NULL &&
       (server_result.outcome < BEAGLE_STORE_SERVER_COMPILE_APPENDED ||
        server_result.outcome > BEAGLE_STORE_SERVER_COMPILE_RETAINED)) ||
      server_result.status != BEAGLE_STORE_SERVER_OK ||
      server_result.found !=
          (server_result.outcome != BEAGLE_STORE_SERVER_COMPILE_COLD)) {
    if (query_value != NULL) {
      store_compile_value_release(query_value);
    }
    set_error(error, BEAGLE_STORE_ENGINE_ERROR,
              "generated compiler operation returned an invalid result");
    result->status = BEAGLE_STORE_ENGINE_ERROR;
    return BEAGLE_STORE_ENGINE_ERROR;
  }
  result->status = BEAGLE_STORE_OK;
  result->found = server_result.found;
  result->outcome = (store_compile_outcome)server_result.outcome;
  return BEAGLE_STORE_OK;
}

uint32_t store_abi_version(void) { return BEAGLE_STORE_ABI_VERSION; }

store_status store_open(const store_open_options_v1 *options,
                      store_database **database_out, store_error *error) {
  store_database *database;
  store_server_host_v1 server_host;
  store_host_v1 allocation_host;
  const store_host_v1 *host;
  char detail[BEAGLE_STORE_SERVER_ERROR_CAPACITY];
  const char *log_label;
  int status;

  clear_error(error);
  if (database_out != NULL) {
    *database_out = NULL;
  }
  if (options == NULL || database_out == NULL ||
      options->abi_version != BEAGLE_STORE_ABI_VERSION ||
      options->struct_size < (uint32_t)sizeof(*options) ||
      options->space_id == NULL || options->space_id[0] == '\0') {
    set_error(error, BEAGLE_STORE_INVALID_ARGUMENT,
              "Beagle Store open options or host ABI are invalid");
    return BEAGLE_STORE_INVALID_ARGUMENT;
  }
  host = options->host;
#ifdef BEAGLE_STORE_WASM_HOST_IMPORTS
  /* No POSIX regime is compiled in to fall through to: the named imports are
     this build's only storage, clock, and allocation seam. */
  if (host == NULL) {
    host = store_wasm_host_v1();
  }
#endif
  if ((host == NULL &&
       (options->log_path == NULL || options->log_path[0] == '\0')) ||
      (host != NULL && !valid_host(host))) {
    set_error(error, BEAGLE_STORE_INVALID_ARGUMENT,
              "Beagle Store open options or host ABI are invalid");
    return BEAGLE_STORE_INVALID_ARGUMENT;
  }
  native_set_trap_reporter(report_trap);
  if (store_server_generated_abi() != BEAGLE_STORE_SERVER_GENERATED_ABI) {
    set_error(error, BEAGLE_STORE_ENGINE_ERROR,
              "generated Beagle Store engine ABI does not match the embedding host");
    return BEAGLE_STORE_ENGINE_ERROR;
  }
  if (host != NULL) {
    allocation_host = *host;
  } else {
    allocation_host = (store_host_v1){
        .abi_version = BEAGLE_STORE_ABI_VERSION,
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
    set_error(error, BEAGLE_STORE_OUT_OF_MEMORY,
              "embedded host could not allocate the database handle");
    return BEAGLE_STORE_OUT_OF_MEMORY;
  }
  memset(database, 0, sizeof(*database));
  database->host = allocation_host;
  database->log_seam.database = database;
  database->log_seam.context = allocation_host.storage_context;
  database->snapshot_seam.database = database;
  database->snapshot_seam.context = allocation_host.snapshot_storage_context;
  if (pthread_mutex_init(&database->mutex, NULL) != 0) {
    allocation_host.deallocate(allocation_host.allocation_context, database);
    set_error(error, BEAGLE_STORE_ENGINE_ERROR,
              "cannot initialize the embedded Beagle Store database mutex");
    return BEAGLE_STORE_ENGINE_ERROR;
  }
  log_label = options->log_path != NULL ? options->log_path : "embedded";
  // The wasm regime compiles the POSIX boot out, so its call site goes too.
#ifndef BEAGLE_STORE_WASM_HOST_IMPORTS
  if (host == NULL) {
    status = store_server_store_boot(log_label, options->space_id,
                                    options->memory_budget_bytes,
                                    &database->store, detail, sizeof(detail));
  } else
#endif
  {
    server_host = (store_server_host_v1){
        .abi_version = BEAGLE_STORE_SERVER_HOST_ABI,
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
    status = store_server_store_boot_with_host(
        log_label, options->space_id, &server_host, &database->store, detail,
        sizeof(detail));
  }
  if (status != BEAGLE_STORE_SERVER_OK) {
    (void)pthread_mutex_destroy(&database->mutex);
    allocation_host.deallocate(allocation_host.allocation_context, database);
    return fail_from_server(status, detail, error);
  }
  *database_out = database;
  return BEAGLE_STORE_OK;
}

store_status store_transact(store_database *database, store_slice request,
                          store_buffer *response, store_error *error) {
  return call(database, request, response, error);
}

store_status store_query(store_database *database, store_slice request,
                       store_buffer *response, store_error *error) {
  return call(database, request, response, error);
}

store_status store_snapshot(store_database *database, store_slice request,
                          store_buffer *response, store_error *error) {
  return call(database, request, response, error);
}

store_status store_compile_query(store_database *database,
                                 const store_compile_key *key,
                                 store_compile_value *value,
                                 store_compile_query_result *result,
                                 store_error *error) {
  if (value == NULL) {
    clear_error(error);
    if (result != NULL) {
      *result = (store_compile_query_result){
          .status = BEAGLE_STORE_INVALID_ARGUMENT,
          .found = false,
          .outcome = BEAGLE_STORE_COMPILE_COLD,
      };
    }
    set_error(error, BEAGLE_STORE_INVALID_ARGUMENT,
              "compiler query requires a value result owner");
    return BEAGLE_STORE_INVALID_ARGUMENT;
  }
  return compile_call(database, key, NULL, value, result, error);
}

store_status store_compile_append(store_database *database,
                                  const store_compile_key *key,
                                  const store_compile_value *value,
                                  store_compile_query_result *result,
                                  store_error *error) {
  if (value == NULL) {
    clear_error(error);
    if (result != NULL) {
      *result = (store_compile_query_result){
          .status = BEAGLE_STORE_INVALID_ARGUMENT,
          .found = false,
          .outcome = BEAGLE_STORE_COMPILE_RETAINED,
      };
    }
    set_error(error, BEAGLE_STORE_INVALID_ARGUMENT,
              "compiler append requires a value");
    return BEAGLE_STORE_INVALID_ARGUMENT;
  }
  return compile_call(database, key, value, NULL, result, error);
}

void store_compile_value_release(store_compile_value *value) {
  void *context;
  store_deallocate_fn release;
  uint8_t *allocation;

  if (value == NULL) {
    return;
  }
  context = value->payload.release_context;
  release = value->payload.release;
  allocation = value->payload.data;
  *value = (store_compile_value){0};
  if (release != NULL && allocation != NULL) {
    release(context, allocation);
  }
}

void store_buffer_release(store_buffer *buffer) {
  void *context;
  store_deallocate_fn release;
  uint8_t *data;

  if (buffer == NULL) {
    return;
  }
  context = buffer->release_context;
  release = buffer->release;
  data = buffer->data;
  *buffer = (store_buffer){0};
  if (release != NULL && data != NULL) {
    release(context, data);
  }
}

store_status store_close(store_database *database, store_error *error) {
  store_host_v1 host;
  char detail[BEAGLE_STORE_SERVER_ERROR_CAPACITY];
  int lock_status;
  int status;

  clear_error(error);
  if (database == NULL) {
    set_error(error, BEAGLE_STORE_INVALID_ARGUMENT,
              "Beagle Store close requires a database handle");
    return BEAGLE_STORE_INVALID_ARGUMENT;
  }
  host = database->host;
  lock_status = pthread_mutex_lock(&database->mutex);
  status = store_server_store_shutdown(database->store, detail, sizeof(detail));
  database->store = NULL;
  if (lock_status == 0) {
    (void)pthread_mutex_unlock(&database->mutex);
  }
  (void)pthread_mutex_destroy(&database->mutex);
  host.deallocate(host.allocation_context, database);
  if (lock_status != 0) {
    set_error(error, BEAGLE_STORE_ENGINE_ERROR,
              "cannot close the embedded Beagle Store database mutex");
    return BEAGLE_STORE_ENGINE_ERROR;
  }
  if (status != BEAGLE_STORE_SERVER_OK) {
    return fail_from_server(status, detail, error);
  }
  return BEAGLE_STORE_OK;
}
