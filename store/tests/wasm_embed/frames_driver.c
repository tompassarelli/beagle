// SPDX-License-Identifier: MIT OR Apache-2.0
// Native lp64 oracle for the wasm host-import smoke: the same FRAMRPC frames
// through the same public ABI, with the same fixed clock and host-held log
// bytes the wasm embedder supplies, so the transcripts are byte-comparable.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "store.h"

#define ORACLE_LOG_CAPACITY ((size_t)(16u * 1024u * 1024u))
#define ORACLE_FRAME_CAPACITY ((size_t)(2u * 1024u * 1024u))
#define ORACLE_FIXED_EPOCH_MS INT64_C(1700000000000)

typedef struct oracle_storage {
  uint8_t bytes[ORACLE_LOG_CAPACITY];
  uint64_t length;
} oracle_storage;

static oracle_storage storage;
static oracle_storage image;
static uint8_t request_bytes[ORACLE_FRAME_CAPACITY];

static void *host_allocate(void *context, size_t size) {
  (void)context;
  return malloc(size);
}

static void host_deallocate(void *context, void *allocation) {
  (void)context;
  free(allocation);
}

static int host_clock(void *context, int64_t *milliseconds_out) {
  (void)context;
  *milliseconds_out = ORACLE_FIXED_EPOCH_MS;
  return 0;
}

static int host_storage_size(void *context, uint64_t *size_out) {
  *size_out = ((oracle_storage *)context)->length;
  return 0;
}

static int host_storage_read(void *context, uint64_t offset,
                             uint8_t *destination, size_t length) {
  oracle_storage *owner = context;

  if (offset + (uint64_t)length > owner->length) {
    return 1;
  }
  memcpy(destination, owner->bytes + offset, length);
  return 0;
}

static int host_storage_truncate(void *context, uint64_t length) {
  oracle_storage *owner = context;

  if (length > owner->length) {
    return 1;
  }
  owner->length = length;
  return 0;
}

static int host_storage_append(void *context, const uint8_t *bytes,
                               size_t length) {
  oracle_storage *owner = context;

  if (owner->length + (uint64_t)length > (uint64_t)sizeof owner->bytes) {
    return 1;
  }
  memcpy(owner->bytes + owner->length, bytes, length);
  owner->length += (uint64_t)length;
  return 0;
}

static int host_storage_sync(void *context) {
  (void)context;
  return 0;
}

static int host_storage_close(void *context) {
  (void)context;
  return 0;
}

static void fill_host(store_host_v1 *host) {
  memset(host, 0, sizeof *host);
  host->abi_version = BEAGLE_STORE_ABI_VERSION;
  host->struct_size = (uint32_t)sizeof *host;
  host->allocation_context = NULL;
  host->clock_context = &storage;
  host->storage_context = &storage;
  host->snapshot_storage_context = &image;
  host->allocate = host_allocate;
  host->deallocate = host_deallocate;
  host->clock_milliseconds = host_clock;
  host->storage_size = host_storage_size;
  host->storage_read = host_storage_read;
  host->storage_truncate = host_storage_truncate;
  host->storage_append = host_storage_append;
  host->storage_sync = host_storage_sync;
  host->storage_close = host_storage_close;
}

static size_t read_frame(const char *directory, const char *name) {
  char path[512];
  FILE *file;
  size_t length;

  snprintf(path, sizeof path, "%s/%s", directory, name);
  file = fopen(path, "rb");
  if (file == NULL) {
    fprintf(stderr, "cannot open frame %s\n", path);
    exit(9);
  }
  length = fread(request_bytes, 1u, sizeof request_bytes, file);
  fclose(file);
  return length;
}

static int run_pass(const char *label, const char *directory,
                    const char *manifest_path, const char *space_id) {
  store_host_v1 host;
  store_open_options_v1 options;
  store_database *database = NULL;
  store_error error;
  store_status status;
  FILE *manifest;
  char line[512];
  size_t index;
  int failures = 0;

  fill_host(&host);
  options.abi_version = BEAGLE_STORE_ABI_VERSION;
  options.struct_size = (uint32_t)sizeof options;
  options.space_id = space_id;
  options.log_path = "in-memory";
  options.host = &host;
  memset(&error, 0, sizeof error);
  status = store_open(&options, &database, &error);
  printf("%s %d \"%s\"\n", label, (int)status, error.message);
  if (status != BEAGLE_STORE_OK) {
    return 1;
  }

  manifest = fopen(manifest_path, "r");
  if (manifest == NULL) {
    fprintf(stderr, "cannot open manifest %s\n", manifest_path);
    exit(9);
  }
  while (fgets(line, sizeof line, manifest) != NULL) {
    char entry[8];
    char name[256];
    unsigned declared = 0u;
    char operation[64];
    size_t length;
    store_slice request;
    store_buffer response;

    operation[0] = '\0';
    if (sscanf(line, "%7s %255s %u %63s", entry, name, &declared, operation) <
        3) {
      continue;
    }
    length = read_frame(directory, name);
    if (length != (size_t)declared) {
      printf("frame %s READ-MISMATCH\n", name);
      failures++;
      continue;
    }
    request.data = request_bytes;
    request.length = length;
    memset(&response, 0, sizeof response);
    memset(&error, 0, sizeof error);
    if (entry[0] == 't') {
      status = store_transact(database, request, &response, &error);
    } else if (entry[0] == 's') {
      status = store_snapshot(database, request, &response, &error);
    } else {
      status = store_query(database, request, &response, &error);
    }
    printf("frame %s %d ", name, (int)status);
    for (index = 0u; index < response.length; index++) {
      printf("%02x", response.data[index]);
    }
    printf("\n");
    if (status != BEAGLE_STORE_OK) {
      failures++;
    }
    store_buffer_release(&response);
    if (response.data != NULL || response.length != 0u ||
        response.release != NULL) {
      printf("frame %s RELEASE-DID-NOT-CLEAR\n", name);
      failures++;
    }
  }
  fclose(manifest);

  memset(&error, 0, sizeof error);
  status = store_close(database, &error);
  printf("close %d \"%s\"\n", (int)status, error.message);
  return (status == BEAGLE_STORE_OK && failures == 0) ? 0 : 1;
}

int main(int argc, char **argv) {
  const char *directory;
  const char *manifest_path;
  const char *reopen_manifest_path;
  const char *image_manifest_path;
  const char *log_path;
  const char *space_id;
  FILE *log;
  int failures = 0;

  if (argc < 7) {
    fprintf(stderr,
            "usage: frames_driver FRAMES MANIFEST REOPEN-MANIFEST "
            "IMAGE-MANIFEST LOG-OUT SPACE\n");
    return 2;
  }
  directory = argv[1];
  manifest_path = argv[2];
  reopen_manifest_path = argv[3];
  image_manifest_path = argv[4];
  log_path = argv[5];
  space_id = argv[6];

  setvbuf(stdout, NULL, _IOLBF, 0);
  failures += run_pass("open", directory, manifest_path, space_id);
  failures += run_pass("reopen", directory, reopen_manifest_path, space_id);
  /* The third pass opens over a host-held image plus the log tail. */
  failures += run_pass("image", directory, image_manifest_path, space_id);

  log = fopen(log_path, "wb");
  if (log == NULL) {
    fprintf(stderr, "cannot write %s\n", log_path);
    return 9;
  }
  if (storage.length != 0u &&
      fwrite(storage.bytes, 1u, (size_t)storage.length, log) !=
          (size_t)storage.length) {
    fprintf(stderr, "short write to %s\n", log_path);
    fclose(log);
    return 9;
  }
  fclose(log);
  printf("log %llu\n", (unsigned long long)storage.length);
  printf("image %llu\n", (unsigned long long)image.length);
  return failures == 0 ? 0 : 1;
}
