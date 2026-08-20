#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-program-cli-native.XXXXXX")"
phase=setup
cleanup() {
  local status=$?
  trap - EXIT TERM
  if (( status == 0 )); then
    rm -rf "${scratch:?}"
  else
    printf 'program CLI native Store vertical: DIAGNOSTIC phase=%s exit=%s artifacts=%s\n' \
      "$phase" "$status" "$scratch" >&2
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 124' TERM

program_executable="$scratch/beagle-program-native"
seed_executable="$scratch/beagle-program-seed-native"
store_log="$scratch/program.storelog"

build_native() {
  local entry="$1"
  local source="$2"
  local executable="$3"
  local artifacts="$4"
  timeout --foreground 120s "$repo/bin/beagle-native-exe" \
    --out "$executable" \
    --artifacts "$artifacts" \
    --entry "$entry" \
    --module-root "store/src=$repo/store/src" \
    --module-root "native-core/src=$repo/native-core/src" \
    "$source"
}

build_native_logged() {
  local build_phase="$1"
  local entry="$2"
  local source="$3"
  local executable="$4"
  local artifacts="$5"
  local log="$scratch/$build_phase.log"
  local status

  phase="$build_phase"
  set +e
  build_native "$entry" "$source" "$executable" "$artifacts" \
    >"$log" 2>&1
  status=$?
  set -e
  if (( status != 0 )); then
    printf 'program CLI native build: DIAGNOSTIC phase=%s exit=%s log=%s\n' \
      "$build_phase" "$status" "$log" >&2
    if [[ -s "$log" ]]; then
      sed -n '1,240p' "$log" >&2
    fi
    return "$status"
  fi
}

build_native_logged \
  fixture-build \
  store.program-cli-fixture/-main \
  "$repo/store/validation/program-cli/fixture.bgl" \
  "$seed_executable" \
  "$scratch/seed-artifacts"

build_native_logged \
  program-build \
  store.program-cli/-main \
  "$repo/store/src/store/program_cli.bgl" \
  "$program_executable" \
  "$scratch/program-artifacts"

phase=fixture-seed
binding_node_index="$($seed_executable "$store_log")"
[[ "$binding_node_index" =~ ^[0-9]+$ ]]

space='program-cli-space'
base_root='"program-cli-root-v1"'
next_root='"program-cli-root-v2"'
binding="[\"fixture/shadowing-rename.bgl\" :declares_at $binding_node_index]"

phase=lock-contention
locked_before_hash="$(sha256sum "$store_log" | awk '{print $1}')"
exec 9<>"$store_log"
flock -x 9
set +e
"$program_executable" "$space" "$store_log" inspect "$base_root" 1 \
  >"$scratch/locked.stdout" 2>"$scratch/locked.stderr" 9>&-
locked_status=$?
set -e
flock -u 9
exec 9>&-
locked_after_hash="$(sha256sum "$store_log" | awk '{print $1}')"
[[ "$locked_status" == 75 ]]
[[ "$locked_before_hash" == "$locked_after_hash" ]]
grep -Fq 'Store log is absent or locked' "$scratch/locked.stderr"

phase=torn-tail
cp "$store_log" "$scratch/torn.storelog"
printf '\001' >>"$scratch/torn.storelog"
torn_before_hash="$(sha256sum "$scratch/torn.storelog" | awk '{print $1}')"
set +e
"$program_executable" "$space" "$scratch/torn.storelog" inspect "$base_root" 1 \
  >"$scratch/torn.stdout" 2>"$scratch/torn.stderr"
torn_status=$?
set -e
torn_after_hash="$(sha256sum "$scratch/torn.storelog" | awk '{print $1}')"
[[ "$torn_status" == 74 ]]
[[ "$torn_before_hash" == "$torn_after_hash" ]]
grep -Fq 'incomplete or unrecognized byte tail' "$scratch/torn.stderr"

phase=base-reads
"$program_executable" "$space" "$store_log" inspect "$base_root" 1 \
  >"$scratch/inspect-base.txt"
grep -Fq '["program-cli-root-v1" :admitted_by "program-cli-profile"]' \
  "$scratch/inspect-base.txt"
if grep -Fq 'fixture/other-root.bgl' "$scratch/inspect-base.txt"; then
  printf 'inspect leaked the other root\n' >&2
  exit 1
fi

"$program_executable" "$space" "$store_log" definition "$base_root" 1 helper \
  >"$scratch/definition-helper.txt"
[[ "$(wc -l <"$scratch/definition-helper.txt")" == 2 ]]
grep -Fqx "$binding" "$scratch/definition-helper.txt"

"$program_executable" "$space" "$store_log" references "$base_root" 1 "$binding" \
  >"$scratch/references.txt"
[[ "$(wc -l <"$scratch/references.txt")" == 1 ]]

"$program_executable" "$space" "$store_log" impact "$base_root" 1 "$binding" \
  >"$scratch/impact.txt"
[[ "$(wc -l <"$scratch/impact.txt")" == 1 ]]

base_admission='["program-cli-root-v1" :admitted_by "program-cli-profile"]'
"$program_executable" "$space" "$store_log" history "$base_root" 1 \
  "$base_admission" >"$scratch/history-seed.txt"
grep -Fq 'occurrence ' "$scratch/history-seed.txt"
grep -Fq "$base_admission" "$scratch/history-seed.txt"

phase=rename-preview
before_preview_hash="$(sha256sum "$store_log" | awk '{print $1}')"
"$program_executable" "$space" "$store_log" rename "$base_root" 1 \
  "$next_root" "$binding" assistant --preview >"$scratch/preview.txt"
after_preview_hash="$(sha256sum "$store_log" | awk '{print $1}')"
[[ "$before_preview_hash" == "$after_preview_hash" ]]
grep -Fq 'root "program-cli-root-v2"' "$scratch/preview.txt"
grep -Fq '(defn assistant' "$scratch/preview.txt"
grep -Fq '(assistant value)' "$scratch/preview.txt"
grep -F '^source "fixture/shadowing-rename.bgl" ' "$scratch/preview.txt" \
  >"$scratch/preview-source.txt"
[[ "$(wc -l <"$scratch/preview-source.txt")" == 1 ]]
grep -Fq 'This local helper shadows the top-level binding.' \
  "$scratch/preview-source.txt"
grep -Fq '(defn shadowed [helper Int] Int' "$scratch/preview-source.txt"
grep -Fq 'comment is not a reference.\n(defn literal' \
  "$scratch/preview-source.txt"
grep -Fq '\"helper\"' "$scratch/preview-source.txt"

phase=rename-commit
"$program_executable" "$space" "$store_log" rename "$base_root" 1 \
  "$next_root" "$binding" assistant --commit >"$scratch/commit.txt"
grep -Fqx 'committed "program-cli-root-v2" 2' "$scratch/commit.txt"

before_stale_hash="$(sha256sum "$store_log" | awk '{print $1}')"
set +e
"$program_executable" "$space" "$store_log" rename "$base_root" 1 \
  '"program-cli-stale-root"' "$binding" stale --commit \
  >"$scratch/stale.stdout" 2>"$scratch/stale.stderr"
stale_status=$?
set -e
after_stale_hash="$(sha256sum "$store_log" | awk '{print $1}')"
[[ "$stale_status" == 75 ]]
[[ "$before_stale_hash" == "$after_stale_hash" ]]
grep -Fq 'Store version conflict: expected 1, observed 2' "$scratch/stale.stderr"

phase=reopen
"$program_executable" "$space" "$store_log" inspect "$next_root" 2 \
  >"$scratch/inspect-next.txt"
grep -Fq '["program-cli-root-v2" :derived_from "program-cli-root-v1"]' \
  "$scratch/inspect-next.txt"
grep -Fq '(defn assistant' "$scratch/inspect-next.txt"
grep -Fq '(assistant value)' "$scratch/inspect-next.txt"
grep -F '["fixture/shadowing-rename.bgl" :represented_by ' \
  "$scratch/inspect-next.txt" >"$scratch/inspect-next-source.txt"
[[ "$(wc -l <"$scratch/inspect-next-source.txt")" == 1 ]]
grep -Fq 'This local helper shadows the top-level binding.' \
  "$scratch/inspect-next-source.txt"
grep -Fq '(defn shadowed [helper Int] Int' "$scratch/inspect-next-source.txt"
grep -Fq 'comment is not a reference.\n(defn literal' \
  "$scratch/inspect-next-source.txt"
grep -Fq '\"helper\"' "$scratch/inspect-next-source.txt"

"$program_executable" "$space" "$store_log" definition "$next_root" 2 assistant \
  >"$scratch/definition-assistant.txt"
[[ "$(wc -l <"$scratch/definition-assistant.txt")" == 1 ]]
grep -Fqx "$binding" "$scratch/definition-assistant.txt"

old_name="[$binding :named \"helper\"]"
"$program_executable" "$space" "$store_log" history "$next_root" 2 "$old_name" \
  >"$scratch/history-rename.txt"
grep -Fq 'occurrence ' "$scratch/history-rename.txt"
grep -Fq 'withdrawal ' "$scratch/history-rename.txt"

phase=invalid-argv
set +e
"$program_executable" "$space" "$store_log" rename "$base_root" 1 \
  "$next_root" "$binding" assistant --apply \
  >"$scratch/invalid.stdout" 2>"$scratch/invalid.stderr"
invalid_status=$?
set -e
[[ "$invalid_status" == 64 ]]
[[ ! -s "$scratch/invalid.stdout" ]]
grep -Fqx \
  '       beagle program SPACE_ID LOG_PATH rename ROOT VERSION NEXT_ROOT BINDING NEW --preview|--commit' \
  "$scratch/invalid.stderr"

phase=native-linkage
grep -Eq \
  '^native-exe-entry PASS name=store\.program-cli/-main symbol=native_m0_fn_[0-9]+ return=Int abi=arena\+capability args=vec-string$' \
  "$scratch/program-artifacts/native-exe.report.txt"
if ldd "$program_executable" 2>/dev/null | grep -Eiq 'racket|babashka|java'; then
  printf 'program CLI links a hosted runtime\n' >&2
  exit 1
fi

printf 'program CLI native Store vertical: PASS\n'
