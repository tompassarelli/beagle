#!/usr/bin/env bash
# One terminal acceptance: G0 -> G1 -> G2 -> G3, with exact process evidence.

set -euo pipefail
export LC_ALL=C
export TZ=UTC

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
seed="$repo/native-core/bootstrap/trusted-seed/lp64-c17"
bundle="$repo/native-core/bootstrap/native-compiler.bundle"

die() {
  printf 'native-selfhost-fixed-point: FAIL %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 2 && "$1" == --evidence ]] ||
  die 'usage: drive.sh --evidence ABSENT_ABSOLUTE_DIRECTORY'
evidence="$2"
[[ "$evidence" == /* ]] || die 'evidence directory must be absolute'
[[ ! -e "$evidence" ]] || die 'evidence directory must not already exist'

for command in strace readelf ldd sha256sum awk sed rg cmp diff date; do
  command -v "$command" >/dev/null 2>&1 || die "required command is absent: $command"
done
[[ -x "$seed/bin/beagle" ]] || die 'committed trusted G0 executable is absent'
[[ -r "$bundle" ]] || die 'committed native compiler bundle is absent'
mkdir -p "$evidence"

sha_id() {
  printf 'sha256:%s' "$(sha256sum "$1" | awk '{print $1}')"
}

manifest_field() {
  local manifest="$1"
  local key="$2"
  local count value
  count="$(awk -v key="$key" '$1 == key && NF == 2 {count += 1} END {print count + 0}' "$manifest")"
  [[ "$count" == 1 ]] || die "manifest field is not unique: $manifest:$key"
  value="$(awk -v key="$key" '$1 == key && NF == 2 {print $2}' "$manifest")"
  printf '%s' "$value"
}

lineage_string_field() {
  local lineage="$1"
  local key="$2"
  local value
  value="$(sed -n "s/.*:$key \"\(sha256:[0-9a-f]\{64\}\)\".*/\1/p" "$lineage")"
  [[ "$value" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    die "lineage field is malformed: $lineage:$key"
  printf '%s' "$value"
}

lineage_generation() {
  local lineage="$1"
  local value
  value="$(sed -n 's/.* :generation \([0-9][0-9]*\) :materialization-content-id .*/\1/p' "$lineage")"
  [[ "$value" =~ ^[0-9]+$ ]] || die "lineage generation is malformed: $lineage"
  printf '%s' "$value"
}

bundle_semantic="$(sed -n '2s/^semantic-content-id //p' "$bundle")"
bundle_materialization="$(sed -n '3s/^materialization-content-id //p' "$bundle")"
[[ "$(sed -n '1p' "$bundle")" == beagle-native-rebuild-bundle/v1 ]] ||
  die 'bundle format is invalid'
[[ "$bundle_semantic" =~ ^sha256:[0-9a-f]{64}$ ]] ||
  die 'bundle semantic content ID is malformed'
[[ "$bundle_materialization" =~ ^sha256:[0-9a-f]{64}$ ]] ||
  die 'bundle materialization content ID is malformed'
[[ "$(sed -n '4p' "$bundle")" == artifact-envelope ]] ||
  die 'bundle artifact marker is invalid'

validate_package() {
  local package="$1"
  local generation="$2"
  local parent="${3:-}"
  local executable="$package/bin/beagle"
  local manifest="$package/beagle-native-artifact.manifest"
  local lineage="$package/beagle-native-lineage.edn"
  local semantic materialization executable_id

  [[ -x "$executable" && -r "$manifest" && -r "$lineage" ]] ||
    die "generation package is incomplete: $package"
  readelf -h "$executable" >/dev/null 2>&1 ||
    die "generation executable is not ELF: $executable"
  if ldd "$executable" 2>/dev/null | rg -qi \
    'racket|raco|python|pypy|babashka|clojure|java|graal|node|deno|bun'; then
    die "hosted runtime dependency found in $executable"
  fi

  semantic="$(manifest_field "$manifest" semantic-content-id)"
  materialization="$(manifest_field "$manifest" materialization-content-id)"
  executable_id="$(manifest_field "$manifest" executable-content-id)"
  [[ "$semantic" == "$bundle_semantic" ]] ||
    die "generation $generation semantic identity differs from the bundle"
  [[ "$materialization" == "$bundle_materialization" ]] ||
    die "generation $generation materialization identity differs from the bundle"
  [[ "$executable_id" == "$(sha_id "$executable")" ]] ||
    die "generation $generation executable identity differs from its bytes"
  [[ "$(lineage_generation "$lineage")" == "$generation" ]] ||
    die "generation $generation lineage counter is invalid"
  [[ "$(lineage_string_field "$lineage" semantic-content-id)" == "$semantic" ]] ||
    die "generation $generation lineage semantic identity differs"
  [[ "$(lineage_string_field "$lineage" materialization-content-id)" == "$materialization" ]] ||
    die "generation $generation lineage materialization identity differs"
  [[ "$(lineage_string_field "$lineage" executable-content-id)" == "$executable_id" ]] ||
    die "generation $generation lineage executable identity differs"

  if [[ "$generation" == 0 ]]; then
    rg -F ':parent-executable-content-id nil :parent-lineage-content-id nil' \
      "$lineage" >/dev/null || die 'G0 lineage is not a root'
  else
    [[ -n "$parent" ]] || die "generation $generation parent is absent"
    [[ "$(lineage_string_field "$lineage" parent-executable-content-id)" == \
       "$(sha_id "$parent/bin/beagle")" ]] ||
      die "generation $generation parent executable identity differs"
    [[ "$(lineage_string_field "$lineage" parent-lineage-content-id)" == \
       "$(sha_id "$parent/beagle-native-lineage.edn")" ]] ||
      die "generation $generation parent lineage identity differs"
  fi
}

validate_package "$seed" 0
: >"$evidence/timing.tsv"
: >"$evidence/process-tree.tsv"

run_generation() {
  local label="$1"
  local generation="$2"
  local parent="$3"
  local output="$4"
  local trace="$evidence/$label.process.trace"
  local started ended status

  started="$(date +%s%N)"
  set +e
  strace -f -qq -s 4096 -e trace=%process -o "$trace" \
    "$parent/bin/beagle" rebuild-next \
      --bundle "$bundle" \
      --out "$output" \
      --parent-lineage "$parent/beagle-native-lineage.edn" \
      >"$evidence/$label.stdout" 2>"$evidence/$label.stderr"
  status=$?
  set -e
  ended="$(date +%s%N)"
  printf '%s\t%s\t%s\t%s\n' "$label" "$started" "$ended" "$((ended - started))" \
    >>"$evidence/timing.tsv"
  [[ $status -eq 0 ]] || {
    tail -n 80 "$evidence/$label.stderr" >&2
    die "$label exited with status $status"
  }
  validate_package "$output" "$generation" "$parent"
  rg 'execve\(' "$trace" | sed "s/^/$label\t/" >>"$evidence/process-tree.tsv" ||
    die "$label process trace has no exec event"
  rg -F "execve(\"$parent/bin/beagle\"" "$trace" >/dev/null ||
    die "$label trace omits its native parent executable"
  rg 'execve\("[^"]*/cc"' "$trace" >/dev/null ||
    die "$label trace omits the C17 compiler"
}

g1="$evidence/G1"
g2="$evidence/G2"
g3="$evidence/G3"
run_generation G0-to-G1 1 "$seed" "$g1"
run_generation G1-to-G2 2 "$g1" "$g2"
run_generation G2-to-G3 3 "$g2" "$g3"

for trace in "$evidence"/*.process.trace; do
  if rg -ni \
    'execve\("[^"]*/(racket|raco|python([0-9.]*)?|pypy([0-9.]*)?|bb|babashka|clojure|clj|java|graal(vm)?|node|deno|bun)("|[[:space:]])' \
    "$trace" >&2; then
    die "hosted runtime appeared in process trace: $trace"
  fi
  if rg -F "execve(\"$repo/bin/" "$trace" >&2; then
    die "hosted repository compiler wrapper appeared in process trace: $trace"
  fi
done

g2_manifest="$g2/beagle-native-artifact.manifest"
g3_manifest="$g3/beagle-native-artifact.manifest"
g2_lineage="$g2/beagle-native-lineage.edn"
g3_lineage="$g3/beagle-native-lineage.edn"

[[ "$(manifest_field "$g2_manifest" semantic-content-id)" == \
   "$(manifest_field "$g3_manifest" semantic-content-id)" ]] ||
  die 'G2/G3 semantic identities differ'
[[ "$(manifest_field "$g2_manifest" materialization-content-id)" == \
   "$(manifest_field "$g3_manifest" materialization-content-id)" ]] ||
  die 'G2/G3 materialization identities differ'
[[ "$(manifest_field "$g2_manifest" executable-content-id)" == \
   "$(manifest_field "$g3_manifest" executable-content-id)" ]] ||
  die 'G2/G3 executable identities differ'
cmp -s "$g2/bin/beagle" "$g3/bin/beagle" || die 'G2/G3 executable bytes differ'
cmp -s "$g2_manifest" "$g3_manifest" || die 'G2/G3 package manifests differ'
diff -qr "$g2/artifacts" "$g3/artifacts" >/dev/null ||
  die 'G2/G3 materialized artifact trees differ'
cmp -s "$g2_lineage" "$g3_lineage" && die 'G2/G3 lineage did not advance'

{
  printf 'generation\tsemantic-content-id\tmaterialization-content-id\texecutable-content-id\tlineage-content-id\n'
  for row in "G0:$seed" "G1:$g1" "G2:$g2" "G3:$g3"; do
    label="${row%%:*}"
    package="${row#*:}"
    manifest="$package/beagle-native-artifact.manifest"
    lineage="$package/beagle-native-lineage.edn"
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$label" \
      "$(manifest_field "$manifest" semantic-content-id)" \
      "$(manifest_field "$manifest" materialization-content-id)" \
      "$(manifest_field "$manifest" executable-content-id)" \
      "$(sha_id "$lineage")"
  done
} >"$evidence/identities.tsv"

printf 'native-selfhost-fixed-point: PASS evidence=%s semantic=%s materialization=%s executable=%s\n' \
  "$evidence" \
  "$(manifest_field "$g3_manifest" semantic-content-id)" \
  "$(manifest_field "$g3_manifest" materialization-content-id)" \
  "$(manifest_field "$g3_manifest" executable-content-id)"
