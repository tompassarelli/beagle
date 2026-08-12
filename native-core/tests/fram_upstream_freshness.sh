#!/usr/bin/env bash
# Report drift between the vendored fram validation sources and a live fram
# checkout. NON-GATING BY CONSTRUCTION: it always exits 0, and nothing that
# gates calls it. That is the whole point of vendoring — a beagle gate must
# not become red because another repository moved — so this check tells you
# a bump is available and never decides anything.
#
# It is also the ONE place in this repository that reads a live fram checkout,
# which keeps live fram out of every traced gate closure (bin/_gate-cache-run).
# Do not call it from a gate, a driver, or a cached layer.
#
# Usage: fram_upstream_freshness.sh [FRAM_CHECKOUT]   (default ~/code/fram/main)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
upstream="$repo/native-core/validation/upstream/fram"
manifest="$upstream/MANIFEST"
live="${1:-${FRAM_CHECKOUT:-$HOME/code/fram/main}}"

say() { printf 'fram-upstream: %s\n' "$*"; }

if [[ ! -f "$manifest" ]]; then
    say "no manifest at $manifest — nothing to compare"
    exit 0
fi

pinned_rev="$(awk '$1 == "revision" { print $2; exit }' "$manifest")"
say "vendored at fram ${pinned_rev:-<unrecorded>}"

if [[ ! -d "$live" ]]; then
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

drift=0
missing=0
while read -r want path; do
    [[ -n "${want:-}" && -n "${path:-}" ]] || continue
    [[ "$want" == \#* || "$want" == revision ]] && continue
    vendored="$upstream/$path"
    if [[ ! -f "$vendored" ]]; then
        say "VENDORED FILE MISSING: $path"
        missing=$((missing + 1))
        continue
    fi
    have_vendored="$(sha256sum "$vendored" | cut -d' ' -f1)"
    if [[ "$have_vendored" != "$want" ]]; then
        say "VENDORED COPY DOES NOT MATCH ITS MANIFEST DIGEST: $path"
        missing=$((missing + 1))
        continue
    fi
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
done < "$manifest"

if [[ "$missing" -gt 0 ]]; then
    say "$missing vendored file(s) do not match the manifest — re-vendor before trusting a bump"
fi
if [[ "$drift" -eq 0 ]]; then
    say "no drift: every vendored file still matches $live"
else
    say "$drift file(s) drifted; bump with a commit carrying the source diff and the regenerated projections"
fi
exit 0
