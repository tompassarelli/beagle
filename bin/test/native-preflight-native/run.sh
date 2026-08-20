#!/usr/bin/env bash
# NATIVE-PREFLIGHT-NATIVE: native Store validation with bounded supervision.
# shellcheck disable=SC2030,SC2031
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$root/native-core/validation/native-compiler-route.sh"

gate="NATIVE-PREFLIGHT-NATIVE"
kill_grace="${BEAGLE_NATIVE_PREFLIGHT_KILL_GRACE_SECONDS:-5}"
suite_deadline="${BEAGLE_NATIVE_PREFLIGHT_SUITE_DEADLINE_SECONDS:-180}"
store_deadline="${BEAGLE_NATIVE_PREFLIGHT_STORE_DEADLINE_SECONDS:-179}"
store_phase_deadline="${BEAGLE_NATIVE_PREFLIGHT_STORE_PHASE_DEADLINE_SECONDS:-165}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-native-preflight.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

for value in "$kill_grace" "$suite_deadline" "$store_deadline" "$store_phase_deadline"; do
  native_validation_positive_seconds "$value" preflight-deadline
done
if ((store_deadline >= 180)); then
  echo "$gate: Store deadline must remain strictly under three minutes" >&2
  exit 2
fi
if ((store_phase_deadline > store_deadline)); then
  echo "$gate: materialization deadline exceeds its Store gate deadline" >&2
  exit 2
fi
export BEAGLE_NATIVE_VALIDATION_KILL_GRACE_SECONDS="$kill_grace"

verify_success_receipts() {
  local receipt_root="$1" receipt count=0
  while IFS= read -r -d '' receipt; do
    count=$((count + 1))
    grep -Fqx 'subtree-reaped-v0 exit status=0' "$receipt" || {
      echo "$gate: supervisor receipt did not record a successful reap: $receipt" >&2
      return 1
    }
  done < <(find "$receipt_root" -type f -name '*.receipt' -print0 | LC_ALL=C sort -z)
  if [[ "$count" == 0 ]]; then
    echo "$gate: no supervisor receipts were produced under $receipt_root" >&2
    return 1
  fi
  echo "$gate: supervisor receipts PASS count=$count root=$receipt_root"
}

selector_contract() {
  # Passed by name to native_validation_select_binary.
  # shellcheck disable=SC2034
  local selected="" status
  echo "$gate: selector contract START"
  set +e
  (
    unset BEAGLE_NATIVE_COMPILER_BIN
    native_validation_select_binary selected
  )
  status=$?
  set -e
  [[ "$status" == 1 ]] || {
    echo "$gate: an unset selector did not preserve the Racket route" >&2
    exit 1
  }

  set +e
  (
    export BEAGLE_NATIVE_COMPILER_BIN=""
    native_validation_select_binary selected
  ) >"$scratch/empty-selector.stdout" 2>"$scratch/empty-selector.stderr"
  status=$?
  set -e
  [[ "$status" == 2 ]] || {
    echo "$gate: an explicitly empty selector did not fail closed" >&2
    exit 1
  }

  set +e
  (
    export BEAGLE_NATIVE_COMPILER_BIN=/bin/true
    native_validation_select_binary selected
  ) >"$scratch/mutable-selector.stdout" 2>"$scratch/mutable-selector.stderr"
  status=$?
  set -e
  [[ "$status" == 2 ]] || {
    echo "$gate: a non-compiler selector did not fail closed" >&2
    exit 1
  }

  for driver in \
    native-core/tests/source_freeze_checkout_path.sh \
    native-core/tests/source_freeze_native.sh \
    native-core/validation/slice-types-full/drive.sh \
    native-core/validation/slice-types-full/drive-native.sh \
    native-core/validation/slice-store/drive.sh \
    native-core/validation/slice-store/drive-native.sh \
    native-core/tests/determinism_gate.sh; do
    bash -n "$root/$driver"
  done
  echo "$gate: selector contract END unset=Racket explicit-invalid=refused"
}

supervisor_contract() {
  local receipt_root="$scratch/supervisor-contract" status
  echo "$gate: supervisor contract START"
  native_validation_run_phase normal-reap 5 "$receipt_root" \
    bash -c 'setsid sh -c "sleep 30" >/dev/null 2>&1 & exit 0'

  set +e
  native_validation_run_phase timeout-reap 1 "$receipt_root" \
    bash -c 'setsid sh -c "sleep 30" >/dev/null 2>&1 & wait'
  status=$?
  set -e
  [[ "$status" == 124 ]] || {
    echo "$gate: wedged-child probe returned status=$status, expected 124" >&2
    exit 1
  }
  grep -Fqx 'subtree-reaped-v0 timeout status=124' \
    "$receipt_root/timeout-reap.receipt"
  grep -Fqx 'subtree-reaped-v0 exit status=0' \
    "$receipt_root/normal-reap.receipt"
  echo "$gate: supervisor contract END normal+timeout reaping PASS"
}

run_emission_suites() {
  local suite slug receipt_root="$scratch/emission-receipts"
  local -a suites=(
    beagle-test/tests/emit.rkt
    beagle-test/tests/emit-clj-behavioral.rkt
    beagle-test/tests/emit-js.rkt
    beagle-test/tests/emit-js-behavioral.rkt
    beagle-test/tests/emit-nix.rkt
    beagle-test/tests/nix-emit-errors.rkt
    beagle-test/tests/emit-matrix.rkt
  )
  echo "$gate: focused emission suites START"
  for suite in "${suites[@]}"; do
    slug="$(printf '%s' "$suite" | tr '/.' '--')"
    # Expanded by the supervised child shell.
    # shellcheck disable=SC2016
    native_validation_run_phase "emission-$slug" "$suite_deadline" "$receipt_root" \
      bash -c 'source "$1/bin/_beagle-racket"; "$RACO" test "$1/$2"' \
        bash "$root" "$suite"
  done
  verify_success_receipts "$receipt_root"
  echo "$gate: focused emission suites END core+clj+js+nix PASS"
}

load_state() {
  local load_one mem_kib cores
  load_one="$(awk '{print $1}' /proc/loadavg)"
  mem_kib="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
  cores="$(nproc)"
  printf '%s %s %s\n' "$load_one" "$mem_kib" "$cores"
}

require_measurement_headroom() {
  local label="$1" state="$2" load_one mem_kib cores
  read -r load_one mem_kib cores <<<"$state"
  if ! awk -v load="$load_one" -v cores="$cores" \
      'BEGIN { exit !(load < (1.5 * cores)) }'; then
    echo "$gate: $label timing refused: load1=$load_one cores=$cores" >&2
    return 2
  fi
  if ((mem_kib < 8388608)); then
    echo "$gate: $label timing refused: MemAvailable=${mem_kib}KiB" >&2
    return 2
  fi
}

run_source_freeze() {
  local receipt_root="$scratch/source-freeze-receipts"
  echo "$gate: source-freeze native path START"
  native_validation_run_phase source-freeze-path 300 "$receipt_root" \
    env BEAGLE_NATIVE_COMPILER_BIN="$native_bin" \
      BEAGLE_NATIVE_VALIDATION_RECEIPT_DIR="$receipt_root/driver" \
      bash "$root/native-core/tests/source_freeze_checkout_path.sh"
  verify_success_receipts "$receipt_root"
  echo "$gate: source-freeze native path END"
}

run_store_gate() {
  local label="$1" module="$2"
  local receipt_root="$scratch/$label-receipts"
  local start_state end_state started_ns ended_ns seconds
  start_state="$(load_state)"
  require_measurement_headroom "$label" "$start_state"
  started_ns="$(date +%s%N)"
  native_validation_run_phase "$label-gate" "$store_deadline" "$receipt_root" \
      env BEAGLE_NATIVE_COMPILER_BIN="$native_bin" \
      BEAGLE_GATE_CACHE_INNER=1 \
      BEAGLE_NATIVE_VALIDATION_SUPERVISED=1 \
      BEAGLE_NATIVE_VALIDATION_PHASE_DEADLINE_SECONDS="$store_phase_deadline" \
      NATIVE_DETERMINISM_RECEIPT_ROOT="$receipt_root/materializations" \
      bash "$root/native-core/tests/determinism_gate.sh" --module "$module"
  ended_ns="$(date +%s%N)"
  seconds=$(((ended_ns - started_ns + 999999999) / 1000000000))
  end_state="$(load_state)"
  if ((seconds >= 180)); then
    echo "$gate: $label exceeded the strict three-minute bound: ${seconds}s" >&2
    exit 1
  fi
  verify_success_receipts "$receipt_root"
  echo "$gate: $label PASS seconds=$seconds load-start=[$start_state] load-end=[$end_state]"
  printf '%s\n' "$seconds" >"$scratch/$label.seconds"
}

run_reference_sample() {
  local label module receipt_root
  echo "$gate: sampled Racket reference START"
  for row in 'store-types-full slice-types-full' 'store-closure slice-store'; do
    read -r label module <<<"$row"
    receipt_root="$scratch/reference-$label-receipts"
    native_validation_run_phase "reference-$label" 1200 "$receipt_root" \
      env -u BEAGLE_NATIVE_COMPILER_BIN \
        BEAGLE_GATE_CACHE_INNER=1 \
        BEAGLE_NATIVE_VALIDATION_SUPERVISED=1 \
        BEAGLE_NATIVE_VALIDATION_PHASE_DEADLINE_SECONDS=600 \
        NATIVE_DETERMINISM_RECEIPT_ROOT="$receipt_root/materializations" \
        bash "$root/native-core/tests/determinism_gate.sh" --module "$module"
    verify_success_receipts "$receipt_root"
  done
  echo "$gate: sampled Racket reference END identical artifacts PASS"
}

case "${1:-}" in
  "") ;;
  --reference-sample)
    supervisor_contract
    run_reference_sample
    exit 0
    ;;
  *)
    echo "$gate: usage: run.sh [--reference-sample]" >&2
    exit 2
    ;;
esac

selector_contract
native_bin=""
if [[ "${BEAGLE_NATIVE_COMPILER_BIN+x}" == x ]]; then
  native_validation_select_binary native_bin || exit $?
fi
supervisor_contract
run_emission_suites

if [[ -z "$native_bin" ]]; then
  echo "$gate: pre-binary assertions PASS; source-freeze native selection, both Store artifact/verdict runs, native timings, and their receipts await BEAGLE_NATIVE_COMPILER_BIN" >&2
  exit 2
fi

run_source_freeze
run_store_gate store-types-full slice-types-full
run_store_gate store-closure slice-store
echo "$gate: PASS store-types-full=$(<"$scratch/store-types-full.seconds")s store-closure=$(<"$scratch/store-closure.seconds")s"
