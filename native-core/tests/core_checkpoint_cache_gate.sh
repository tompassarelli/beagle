#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

git -C "$repo" diff --quiet --ignore-submodules -- || {
    echo "core_checkpoint_cache_gate.sh: compiler worktree must be clean" >&2
    exit 2
}
git -C "$repo" diff --cached --quiet --ignore-submodules -- || {
    echo "core_checkpoint_cache_gate.sh: compiler index must be clean" >&2
    exit 2
}

work="$(mktemp -d "${TMPDIR:-/tmp}/core-checkpoint-cache.XXXXXX")"
cleanup() {
    local rc=$? log
    if [[ $rc -ne 0 ]]; then
        for log in "$work"/*.stderr; do
            [[ -f "$log" ]] || continue
            echo "core_checkpoint_cache_gate.sh: failure log $log" >&2
            sed -n '1,260p' "$log" >&2
        done
    fi
    rm -rf "${work:?}"
    return "$rc"
}
trap cleanup EXIT

cache="$work/cache"
source_file="$work/checkpoint-fixture.bgl"
mkdir -p "$work/out-cold" "$work/out-seed" "$work/out-resume" \
    "$work/out-qbe-resume" "$work/out-invalidated" "$work/out-corrupt" \
    "$work/out-legacy"

write_fixture() {
    local value="$1"
    sed "s/@VALUE@/$value/" >"$source_file" <<'BGL'
#lang beagle
(ns core.checkpoint-cache-gate)

(defn value [] Int
  @VALUE@)
BGL
}

run_build() {
    local output="$1" log="$2"
    shift 2
    timeout --foreground 180s nice -n 19 env \
        BEAGLE_CORE_BUILD_CACHE="$cache" "$@" \
        "$repo/bin/beagle-build-core" --materializer c17 \
        --out "$output" "$source_file" >"$log.stdout" 2>"$log.stderr"
}

run_build_failure() {
    local output="$1" log="$2" rc
    shift 2
    set +e
    run_build "$output" "$log" "$@"
    rc=$?
    set -e
    [[ $rc -ne 0 && $rc -ne 124 ]] || {
        echo "core_checkpoint_cache_gate.sh: expected bounded product failure, got $rc" >&2
        return 1
    }
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

checkpoint_key() {
    local log="$1"
    sed -n 's/^beagle build: core-checkpoint PUBLISHED \([0-9a-f]\{64\}\)$/\1/p' \
        "$log.stderr"
}

write_fixture 1
run_build "$work/out-cold" "$work/cold"
cold_key="$(checkpoint_key "$work/cold")"
[[ "$cold_key" =~ ^[0-9a-f]{64}$ ]] || {
    echo "core_checkpoint_cache_gate.sh: cold reference did not publish a checkpoint" >&2
    exit 1
}
cold_early_key="$(sed -n \
    's/^beagle build: core-checkpoint-alias MISS \([0-9a-f]\{64\}\)$/\1/p' \
    "$work/cold.stderr")"
[[ "$cold_early_key" =~ ^[0-9a-f]{64}$ ]] || {
    echo "core_checkpoint_cache_gate.sh: cold reference omitted its early key" >&2
    exit 1
}

# Preserve the compiled compiler projection, but remove every reusable product
# result/checkpoint so the deliberate failing build is the only seed.
rm -rf -- "${cache:?}/aliases" "${cache:?}/results" \
    "${cache:?}/checkpoint-aliases" "${cache:?}/checkpoints"

run_build_failure "$work/out-seed" "$work/seed" \
    BEAGLE_CORE_CHECKPOINT_FAILPOINT=after-stage
seed_key="$(checkpoint_key "$work/seed")"
seed_early_key="$(sed -n \
    's/^beagle build: core-checkpoint-alias MISS \([0-9a-f]\{64\}\)$/\1/p' \
    "$work/seed.stderr")"
[[ "$seed_key" == "$cold_key" && "$seed_early_key" == "$cold_early_key" ]] || {
    echo "core_checkpoint_cache_gate.sh: failpoint seed changed checkpoint identity" >&2
    exit 1
}
[[ -d "$cache/checkpoints/$seed_key" &&
   -f "$cache/checkpoint-aliases/$seed_early_key" &&
   ! -e "$cache/results/$seed_key" ]] || {
    echo "core_checkpoint_cache_gate.sh: failpoint did not leave checkpoint-only state" >&2
    exit 1
}
grep -Fq "Core checkpoint post-stage failpoint" "$work/seed.stderr" || {
    echo "core_checkpoint_cache_gate.sh: deliberate failpoint was not visible" >&2
    exit 1
}

timeout --foreground 180s nice -n 19 env \
    BEAGLE_CORE_BUILD_CACHE="$cache" \
    "$repo/bin/beagle-build-core" --materializer qbe \
    --out "$work/out-qbe-resume" "$source_file" \
    >"$work/qbe-resume.stdout" 2>"$work/qbe-resume.stderr" &
qbe_resume_pid=$!
run_build "$work/out-resume" "$work/resume"
wait "$qbe_resume_pid"
grep -Fqx "beagle build: core-checkpoint-alias HIT $seed_early_key -> $seed_key" \
    "$work/resume.stderr" || {
    echo "core_checkpoint_cache_gate.sh: resume did not hit the early checkpoint alias" >&2
    exit 1
}
grep -Fqx "beagle build: core-checkpoint HIT $seed_key" \
    "$work/resume.stderr" || {
    echo "core_checkpoint_cache_gate.sh: resume did not decode the frozen checkpoint" >&2
    exit 1
}
grep -Fq "beagle build: core-result-cache HIT" "$work/resume.stderr" && {
    echo "core_checkpoint_cache_gate.sh: resume incorrectly used a whole result" >&2
    exit 1
}
[[ "$(tree_digest "$work/out-cold")" == "$(tree_digest "$work/out-resume")" ]] || {
    echo "core_checkpoint_cache_gate.sh: cold and resumed output trees differ" >&2
    exit 1
}

grep -Fqx "beagle build: core-checkpoint-alias HIT $seed_early_key -> $seed_key" \
    "$work/qbe-resume.stderr" || {
    echo "core_checkpoint_cache_gate.sh: QBE did not share C17's pre-materializer alias" >&2
    exit 1
}
grep -Fqx "beagle build: core-checkpoint HIT $seed_key" \
    "$work/qbe-resume.stderr" || {
    echo "core_checkpoint_cache_gate.sh: QBE did not reuse C17's frozen checkpoint" >&2
    exit 1
}
[[ -f "$work/out-qbe-resume/module_0.ssa" ]] || {
    echo "core_checkpoint_cache_gate.sh: QBE checkpoint resume omitted its projection" >&2
    exit 1
}

write_fixture 2
run_build "$work/out-invalidated" "$work/invalidated"
invalidated_key="$(checkpoint_key "$work/invalidated")"
invalidated_early_key="$(sed -n \
    's/^beagle build: core-checkpoint-alias MISS \([0-9a-f]\{64\}\)$/\1/p' \
    "$work/invalidated.stderr")"
[[ "$invalidated_key" =~ ^[0-9a-f]{64}$ &&
   "$invalidated_key" != "$seed_key" &&
   "$invalidated_early_key" =~ ^[0-9a-f]{64}$ &&
   "$invalidated_early_key" != "$seed_early_key" ]] || {
    echo "core_checkpoint_cache_gate.sh: source mutation reused a checkpoint key" >&2
    exit 1
}

# Remove the completed whole result, then make one checkpoint artifact a
# symlink. Both the early alias and full-key validation must retire it before a
# normal rebuild, and the rebuilt output must remain byte-identical.
rm -f -- "$cache/aliases/$seed_early_key"
rm -rf -- "${cache:?}/results/$seed_key"
rm -f -- "$cache/checkpoints/$seed_key/artifacts/report.head"
ln -s module.native-program \
    "$cache/checkpoints/$seed_key/artifacts/report.head"
write_fixture 1
run_build "$work/out-corrupt" "$work/corrupt"
grep -Fqx "beagle build: core-checkpoint-alias CORRUPT $seed_early_key; retiring" \
    "$work/corrupt.stderr" || {
    echo "core_checkpoint_cache_gate.sh: symlink checkpoint alias was not retired" >&2
    exit 1
}
grep -Fqx "beagle build: core-checkpoint CORRUPT $seed_key; retiring" \
    "$work/corrupt.stderr" || {
    echo "core_checkpoint_cache_gate.sh: symlink checkpoint was not retired" >&2
    exit 1
}
[[ "$(tree_digest "$work/out-cold")" == "$(tree_digest "$work/out-corrupt")" ]] || {
    echo "core_checkpoint_cache_gate.sh: corruption recovery changed outputs" >&2
    exit 1
}

# The legacy module.native-program identity is deliberately lossy. Make every
# shell-level hash and marker internally consistent around those old bytes; the
# wire decoder must still reject and retire the entry before materialization.
rm -f -- "$cache/aliases/$seed_early_key"
rm -rf -- "${cache:?}/results/$seed_key"
checkpoint_entry="$cache/checkpoints/$seed_key"
cp -- "$checkpoint_entry/artifacts/module.native-program" \
    "$checkpoint_entry/artifacts/frozen-native-stage.wire-v1"
(
    cd "$checkpoint_entry/artifacts"
    find . -mindepth 1 -maxdepth 1 -type f -printf '%P\0' |
        LC_ALL=C sort -z |
        xargs -0 -r sha256sum
) >"$checkpoint_entry/artifacts.sha256"
legacy_manifest_digest="$(sha256sum "$checkpoint_entry/artifacts.sha256" |
    awk '{print $1}')"
printf 'beagle-core-pre-materializer/v1 %s %s\n' "$seed_key" \
    "$legacy_manifest_digest" >"$checkpoint_entry/READY"

run_build_failure "$work/out-legacy" "$work/legacy"
grep -Fqx "beagle build: core-checkpoint-alias HIT $seed_early_key -> $seed_key" \
    "$work/legacy.stderr" || {
    echo "core_checkpoint_cache_gate.sh: legacy probe did not pass shell validation" >&2
    exit 1
}
grep -Fqx "beagle build: core-checkpoint CORRUPT $seed_key; retiring" \
    "$work/legacy.stderr" || {
    echo "core_checkpoint_cache_gate.sh: legacy lossy bytes reached materialization" >&2
    exit 1
}
[[ ! -e "$cache/checkpoints/$seed_key" &&
   ! -e "$cache/checkpoint-aliases/$seed_early_key" &&
   ! -e "$cache/results/$seed_key" ]] || {
    echo "core_checkpoint_cache_gate.sh: legacy rejection left reusable cache state" >&2
    exit 1
}

echo "core checkpoint cache: failpoint seed, resume, invalidation, corruption recovery, legacy rejection, byte identity PASS"
