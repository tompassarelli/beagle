#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

work="$(mktemp -d "${TMPDIR:-/tmp}/core-result-cache.XXXXXX")"
cleanup() {
    local rc=$? log
    if [[ $rc -ne 0 ]]; then
        for log in "$work"/*.stderr; do
            [[ -f "$log" ]] || continue
            echo "core_result_cache_gate.sh: failure log $log" >&2
            sed -n '1,240p' "$log" >&2
        done
    fi
    rm -rf "${work:?}"
    return "$rc"
}
trap cleanup EXIT

cache="$work/cache"
source_file="$work/cache-fixture.bgl"
mkdir -p "$work/out-miss" "$work/out-hit" "$work/out-invalidated" \
    "$work/out-alias-corrupt" "$work/out-alias-directory" "$work/out-corrupt"

write_fixture() {
    local value="$1"
    sed "s/@VALUE@/$value/" >"$source_file" <<'BGL'
#lang beagle
(ns core.result-cache-gate)

(defn value [] Int
  @VALUE@)
BGL
}

run_build() {
    local output="$1" log="$2"
    timeout --foreground 180s env BEAGLE_CORE_BUILD_CACHE="$cache" \
        "$repo/bin/beagle-build-core" --materializer c17 \
        --out "$output" "$source_file" >"$log.stdout" 2>"$log.stderr"
}

tree_digest() {
    local root="$1"
    (
        cd "$root"
        find . -type f ! -name .beagle-publish.lock -print0 |
            LC_ALL=C sort -z |
            xargs -0 sha256sum
    ) | sha256sum | awk '{print $1}'
}

write_fixture 1
run_build "$work/out-miss" "$work/miss"
miss_early_key="$(sed -n \
    's/^beagle build: core-result-alias MISS \([0-9a-f]\{64\}\)$/\1/p' \
    "$work/miss.stderr")"
miss_key="$(sed -n 's/^beagle build: core-result-cache MISS \([0-9a-f]\{64\}\)$/\1/p' \
    "$work/miss.stderr")"
[[ "$miss_early_key" =~ ^[0-9a-f]{64}$ && "$miss_key" =~ ^[0-9a-f]{64}$ ]] || {
    echo "core_result_cache_gate.sh: first build did not report one cache miss" >&2
    sed -n '1,200p' "$work/miss.stderr" >&2
    exit 1
}

run_build "$work/out-hit" "$work/hit"
grep -Eq "^beagle build: core-result-alias HIT $miss_early_key -> $miss_key$" \
    "$work/hit.stderr" || {
    echo "core_result_cache_gate.sh: second build did not hit the early alias" >&2
    sed -n '1,200p' "$work/hit.stderr" >&2
    exit 1
}
grep -Fqx "beagle build: core-result-cache HIT $miss_key" \
    "$work/hit.stderr" || {
    echo "core_result_cache_gate.sh: second build did not hit the first result" >&2
    sed -n '1,200p' "$work/hit.stderr" >&2
    exit 1
}
[[ "$(tree_digest "$work/out-miss")" == "$(tree_digest "$work/out-hit")" ]] || {
    echo "core_result_cache_gate.sh: miss and hit artifacts differ" >&2
    exit 1
}

write_fixture 2
run_build "$work/out-invalidated" "$work/invalidated"
invalidated_early_key="$(sed -n \
    's/^beagle build: core-result-alias MISS \([0-9a-f]\{64\}\)$/\1/p' \
    "$work/invalidated.stderr")"
invalidated_key="$(sed -n \
    's/^beagle build: core-result-cache MISS \([0-9a-f]\{64\}\)$/\1/p' \
    "$work/invalidated.stderr")"
[[ "$invalidated_early_key" =~ ^[0-9a-f]{64}$ &&
   "$invalidated_early_key" != "$miss_early_key" &&
   "$invalidated_key" =~ ^[0-9a-f]{64}$ && "$invalidated_key" != "$miss_key" ]] || {
    echo "core_result_cache_gate.sh: source mutation did not invalidate the result" >&2
    sed -n '1,200p' "$work/invalidated.stderr" >&2
    exit 1
}

printf 'corrupt\n' >"$cache/aliases/$miss_early_key"
write_fixture 1
run_build "$work/out-alias-corrupt" "$work/alias-corrupt"
grep -Fqx "beagle build: core-result-alias CORRUPT $miss_early_key; retiring" \
    "$work/alias-corrupt.stderr" || {
    echo "core_result_cache_gate.sh: corrupt alias was not visibly retired" >&2
    sed -n '1,200p' "$work/alias-corrupt.stderr" >&2
    exit 1
}
grep -Fqx "beagle build: core-result-cache HIT $miss_key" \
    "$work/alias-corrupt.stderr" || {
    echo "core_result_cache_gate.sh: corrupt alias did not fall back to the full result" >&2
    sed -n '1,200p' "$work/alias-corrupt.stderr" >&2
    exit 1
}
[[ "$(tree_digest "$work/out-miss")" == \
   "$(tree_digest "$work/out-alias-corrupt")" ]] || {
    echo "core_result_cache_gate.sh: alias recovery changed artifacts" >&2
    exit 1
}

rm -f -- "$cache/aliases/$miss_early_key"
mkdir "$cache/aliases/$miss_early_key"
run_build "$work/out-alias-directory" "$work/alias-directory"
grep -Fqx "beagle build: core-result-alias CORRUPT $miss_early_key; retiring" \
    "$work/alias-directory.stderr" || {
    echo "core_result_cache_gate.sh: directory alias was not visibly retired" >&2
    sed -n '1,200p' "$work/alias-directory.stderr" >&2
    exit 1
}
grep -Fqx "beagle build: core-result-cache HIT $miss_key" \
    "$work/alias-directory.stderr" || {
    echo "core_result_cache_gate.sh: directory alias did not fall back to the full result" >&2
    sed -n '1,200p' "$work/alias-directory.stderr" >&2
    exit 1
}
[[ "$(tree_digest "$work/out-miss")" == \
   "$(tree_digest "$work/out-alias-directory")" ]] || {
    echo "core_result_cache_gate.sh: directory alias recovery changed artifacts" >&2
    exit 1
}

printf '\ncorrupt\n' >>"$cache/results/$miss_key/artifacts/module.native-program"
run_build "$work/out-corrupt" "$work/corrupt"
grep -Fqx "beagle build: core-result-alias CORRUPT $miss_early_key; retiring" \
    "$work/corrupt.stderr" || {
    echo "core_result_cache_gate.sh: result corruption did not retire its alias" >&2
    sed -n '1,200p' "$work/corrupt.stderr" >&2
    exit 1
}
grep -Fqx "beagle build: core-result-cache CORRUPT $miss_key; retiring" \
    "$work/corrupt.stderr" || {
    echo "core_result_cache_gate.sh: corruption was not visibly retired" >&2
    sed -n '1,200p' "$work/corrupt.stderr" >&2
    exit 1
}
grep -Fqx "beagle build: core-result-cache MISS $miss_key" \
    "$work/corrupt.stderr" || {
    echo "core_result_cache_gate.sh: corruption did not rebuild as a miss" >&2
    sed -n '1,200p' "$work/corrupt.stderr" >&2
    exit 1
}
[[ "$(tree_digest "$work/out-miss")" == "$(tree_digest "$work/out-corrupt")" ]] || {
    echo "core_result_cache_gate.sh: corruption recovery changed artifacts" >&2
    exit 1
}

echo "core result cache: early/full miss, hit, invalidation, alias/result corruption retirement, byte identity PASS"
