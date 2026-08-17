// SPDX-License-Identifier: MIT OR Apache-2.0
#if !defined(BEAGLE_STORE_WASM_HOST_IMPORTS)
#error "store_wasm_host.c belongs to the wasm host-import regime"
#endif
#if !defined(__wasm32__)
#error "the store_host_v1 import regime targets wasm32"
#endif

#include "store.h"

#include <stdint.h>
#include <stdlib.h>

/* The import module IS the store_host_v1 struct, field for field: one hook is
   one import name with that field's prototype, so adding a hook stays one
   mechanical seam (header field, import, seam ledger line). */
#define BEAGLE_STORE_HOST_IMPORT(field)                                                \
  __attribute__((import_module("store_host_v1"), import_name(#field)))

BEAGLE_STORE_HOST_IMPORT(allocate)
void *store_host_import_allocate(void *context, size_t size);
BEAGLE_STORE_HOST_IMPORT(deallocate)
void store_host_import_deallocate(void *context, void *allocation);
BEAGLE_STORE_HOST_IMPORT(clock_milliseconds)
int store_host_import_clock_milliseconds(void *context,
                                        int64_t *milliseconds_out);
BEAGLE_STORE_HOST_IMPORT(storage_size)
int store_host_import_storage_size(void *context, uint64_t *size_out);
BEAGLE_STORE_HOST_IMPORT(storage_read)
int store_host_import_storage_read(void *context, uint64_t offset,
                                  uint8_t *destination, size_t length);
BEAGLE_STORE_HOST_IMPORT(storage_truncate)
int store_host_import_storage_truncate(void *context, uint64_t length);
BEAGLE_STORE_HOST_IMPORT(storage_append)
int store_host_import_storage_append(void *context, const uint8_t *bytes,
                                    size_t length);
BEAGLE_STORE_HOST_IMPORT(storage_sync)
int store_host_import_storage_sync(void *context);
BEAGLE_STORE_HOST_IMPORT(storage_close)
int store_host_import_storage_close(void *context);

/* One instance binds one host database, so a context is only an object
   discriminator: 0 is the FRAMLOG and 1 is the snapshot image. */
static const store_host_v1 import_host = {
    .abi_version = BEAGLE_STORE_ABI_VERSION,
    .struct_size = (uint32_t)sizeof(store_host_v1),
    .allocation_context = NULL,
    .clock_context = NULL,
    .storage_context = NULL,
    .snapshot_storage_context = (void *)(uintptr_t)1u,
    .allocate = store_host_import_allocate,
    .deallocate = store_host_import_deallocate,
    .clock_milliseconds = store_host_import_clock_milliseconds,
    .storage_size = store_host_import_storage_size,
    .storage_read = store_host_import_storage_read,
    .storage_truncate = store_host_import_storage_truncate,
    .storage_append = store_host_import_storage_append,
    .storage_sync = store_host_import_storage_sync,
    .storage_close = store_host_import_storage_close,
};

const store_host_v1 *store_wasm_host_v1(void) { return &import_host; }

void *store_wasm_alloc(size_t size) { return malloc(size); }

void store_wasm_free(void *allocation) { free(allocation); }
