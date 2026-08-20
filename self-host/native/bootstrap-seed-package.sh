#!/usr/bin/env bash
# Freeze an already-native seed. This is a release packaging step; normal
# compiler rebuilds invoke the packaged ELF directly through `rebuild-next`.
# Callers must run this after any binary fixup so the recorded digest names the
# bytes users execute.

set -euo pipefail

die() {
    printf 'bootstrap-seed-package: %s\n' "$*" >&2
    exit 2
}

candidate=""
out=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --candidate)
            [[ $# -ge 2 ]] || die "--candidate needs an executable"
            candidate="$2"
            shift 2
            ;;
        --out)
            [[ $# -ge 2 ]] || die "--out needs a directory"
            out="$2"
            shift 2
            ;;
        --help|-h)
            sed -n '2,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

[[ -n "$candidate" && -x "$candidate" ]] ||
    die "--candidate must name an executable native seed"
[[ -n "$out" ]] || die "--out is required"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
expected_contract="$here/bootstrap-contract.manifest"
[[ -f "$expected_contract" ]] || die "bootstrap contract is unavailable"

candidate="$(realpath -e "$candidate")"
readelf -h "$candidate" >/dev/null 2>&1 ||
    die "candidate is not a native ELF executable"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/beagle-bootstrap-seed.XXXXXX")"
cleanup() {
    local status=$?
    rm -rf "${tmp:?}"
    return "$status"
}
trap cleanup EXIT

timeout --foreground 10s "$candidate" bootstrap-contract >"$tmp/contract"
cmp -s "$expected_contract" "$tmp/contract" ||
    die "candidate reports a different bootstrap contract"

expected_rebuild_usage="usage: beagle rebuild-next --bundle MANIFEST --out OUT --parent-lineage FILE"
actual_rebuild_usage="$(timeout --foreground 10s "$candidate" rebuild-next --help 2>&1)" ||
    die "candidate does not expose rebuild-next"
[[ "$actual_rebuild_usage" == "$expected_rebuild_usage" ]] ||
    die "candidate rebuild-next usage differs from the frozen contract"

if ldd "$candidate" 2>/dev/null | rg -qi \
    'racket|raco|clojure|babashka|java|graal'; then
    die "hosted runtime dependency found in candidate"
fi

mkdir -p "$out/bin"
out="$(realpath "$out")"
install -m 0755 "$candidate" "$out/bin/beagle"
artifact_sha="$(sha256sum "$out/bin/beagle" | awk '{print $1}')"
artifact_id="sha256:$artifact_sha"

compiler_context="$(awk '$1 == "compiler-context-content-id" {print $2}' "$expected_contract")"
schema="$(awk '$1 == "schema-content-id" {print $2}' "$expected_contract")"
rules="$(awk '$1 == "rule-set-content-id" {print $2}' "$expected_contract")"
target="$(awk '$1 == "target-id" {print $2}' "$expected_contract")"
datum_reader="$(awk '$1 == "datum-reader-content-id" {print $2}' "$expected_contract")"
store_evaluator="$(awk '$1 == "store-evaluator-content-id" {print $2}' "$expected_contract")"
rule_scheduler="$(awk '$1 == "rule-scheduler-content-id" {print $2}' "$expected_contract")"
materializer="$(awk '$1 == "materializer-content-id" {print $2}' "$expected_contract")"

for content_id in \
    "$compiler_context" "$schema" "$rules" "$datum_reader" \
    "$store_evaluator" "$rule_scheduler" "$materializer"; do
    [[ "$content_id" =~ ^sha256:[0-9a-f]{64}$ ]] ||
        die "bootstrap contract contains a malformed content ID"
done
[[ "$target" == "c17" ]] || die "bootstrap contract target is not c17"

manifest="$out/beagle-native-artifact.manifest"
lineage="$out/beagle-native-lineage.edn"
{
    printf 'beagle-native-seed-artifact/v1\n'
    printf 'artifact-content-id %s\n' "$artifact_id"
    printf 'compiler-context-content-id %s\n' "$compiler_context"
    printf 'schema-content-id %s\n' "$schema"
    printf 'rule-set-content-id %s\n' "$rules"
    printf 'target-id %s\n' "$target"
    printf 'datum-reader-content-id %s\n' "$datum_reader"
    printf 'store-evaluator-content-id %s\n' "$store_evaluator"
    printf 'rule-scheduler-content-id %s\n' "$rule_scheduler"
    printf 'materializer-content-id %s\n' "$materializer"
    printf 'entry-command rebuild-next\n'
    printf 'hosted-runtime-required false\n'
} >"$manifest"

printf '{:artifact-content-id "%s" :compiler-context-id "%s" :format "beagle-native-compiler-lineage/v1" :generation 0 :parent-artifact-content-id nil :parent-lineage-content-id nil :rule-set-content-id "%s" :schema-content-id "%s" :target-id "%s"}\n' \
    "$artifact_id" "$compiler_context" "$rules" "$schema" "$target" >"$lineage"

chmod 0444 "$manifest" "$lineage"
printf 'bootstrap-seed-package: artifact-content-id=%s lineage-content-id=sha256:%s\n' \
    "$artifact_id" "$(sha256sum "$lineage" | awk '{print $1}')" >&2
