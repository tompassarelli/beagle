// SPDX-License-Identifier: MIT OR Apache-2.0
#include "store.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void fail(const char *message) {
  fprintf(stderr, "embedded-c: %s\n", message);
  exit(1);
}

static store_buffer exchange(store_database *database,
                             const char *entry,
                             store_slice request) {
  store_buffer response = {0};
  store_error error = {0};
  store_status status;

  if (strcmp(entry, "transact") == 0) {
    status = store_transact(database, request, &response, &error);
  } else if (strcmp(entry, "query") == 0) {
    status = store_query(database, request, &response, &error);
  } else if (strcmp(entry, "snapshot") == 0) {
    status = store_snapshot(database, request, &response, &error);
  } else {
    fail("entry must be transact, query, or snapshot");
  }

  if (status != BEAGLE_STORE_OK) {
    fprintf(stderr, "embedded-c: exchange failed (%d): %s\n",
            error.code, error.message);
    exit(1);
  }
  return response;
}

static store_slice read_request(void) {
  size_t capacity = 4096;
  size_t length = 0;
  uint8_t *bytes = malloc(capacity);
  if (bytes == NULL) fail("could not allocate request buffer");

  for (;;) {
    if (length == capacity) {
      capacity *= 2;
      uint8_t *larger = realloc(bytes, capacity);
      if (larger == NULL) {
        free(bytes);
        fail("could not grow request buffer");
      }
      bytes = larger;
    }
    size_t received = fread(bytes + length, 1, capacity - length, stdin);
    length += received;
    if (received == 0) {
      if (ferror(stdin)) {
        free(bytes);
        fail("could not read request packet");
      }
      break;
    }
  }

  store_slice request = {.data = bytes, .length = length};
  return request;
}

int main(int argc, char **argv) {
  if (argc != 4) {
    fprintf(stderr,
            "usage: embedded-c LOG_PATH SPACE_ID transact|query|snapshot\n");
    return 64;
  }

  store_open_options_v1 options = {
      .abi_version = BEAGLE_STORE_ABI_VERSION,
      .struct_size = sizeof(store_open_options_v1),
      .space_id = argv[2],
      .log_path = argv[1],
      .host = NULL,
      .memory_budget_bytes = 0,
  };
  store_database *database = NULL;
  store_error error = {0};
  store_status status = store_open(&options, &database, &error);
  if (status != BEAGLE_STORE_OK) {
    fprintf(stderr, "embedded-c: open failed (%d): %s\n",
            error.code, error.message);
    return 1;
  }

  store_slice request = read_request();
  store_buffer response = exchange(database, argv[3], request);
  free((void *)request.data);

  if (fwrite(response.data, 1, response.length, stdout) != response.length) {
    store_buffer_release(&response);
    fail("could not write response packet");
  }
  store_buffer_release(&response);

  status = store_close(database, &error);
  if (status != BEAGLE_STORE_OK) {
    fprintf(stderr, "embedded-c: close failed (%d): %s\n",
            error.code, error.message);
    return 1;
  }
  return 0;
}
