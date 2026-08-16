#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-host-context.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT
exec 3>&2

die() {
  echo "host-context: $*" >&2
  exit 1
}

for command in cc rg sed sort unshare; do
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

  echo "host-context: $phase START deadline=${deadline}s" >&3
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
      echo "host-context: $phase PASS status=0" >&3
      return 0
    fi
    echo "host-context: $phase SEMANTIC-REJECTION child-status=$status" >&3
    return 1
  fi
  die "$phase SETUP-FAILURE invalid receipt '$outcome' observed=$status"
}

mkdir -p "$scratch/context-c17" "$scratch/context-qbe" "$scratch/exec-qbe"

run_phase typed-source-check 45 \
  "$repo/bin/beagle" check --agent \
  "$here/host_context_probe.bgl" \
  "$here/context_only_probe.bgl" \
  "$here/exec_only_probe.bgl"

run_phase c17-materialization 180 \
  "$repo/bin/beagle" build --materializer c17 \
  --out "$scratch/context-c17" "$here/host_context_probe.bgl"

report="$scratch/context-c17/report.txt"
rg -Fx 'stage typed-to-native COMPLETE' "$report" >/dev/null \
  || die "host context probe did not lower"
[[ "$(rg -c '^obligation-projection PASS ' "$report")" == "10" ]] \
  || die "host context probe failed ten Native obligations"
rg -Fx 'materialize-c17 OK module_0.h module_0.c' "$report" >/dev/null \
  || die "host context probe did not materialize as C17"

mapfile -t actual_imports < <(
  rg -o 'native_host_[[:alnum:]_]+_v0[[:space:]]*\(' \
    "$scratch/context-c17/module_0.c" \
    | sed -E 's/[[:space:]]*\($//' | sort -u
)
expected_imports=(
  native_host_process_exec_replace_v0
  native_host_system_hostname_v0
  native_host_system_platform_v0
  native_host_terminal_stdout_tty_v0
)
[[ "$(printf '%s\n' "${actual_imports[@]}")" == \
   "$(printf '%s\n' "${expected_imports[@]}" | sort)" ]] \
  || die "C17 host imports were not exactly the four Group A symbols"

if run_phase context-qbe-refusal 180 \
    "$repo/bin/beagle" build --materializer qbe \
    --out "$scratch/context-qbe" "$here/context_only_probe.bgl" \
    >"$scratch/context-qbe.log" 2>&1; then
  die "QBE unexpectedly accepted host context"
fi
rg -Fx \
  'materialize-qbe REFUSED QBE host context extern ABI is unsupported: ambient host identity and terminal state have no QBE call representation' \
  "$scratch/context-qbe.log" >/dev/null \
  || die "QBE host context refusal changed"

if run_phase exec-qbe-refusal 180 \
    "$repo/bin/beagle" build --materializer qbe \
    --out "$scratch/exec-qbe" "$here/exec_only_probe.bgl" \
    >"$scratch/exec-qbe.log" 2>&1; then
  die "QBE unexpectedly accepted exec replacement"
fi
rg -Fx \
  'materialize-qbe REFUSED QBE exec-replacement extern ABI is unsupported: process image replacement has no QBE call representation' \
  "$scratch/exec-qbe.log" >/dev/null \
  || die "QBE exec replacement refusal changed"

strict=(-std=c17 -Wall -Wextra -Werror -pedantic)
run_phase generated-c17-strict-compile 45 \
  cc "${strict[@]}" -I"$repo/native-core/shim" \
  -I"$scratch/context-c17" -c "$scratch/context-c17/module_0.c" \
  -o "$scratch/context-module.o"
run_phase exec-helper-strict-build 45 \
  cc "${strict[@]}" "$here/replace_child.c" -o "$scratch/replace-child"
run_phase native-shim-strict-build 60 \
  cc "${strict[@]}" -I"$repo/native-core/shim" \
  "$here/shim_contract.c" "$repo/native-core/shim/native_shim.c" \
  -pthread -lm -o "$scratch/native-contract"
run_phase native-host-context-runtime 30 \
  "$scratch/native-contract" "$scratch/replace-child"
run_phase wasi-shim-strict-build 60 \
  cc "${strict[@]}" -D__wasi__ -I"$repo/native-core/shim" \
  "$here/shim_contract.c" "$repo/native-core/shim/native_shim.c" \
  -pthread -lm -o "$scratch/wasi-contract"
run_phase wasi-host-context-runtime 15 "$scratch/wasi-contract"

echo "host-context: strict source/C17/shim, ten obligations, imports, QBE refusals, native context/exec, and WASI pass"
