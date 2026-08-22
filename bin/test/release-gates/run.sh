#!/usr/bin/env bash
# Tests the two release gates in scripts/: check-release-notes.sh (the authored
# release-notes gate) and check-release-version.sh (the tag/version-literal
# gate). Both derive their repo root from their own location and
# check-release-notes.sh additionally requires the notes file to be git-tracked,
# so every fixture is a real throwaway git repo with the real scripts copied in
# and the fixture files staged — a bare mktemp directory cannot exercise them.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/bin/_beagle-cold-authority"
export LC_ALL=C

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
notes_gate="$repo_root/scripts/check-release-notes.sh"
version_gate="$repo_root/scripts/check-release-version.sh"
workflow="$repo_root/.github/workflows/native.yml"
provenance_helper="$repo_root/bin/_beagle-compiler-provenance"
core_builder="$repo_root/bin/beagle-build-core"
ast_cli="$repo_root/bin/beagle-ast"
flake="$repo_root/flake.nix"

test_root="$(mktemp -d)"
trap 'rm -rf "${test_root:?}"' EXIT

fail() {
  echo "release gates test: $*" >&2
  exit 1
}

# A fixture is a self-contained git repo holding copies of the real gates, so
# the gates' own repo-root derivation and git-tracked check operate on it.
new_fixture() {
  local root="$test_root/$1"
  mkdir -p "$root/scripts"
  cp "$notes_gate" "$version_gate" "$root/scripts/"
  git init -q -b main "$root"
  printf '%s' "$root"
}

write_info() {
  local root="$1" collection="$2" version="$3"
  mkdir -p "$root/$collection"
  printf '#lang info\n(define collection "beagle")\n(define version "%s")\n' \
    "$version" > "$root/$collection/info.rkt"
}

write_flake() {
  local root="$1" version="$2"
  printf '{\n  outputs = { ... }: {\n          version = "%s";\n  };\n}\n' \
    "$version" > "$root/flake.nix"
}

# Every version literal at one value: the shape a correct release tree has.
write_versions() {
  local root="$1" version="$2"
  write_info "$root" beagle-lib "$version"
  write_info "$root" beagle "$version"
  write_flake "$root" "$version"
}

# Four bullets satisfies both the >=2 bullet rule and the >=4 substantive-line
# rule, so a fixture that trips one check is not accidentally tripping the other.
write_notes() {
  local root="$1" tag="$2" heading="$3" body="$4"
  mkdir -p "$root/.github/release-notes"
  printf '%s\n\n%s\n' "$heading" "$body" > "$root/.github/release-notes/$tag.md"
  git -C "$root" add ".github/release-notes/$tag.md"
}

full_body=$'## Highlights\n\n- Entry exports are qualified per entry name.\n- Host byte records travel through the mailbox.\n- Native writes are atomic at the capability boundary.\n- Build receipts bind the runtime policy.\n'

expect_success() {
  local label="$1"
  shift
  "$@" >/dev/null 2>&1 || fail "expected success: $label"
}

expect_failure() {
  local label="$1" expected="$2"
  shift 2
  local output status=0
  output="$("$@" 2>&1)" || status=$?
  [[ "$status" -ne 0 ]] || fail "expected failure: $label"
  [[ "$status" -eq 2 ]] ||
    fail "$label: expected exit 2, got $status"
  [[ "$output" == *"$expected"* ]] ||
    fail "$label: missing diagnostic '$expected': $output"
}

expect_output() {
  local label="$1" expected="$2"
  shift 2
  local output
  output="$("$@")" || fail "expected success: $label"
  [[ "$output" == "$expected" ]] ||
    fail "$label: expected '$expected', got '$output'"
}

# ---------------------------------------------------------------------------
# check-release-notes.sh
# ---------------------------------------------------------------------------

valid="$(new_fixture notes-valid)"
write_notes "$valid" v0.22.0 '# Beagle v0.22.0' "$full_body"
expect_success "authored notes accepted" \
  bash "$valid/scripts/check-release-notes.sh" v0.22.0

args="$(new_fixture notes-args)"
expect_failure "no argument" "usage: check-release-notes.sh" \
  bash "$args/scripts/check-release-notes.sh"
expect_failure "two arguments" "usage: check-release-notes.sh" \
  bash "$args/scripts/check-release-notes.sh" v0.22.0 v0.23.0
expect_failure "unversioned tag" "release tag must be vMAJOR.MINOR.PATCH" \
  bash "$args/scripts/check-release-notes.sh" 0.22.0

missing="$(new_fixture notes-missing)"
expect_failure "notes absent" "authored notes are missing" \
  bash "$missing/scripts/check-release-notes.sh" v0.22.0

symlinked="$(new_fixture notes-symlink)"
write_notes "$symlinked" v0.21.1 '# Beagle v0.21.1' "$full_body"
ln -s "v0.21.1.md" "$symlinked/.github/release-notes/v0.22.0.md"
git -C "$symlinked" add ".github/release-notes/v0.22.0.md"
expect_failure "notes are a symlink" "authored notes are missing" \
  bash "$symlinked/scripts/check-release-notes.sh" v0.22.0

untracked="$(new_fixture notes-untracked)"
write_notes "$untracked" v0.22.0 '# Beagle v0.22.0' "$full_body"
git -C "$untracked" rm -q --cached ".github/release-notes/v0.22.0.md"
expect_failure "notes not tracked" "authored notes are not tracked" \
  bash "$untracked/scripts/check-release-notes.sh" v0.22.0

heading="$(new_fixture notes-heading)"
write_notes "$heading" v0.22.0 '# Beagle v0.21.1' "$full_body"
expect_failure "wrong heading" "first line must be exactly" \
  bash "$heading/scripts/check-release-notes.sh" v0.22.0

sectionless="$(new_fixture notes-sectionless)"
write_notes "$sectionless" v0.22.0 '# Beagle v0.22.0' \
  $'- Entry exports are qualified per entry name.\n- Host byte records travel through the mailbox.\n- Native writes are atomic at the capability boundary.\n- Build receipts bind the runtime policy.\n'
expect_failure "no named section" "need at least one named section" \
  bash "$sectionless/scripts/check-release-notes.sh" v0.22.0

thin_bullets="$(new_fixture notes-bullets)"
write_notes "$thin_bullets" v0.22.0 '# Beagle v0.22.0' \
  $'## Highlights\n\n- Entry exports are qualified per entry name.\n'
expect_failure "one bullet" "need at least two change-specific bullets" \
  bash "$thin_bullets/scripts/check-release-notes.sh" v0.22.0

placeholder="$(new_fixture notes-placeholder)"
write_notes "$placeholder" v0.22.0 '# Beagle v0.22.0' \
  $'## Highlights\n\n- Entry exports are qualified per entry name.\n- Host byte records travel through the mailbox.\n- TODO: describe the capability surface.\n- Build receipts bind the runtime policy.\n'
expect_failure "unfinished placeholder" "contain an unfinished placeholder" \
  bash "$placeholder/scripts/check-release-notes.sh" v0.22.0

thin_body="$(new_fixture notes-thin)"
write_notes "$thin_body" v0.22.0 '# Beagle v0.22.0' \
  $'## Highlights\n\n- Entry exports are qualified per entry name.\n- Host byte records travel through the mailbox.\n\n**Full Changelog**: https://example.invalid/compare\n'
expect_failure "no substantive body" "no substantive body beyond the changelog link" \
  bash "$thin_body/scripts/check-release-notes.sh" v0.22.0

# ---------------------------------------------------------------------------
# check-release-version.sh
# ---------------------------------------------------------------------------

version_ok="$(new_fixture version-valid)"
write_versions "$version_ok" 0.22.0
expect_success "matching versions accepted" \
  bash "$version_ok/scripts/check-release-version.sh" v0.22.0

expect_failure "no argument" "usage: check-release-version.sh" \
  bash "$version_ok/scripts/check-release-version.sh"
expect_failure "unversioned tag" "release tag must be vMAJOR.MINOR.PATCH" \
  bash "$version_ok/scripts/check-release-version.sh" 0.22.0
expect_failure "tag ahead of every literal" \
  "beagle-lib/info.rkt declares 0.22.0 but release tag v0.23.0 expects 0.23.0" \
  bash "$version_ok/scripts/check-release-version.sh" v0.23.0

lib_stale="$(new_fixture version-lib)"
write_versions "$lib_stale" 0.22.0
write_info "$lib_stale" beagle-lib 0.21.1
expect_failure "stale beagle-lib version" \
  "beagle-lib/info.rkt declares 0.21.1 but release tag v0.22.0 expects 0.22.0" \
  bash "$lib_stale/scripts/check-release-version.sh" v0.22.0

umbrella_stale="$(new_fixture version-umbrella)"
write_versions "$umbrella_stale" 0.22.0
write_info "$umbrella_stale" beagle 0.18.0
expect_failure "stale umbrella version" \
  "beagle/info.rkt declares 0.18.0 but release tag v0.22.0 expects 0.22.0" \
  bash "$umbrella_stale/scripts/check-release-version.sh" v0.22.0

flake_stale="$(new_fixture version-flake)"
write_versions "$flake_stale" 0.22.0
write_flake "$flake_stale" 0.17.1
expect_failure "stale flake version" \
  "flake.nix declares 0.17.1 but release tag v0.22.0 expects 0.22.0" \
  bash "$flake_stale/scripts/check-release-version.sh" v0.22.0

version_absent="$(new_fixture version-absent)"
write_versions "$version_absent" 0.22.0
rm "$version_absent/beagle-lib/info.rkt"
expect_failure "version source missing" \
  "version source is missing: beagle-lib/info.rkt" \
  bash "$version_absent/scripts/check-release-version.sh" v0.22.0

literal_absent="$(new_fixture version-literal)"
write_versions "$literal_absent" 0.22.0
printf '#lang info\n(define collection "beagle")\n' \
  > "$literal_absent/beagle-lib/info.rkt"
expect_failure "version literal missing" \
  "no version literal found in: beagle-lib/info.rkt" \
  bash "$literal_absent/scripts/check-release-version.sh" v0.22.0

# ---------------------------------------------------------------------------
# Packaged compiler provenance
# ---------------------------------------------------------------------------

checkout="$test_root/provenance-checkout"
mkdir -p "$checkout"
git init -q -b main "$checkout"
git -C "$checkout" -c user.name=Beagle -c user.email=beagle.invalid \
  commit -q --allow-empty -m initial
checkout_commit="$(git -C "$checkout" rev-parse HEAD)"
other_commit="0000000000000000000000000000000000000000"

expect_output "checkout HEAD is authoritative" "$checkout_commit" \
  env -u BEAGLE_PACKAGED_COMPILER_COMMIT \
  bash -c 'source "$1"; beagle_resolve_compiler_commit "$2"' \
  resolve-compiler-commit "$provenance_helper" "$checkout"
expect_output "matching packaged revision is accepted in a checkout" "$checkout_commit" \
  env BEAGLE_PACKAGED_COMPILER_COMMIT="$checkout_commit" \
  bash -c 'source "$1"; beagle_resolve_compiler_commit "$2"' \
  resolve-compiler-commit "$provenance_helper" "$checkout"
expect_failure "malformed packaged revision" "must be 40 lowercase hexadecimal characters" \
  env BEAGLE_PACKAGED_COMPILER_COMMIT=NOT-A-COMMIT \
  bash -c 'source "$1"; beagle_resolve_compiler_commit "$2"' \
  resolve-compiler-commit "$provenance_helper" "$checkout"
expect_failure "conflicting checkout and package provenance" "conflicts with checkout HEAD" \
  env BEAGLE_PACKAGED_COMPILER_COMMIT="$other_commit" \
  bash -c 'source "$1"; beagle_resolve_compiler_commit "$2"' \
  resolve-compiler-commit "$provenance_helper" "$checkout"

package_root="$test_root/provenance-package"
mkdir -p "$package_root"
expect_output "package revision replaces absent Git metadata" "$checkout_commit" \
  env BEAGLE_PACKAGED_COMPILER_COMMIT="$checkout_commit" \
  bash -c 'source "$1"; beagle_resolve_compiler_commit "$2"' \
  resolve-compiler-commit "$provenance_helper" "$package_root"
expect_failure "package without revision" "Git metadata is absent and BEAGLE_PACKAGED_COMPILER_COMMIT is unset" \
  env -u BEAGLE_PACKAGED_COMPILER_COMMIT \
  bash -c 'source "$1"; beagle_resolve_compiler_commit "$2"' \
  resolve-compiler-commit "$provenance_helper" "$package_root"
printf 'broken worktree pointer\n' > "$package_root/.git"
expect_failure "broken checkout metadata cannot fall back to package provenance" \
  "Git metadata is present but checkout HEAD is unavailable" \
  env BEAGLE_PACKAGED_COMPILER_COMMIT="$checkout_commit" \
  bash -c 'source "$1"; beagle_resolve_compiler_commit "$2"' \
  resolve-compiler-commit "$provenance_helper" "$package_root"

grep -Fq 'source "$BIN/_beagle-compiler-provenance"' "$core_builder" ||
  fail "beagle-build-core does not load the compiler provenance resolver"
grep -Fq 'beagle_resolve_compiler_commit "$BEAGLE_DIR"' "$core_builder" ||
  fail "beagle-build-core does not use the compiler provenance resolver"
grep -Fq 'BEAGLE_PACKAGED_COMPILER_COMMIT = self.rev or "";' "$flake" ||
  fail "the package does not capture the exact flake revision"
grep -Fq -- '--set BEAGLE_PACKAGED_COMPILER_COMMIT "$BEAGLE_PACKAGED_COMPILER_COMMIT"' "$flake" ||
  fail "the package wrapper does not expose its captured compiler revision"
grep -Fq 'pkgs.ripgrep' "$flake" ||
  fail "the packaged runtime does not contain ripgrep"
grep -Fq 'BEAGLE_CHECKED_AST_CACHE:-${XDG_CACHE_HOME:-${HOME:?HOME is required}/.cache}/beagle/checked-ast' "$ast_cli" ||
  fail "checked AST reuse is not rooted in the writable user cache"
if grep -Fq 'BEAGLE_ROOT/.beagle/checked-ast' "$ast_cli"; then
  fail "checked AST reuse still writes below the immutable package root"
fi

# ---------------------------------------------------------------------------
# The real tree, and the wiring that makes these gates run at all
# ---------------------------------------------------------------------------

release_tag="v$(sed -nE 's/^\(define version "([^"]*)"\)$/\1/p' \
  "$repo_root/beagle-lib/info.rkt")"
expect_success "committed notes pass for $release_tag" \
  bash "$notes_gate" "$release_tag"
expect_success "committed versions agree with $release_tag" \
  bash "$version_gate" "$release_tag"

# There is no glob runner for bin/test/*/run.sh: an unwired test never runs.
grep -Fq 'bin/test/release-gates/run.sh' "$workflow" ||
  fail "this test is not wired into .github/workflows/native.yml"
grep -Fq 'scripts/check-release-version.sh' "$workflow" ||
  fail "the version gate is not wired into .github/workflows/native.yml"

echo "release gates test: OK"
