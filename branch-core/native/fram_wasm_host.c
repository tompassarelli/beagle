// SPDX-License-Identifier: MIT OR Apache-2.0
#if !defined(FRAM_WASM_HOST_IMPORTS)
#error "fram_wasm_host.c belongs to the wasm host-import regime"
#endif
#if !defined(__wasm32__)
#error "the fram_host_v1 import regime targets wasm32"
#endif

#include "fram.h"

#include <stdint.h>
#include <stdlib.h>

/* The import module IS the fram_host_v1 struct, field for field: one hook is
   one import name with that field's prototype, so adding a hook stays one
   mechanical seam (header field, import, seam ledger line). */
#define FRAM_HOST_IMPORT(field)                                                \
  __attribute__((import_module("fram_host_v1"), import_name(#field)))

FRAM_HOST_IMPORT(allocate)
void *fram_host_import_allocate(void *context, size_t size);
FRAM_HOST_IMPORT(deallocate)
void fram_host_import_deallocate(void *context, void *allocation);
FRAM_HOST_IMPORT(clock_milliseconds)
int fram_host_import_clock_milliseconds(void *context,
                                        int64_t *milliseconds_out);
FRAM_HOST_IMPORT(storage_size)
int fram_host_import_storage_size(void *context, uint64_t *size_out);
FRAM_HOST_IMPORT(storage_read)
int fram_host_import_storage_read(void *context, uint64_t offset,
                                  uint8_t *destination, size_t length);
FRAM_HOST_IMPORT(storage_truncate)
int fram_host_import_storage_truncate(void *context, uint64_t length);
FRAM_HOST_IMPORT(storage_append)
int fram_host_import_storage_append(void *context, const uint8_t *bytes,
                                    size_t length);
FRAM_HOST_IMPORT(storage_sync)
int fram_host_import_storage_sync(void *context);
FRAM_HOST_IMPORT(storage_close)
int fram_host_import_storage_close(void *context);

/* One instance binds one host database, so a context is only an object
   discriminator: 0 is the FRAMLOG and 1 is the snapshot image. */
static const fram_host_v1 import_host = {
    .abi_version = FRAM_ABI_VERSION,
    .struct_size = (uint32_t)sizeof(fram_host_v1),
    .allocation_context = NULL,
    .clock_context = NULL,
    .storage_context = NULL,
    .snapshot_storage_context = (void *)(uintptr_t)1u,
    .allocate = fram_host_import_allocate,
    .deallocate = fram_host_import_deallocate,
    .clock_milliseconds = fram_host_import_clock_milliseconds,
    .storage_size = fram_host_import_storage_size,
    .storage_read = fram_host_import_storage_read,
    .storage_truncate = fram_host_import_storage_truncate,
    .storage_append = fram_host_import_storage_append,
    .storage_sync = fram_host_import_storage_sync,
    .storage_close = fram_host_import_storage_close,
};

const fram_host_v1 *fram_wasm_host_v1(void) { return &import_host; }

void *fram_wasm_alloc(size_t size) { return malloc(size); }

void fram_wasm_free(void *allocation) { free(allocation); }
