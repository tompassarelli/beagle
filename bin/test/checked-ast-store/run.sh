#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-checked-ast-store.XXXXXX")"
trap 'rm -rf -- "${scratch:?}"' EXIT

store="$scratch/store.log"
payload="$scratch/payload"
changed_payload="$scratch/changed-payload"
key="sha256:1111111111111111111111111111111111111111111111111111111111111111"
changed_key="sha256:2222222222222222222222222222222222222222222222222222222222222222"
context="sha256:3333333333333333333333333333333333333333333333333333333333333333"
profile="core"
unit="checked-ast-store-test"

printf 'payload-v1\n' >"$payload"
printf 'payload-v2\n' >"$changed_payload"

run_store() {
    bb -cp "$repo/store/out" "$repo/bin/_beagle-checked-ast-store.clj" "$@"
}

if run_store query "$store" "$key" "$context" "$profile" "$unit" \
    >"$scratch/initial-query" 2>"$scratch/initial-query.err"; then
    echo "checked-ast-store: initial query unexpectedly hit" >&2
    exit 1
fi

run_store append "$store" "$key" "$context" "$profile" "$unit" "$payload"
run_store query "$store" "$key" "$context" "$profile" "$unit" >"$scratch/query"
cmp -s "$payload" "$scratch/query"

run_store append "$store" "$key" "$context" "$profile" "$unit" "$payload"
run_store query "$store" "$key" "$context" "$profile" "$unit" >"$scratch/query-duplicate"
cmp -s "$payload" "$scratch/query-duplicate"

if run_store query "$store" "$changed_key" "$context" "$profile" "$unit" \
    >"$scratch/changed-key-query" 2>"$scratch/changed-key-query.err"; then
    echo "checked-ast-store: changed key unexpectedly hit" >&2
    exit 1
fi

if run_store append "$store" "$key" "$context" "$profile" "$unit" "$changed_payload" \
    >"$scratch/changed-payload-append" 2>"$scratch/changed-payload-append.err"; then
    echo "checked-ast-store: changed payload unexpectedly accepted" >&2
    exit 1
fi

echo "checked-ast-store: PASS"
