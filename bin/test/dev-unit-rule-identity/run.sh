#!/usr/bin/env bash

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
helper="$repo/bin/_beagle-dev-unit-rule-identity"
projection_key="$("$repo/bin/beagle-core-compiler-projection" --print-key)"
compiled="${BEAGLE_CORE_COMPILED_OVERRIDE:-${BEAGLE_CORE_COMPILER_CACHE:-${XDG_CACHE_HOME:-${HOME:?HOME is required}/.cache}/beagle/core-compiler-projections}/$projection_key/compiled}"
store_adapter="$repo/store/out/store/dev_compile_facts.clj"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-dev-unit-rule-identity.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

[[ -f "$compiled/native/unit_compile.clj" ]] || {
    echo "dev-unit-rule-identity: current compiled projection is not cached: $compiled" >&2
    exit 2
}

mkdir -p "$scratch/compiled/native" "$scratch/store/out/store"
for module in core stages obligations lower unit_reuse unit_compile qbe; do
    cp "$compiled/native/$module.clj" "$scratch/compiled/native/$module.clj"
done
cp "$repo/bin/beagle-build-core" "$scratch/beagle-build-core"
cp "$store_adapter" "$scratch/store/out/store/dev_compile_facts.clj"

identity_args=(
    --compiled "$scratch/compiled"
    --driver "$scratch/beagle-build-core"
    --store-adapter "$scratch/store/out/store/dev_compile_facts.clj"
    --profile "profile=3"
    --abi "lp64"
)

baseline_epoch="$("$helper" "${identity_args[@]}")"

sed -i '$a;; fixture edit outside the unit compiler phase' \
    "$scratch/compiled/native/qbe.clj"
sed -i '$a# fixture driver edit outside the dev-unit adapter' \
    "$scratch/beagle-build-core"
outside_epoch="$("$helper" "${identity_args[@]}")"

[[ "$baseline_epoch" == "$outside_epoch" ]] || {
    echo "dev-unit-rule-identity: outside-closure edit changed the rule epoch" >&2
    exit 1
}

sed -i '$a;; fixture semantic edit inside the unit compiler phase' \
    "$scratch/compiled/native/unit_compile.clj"
inside_epoch="$("$helper" "${identity_args[@]}")"

[[ "$baseline_epoch" != "$inside_epoch" ]] || {
    echo "dev-unit-rule-identity: inside-closure edit kept the rule epoch" >&2
    exit 1
}

bb -cp "$scratch/compiled" "$here/receipt_keys.clj" \
    "$baseline_epoch" "$outside_epoch" "$inside_epoch"
