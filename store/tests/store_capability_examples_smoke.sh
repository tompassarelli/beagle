#!/usr/bin/env bash
set -euo pipefail

store_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "${scratch:?}"' EXIT INT TERM

fail() {
  echo "store capability examples smoke: FAIL: $*" >&2
  exit 1
}

command -v cc >/dev/null 2>&1 || fail "cc is not on PATH"
command -v bun >/dev/null 2>&1 || fail "Bun is not on PATH"

cat >"$scratch/store-stub.c" <<'STUB'
#include "store.h"

#include <stdlib.h>
#include <string.h>

struct store_database { int open; };

uint32_t store_abi_version(void) { return BEAGLE_STORE_ABI_VERSION; }

store_status store_open(const store_open_options_v1 *options,
                        store_database **database_out,
                        store_error *error) {
  (void)error;
  if (options == NULL || database_out == NULL || options->space_id == NULL ||
      options->log_path == NULL) return BEAGLE_STORE_INVALID_ARGUMENT;
  *database_out = malloc(sizeof(store_database));
  if (*database_out == NULL) return BEAGLE_STORE_OUT_OF_MEMORY;
  (*database_out)->open = 1;
  return BEAGLE_STORE_OK;
}

static store_status reply(store_database *database, store_slice request,
                          store_buffer *response) {
  if (database == NULL || response == NULL) return BEAGLE_STORE_INVALID_ARGUMENT;
  response->data = malloc(request.length);
  if (response->data == NULL && request.length != 0) return BEAGLE_STORE_OUT_OF_MEMORY;
  memcpy(response->data, request.data, request.length);
  response->length = request.length;
  response->release_context = NULL;
  response->release = NULL;
  return BEAGLE_STORE_OK;
}

store_status store_transact(store_database *database, store_slice request,
                            store_buffer *response, store_error *error) {
  (void)error;
  return reply(database, request, response);
}

store_status store_query(store_database *database, store_slice request,
                         store_buffer *response, store_error *error) {
  (void)error;
  return reply(database, request, response);
}

store_status store_snapshot(store_database *database, store_slice request,
                            store_buffer *response, store_error *error) {
  (void)error;
  return reply(database, request, response);
}

void store_buffer_release(store_buffer *buffer) {
  free(buffer->data);
  memset(buffer, 0, sizeof(*buffer));
}

store_status store_close(store_database *database, store_error *error) {
  (void)error;
  free(database);
  return BEAGLE_STORE_OK;
}
STUB

cc -std=c17 -pedantic -Wall -Wextra -Werror \
  -I"$store_root/native" \
  "$store_root/examples/embedded-c.c" "$scratch/store-stub.c" \
  -o "$scratch/embedded-c"
printf 'closed-store-packet' >"$scratch/request.packet"
"$scratch/embedded-c" "$scratch/history.storelog" example transact \
  <"$scratch/request.packet" >"$scratch/response.packet"
cmp "$scratch/request.packet" "$scratch/response.packet" >/dev/null ||
  fail "embedded C example did not exchange one exact packet"

store_root_json="$(printf '%s' "$store_root" | sed 's/[\\"]/\\&/g')"
cat >"$scratch/examples.mjs" <<EOF
import { putDocument, readDocument } from '${store_root_json}/examples/rpc-sidecar.mjs';
import { storeCache } from '${store_root_json}/examples/cache-profile.mjs';
import {
  term,
  tripleTerm,
} from '${store_root_json}/clients/bun/store-rpc.mjs';

const equal = (left, right) => JSON.stringify(left) === JSON.stringify(right);

class MemoryTransportDouble {
  constructor() {
    this.servedVersion = 0n;
    this.triples = [];
  }

  async version() {
    return { servedVersion: this.servedVersion, result: null };
  }

  preflightBatch(actions) {
    return Object.freeze({ actionCount: actions.length });
  }

  async batch(actions, options = {}) {
    if (options.expectedVersion !== undefined &&
        options.expectedVersion !== this.servedVersion) {
      throw new Error('stale smoke-test version');
    }
    for (const action of actions) {
      const proposition = action.proposition ||
        tripleTerm(action.t1, action.t2, action.t3);
      if (action.op === 'assert') {
        this.triples.push(proposition);
      } else {
        const index = this.triples.findIndex((value) => equal(value, proposition));
        if (index >= 0) this.triples.splice(index, 1);
      }
    }
    this.servedVersion += 1n;
    return { servedVersion: this.servedVersion, result: [] };
  }

  async scan(pattern = {}) {
    const normalized = Object.fromEntries(
      Object.entries(pattern).map(([key, value]) => [key, term(value)]),
    );
    const positions = { t1: 1, t2: 2, t3: 3 };
    const result = this.triples.filter((triple) =>
      Object.entries(normalized).every(([key, value]) =>
        equal(triple[positions[key]], value)));
    return { servedVersion: this.servedVersion, result };
  }
}

const direct = new MemoryTransportDouble();
await putDocument(direct, { id: 'doc-1', title: 'Direct Store RPC' });
const document = await readDocument(direct, 'doc-1');
if (document.result.length !== 2) throw new Error('sidecar example lost a triple');

const backing = new MemoryTransportDouble();
const cache = storeCache(backing, { namespace: 'smoke', now: () => 1000 });
await cache.put('answer', 'forty-two', {
  ttlMs: 500,
  materializedFrom: 'source-v1',
});
const hit = await cache.get('answer');
if (!equal(hit, term('forty-two'))) throw new Error('cache example missed a live value');
await cache.invalidate('answer');
if (await cache.get('answer') !== null) throw new Error('cache invalidation left a live value');
EOF

bun "$scratch/examples.mjs"

echo "store capability examples smoke: PASS embedded=1 sidecar=1 cache=1"
