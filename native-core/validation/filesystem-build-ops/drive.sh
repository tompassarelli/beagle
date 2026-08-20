#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-filesystem-build-ops.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT
exec 3>&2

die() {
  echo "filesystem-build-ops: $*" >&2
  exit 1
}

for command in bb cc cp rg sed sort unshare; do
  command -v "$command" >/dev/null 2>&1 || die "missing command: $command"
done

source "$repo/bin/_beagle-racket"
supervisor="$repo/native-core/bin/run-bounded.rkt"
unshare_bin="$(command -v unshare)"

run_phase() {
  local phase="$1"
  local deadline="$2"
  shift 2
  local receipt="$scratch/$phase.receipt"
  local status
  local outcome

  echo "filesystem-build-ops: $phase START deadline=${deadline}s" >&3
  set +e
  BEAGLE_BOUNDED_COMPLETION_RECEIPT="$receipt" \
    "$unshare_bin" --user --map-current-user --pid --fork --kill-child \
      "$RACKET" "$supervisor" "$deadline" 5 -- "$@"
  status=$?
  set -e
  [[ -f "$receipt" ]] \
    || die "$phase SETUP-FAILURE status=2 observed=$status"
  outcome="$(<"$receipt")"
  if [[ "$outcome" == "subtree-reaped-v0 timeout status=124" && \
        "$status" -eq 124 ]]; then
    die "$phase TIMEOUT status=124"
  fi
  if [[ "$outcome" =~ ^subtree-reaped-v0\ exit\ status=([0-9]+)$ && \
        "${BASH_REMATCH[1]}" -eq "$status" ]]; then
    if [[ "$status" -eq 0 ]]; then
      echo "filesystem-build-ops: $phase PASS status=0" >&3
      return 0
    fi
    echo "filesystem-build-ops: $phase SEMANTIC-REJECTION child-status=$status" >&3
    return 1
  fi
  die "$phase SETUP-FAILURE invalid receipt '$outcome' observed=$status"
}

mkdir -p \
  "$scratch/current-selfhost" \
  "$scratch/source-c17" \
  "$scratch/source-qbe" \
  "$scratch/exe-artifacts" \
  "$scratch/runtime"

run_phase oracle-source-check 45 \
  "$repo/bin/beagle" check --agent "$here/filesystem_build_ops_probe.bgl"

run_phase current-selfhost-build 180 \
  "$repo/bin/beagle-build-all" "$repo/self-host/src/selfhost" \
  --out "$scratch/current-selfhost"
cp "$repo/self-host/src/selfhost/rt.clj" \
  "$scratch/current-selfhost/selfhost/rt.clj"
run_phase current-selfhost-source-check 45 \
  bb -cp "$scratch/current-selfhost" -m selfhost.main \
  check --target core "$here/filesystem_build_ops_probe.bgl"

run_phase c17-materialization 300 \
  "$repo/bin/beagle" build --materializer c17 \
  --out "$scratch/source-c17" "$here/filesystem_build_ops_probe.bgl"

report="$scratch/source-c17/report.txt"
rg -Fx 'stage typed-to-native COMPLETE' "$report" >/dev/null \
  || die "typed filesystem build operations did not lower"
[[ "$(rg -c '^obligation-projection PASS ' "$report")" == "10" ]] \
  || die "typed filesystem build operations failed ten Native obligations"
rg -Fx 'materialize-c17 OK module_0.h module_0.c' "$report" >/dev/null \
  || die "typed filesystem build operations did not materialize as C17"

mapfile -t actual_imports < <(
  rg -o 'native_host_filesystem_[[:alnum:]_]+_v0[[:space:]]*\(' \
    "$scratch/source-c17/module_0.c" \
    | sed -E 's/[[:space:]]*\($//' | sort -u
)
expected_imports=(
  native_host_filesystem_create_temporary_sibling_v0
  native_host_filesystem_mtime_nanoseconds_v0
  native_host_filesystem_remove_file_v0
  native_host_filesystem_rename_file_v0
)
[[ "$(printf '%s\n' "${actual_imports[@]}")" == \
   "$(printf '%s\n' "${expected_imports[@]}" | sort)" ]] \
  || die "C17 host imports were not exactly the four build operations"

if run_phase qbe-explicit-refusal 300 \
    "$repo/bin/beagle" build --materializer qbe \
    --out "$scratch/source-qbe" "$here/filesystem_build_ops_probe.bgl" \
    >"$scratch/source-qbe.log" 2>&1; then
  die "QBE unexpectedly accepted filesystem build operations"
fi
rg -Fx \
  'materialize-qbe REFUSED QBE filesystem extern ABI is unsupported: typed host outcomes have no QBE call representation' \
  "$scratch/source-qbe.log" >/dev/null \
  || die "QBE filesystem refusal changed"

strict=(-std=c17 -Wall -Wextra -Werror -pedantic)
run_phase generated-c17-strict-compile 45 \
  cc "${strict[@]}" -I"$repo/native-core/shim" \
  -I"$scratch/source-c17" -c "$scratch/source-c17/module_0.c" \
  -o "$scratch/source-module.o"
run_phase native-shim-strict-build 60 \
  cc "${strict[@]}" -I"$repo/native-core/shim" \
  "$here/shim_contract.c" "$repo/native-core/shim/native_shim.c" \
  -pthread -lm -o "$scratch/native-contract"
run_phase native-shim-runtime 30 \
  "$scratch/native-contract" "$scratch/runtime/shim-target.txt"
run_phase wasi-shim-strict-build 60 \
  cc "${strict[@]}" -D__wasi__ -I"$repo/native-core/shim" \
  "$here/shim_contract.c" "$repo/native-core/shim/native_shim.c" \
  -pthread -lm -o "$scratch/wasi-contract"
run_phase wasi-explicit-refusal 15 "$scratch/wasi-contract"

printf '%s\n' old >"$scratch/runtime/source-target.txt"
run_phase native-executable-build 300 \
  "$repo/bin/beagle-native-exe" \
  --out "$scratch/filesystem-build-ops-probe" \
  --artifacts "$scratch/exe-artifacts" \
  --entry native.filesystem-build-ops-probe/probe \
  -- "$here/filesystem_build_ops_probe.bgl"
run_phase typed-source-runtime 30 \
  "$scratch/filesystem-build-ops-probe" "$scratch/runtime/source-target.txt"
[[ ! -e "$scratch/runtime/source-target.txt" ]] \
  || die "typed source did not remove the published target"

echo "filesystem-build-ops: oracle and current self-host checks, C17 lowering, ten obligations, exact imports, QBE refusal, strict native/WASI shims, atomic replacement, mtime, cleanup, and typed source runtime pass"
