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

"$repo_dir/bin/beagle-check" "$artifact_dir/first.bclj"

assert_rejected() {
  local name="$1"
  local source="$2"
  local run_dir="$3"
  shift 3
  printf '%s' "$source" >"$artifact_dir/$name.clj"
  if (cd "$run_dir" && \
      "$clojure_bin" "$@" -M "$emitted_converter" "$artifact_dir/$name.clj") \
        >"$artifact_dir/$name.stdout" 2>"$artifact_dir/$name.stderr"; then
    echo "$name input was accepted" >&2
    exit 1
  fi
  test ! -s "$artifact_dir/$name.stdout"
  test "$(cat "$artifact_dir/$name.stderr")" = \
    "rejected: unsafe, malformed, or unsupported Clojure input"
}

assert_rejected reader-eval $'#=(+ 1 2)\n' "$repo_dir"
assert_rejected malformed $'(ns demo.greeter\n' "$repo_dir"
assert_rejected unsupported \
  $'(ns demo.greeter)\n\n(def greeting "Hello")\n' "$repo_dir"

reader_cp="$artifact_dir/reader-cp"
reader_marker="$artifact_dir/reader-executed"
mkdir -p "$reader_cp"
printf '%s\n' '{evil/tag reader-payload/execute}' >"$reader_cp/data_readers.clj"
printf '%s\n' \
  '(ns reader-payload)' \
  '' \
  '(defn execute [value]' \
  '  (spit (System/getProperty "reader.marker") "executed")' \
  '  value)' >"$reader_cp/reader_payload.clj"
assert_rejected tagged-reader \
  $'(ns demo.greeter)\n\n(defn greet [name]\n  (str #evil/tag "Hello, " name))\n' \
  "$reader_cp" "-J-Dreader.marker=$reader_marker" -Sdeps '{:paths ["."]}'
test ! -e "$reader_marker"

printf 'byte-identical output:\n'
cat "$artifact_dir/first.bclj"
