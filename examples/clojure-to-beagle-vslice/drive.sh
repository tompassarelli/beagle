#!/usr/bin/env bash
set -euo pipefail

slice_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$slice_dir/../.." && pwd)"
converter_source="$slice_dir/converter.bclj"
fixture_source="$slice_dir/input.clj"
artifact_dir="$(mktemp -d)"
trap 'rm -rf -- "$artifact_dir"' EXIT

fail() {
  printf 'clojure-to-beagle-vslice: %s\n' "$*" >&2
  exit 1
}

assert_equal() {
  local actual="$1"
  local expected="$2"
  local claim="$3"

  if [[ "$actual" != "$expected" ]]; then
    printf 'clojure-to-beagle-vslice: %s\nexpected: %s\nactual:   %s\n' \
      "$claim" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_converter_failure() {
  local label="$1"
  local input_path="$2"
  local run_dir="$3"
  local expected="$4"
  shift 4

  local stdout_path="$artifact_dir/$label.stdout"
  local stderr_path="$artifact_dir/$label.stderr"
  local status=0

  (cd "$run_dir" &&
    "$clojure_bin" "$@" -M "$emitted_converter" "$input_path") \
    >"$stdout_path" 2>"$stderr_path" || status=$?

  ((status == 2)) || fail "$label exited $status instead of 2"
  [[ ! -s "$stdout_path" ]] || fail "$label wrote output before rejection"
  assert_equal "$(<"$stderr_path")" "$expected" "$label diagnostic drifted"
}

clojure_bin="$(nix develop "$repo_dir" --command bash -c 'command -v clojure')"
emitted_converter="$artifact_dir/converter.clj"

"$repo_dir/bin/beagle-check" "$converter_source"
"$repo_dir/bin/beagle-build" "$converter_source" "$emitted_converter"

preserve_source="$artifact_dir/preserve.clj"
preserve_expected="$artifact_dir/preserve.expected.bclj"
preserve_actual="$artifact_dir/preserve.actual.bclj"
printf '%s' \
  $'; leading comment must stay byte-identical\n(ns demo.preserve)\n\n;; body comment\n(defn identity [value]\n  value)\n' \
  >"$preserve_source"
{
  printf '#lang beagle/clj\n\n'
  cat "$preserve_source"
} >"$preserve_expected"
"$clojure_bin" -M "$emitted_converter" --preserve "$preserve_source" \
  >"$preserve_actual"
cmp -s "$preserve_actual" "$preserve_expected" ||
  fail '--preserve changed comments or source bytes after the Beagle header'

"$clojure_bin" -M "$emitted_converter" --reserved-heads |
  tr ' ' '\n' | sort -u >"$artifact_dir/converter-reserved-heads"
rg -o "register-combiner! '[^[:space:])]+" \
  "$repo_dir/beagle-lib/private/parse.rkt" |
  sed "s/.*'//" | sort -u >"$artifact_dir/compiler-reserved-heads"
comm -23 "$artifact_dir/compiler-reserved-heads" \
  "$artifact_dir/converter-reserved-heads" \
  >"$artifact_dir/missing-reserved-heads"
[[ ! -s "$artifact_dir/missing-reserved-heads" ]] ||
  fail "reserved call-head table trails the compiler registry: $(<"$artifact_dir/missing-reserved-heads")"

for run in first second; do
  "$clojure_bin" -M "$emitted_converter" "$fixture_source" \
    >"$artifact_dir/$run.bclj"
  "$clojure_bin" -M "$emitted_converter" --report "$fixture_source" \
    >"$artifact_dir/$run.report"
done

cmp -s "$artifact_dir/first.bclj" "$artifact_dir/second.bclj" ||
  fail 'successive migrations were not byte-identical'
cmp -s "$artifact_dir/first.report" "$artifact_dir/second.report" ||
  fail 'successive reports were not byte-identical'

expected_report='{:namespace "demo.parity" :functions 2 :sccs [{:members [even-step odd-step] :recurrent true}] :rewrites 4 :obligations 0}'
actual_report="$(<"$artifact_dir/first.report")"
assert_equal "$actual_report" "$expected_report" 'migration report drifted'

generated_beagle="$artifact_dir/first.bclj"
generated_clojure="$artifact_dir/generated.clj"
"$repo_dir/bin/beagle-check" "$generated_beagle"
"$repo_dir/bin/beagle-build" "$generated_beagle" "$generated_clojure"

parity_expression='(do (load-file (System/getenv "ORACLE_PATH")) (print (mapv (fn [n] [n (demo.parity/even-step n) (demo.parity/odd-step n)]) [0 1 2 3 8 9 20 21])))'
original_result="$(ORACLE_PATH="$fixture_source" "$clojure_bin" -M -e "$parity_expression")"
generated_result="$(ORACLE_PATH="$generated_clojure" "$clojure_bin" -M -e "$parity_expression")"
expected_result='[[0 true false] [1 false true] [2 true false] [3 false true] [8 true false] [9 false true] [20 true false] [21 false true]]'
assert_equal "$original_result" "$expected_result" 'source fixture parity oracle drifted'
assert_equal "$generated_result" "$original_result" 'generated behavior diverged from source'

generic_rejection='rejected: unsafe, malformed, or unsupported Clojure input'
reader_marker="$artifact_dir/reader-eval-executed"
printf '%s' \
  $'(ns demo.reader-eval)\n\n#=(spit (System/getProperty "reader.marker") "executed")\n' \
  >"$artifact_dir/reader-eval.clj"
assert_converter_failure \
  reader-eval "$artifact_dir/reader-eval.clj" "$repo_dir" "$generic_rejection" \
  "-J-Dreader.marker=$reader_marker"
[[ ! -e "$reader_marker" ]] || fail 'reader evaluation executed before rejection'

reader_cp="$artifact_dir/reader-cp"
tagged_marker="$artifact_dir/tagged-reader-executed"
mkdir -p "$reader_cp"
printf '%s\n' '{evil/tag reader-payload/execute}' >"$reader_cp/data_readers.clj"
printf '%s\n' \
  '(ns reader-payload)' \
  '' \
  '(defn execute [value]' \
  '  (spit (System/getProperty "reader.marker") "executed")' \
  '  value)' \
  >"$reader_cp/reader_payload.clj"
printf '%s' \
  $'(ns demo.tagged-reader)\n\n(defn identity [value]\n  #evil/tag value)\n' \
  >"$artifact_dir/tagged-reader.clj"
assert_converter_failure \
  tagged-reader "$artifact_dir/tagged-reader.clj" "$reader_cp" \
  "$generic_rejection" "-J-Dreader.marker=$tagged_marker" \
  -Sdeps '{:paths ["."]}'
[[ ! -e "$tagged_marker" ]] || fail 'tagged reader executed before rejection'

printf '%s' \
  $'(ns demo.unresolved)\n\n(defn parity [n]\n  (mystery n))\n' \
  >"$artifact_dir/unresolved.clj"
expected_obligation='clojure-to-beagle[E_UNRESOLVED_OBLIGATION] <input>:4:3 owner=parity kind=missing-call-contract subject=mystery'
for run in first second; do
  assert_converter_failure \
    "unresolved.$run" "$artifact_dir/unresolved.clj" "$repo_dir" \
    "$expected_obligation"
done
cmp -s "$artifact_dir/unresolved.first.stderr" \
  "$artifact_dir/unresolved.second.stderr" ||
  fail 'successive unresolved-call diagnostics were not byte-identical'

"$clojure_bin" -M "$emitted_converter" --report "$artifact_dir/unresolved.clj" \
  >"$artifact_dir/unresolved.report"
expected_unresolved_report='{:namespace "demo.unresolved" :functions 1 :sccs [{:members [parity] :recurrent false}] :rewrites 0 :obligations 3}'
assert_equal "$(<"$artifact_dir/unresolved.report")" \
  "$expected_unresolved_report" 'mixed obligation aggregation drifted'

printf '%s' \
  $'(ns demo.collision)\n\n(defn inc [n]\n  n)\n' \
  >"$artifact_dir/collision.clj"
expected_collision='clojure-to-beagle[E_DEFINITION_SHAPE] <input>:3:1 function/name: function name collides with admitted call: inc'
assert_converter_failure \
  collision "$artifact_dir/collision.clj" "$repo_dir" "$expected_collision"

printf '%s' \
  $'(ns demo.local-type)\n\n(defn spin []\n  (let [value (loop [n 0] (recur n))]\n    1))\n' \
  >"$artifact_dir/local-type.clj"
expected_local_type='clojure-to-beagle[E_UNRESOLVED_OBLIGATION] <input>:4:3 owner=spin kind=unresolved-type subject=fn/spin/body/binding/value'
assert_converter_failure \
  local-type "$artifact_dir/local-type.clj" "$repo_dir" "$expected_local_type"

printf '%s' \
  $'(ns demo.shadow)\n\n(defn shadow [inc]\n  (inc 1))\n' \
  >"$artifact_dir/lexical-call.clj"
expected_lexical_call='clojure-to-beagle[E_EXPRESSION_SHAPE] <input>:4:3 fn/shadow/body: lexical binding cannot be used as a call: inc'
assert_converter_failure \
  lexical-call "$artifact_dir/lexical-call.clj" "$repo_dir" \
  "$expected_lexical_call"

printf '%s' \
  $'(ns demo.reserved)\n\n(defn safe\n  [$beagle$x]\n  1)\n' \
  >"$artifact_dir/reserved-identifier.clj"
expected_reserved_identifier="clojure-to-beagle[E_DEFINITION_SHAPE] <input>:3:1 function/parameters: identifier uses reserved compiler prefix: \$beagle\$x"
assert_converter_failure \
  reserved-identifier "$artifact_dir/reserved-identifier.clj" "$repo_dir" \
  "$expected_reserved_identifier"

printf '%s' \
  $'(ns demo.head)\n\n(defn match [x]\n  x)\n' \
  >"$artifact_dir/reserved-head.clj"
expected_reserved_head='clojure-to-beagle[E_DEFINITION_SHAPE] <input>:3:1 function/name: function name collides with admitted call: match'
assert_converter_failure \
  reserved-head "$artifact_dir/reserved-head.clj" "$repo_dir" \
  "$expected_reserved_head"

printf '%s' \
  $'(ns demo.forward)\n\n(defn first-step [n]\n  (second-step n))\n\n(defn second-step [n]\n  (+ n 1))\n' \
  >"$artifact_dir/missing-declare.clj"
expected_missing_declare='clojure-to-beagle[E_UNRESOLVED_OBLIGATION] <input>:4:3 owner=first-step kind=missing-call-contract subject=second-step'
assert_converter_failure \
  missing-declare "$artifact_dir/missing-declare.clj" "$repo_dir" \
  "$expected_missing_declare"

printf '%s' \
  $'(ns demo.late-forward)\n\n(defn first-step [n]\n  (second-step n))\n\n(declare second-step)\n\n(defn second-step [n]\n  (+ n 1))\n' \
  >"$artifact_dir/late-declare.clj"
expected_late_declare='clojure-to-beagle[E_UNRESOLVED_OBLIGATION] <input>:4:3 owner=first-step kind=missing-call-contract subject=second-step'
assert_converter_failure \
  late-declare "$artifact_dir/late-declare.clj" "$repo_dir" \
  "$expected_late_declare"

printf '%s' \
  $'(ns demo.interleaved)\n\n(defn seed [n]\n  (+ n 1))\n\n(declare later)\n\n(defn caller [n]\n  (later n))\n\n(defn later [n]\n  (+ n 1))\n' \
  >"$artifact_dir/interleaved-declare.clj"
"$clojure_bin" -M "$emitted_converter" --report \
  "$artifact_dir/interleaved-declare.clj" \
  >"$artifact_dir/interleaved-declare.report"
expected_interleaved_report='{:namespace "demo.interleaved" :functions 3 :sccs [{:members [seed] :recurrent false} {:members [caller] :recurrent false} {:members [later] :recurrent false}] :rewrites 0 :obligations 0}'
assert_equal "$(<"$artifact_dir/interleaved-declare.report")" \
  "$expected_interleaved_report" 'interleaved declaration visibility drifted'

printf '%s' \
  $'(ns demo.graph)\n\n(declare beta)\n\n(defn alpha [n]\n  (if (zero? n) true (beta (dec n))))\n\n(defn beta [n]\n  (if (zero? n) false (alpha (dec n))))\n\n(defn gamma [n]\n  (+ n 1))\n\n(defn self [n]\n  (if (zero? n) 0 (self (dec n))))\n' \
  >"$artifact_dir/graph.clj"
"$clojure_bin" -M "$emitted_converter" --report "$artifact_dir/graph.clj" \
  >"$artifact_dir/graph.report"
expected_graph_report='{:namespace "demo.graph" :functions 4 :sccs [{:members [alpha beta] :recurrent true} {:members [gamma] :recurrent false} {:members [self] :recurrent true}] :rewrites 6 :obligations 0}'
assert_equal "$(<"$artifact_dir/graph.report")" \
  "$expected_graph_report" 'dependency SCC report drifted'

for tagged_literal in inst uuid; do
  case "$tagged_literal" in
    inst)
      tagged_source=$'(ns demo.inst)\n\n(defn stamp []\n  #inst "2020-01-01T00:00:00.000-00:00")\n'
      tagged_diagnostic='clojure-to-beagle[E_EXPRESSION_SHAPE] <input>:3:1 fn/stamp/body: literal is outside the admitted algebra'
      ;;
    uuid)
      tagged_source=$'(ns demo.uuid)\n\n(defn identity []\n  #uuid "550e8400-e29b-41d4-a716-446655440000")\n'
      tagged_diagnostic='clojure-to-beagle[E_EXPRESSION_SHAPE] <input>:3:1 fn/identity/body: literal is outside the admitted algebra'
      ;;
  esac
  printf '%s' "$tagged_source" >"$artifact_dir/$tagged_literal.clj"
  assert_converter_failure \
    "$tagged_literal" "$artifact_dir/$tagged_literal.clj" "$repo_dir" \
    "$tagged_diagnostic"
done

converter_loc="$(wc -l <"$converter_source" | tr -d '[:space:]')"
any_count="$(rg -o '\bAny\b' "$converter_source" | wc -l | tr -d '[:space:]')"
table_authorities="$(rg -c '^\(def (BUILTIN-CONTRACTS|STRUCTURAL-RULES) ' "$converter_source")"
append_helpers="$(rg -c '^\(defvec-append ' "$converter_source")"
projection_helpers="$(rg -c '^\(defvec-project ' "$converter_source")"
find_helpers="$(rg -c '^\(defvec-find-by ' "$converter_source")"
reserved_heads="$(wc -l <"$artifact_dir/converter-reserved-heads" | tr -d '[:space:]')"

printf '%s\n' \
  'clojure-to-beagle-vslice: PASS' \
  '  determinism: 2 byte-identical migrations, reports, and obligation diagnostics' \
  "  report: $actual_report" \
  '  behavior: source and generated Beagle agree at 8 parity points' \
  '  reader boundary: read-eval and ambient tagged readers rejected without effects' \
  "  mixed obligations: $expected_unresolved_report" \
  "  declaration visibility: $expected_interleaved_report" \
  "  graph: $expected_graph_report" \
  "  authored LOC: $converter_loc" \
  "  explicit table authorities: $table_authorities; macro reuse: $append_helpers append + $projection_helpers projection + $find_helpers find-by helpers" \
  "  compiler call-head coverage: $reserved_heads reserved heads, no registry omissions" \
  "  Any occurrences: $any_count" \
  '  unresolved obligations in migrated fixture: 0' \
  '  change surface: converter.bclj, input.clj, drive.sh (3 files)'
