#!/usr/bin/env bash
set -euo pipefail

store_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
manifest_dir="$store_root/build/generated-targets.d"
ungenerated="$store_root/build/ungenerated-out.tsv"

fail() {
  echo "generated targets manifest test: FAIL: $*" >&2
  exit 1
}

assert_beagle_route() {
  local source="$1"
  local destination="$2"
  local -a matches=()

  mapfile -t matches < <(
    awk -F '\t' -v source="$source" -v destination="$destination" \
      '$2 == source || $3 == destination { print $1 "\t" $2 "\t" $3 }' \
      "$manifest_dir"/*.tsv
  )
  [[ "${#matches[@]}" == 1 ]] ||
    fail "$source and $destination must form one unique generation route"
  [[ "${matches[0]}" == $'beagle\t'"$source"$'\t'"$destination" ]] ||
    fail "$source must compile through Beagle to $destination"
  ! awk -F '\t' -v destination="$destination" \
    '$1 == destination { found = 1 } END { exit !found }' "$ungenerated" ||
    fail "$destination is generated and must not be declared ungenerated"
}

assert_beagle_route \
  "src/store/dev_compile_facts.bclj" \
  "out/store/dev_compile_facts.clj"
assert_beagle_route \
  "src/store/gate_facts.bclj" \
  "out/store/gate_facts.clj"

echo "generated targets manifest test: PASS"
