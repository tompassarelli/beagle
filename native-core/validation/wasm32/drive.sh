#!/usr/bin/env bash
# Runs two Native Core corpora through the wasm32 ABI profile: materialize with
# NATIVE_SLICE_ABI=wasm32, compile with the wasi clang at -std=c17 -pedantic
# -Wall -Wextra -Werror and ZERO -D layout gates, link, run under wasmtime.
# The emitted _Static_assert wall is the per-target enforcement instrument.
# slice-union carries the value descriptor channel (native_value_equal/hash/
# compare over an Any whose Pair variant is a reference), which traps in the
# shim when a descriptor size disagrees with sizeof(void *). It stands in for
# slice-rt-core, which cannot run here without per-ABI goldens and a wasm
# managed-oracle comparison.
# Toolchain, declared: BEAGLE_WASI_CC (or WASI_CC), WASMTIME, and wasm-ld on
# PATH (the clang wrapper spawns it by bare name). The supported flake devshell
# supplies all three and sets BEAGLE_WASI=1; a missing component there is a hard
# failure. Outside that environment, absence remains a named diagnostic skip.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SLICE_REPO:-$(cd "$here/../../.." && pwd)}"
artifacts="${NATIVE_SLICE_ARTIFACTS:-$here}"
work="$(mktemp -d "${TMPDIR:-/tmp}/native-wasm32.XXXXXX")"
trap 'rm -rf "${work:?}"' EXIT

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
  local corpus="$1" name="$2" file
  materialize "$corpus" "$work/$name-a"
  materialize "$corpus" "$work/$name-b"
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

# ---- slice-fold: generated probe main, arena round trip -------------------
determinism slice-fold fold
fold_asserts="$(grep -c '_Static_assert' "$work/fold-a/module_0.h")"
[[ "$fold_asserts" -gt 0 ]] || die "slice-fold emitted no layout assertions"
grep -q '_Static_assert(sizeof(native_m0_type_0) == 4' "$work/fold-a/module_0.h" \
  || die "slice-fold layout is not wasm32-measured"
build_and_run slice_fold "$work/fold-a" "$work/fold-a/main.c"

# ---- slice-union: value descriptor channel over a reference ---------------
determinism slice-union union
union_header="$work/union-a/module_0.h"
any_type="$(sed -nE 's/^(native_m0_type_[0-9]+) native_m0_fn_1\(.*/\1/p' "$union_header")"
nil_type="$(sed -nE 's/^(native_m0_type_[0-9]+) native_m0_fn_15\(.*/\1/p' "$union_header")"
pair_type="$(sed -nE 's/^(native_m0_type_[0-9]+) native_m0_fn_7\(.*/\1/p' "$union_header")"
[[ -n "$any_type" && -n "$nil_type" && -n "$pair_type" ]] \
  || die "could not read the union probe types out of the wasm32 header"
build_and_run slice_union "$work/union-a" \
  "$repo/native-core/validation/slice-union/main.c" \
  "-DSLICE_ANY_TYPE=$any_type" "-DSLICE_NIL_TYPE=$nil_type" \
  "-DSLICE_PAIR_TYPE=$pair_type"

# QBE materializes LP64 only and must say so by name rather than emit or crash.
refusal='qbe-materialize REFUSED abi profile wasm32: qbe materializes lp64 only'
grep -Fqx "$refusal" "$work/union-a/report.txt" \
  || { grep -F 'qbe-materialize' "$work/union-a/report.txt" >&2 || true
       die "the wasm32 program did not draw the named QBE refusal"; }
echo "wasm32/drive.sh: QBE refused the wasm32 program by name"

# ---- committed seam ledger + determinism digests --------------------------
mkdir -p "$artifacts"
for name in slice_fold slice_union; do
  bb "$here/seams.clj" "$work/$name.wasm" >"$work/$name.seams"
  if [[ -f "$here/$name.seams" && "${NATIVE_WASM32_UPDATE:-0}" != 1 ]]; then
    diff -u "$here/$name.seams" "$work/$name.seams" \
      || die "$name host seam changed: every import and export is a committed claim"
  fi
  cp "$work/$name.seams" "$artifacts/$name.seams"
done

{
  ( cd "$work/fold-a" && sha256sum module_0.h module_0.c main.c \
      | sed 's|$| slice-fold|' )
  ( cd "$work/union-a" && sha256sum module_0.h module_0.c | sed 's|$| slice-union|' )
} >"$work/determinism.txt"
if [[ -f "$here/determinism.txt" && "${NATIVE_WASM32_UPDATE:-0}" != 1 ]]; then
  diff -u "$here/determinism.txt" "$work/determinism.txt" \
    || die "wasm32 emission drifted from the committed digests"
fi
cp "$work/determinism.txt" "$artifacts/determinism.txt"

echo "wasm32/drive.sh: slice-fold and slice-union PASS at the wasm32 ABI profile"
