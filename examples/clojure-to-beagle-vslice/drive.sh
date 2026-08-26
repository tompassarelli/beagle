#!/usr/bin/env bash
set -euo pipefail

slice_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$slice_dir/../.." && pwd)"
artifact_dir="$(mktemp -d)"
trap 'rm -rf -- "$artifact_dir"' EXIT
clojure_bin="$(nix develop "$repo_dir" --command bash -c 'command -v clojure')"

emitted_converter="$artifact_dir/converter.clj"
"$repo_dir/bin/beagle-build" "$slice_dir/converter.bclj" "$emitted_converter"

"$clojure_bin" -M "$emitted_converter" "$slice_dir/input.clj" >"$artifact_dir/first.bclj"
"$clojure_bin" -M "$emitted_converter" "$slice_dir/input.clj" >"$artifact_dir/second.bclj"
cmp "$artifact_dir/first.bclj" "$artifact_dir/second.bclj"

"$repo_dir/bin/beagle" syntax "$artifact_dir/first.bclj"

printf '#=(+ 1 2)\n' >"$artifact_dir/unsafe.clj"
if "$clojure_bin" -M "$emitted_converter" "$artifact_dir/unsafe.clj" \
    >"$artifact_dir/unsafe.stdout" 2>"$artifact_dir/unsafe.stderr"; then
  echo "unsafe reader form was accepted" >&2
  exit 1
fi
test ! -s "$artifact_dir/unsafe.stdout"
test "$(cat "$artifact_dir/unsafe.stderr")" = \
  "rejected: unsafe, malformed, or unsupported Clojure input"

printf 'byte-identical output:\n'
cat "$artifact_dir/first.bclj"
