#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-slice-transient-vec.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

fixture="$here/fixture.bgl"
artifacts="$scratch/c17"
build_log="$scratch/c17-build.log"
negative_fixture="$scratch/ownership-refusals.bgl"
negative_artifacts="$scratch/ownership-refusals-c17"
negative_log="$scratch/ownership-refusals.log"

die() {
  echo "slice-transient-vec/drive.sh: $*" >&2
  exit 1
}

for command in awk gcc rg timeout; do
  command -v "$command" >/dev/null 2>&1 \
    || die "required command is unavailable: $command"
done

if ! timeout --foreground --kill-after=10s 180s \
    "$repo/bin/beagle" build --materializer c17 --out "$artifacts" \
    "$fixture" >"$build_log" 2>&1; then
  sed -n '1,240p' "$build_log" >&2
  die "C17 build failed or exceeded 180s"
fi

report="$artifacts/report.txt"
for expected in \
  'stage source-to-typed ACCEPTED' \
  'stage typed-to-native COMPLETE' \
  'native-lowering-result NativeLoweringCompleteV0' \
  'materialize-c17 OK module_0.h module_0.c' \
  'result PASS'; do
  rg -Fx "$expected" "$report" >/dev/null \
    || die "build report is missing: $expected"
done
[[ "$(rg -c '^obligation-projection PASS ' "$report")" -eq 10 ]] \
  || die "Native program did not pass all ten obligations"
if rg -q '^pending ' "$report"; then
  rg '^pending ' "$report" >&2
  die "fixture left a Native lowering root"
fi

function_index() {
  local name="$1"
  awk -v name="$name" \
    '$1 == "lowered" && $3 == name { sub(/^fn_/, "", $2); print $2 }' \
    "$report"
}

build_index="$(function_index 'build-ordered!')"
copy_index="$(function_index 'copy-nonempty!')"
paired_index="$(function_index 'build-paired!')"
[[ "$build_index" =~ ^[0-9]+$ ]] \
  || die "build-ordered! function index is unresolved"
[[ "$copy_index" =~ ^[0-9]+$ ]] \
  || die "copy-nonempty! function index is unresolved"
[[ "$paired_index" =~ ^[0-9]+$ ]] \
  || die "build-paired! function index is unresolved"

gcc -std=c17 -pedantic -Wall -Wextra -Werror \
  -DBUILD_ORDERED_FN="native_m0_fn_$build_index" \
  -DCOPY_NONEMPTY_FN="native_m0_fn_$copy_index" \
  -I "$artifacts" "$artifacts/module_0.c" "$artifacts/native_shim.c" \
  "$here/main.c" -lm -o "$scratch/probe"
timeout --foreground --kill-after=2s 20s "$scratch/probe"

cat >"$negative_fixture" <<'BGL'
#lang beagle
(ns native.transient-vec-ownership-refusals)

(defrecord PairResult [(left (Vec Int)) (right (Vec Int))])
(def empty-ints (Vec Int) [])

(defn consume-owner! [(owner (TransientVec Int))] (Vec Int)
  [])

(defn alias-owner! [] PairResult
  (loop [(index Int) 0
         (left (TransientVec Int)) (transient empty-ints)
         (right (TransientVec Int)) (transient empty-ints)]
    (if (= index 1)
      (->PairResult (persistent! left) (persistent! right))
      (recur (+ index 1) (conj! left index) left))))

(defn borrow-owner! [(borrowed (TransientVec Int))] PairResult
  (loop [(index Int) 0
         (left (TransientVec Int)) (transient empty-ints)
         (right (TransientVec Int)) borrowed]
    (if (= index 1)
      (->PairResult (persistent! left) (persistent! right))
      (recur (+ index 1)
             (conj! left index)
             (conj! right index)))))

(defn escape-owner! [] PairResult
  (loop [(index Int) 0
         (left (TransientVec Int)) (transient empty-ints)
         (right (TransientVec Int)) (transient empty-ints)]
    (if (= index 1)
      (->PairResult (consume-owner! left) (persistent! right))
      (recur (+ index 1)
             (conj! left index)
             (conj! right index)))))

(defn stale-owner! [] PairResult
  (loop [(index Int) 0
         (left (TransientVec Int)) (transient empty-ints)
         (right (TransientVec Int)) (transient empty-ints)]
    (if (= index 1)
      (->PairResult (persistent! left) (persistent! right))
      (let [(next-left (TransientVec Int)) (conj! left index)]
        (recur (+ index 1) left (conj! right index))))))

(defn unconsumed-owner! [] (Vec Int)
  (loop [(index Int) 0
         (left (TransientVec Int)) (transient empty-ints)
         (right (TransientVec Int)) (transient empty-ints)]
    (if (= index 1)
      (persistent! left)
      (recur (+ index 1)
             (conj! left index)
             (conj! right index)))))

(defn double-close-owner! [] (Vec Int)
  (loop [(index Int) 0
         (left (TransientVec Int)) (transient empty-ints)
         (right (TransientVec Int)) (transient empty-ints)]
    (if (= index 1)
      (let [(closed-left (Vec Int)) (persistent! left)
            (closed-left-again (Vec Int)) (persistent! left)
            (closed-right (Vec Int)) (persistent! right)]
        closed-left-again)
      (recur (+ index 1)
             (conj! left index)
             (conj! right index)))))
BGL

set +e
timeout --foreground --kill-after=10s 180s \
  "$repo/bin/beagle" build --materializer c17 --out "$negative_artifacts" \
  "$negative_fixture" >"$negative_log" 2>&1
negative_status=$?
set -e
[[ $negative_status -ne 0 && $negative_status -ne 124 ]] \
  || die "invalid transient ownership did not fail closed"

for function in \
  alias-owner! \
  borrow-owner! \
  escape-owner! \
  stale-owner! \
  unconsumed-owner! \
  double-close-owner!; do
  rg -e "TODO-NATIVE-TRANSIENT-LOOP-OWNERSHIP:.*\\[$function\\]" \
    "$negative_log" >/dev/null \
    || { sed -n '1,240p' "$negative_log" >&2
         die "ownership refusal is missing for $function"; }
done
for refused_artifact in \
  module.native-program module.native-program.sha256 module_0.h module_0.c; do
  [[ ! -e "$negative_artifacts/$refused_artifact" ]] \
    || die "ownership refusal published $refused_artifact"
done

qbe_out="$scratch/qbe"
qbe_log="$scratch/qbe-build.log"
set +e
timeout --foreground --kill-after=5s 60s \
  "$repo/bin/beagle" build --materializer qbe --out "$qbe_out" \
  "$fixture" >"$qbe_log" 2>&1
qbe_status=$?
set -e
[[ $qbe_status -ne 0 && $qbe_status -ne 124 ]] \
  || die "QBE did not fail closed for TransientVec"
rg -e 'REFUSED .*QBE.*(TransientVec|transient vector)|QBE.*(TransientVec|transient vector).*unsupported' \
  "$qbe_log" >/dev/null \
  || die "QBE refusal did not identify unsupported TransientVec materialization"
[[ ! -e "$qbe_out/report.txt" && ! -e "$qbe_out/module_0.ssa" ]] \
  || die "refused QBE build published materialization artifacts"

echo "slice-transient-vec/drive.sh: C17 builder and QBE refusal checks passed"
