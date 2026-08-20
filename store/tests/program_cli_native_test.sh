#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-program-cli-native.XXXXXX")"
cleanup() { rm -rf "${scratch:?}"; }
trap cleanup EXIT

executable="$scratch/beagle-program-native"
"$repo/bin/beagle-native-exe" \
  --out "$executable" \
  --artifacts "$scratch/artifacts" \
  --entry store.program-cli/main \
  "$repo/store/src/store/program_cli.bgl" \
  >"$scratch/build.log"

valid_cases=(
  'space|program.storelog|inspect|root|0'
  'space|program.storelog|definition|root|7|same-name'
  'space|program.storelog|references|root|7|:binding-a'
  'space|program.storelog|impact|root|7|:binding-a'
  'space|program.storelog|history|root|7|[:binding-a :named "same-name"]'
  'space|program.storelog|rename|root|7|:binding-a|renamed|--preview'
  'space|program.storelog|rename|root|7|:binding-a|renamed|--commit'
)

for encoded in "${valid_cases[@]}"; do
  IFS='|' read -r -a argv <<<"$encoded"
  "$executable" "${argv[@]}"
done

set +e
"$executable" space program.storelog rename root 7 :binding-a renamed --apply \
  >"$scratch/invalid.stdout" 2>"$scratch/invalid.stderr"
invalid_status=$?
set -e

[[ "$invalid_status" == 64 ]]
[[ ! -s "$scratch/invalid.stdout" ]]
grep -Fqx \
  '       beagle program SPACE_ID LOG_PATH rename ROOT VERSION BINDING NEW --preview|--commit' \
  "$scratch/invalid.stderr"
grep -Eq \
  '^native-exe-entry PASS name=store\.program-cli/main symbol=native_m0_fn_[0-9]+ return=Int abi=arena\+capability args=vec-string$' \
  "$scratch/artifacts/native-exe.report.txt"

printf 'program CLI native argv seam: PASS\n'
