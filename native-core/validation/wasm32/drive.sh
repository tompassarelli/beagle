#!/usr/bin/env bash
# Runs two Native Core corpora through the wasm32 ABI profile: materialize with
# NATIVE_SLICE_ABI=wasm32, compile with the wasi clang at -std=c17 -pedantic
# -Wall -Wextra -Werror and ZERO -D layout gates, link, run under wasmtime.
# The emitted _Static_assert wall is the per-target enforcement instrument.
# slice-union carries the value descriptor channel (native_value_equal/hash/
# compare over an Any whose Pair variant is a reference), which traps in the
# shim when a descriptor size disagrees with sizeof(void *).
# Toolchain, declared: BEAGLE_WASI_CC (or WASI_CC), WASMTIME, and wasm-ld on
# PATH (the clang wrapper spawns it by bare name). The supported flake devshell
# supplies all three and sets BEAGLE_WASI=1; a missing component there is a hard
# failure. Outside that environment, absence remains a named diagnostic skip.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
artifacts="${NATIVE_SLICE_ARTIFACTS:-}"
work="$(mktemp -d "${TMPDIR:-/tmp}/native-wasm32.XXXXXX")"
[[ -n "$artifacts" ]] || artifacts="$work/artifacts"
trap 'rm -rf "${work:?}"' EXIT
mkdir -p "$artifacts"

die() {
  echo "wasm32/drive.sh: $*" >&2
  exit 1
}

skip() {
  echo "SKIP: wasm32: $*"
  exit 0
}

missing-tool() {
  if [[ "${BEAGLE_WASI:-}" == 1 ]]; then
    die "$*"
  fi
  skip "$*"
}

cc="${BEAGLE_WASI_CC:-${WASI_CC:-}}"
[[ -n "$cc" && -x "$cc" ]] \
  || missing-tool "no wasm32-wasi clang; set BEAGLE_WASI_CC (or WASI_CC) to an executable"
wasmtime="${WASMTIME:-$(command -v wasmtime || true)}"
[[ -n "$wasmtime" && -x "$wasmtime" ]] \
  || missing-tool "no wasmtime; set WASMTIME to an executable"
command -v wasm-ld >/dev/null 2>&1 \
  || missing-tool "no wasm-ld on PATH; the wasi clang wrapper spawns it by bare name"
for command in bb cmp sha256sum; do
  command -v "$command" >/dev/null 2>&1 \
    || die "required command is unavailable: $command"
done

strict=(-std=c17 -pedantic -Wall -Wextra -Werror)
shim="$repo/native-core/shim"

materialize() { # materialize <corpus> <outdir>
  local corpus="$1" outdir="$2"
  mkdir -p "$outdir"
  NATIVE_SLICE_ABI=wasm32 NATIVE_SLICE_NO_COMPILE=1 \
    NATIVE_SLICE_ARTIFACTS="$outdir" \
    "$repo/native-core/validation/$corpus/drive.sh" >"$outdir/drive.log" 2>&1 \
    || { sed -n '1,80p' "$outdir/drive.log" >&2; die "$corpus did not materialize at wasm32"; }
}

# Two independent materializations of the same corpus must be byte-identical.
determinism() { # determinism <corpus> <name>
  local corpus="$1" name="$2" file first_pid second_pid failed=0
  materialize "$corpus" "$work/$name-a" &
  first_pid=$!
  materialize "$corpus" "$work/$name-b" &
  second_pid=$!
  wait "$first_pid" || failed=1
  wait "$second_pid" || failed=1
  [[ "$failed" -eq 0 ]] || die "$corpus parallel materialization failed"
  for file in module_0.h module_0.c; do
    cmp -s "$work/$name-a/$file" "$work/$name-b/$file" \
      || die "$corpus re-emission is not byte-identical for $file"
  done
}

build_and_run() { # build_and_run <name> <srcdir> <main.c> [extra cc flags...]
  local name="$1" srcdir="$2" main="$3"; shift 3
  local build="$work/$name-c"
  mkdir -p "$build"
  cp "$srcdir/module_0.h" "$srcdir/module_0.c" "$main" "$build/"
  cp "$shim/native_shim.c" "$shim/native_shim.h" "$shim/native_unicode15_data.h" \
    "$build/"
  ( cd "$build" && "$cc" "${strict[@]}" "$@" -o "$name.wasm" \
      module_0.c native_shim.c "$(basename "$main")" ) \
    || die "$name did not compile clean at wasm32 with zero -D gates"
  "$wasmtime" run "$build/$name.wasm" \
    || die "$name did not run to exit 0 under wasmtime"
  cp "$build/$name.wasm" "$work/$name.wasm"
  echo "wasm32/drive.sh: $name strict compile + wasmtime run ok"
}

# ---- independent deterministic materializations ---------------------------
determinism slice-fold fold &
fold_determinism_pid=$!
determinism slice-union union &
union_determinism_pid=$!
determinism_failed=0
wait "$fold_determinism_pid" || determinism_failed=1
wait "$union_determinism_pid" || determinism_failed=1
[[ "$determinism_failed" -eq 0 ]] \
  || die "parallel fold/union determinism materialization failed"

# ---- slice-fold: generated probe main, arena round trip -------------------
fold_asserts="$(grep -c '_Static_assert' "$work/fold-a/module_0.h")"
[[ "$fold_asserts" -gt 0 ]] || die "slice-fold emitted no layout assertions"
grep -q '_Static_assert(sizeof(native_m0_type_0) == 4' "$work/fold-a/module_0.h" \
  || die "slice-fold layout is not wasm32-measured"
build_and_run slice_fold "$work/fold-a" "$work/fold-a/main.c"

# ---- slice-union: value descriptor channel over a reference ---------------
union_header="$work/union-a/module_0.h"
union_report="$work/union-a/report.txt"
function_index() { # function_index <source-name>
  local function="$1"
  awk -v fn_name="$function" \
    '$1 == "lowered" && $2 ~ /^fn_[0-9]+$/ && $3 == fn_name {
       sub(/^fn_/, "", $2)
       print $2
       found = 1
       exit
     }
     END { exit !found }' \
    "$union_report"
}
any_function="$(function_index wrap-int)"
nil_function="$(function_index logic-empty-or)"
pair_function="$(function_index pair-copy-of)"
any_type="$(sed -nE \
  "s/^(native_m0_type_[0-9]+) native_m0_fn_${any_function}\\(.*/\\1/p" \
  "$union_header")"
nil_type="$(sed -nE \
  "s/^(native_m0_type_[0-9]+) native_m0_fn_${nil_function}\\(.*/\\1/p" \
  "$union_header")"
pair_type="$(sed -nE \
  "s/^(native_m0_type_[0-9]+) native_m0_fn_${pair_function}\\(.*/\\1/p" \
  "$union_header")"
[[ -n "$any_type" && -n "$nil_type" && -n "$pair_type" ]] \
  || die "could not read the union probe types out of the wasm32 header"
mapfile -t source_functions \
  < <(sed -nE 's/^\(defn ([^ ]+).*/\1/p' \
    "$repo/native-core/validation/slice-union/fixture.bgl")
function_definitions=()
for old_index in "${!source_functions[@]}"; do
  current_index="$(function_index "${source_functions[$old_index]}")" \
    || die "lowered function missing for wasm32 C harness: ${source_functions[$old_index]}"
  function_definitions+=("-DSLICE_FN_${old_index}=native_m0_fn_${current_index}")
done
build_and_run slice_union "$work/union-a" \
  "$repo/native-core/validation/slice-union/main.c" \
  "-DSLICE_ANY_TYPE=$any_type" "-DSLICE_NIL_TYPE=$nil_type" \
  "-DSLICE_PAIR_TYPE=$pair_type" "${function_definitions[@]}"

# QBE materializes LP64 only and must say so by name rather than emit or crash.
refusal='qbe-materialize REFUSED abi profile wasm32: qbe materializes lp64 only'
grep -Fqx "$refusal" "$work/union-a/report.txt" \
  || { grep -F 'qbe-materialize' "$work/union-a/report.txt" >&2 || true
       die "the wasm32 program did not draw the named QBE refusal"; }
echo "wasm32/drive.sh: QBE refused the wasm32 program by name"

# ---- TransientVec: two loop-owned builders through the public entry seam --
transient_source="$here/transient_vec_two_owner.bgl"
transient_entry="native.wasm32-transient-vec/two-owner-loop"
transient_export="beagle_wasm_entry_v1__native_wasm32_transient_vec__two_owner_loop"
transient_artifacts="$work/transient-vec"
transient_log="$work/transient-vec.log"
if ! "$repo/bin/beagle" build --materializer wasm --abi wasm32 \
    --entry "$transient_entry" --out "$transient_artifacts" \
    "$transient_source" >"$transient_log" 2>&1; then
  sed -n '1,160p' "$transient_log" >&2
  die "two-owner TransientVec entry did not build and run at wasm32"
fi
transient_report="$transient_artifacts/report.txt"
for expected in \
  'stage typed-to-native COMPLETE' \
  "wasm-entry-contract PASS $transient_entry source-ast-to-lowered-header" \
  "wasm-entry-export $transient_entry $transient_export" \
  "wasm-entry-lowered-abi $transient_entry arena+capability" \
  "wasm-entry-result $transient_entry 0" \
  'wasm-determinism PASS repeated-identical-build' \
  'wasm-validation PASS source-entries-invoked' \
  'result PASS'; do
  grep -Fqx "$expected" "$transient_report" \
    || die "two-owner TransientVec report is missing: $expected"
done
[[ "$(grep -c '^obligation-projection PASS ' "$transient_report")" -eq 10 ]] \
  || die "two-owner TransientVec program did not pass all ten obligations"
[[ -s "$transient_artifacts/module_0.wasm" ]] \
  || die "two-owner TransientVec build published no Wasm module"
echo "wasm32/drive.sh: two-owner TransientVec entry build + run ok"

# ---- seam report + materialization digests --------------------------------
mkdir -p "$artifacts"
for name in slice_fold slice_union; do
  bb "$here/seams.clj" "$work/$name.wasm" >"$work/$name.seams"
  cp "$work/$name.seams" "$artifacts/$name.seams"
done

{
  ( cd "$work/fold-a" && sha256sum module_0.h module_0.c main.c \
      | sed 's|$| slice-fold|' )
  ( cd "$work/union-a" && sha256sum module_0.h module_0.c | sed 's|$| slice-union|' )
} >"$work/determinism.txt"
cp "$work/determinism.txt" "$artifacts/determinism.txt"

echo "wasm32/drive.sh: slice-fold and slice-union PASS at the wasm32 ABI profile"
