#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

die() {
  echo "check-release-notes: $*" >&2
  exit 2
}

[[ $# -eq 1 ]] || die "usage: check-release-notes.sh vMAJOR.MINOR.PATCH"
release_tag="$1"
[[ "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "release tag must be vMAJOR.MINOR.PATCH: $release_tag"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
notes_path="$repo_root/.github/release-notes/$release_tag.md"
[[ -f "$notes_path" && ! -L "$notes_path" ]] ||
  die "authored notes are missing: .github/release-notes/$release_tag.md"
git -C "$repo_root" ls-files --error-unmatch \
  ".github/release-notes/$release_tag.md" >/dev/null 2>&1 ||
  die "authored notes are not tracked: .github/release-notes/$release_tag.md"

[[ "$(head -n 1 "$notes_path")" == "# Beagle $release_tag" ]] ||
  die "first line must be exactly: # Beagle $release_tag"
grep -Eq '^## [^#[:space:]].+' "$notes_path" ||
  die "authored notes need at least one named section"
[[ "$(grep -Ec '^- ' "$notes_path")" -ge 2 ]] ||
  die "authored notes need at least two change-specific bullets"
if grep -Eiq '(^|[^[:alnum:]])(TODO|TBD|PLACEHOLDER)([^[:alnum:]]|$)' \
  "$notes_path"; then
  die "authored notes contain an unfinished placeholder"
fi

meaningful_lines="$({
  sed -E '/^[[:space:]]*$/d; /^#/d; /^\*\*Full Changelog\*\*/d' "$notes_path"
} | wc -l)"
[[ "$meaningful_lines" -ge 4 ]] ||
  die "authored notes contain no substantive body beyond the changelog link"
