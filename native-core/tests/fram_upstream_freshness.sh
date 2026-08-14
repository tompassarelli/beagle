#!/usr/bin/env bash
# Default mode reports drift against a live Fram checkout and never gates.
# `--verify-derived` is the hermetic gate: it proves every derived vendored
# source from its content-addressed patch with strict reverse/forward replay.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
upstream="$repo/native-core/validation/upstream/fram"
manifest="$upstream/MANIFEST"
mode='freshness'
if [[ "${1:-}" == '--verify-derived' ]]; then
    mode='verify-derived'
    shift
fi
if [[ "$#" -gt 1 ]]; then
    echo "usage: fram_upstream_freshness.sh [--verify-derived | FRAM_CHECKOUT]" >&2
    exit 2
fi
live="${1:-${FRAM_CHECKOUT:-$HOME/code/fram/main}}"

say() { printf 'fram-upstream: %s\n' "$*"; }

if [[ ! -f "$manifest" ]]; then
    say "no manifest at $manifest"
    [[ "$mode" == 'verify-derived' ]] && exit 1
    exit 0
fi
for command in cmp mktemp patch sha256sum; do
    if ! command -v "$command" >/dev/null 2>&1; then
        say "required command is unavailable: $command"
        [[ "$mode" == 'verify-derived' ]] && exit 1
        exit 0
    fi
done

valid_sha() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
safe_relative_path() {
    [[ -n "$1" && "$1" != /* && "$1" != '..' && "$1" != ../* &&
       "$1" != */../* && "$1" != */.. ]]
}

pinned_rev="$(awk '$1 == "revision" { print $2; exit }' "$manifest")"
say "vendored at fram ${pinned_rev:-<unrecorded>}"
live_available=1
if [[ "$mode" == 'freshness' && ! -d "$live" ]]; then
    live_available=0
fi

drift=0
contract_failures=0
derived_count=0
while read -r kind field_2 field_3 field_4 field_5 field_6 extra; do
    [[ -n "${kind:-}" ]] || continue
    [[ "$kind" == \#* || "$kind" == revision ]] && continue

    if [[ "$kind" == 'derived-patch-v1' ]]; then
        want="$field_2"
        path="$field_3"
        live_want="$field_4"
        live_path="$field_5"
        patch_digest="$field_6"
        derived_count=$((derived_count + 1))
        if [[ -n "${extra:-}" ]] ||
           ! valid_sha "$want" || ! valid_sha "$live_want" ||
           ! valid_sha "$patch_digest" ||
           ! safe_relative_path "$path" || ! safe_relative_path "$live_path"; then
            say "MALFORMED DERIVED ENTRY: $kind $field_2 $field_3 $field_4 $field_5 $field_6 ${extra:-}"
            contract_failures=$((contract_failures + 1))
            continue
        fi
        transform="patch:$patch_digest"
    elif valid_sha "$kind" && safe_relative_path "${field_2:-}" &&
         [[ -z "${field_3:-}${field_4:-}${field_5:-}${field_6:-}${extra:-}" ]]; then
        want="$kind"
        path="$field_2"
        live_want="$want"
        live_path="$path"
        patch_digest=''
        transform='direct-copy'
    else
        say "MALFORMED MANIFEST ENTRY: $kind $field_2 $field_3 $field_4 $field_5 $field_6 ${extra:-}"
        contract_failures=$((contract_failures + 1))
        continue
    fi

    vendored="$upstream/$path"
    if [[ ! -f "$vendored" ]]; then
        say "VENDORED FILE MISSING: $path"
        contract_failures=$((contract_failures + 1))
        continue
    fi
    have_vendored="$(sha256sum "$vendored" | cut -d' ' -f1)"
    if [[ "$have_vendored" != "$want" ]]; then
        say "VENDORED COPY DOES NOT MATCH ITS MANIFEST DIGEST: $path"
        contract_failures=$((contract_failures + 1))
        continue
    fi

    if [[ -n "$patch_digest" ]]; then
        patch_file="$upstream/transforms/$patch_digest.patch"
        if [[ ! -f "$patch_file" ]] ||
           [[ "$(sha256sum "$patch_file" | cut -d' ' -f1)" != "$patch_digest" ]]; then
            say "DERIVED PATCH MISSING OR MISNAMED: $patch_digest"
            contract_failures=$((contract_failures + 1))
            continue
        fi
        replay="$(mktemp -d "${TMPDIR:-/tmp}/fram-derived-replay.XXXXXX")"
        reconstructed="$replay/upstream"
        regenerated="$replay/derived"
        if ! patch --batch --silent --fuzz=0 --reverse \
             --output="$reconstructed" "$vendored" <"$patch_file" ||
           [[ "$(sha256sum "$reconstructed" | cut -d' ' -f1)" != "$live_want" ]] ||
           ! patch --batch --silent --fuzz=0 \
             --output="$regenerated" "$reconstructed" <"$patch_file" ||
           ! cmp -s "$regenerated" "$vendored"; then
            say "DERIVED PATCH REPLAY FAILED: $path"
            contract_failures=$((contract_failures + 1))
            rm -rf "${replay:?}"
            continue
        fi
        rm -rf "${replay:?}"
    fi

    if [[ "$mode" == 'freshness' && "$live_available" == 1 ]]; then
        if [[ ! -f "$live/$live_path" ]]; then
            say "gone upstream: $live_path"
            drift=$((drift + 1))
            continue
        fi
        have_live="$(sha256sum "$live/$live_path" | cut -d' ' -f1)"
        [[ "$have_live" == "$live_want" ]] && continue
        say "DRIFTED: $live_path"
        say "  pinned   $live_want ($transform -> $path at $want)"
        say "  live     $have_live"
        drift=$((drift + 1))
    fi
done < "$manifest"

if [[ "$mode" == 'verify-derived' ]]; then
    if [[ "$derived_count" -eq 0 ]]; then
        say "derived contract contains no files"
        exit 1
    fi
    if [[ "$contract_failures" -ne 0 ]]; then
        say "derived contract FAIL files=$derived_count failures=$contract_failures"
        exit 1
    fi
    say "derived contract PASS files=$derived_count"
    exit 0
fi

if [[ "$contract_failures" -gt 0 ]]; then
    say "$contract_failures vendored contract failure(s) — repair before trusting a bump"
fi
if [[ "$live_available" == 0 ]]; then
    say "no live checkout at $live — drift not evaluated"
    exit 0
fi

live_rev="$(git -C "$live" rev-parse HEAD 2>/dev/null || true)"
if [[ -n "$live_rev" ]]; then
    if [[ "$live_rev" == "$pinned_rev" ]]; then
        say "live $live is at the pinned revision"
    else
        say "live $live is at $live_rev"
        if [[ -n "$pinned_rev" ]] &&
           git -C "$live" merge-base --is-ancestor "$pinned_rev" "$live_rev" 2>/dev/null; then
            say "live fram has moved $(git -C "$live" rev-list --count "$pinned_rev..$live_rev" 2>/dev/null) commits past the pin"
        fi
    fi
fi
if [[ "$drift" -eq 0 ]]; then
    say "no drift: every vendored input still matches $live"
else
    say "$drift file(s) drifted; bump source, patch, and regenerated projections together"
fi
exit 0
