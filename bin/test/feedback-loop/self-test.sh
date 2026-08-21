#!/usr/bin/env bash
# L0 contract evidence.  It copies the existing branch-corpus bytes but runs
# only tiny fake stages: no Store, Firn, or Core materialization occurs.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
runner="$here/run.sh"
fixture="$repo/bin/test/branch-compile-corpus/corpus/foundation.bgl"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-feedback-loop-self-test.XXXXXX")"

cleanup() {
  local status=$?
  rm -rf -- "${scratch:?}"
  return "$status"
}
trap cleanup EXIT

run_case() {
  local benchmark_class="$1"
  local root="$2"
  local input="$root/input/foundation.bgl"
  local materialized="$root/materialized"
  local record="$root/record.json"
  # shellcheck disable=SC2016
  # This exact text is evaluated by the child shell.
  local materialize_command='mkdir -p "$1"; printf "deterministic materialization\n" > "$1/module.c"'
  mkdir -p "$root/input"
  cp "$fixture" "$input"

  if [[ "$benchmark_class" == edit-diagnostic ]]; then
    "$runner" \
      --class "$benchmark_class" \
      --workload branch-corpus-feedback-v1 \
      --queue-ns 1234 \
      --input "corpus/foundation.bgl=$input" \
      --semantic stage-log:diagnostic \
      --materialization none \
      --output "$record" \
      --stage diagnostic --expect-exit 7 -- \
        bash -c 'printf "BEAGLE-DEMO-DIAGNOSTIC\n"; exit 7'
  else
    "$runner" \
      --class "$benchmark_class" \
      --workload branch-corpus-feedback-v1 \
      --queue-ns 1234 \
      --input "corpus/foundation.bgl=$input" \
      --semantic stage-log:semantic \
      --materialization "output=$materialized" \
      --output "$record" \
      --stage semantic -- \
        bash -c 'printf "checked semantic fixture\n"' \
      --next-stage --stage materialization -- \
        bash -c "$materialize_command" \
          feedback-loop "$materialized"
  fi
}

classes=(
  edit-diagnostic
  changed-function-module
  warm-large
  cold-full-closure
  no-op-identity
)
for benchmark_class in "${classes[@]}"; do
  run_case "$benchmark_class" "$scratch/first/$benchmark_class"
  run_case "$benchmark_class" "$scratch/second/$benchmark_class"
done

# Monotonic timing is expected to differ. The semantic/materialization/identity
# contract must not depend on which temporary directory held the copied bytes.
python3 - "$scratch" <<'PY'
import json, pathlib, sys

root = pathlib.Path(sys.argv[1])
classes = [
    "edit-diagnostic",
    "changed-function-module",
    "warm-large",
    "cold-full-closure",
    "no-op-identity",
]
for benchmark_class in classes:
    left = json.loads((root / "first" / benchmark_class / "record.json").read_text())
    right = json.loads((root / "second" / benchmark_class / "record.json").read_text())
    for record in (left, right):
        assert record["schema"] == "beagle.feedback-loop-benchmark/v1"
        assert record["benchmarkClass"] == benchmark_class
        assert record["result"]["status"] == "pass"
        assert record["workload"]["inputStable"] is True
        assert record["timing"]["queueNs"] == 1234
        assert record["timing"]["activeNs"] >= 0
        assert record["timing"]["stages"]
        assert record["semantic"]["identity"].startswith("sha256:")
        assert record["materialization"]["identity"].startswith("sha256:")
    for key in ("schema", "benchmarkClass", "workload", "semantic", "materialization", "result"):
        assert left[key] == right[key], (benchmark_class, key)
PY

# A command may succeed yet still be invalid evidence if it mutates its declared
# input. The runner must emit JSON and classify that observation as a failure.
cp "$fixture" "$scratch/mutated-input.bgl"
# shellcheck disable=SC2016
# This exact text is evaluated by the child shell.
mutation_command='printf "mutation observed\n"; printf "\n; forbidden mutation\n" >> "$1"'
set +e
"$runner" \
  --class changed-function-module \
  --workload branch-corpus-feedback-v1 \
  --input "corpus/foundation.bgl=$scratch/mutated-input.bgl" \
  --semantic stage-log:mutate \
  --materialization none \
  --output "$scratch/mutated-input.json" \
  --stage mutate -- \
    bash -c "$mutation_command" \
      feedback-loop "$scratch/mutated-input.bgl"
mutation_status=$?
set -e
[[ "$mutation_status" == 1 ]]

python3 - "$scratch/mutated-input.json" <<'PY'
import json, pathlib, sys
record = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert record["result"]["status"] == "fail"
assert record["workload"]["inputStable"] is False
PY

echo "feedback-loop self-test: PASS classes=5 equality=content-addressed input-mutation=rejected"
