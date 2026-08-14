#!/usr/bin/env bash
# Report drift between the vendored Fram validation sources and a live Fram
# checkout. This is non-gating: it reports a bump opportunity and exits 0.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
upstream="$repo/native-core/validation/upstream/fram"
manifest="$upstream/MANIFEST"
if [[ "$#" -gt 1 ]]; then
    echo "usage: fram_upstream_freshness.sh [FRAM_CHECKOUT]" >&2
    exit 2
fi
live="${1:-${FRAM_CHECKOUT:-$HOME/code/fram/main}}"

say() { printf 'fram-upstream: %s\n' "$*"; }

if [[ ! -f "$manifest" ]]; then
    say "no manifest at $manifest — nothing to compare"
    exit 0
fi

valid_sha() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }
safe_relative_path() {
    [[ -n "$1" && "$1" != /* && "$1" != '..' && "$1" != ../* &&
       "$1" != */../* && "$1" != */.. ]]
}

pinned_rev="$(awk '$1 == "revision" { print $2; exit }' "$manifest")"
say "vendored at fram ${pinned_rev:-<unrecorded>}"
live_available=1
if [[ ! -d "$live" ]]; then
    live_available=0
fi

drift=0
contract_failures=0
while read -r want path extra; do
    [[ -n "${want:-}" ]] || continue
    [[ "$want" == \#* || "$want" == revision ]] && continue
    if ! valid_sha "$want" || ! safe_relative_path "${path:-}" ||
       [[ -n "${extra:-}" ]]; then
        say "MALFORMED MANIFEST ENTRY: $want ${path:-} ${extra:-}"
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

    if [[ "$live_available" == 1 ]]; then
        if [[ ! -f "$live/$path" ]]; then
            say "gone upstream: $path"
            drift=$((drift + 1))
            continue
        fi
        have_live="$(sha256sum "$live/$path" | cut -d' ' -f1)"
        [[ "$have_live" == "$want" ]] && continue
        say "DRIFTED: $path"
        say "  vendored $want"
        say "  live     $have_live"
        drift=$((drift + 1))
    fi
done < "$manifest"

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
    say "no drift: every vendored file still matches $live"
else
    say "$drift file(s) drifted; bump with a commit carrying the source diff and the regenerated projections"
fi
exit 0
