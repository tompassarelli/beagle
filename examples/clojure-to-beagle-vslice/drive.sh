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
"$repo_dir/bin/beagle-build" "$artifact_dir/first.bclj" "$artifact_dir/generated.clj"

original_result="$(ORACLE_PATH="$slice_dir/input.clj" "$clojure_bin" -M -e \
  '(do (load-file (System/getenv "ORACLE_PATH")) (print (demo.offset/tail-offset "abcdef" 1)))')"
generated_result="$(ORACLE_PATH="$artifact_dir/generated.clj" "$clojure_bin" -M -e \
  '(do (load-file (System/getenv "ORACLE_PATH")) (print (demo.offset/tail-offset "abcdef" 1)))')"
test "$original_result" = "cdef"
test "$generated_result" = "$original_result"

multi_source=$' (ns demo.multi)\n\n(defn greet\n  ([name]\n    (str "Hello, " name))\n  ([name title]\n    (str "Hello, " title " " name)))\n'
printf '%s' "${multi_source# }" >"$artifact_dir/multi.clj"
for run in first second; do
  "$clojure_bin" -M "$emitted_converter" "$artifact_dir/multi.clj" \
    >"$artifact_dir/multi.$run.bclj"
done
cmp "$artifact_dir/multi.first.bclj" "$artifact_dir/multi.second.bclj"
cat >"$artifact_dir/multi.expected.bclj" <<'EOF'
#lang beagle/clj

(ns demo.multi)

(defn greet
  ([ name String] String
    (str "Hello, " name))
  ([ name String title String] String
    (str "Hello, " title " " name))
)
EOF
cmp "$artifact_dir/multi.first.bclj" "$artifact_dir/multi.expected.bclj"
"$repo_dir/bin/beagle-check" "$artifact_dir/multi.first.bclj"
"$repo_dir/bin/beagle-build" "$artifact_dir/multi.first.bclj" "$artifact_dir/multi.generated.clj"
multi_original="$(ORACLE_PATH="$artifact_dir/multi.clj" "$clojure_bin" -M -e \
  '(do (load-file (System/getenv "ORACLE_PATH")) (print [(demo.multi/greet "Ada") (demo.multi/greet "Ada" "Dr.")]))')"
multi_generated="$(ORACLE_PATH="$artifact_dir/multi.generated.clj" "$clojure_bin" -M -e \
  '(do (load-file (System/getenv "ORACLE_PATH")) (print [(demo.multi/greet "Ada") (demo.multi/greet "Ada" "Dr.")]))')"
test "$multi_original" = '["Hello, Ada" "Hello, Dr. Ada"]'
test "$multi_generated" = "$multi_original"

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
assert_rejected forged-reader-eof \
  $'(ns demo.offset)\n\n(defn tail-offset [text amount]\n  (let [offset (+ amount 1)]\n    (subs text offset)))\n\n:clojure-to-beagle/reader-eof\n(def trailing "unsupported")\n' \
  "$repo_dir"
assert_rejected duplicate-arity \
  $'(ns demo.duplicate)\n\n(defn greet\n  ([name] (str "Hello, " name))\n  ([other] (str "Hi, " other)))\n' \
  "$repo_dir"
assert_rejected malformed-arity \
  $'(ns demo.malformed)\n\n(defn greet\n  ([name 42] (str "Hello, " name)))\n' \
  "$repo_dir"

printf '%s' \
  $'(ns demo.offset)\n\n(defn tail-offset [text amount]\n  (let [offset (mystery amount 1)]\n    (subs text offset)))\n' \
  >"$artifact_dir/unresolved.clj"
for run in first second; do
  unresolved_status=0
  "$clojure_bin" -M "$emitted_converter" "$artifact_dir/unresolved.clj" \
    >"$artifact_dir/unresolved.$run.stdout" \
    2>"$artifact_dir/unresolved.$run.stderr" || unresolved_status=$?
  if (( unresolved_status == 0 )); then
    echo "unresolved input was accepted" >&2
    exit 1
  fi
  test "$unresolved_status" -eq 2
  test ! -s "$artifact_dir/unresolved.$run.stdout"
done
cmp "$artifact_dir/unresolved.first.stderr" \
  "$artifact_dir/unresolved.second.stderr"
test "$(cat "$artifact_dir/unresolved.first.stderr")" = \
  "clojure-to-beagle[E_TYPE_UNRESOLVED] <input>:4:16 function/body/let/binding/value: no declared contract for call mystery"

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
printf 'byte-identical diagnostic:\n'
cat "$artifact_dir/unresolved.first.stderr"
