#!/usr/bin/env bash
# Assert that a release tag agrees with every version literal committed in the
# tree. Deliberately NOT folded into check-release-notes.sh: that script is
# replayed by .github/workflows/native.yml over every committed release-notes
# file on non-tag pushes, so it is called with older tags against the current
# tree. A version assertion living there would fail every push to main as soon
# as a second notes file exists. This script is invoked only for the release
# tag itself.
set -euo pipefail
export LC_ALL=C

die() {
  echo "check-release-version: $*" >&2
  exit 2
}

[[ $# -eq 1 ]] || die "usage: check-release-version.sh vMAJOR.MINOR.PATCH"
release_tag="$1"
[[ "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "release tag must be vMAJOR.MINOR.PATCH: $release_tag"
expected_version="${release_tag#v}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# die() inside this function exits the script; keeping the extraction free of a
# command substitution is what makes that true.
check_declared_version() {
  local path="$1" pattern="$2" declared
  [[ -f "$repo_root/$path" ]] || die "version source is missing: $path"
  declared="$(sed -nE "$pattern" "$repo_root/$path")"
  declared="${declared%%$'\n'*}"
  [[ -n "$declared" ]] || die "no version literal found in: $path"
  [[ "$declared" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "version literal is not MAJOR.MINOR.PATCH in $path: $declared"
  [[ "$declared" == "$expected_version" ]] ||
    die "$path declares $declared but release tag $release_tag expects $expected_version"
}

# beagle/info.rkt is the 'multi umbrella that `implies` beagle-lib; it mirrors
# the product version rather than carrying one of its own.
check_declared_version beagle-lib/info.rkt \
  's/^\(define version "([^"]*)"\)$/\1/p'
check_declared_version beagle/info.rkt \
  's/^\(define version "([^"]*)"\)$/\1/p'
check_declared_version flake.nix \
  's/^[[:space:]]*version = "([^"]*)";$/\1/p'

echo "check-release-version: $release_tag matches every declared version"
