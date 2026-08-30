#!/usr/bin/env bash
# Exact semantic-admission regression for the normal hosted compiler route.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-hosted-preflight.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

fail() {
    printf 'hosted-preflight-routing: %s\n' "$*" >&2
    exit 1
}

expect_status() {
    local label="$1" expected="$2" actual="$3"
    [[ "$actual" -eq "$expected" ]] ||
        fail "$label returned $actual, expected $expected"
}

expect_log() {
    local label="$1" path="$2"
    shift 2
    local -a actual=()
    mapfile -t actual <"$path"
    [[ ${#actual[@]} -eq $# ]] ||
        fail "$label logged ${#actual[@]} lines, expected $#"
    local index=0 expected
    for expected in "$@"; do
        [[ "${actual[$index]}" == "$expected" ]] ||
            fail "$label line $((index + 1)) was '${actual[$index]}', expected '$expected'"
        index=$((index + 1))
    done
}

require_reminted_semantic_seed() {
    local receipt="$root/self-host/seed/selfhost/.remint-receipt"
    local source_name output_name expected actual
    [[ -r "$receipt" ]] ||
        fail "semantic admission gate requires the tracked remint receipt"
    for source_name in main.bclj parse.bclj reader.bclj; do
        output_name="${source_name%.bclj}.clj"
        expected="$(awk -F '\t' -v path="$source_name" \
            '$1 == "source" && $2 == path { print $3 }' "$receipt")"
        [[ -n "$expected" ]] ||
            fail "remint receipt does not name source $source_name"
        actual="$(sha256sum -- \
            "$root/self-host/src/selfhost/$source_name")"
        actual="${actual%% *}"
        [[ "$actual" == "$expected" ]] ||
            fail "semantic admission gate requires coordinated remint: source $source_name is newer than the seed"

        expected="$(awk -F '\t' -v path="$output_name" \
            '$1 == "output" && $2 == path { print $3 }' "$receipt")"
        [[ -n "$expected" ]] ||
            fail "remint receipt does not name output $output_name"
        actual="$(sha256sum -- \
            "$root/self-host/seed/selfhost/$output_name")"
        actual="${actual%% *}"
        [[ "$actual" == "$expected" ]] ||
            fail "semantic admission gate requires coordinated remint: seed output $output_name is newer than its receipt"
    done
}

# The semantic half executes the generated bootstrap artifact deliberately.
# Refuse stale evidence: it becomes runnable only after the coordinated remint
# has captured the authored reader, decoder, and admission fold.
require_reminted_semantic_seed

mkdir -p "$scratch/sources"
cat >"$scratch/sources/provider.bjs" <<'EOF'
#lang beagle/js
(ns pkg.name)
(def value Int 1)
EOF
cat >"$scratch/sources/bare.bjs" <<'EOF'
#lang beagle/js
(ns preflight.bare
  (:require [pkg.name :as pkg]))
(def value Int pkg/value)
EOF
cat >"$scratch/sources/undotted-provider.bjs" <<'EOF'
#lang beagle/js
(ns react)
(def version Int 1)
EOF
cat >"$scratch/sources/undotted-bare.bjs" <<'EOF'
#lang beagle/js
(ns preflight.undotted-bare
  (:require [react :as react]))
(def version Int react/version)
EOF
cat >"$scratch/sources/undotted-foreign.bjs" <<'EOF'
#lang beagle/js
(ns preflight.undotted-foreign
  (:require ["react" :as react]))
EOF
cat >"$scratch/sources/foreign.bjs" <<'EOF'
#lang beagle/js
(ns preflight.foreign
  (:require ["pkg.name" :as pkg :refer [make] :rename {make build}]))
EOF
cat >"$scratch/sources/renamed.bjs" <<'EOF'
#lang beagle/js
(ns preflight.renamed
  (:require [pkg.name :refer [value] :rename {value renamed-value}]))
EOF
cat >"$scratch/sources/transitive-provider.bjs" <<'EOF'
#lang beagle/js
(ns preflight.transitive-provider
  (:require ["pkg.name" :as pkg]))
EOF
cat >"$scratch/sources/transitive-consumer.bjs" <<'EOF'
#lang beagle/js
(ns preflight.transitive-consumer
  (:require [preflight.transitive-provider :as provider]))
EOF
cat >"$scratch/sources/noise.bjs" <<'EOF'
#lang beagle/js
(ns preflight.noise
  "The text require [\"pkg.name\"] is not a dependency.")
(def value String "pkg.name")
EOF
cat >"$scratch/sources/--boundary.bjs" <<'EOF'
#lang beagle/js
(ns preflight.boundary)
(def value Int 1)
EOF
cat >"$scratch/sources/malformed.bjs" <<'EOF'
#lang beagle/js
(ns preflight.malformed
  (:require ["pkg.name" :bogus pkg]))
EOF
cat >"$scratch/sources/type-invalid-provider.bjs" <<'EOF'
#lang beagle/js
(ns preflight.type-invalid-provider)
(def value Int "not-an-int")
EOF
cat >"$scratch/sources/invalid-then-esm.bjs" <<'EOF'
#lang beagle/js
(ns preflight.invalid-then-esm
  (:require [preflight.type-invalid-provider :as invalid]
            ["react" :as react]))
(def value Int invalid/value)
EOF
cat >"$scratch/sources/esm-then-invalid.bjs" <<'EOF'
#lang beagle/js
(ns preflight.esm-then-invalid
  (:require ["react" :as react]
            [preflight.type-invalid-provider :as invalid]))
(def value Int invalid/value)
EOF
cat >"$scratch/sources/transitive-malformed-provider.bjs" <<'EOF'
#lang beagle/js
(ns preflight.transitive-malformed-provider
  (:require [missing.provider :bogus value]))
EOF
cat >"$scratch/sources/malformed-then-esm.bjs" <<'EOF'
#lang beagle/js
(ns preflight.malformed-then-esm
  (:require [preflight.transitive-malformed-provider :as malformed]
            ["react" :as react]))
EOF
cat >"$scratch/sources/esm-then-malformed.bjs" <<'EOF'
#lang beagle/js
(ns preflight.esm-then-malformed
  (:require ["react" :as react]
            [preflight.transitive-malformed-provider :as malformed]))
EOF
cat >"$scratch/sources/unresolved-then-esm.bjs" <<'EOF'
#lang beagle/js
(ns preflight.unresolved-then-esm
  (:require [missing.provider :as missing]
            ["react" :as react]))
EOF
cat >"$scratch/sources/esm-then-unresolved.bjs" <<'EOF'
#lang beagle/js
(ns preflight.esm-then-unresolved
  (:require ["react" :as react]
            [missing.provider :as missing]))
EOF
cat >"$scratch/sources/malformed-reader.bjs" <<'EOF'
#lang beagle/js
(ns preflight.malformed-reader
EOF
mkdir -p "$scratch/late-root/late"
cat >"$scratch/late-root/late/provider.bjs" <<'EOF'
#lang beagle/js
(ns late.provider)
(def value Int "must-not-be-selected-after-admission")
EOF
cat >"$scratch/sources/late-edge.bjs" <<'EOF'
#lang beagle/js
(ns preflight.late-edge
  (:require [late.provider :as late]))
(declare-extern late/value Int)
(def value Int late/value)
EOF

write_malformed_source() {
    local label="$1" spec="$2"
    printf '#lang beagle/js\n(ns preflight.%s\n  (:require %s))\n' \
        "$label" "$spec" >"$scratch/sources/$label.bjs"
}

write_malformed_source duplicate-option \
    '["pkg.name" :as pkg :as again]'
write_malformed_source duplicate-refer-option \
    '["pkg.name" :refer [make] :refer [send]]'
write_malformed_source duplicate-rename-option \
    '["pkg.name" :refer [make] :rename {make build} :rename {make again}]'
write_malformed_source missing-as \
    '["pkg.name" :as]'
write_malformed_source missing-rename \
    '["pkg.name" :rename]'
write_malformed_source keyword-alias \
    '["pkg.name" :as :pkg]'
write_malformed_source duplicate-refer \
    '["pkg.name" :refer [make make]]'
write_malformed_source implicit-rename \
    '["pkg.name" :rename {make build}]'
write_malformed_source duplicate-rename-source \
    '["pkg.name" :refer [make] :rename {make build make again}]'
write_malformed_source duplicate-rename-target \
    '["pkg.name" :refer [make send] :rename {make build send build}]'
write_malformed_source local-rename-collision \
    '["pkg.name" :refer [make build] :rename {make build}]'
write_malformed_source identity-rename \
    '["pkg.name" :refer [make] :rename {make make}]'
write_malformed_source nonsymbol-rename \
    '["pkg.name" :refer [make] :rename {make "build"}]'
write_malformed_source nonsymbol-rename-source \
    '["pkg.name" :refer [make] :rename {:make build}]'
write_malformed_source empty-libspec \
    '[]'
write_malformed_source keyword-source \
    '[:pkg.name]'

run_seed_admission() {
    local label="$1" expected="$2" status
    shift 2
    set +e
    bb -cp "$root/self-host/seed" -m selfhost.main check \
        --target js "$@" >"$scratch/$label.stdout" 2>"$scratch/$label.stderr"
    status=$?
    set -e
    expect_status "$label" "$expected" "$status"
    [[ ! -s "$scratch/$label.stdout" ]] ||
        fail "$label wrote check output to stdout"
    if [[ "$expected" -eq 200 ]]; then
        [[ ! -s "$scratch/$label.stderr" ]] ||
            fail "$label status 200 was not a quiet admission result"
    fi
}

run_seed_admission bare-symbol 0 \
    --source "$scratch/sources/provider.bjs" "$scratch/sources/bare.bjs"
mkdir -p "$scratch/module root/pkg"
cp "$scratch/sources/provider.bjs" "$scratch/module root/pkg/name.bjs"
run_seed_admission module-root-space 0 \
    --module-root "pkg=$scratch/module root" "$scratch/sources/bare.bjs"
run_seed_admission double-dash-source 0 \
    -- "$scratch/sources/--boundary.bjs"
run_seed_admission undotted-bare-symbol 0 \
    --source "$scratch/sources/undotted-provider.bjs" \
    "$scratch/sources/undotted-bare.bjs"
run_seed_admission undotted-bare-unresolved 1 \
    "$scratch/sources/undotted-bare.bjs"
grep -Fq 'required namespace react' "$scratch/undotted-bare-unresolved.stderr" ||
    fail "undotted bare symbol was not treated as a Beagle provider identity"
run_seed_admission undotted-native-esm-string 200 \
    "$scratch/sources/undotted-foreign.bjs"
run_seed_admission native-esm-string 200 "$scratch/sources/foreign.bjs"
run_seed_admission namespace-rename 200 \
    --source "$scratch/sources/provider.bjs" "$scratch/sources/renamed.bjs"
run_seed_admission transitive-native-esm 200 \
    --source "$scratch/sources/transitive-provider.bjs" \
    "$scratch/sources/transitive-consumer.bjs"
run_seed_admission invalid-before-esm 200 \
    --source "$scratch/sources/type-invalid-provider.bjs" \
    "$scratch/sources/invalid-then-esm.bjs"
run_seed_admission esm-before-invalid 200 \
    --source "$scratch/sources/type-invalid-provider.bjs" \
    "$scratch/sources/esm-then-invalid.bjs"
run_seed_admission malformed-before-esm 1 \
    --source "$scratch/sources/transitive-malformed-provider.bjs" \
    "$scratch/sources/malformed-then-esm.bjs"
run_seed_admission esm-before-malformed 1 \
    --source "$scratch/sources/transitive-malformed-provider.bjs" \
    "$scratch/sources/esm-then-malformed.bjs"
cmp -s "$scratch/malformed-before-esm.stderr" \
    "$scratch/esm-before-malformed.stderr" ||
    fail "malformed transitive diagnostic depended on require order"
run_seed_admission unresolved-before-esm 1 \
    "$scratch/sources/unresolved-then-esm.bjs"
run_seed_admission esm-before-unresolved 1 \
    "$scratch/sources/esm-then-unresolved.bjs"
grep -Fq 'required namespace missing.provider' \
    "$scratch/unresolved-before-esm.stderr" ||
    fail "unresolved-first graph lost the terminal native diagnostic"
grep -Fq 'required namespace missing.provider' \
    "$scratch/esm-before-unresolved.stderr" ||
    fail "ESM-first graph changed unresolved-error precedence to fallback"
run_seed_admission malformed-reader 1 \
    "$scratch/sources/malformed-reader.bjs"
grep -Fq 'expected ) before EOF' "$scratch/malformed-reader.stderr" ||
    fail "malformed reader input did not retain its native diagnostic"
run_seed_admission source-text-noise 0 "$scratch/sources/noise.bjs"
run_seed_admission malformed-require 1 "$scratch/sources/malformed.bjs"
grep -Fq 'unsupported libspec option :bogus' \
    "$scratch/malformed-require.stderr" ||
    fail "malformed require did not retain its native preflight diagnostic"

run_malformed_admission() {
    local label="$1" diagnostic="$2"
    run_seed_admission "$label" 1 "$scratch/sources/$label.bjs"
    grep -Fq "$diagnostic" "$scratch/$label.stderr" ||
        fail "$label did not report '$diagnostic'"
}

run_malformed_admission duplicate-option 'appears more than once'
run_malformed_admission duplicate-refer-option 'appears more than once'
run_malformed_admission duplicate-rename-option 'appears more than once'
run_malformed_admission missing-as 'option :as requires a value'
run_malformed_admission missing-rename 'option :rename requires a value'
run_malformed_admission keyword-alias ':as expects a symbol'
run_malformed_admission duplicate-refer 'duplicate-free vector of symbols'
run_malformed_admission implicit-rename 'explicitly referred symbol'
run_malformed_admission duplicate-rename-source 'repeats source make'
run_malformed_admission duplicate-rename-target 'duplicate-free local names'
run_malformed_admission local-rename-collision 'duplicate-free local names'
run_malformed_admission identity-rename 'cannot rename a symbol to itself'
run_malformed_admission nonsymbol-rename 'symbol-to-symbol map'
run_malformed_admission nonsymbol-rename-source 'symbol-to-symbol map'
run_malformed_admission empty-libspec 'libspec cannot be empty'
run_malformed_admission keyword-source 'namespace symbol or native ESM string'

run_seed_admission unknown-option 2 \
    --unknown "$scratch/sources/noise.bjs"
run_seed_admission missing-module-root-value 2 \
    "$scratch/sources/noise.bjs" --module-root
run_seed_admission duplicate-target 2 \
    --target js "$scratch/sources/noise.bjs"
run_seed_admission extra-positional 2 \
    "$scratch/sources/noise.bjs" "$scratch/sources/provider.bjs"

# Instrument the irreducible file boundary directly.  The graph command must
# snapshot each exact source once and must reuse a captured module-root miss
# even if that candidate would appear on a later probe in the same process.
set +e
BEAGLE_TEST_ENTRY="$scratch/sources/bare.bjs" \
BEAGLE_TEST_PROVIDER="$scratch/sources/provider.bjs" \
    bb -cp "$root/self-host/seed" -e '
      (require (quote [selfhost.main :as main])
               (quote [selfhost.rt :as rt]))
      (let [entry (System/getenv "BEAGLE_TEST_ENTRY")
            provider (System/getenv "BEAGLE_TEST_PROVIDER")
            real-read rt/read-source-snapshot
            reads (atom {})]
        (with-redefs [rt/read-source-snapshot
                      (fn [path]
                        (let [absolute (.getAbsolutePath (java.io.File. path))]
                          (swap! reads update absolute (fnil inc 0))
                          (real-read path)))]
          (main/-main "check" "--target" "js" "--source" provider "--" entry))
        (let [expected #{(.getAbsolutePath (java.io.File. entry))
                         (.getAbsolutePath (java.io.File. provider))}]
          (when-not (= expected (set (keys @reads)))
            (throw (ex-info "source-unit probe observed the wrong paths"
                     {:expected expected :actual @reads})))
          (when-not (every? (fn [count] (= count 1)) (vals @reads))
            (throw (ex-info "source-unit probe observed a repeated read"
                     {:actual @reads})))))
    ' >"$scratch/source-unit-probe.stdout" \
      2>"$scratch/source-unit-probe.stderr"
source_unit_status=$?
set -e
expect_status source-unit-probe 0 "$source_unit_status"

set +e
BEAGLE_TEST_ENTRY="$scratch/sources/late-edge.bjs" \
BEAGLE_TEST_ROOT="$scratch/late-root" \
BEAGLE_TEST_CANDIDATE="$scratch/late-root/late/provider.bjs" \
    bb -cp "$root/self-host/seed" -e '
      (require (quote [selfhost.main :as main])
               (quote [selfhost.rt :as rt]))
      (let [entry (System/getenv "BEAGLE_TEST_ENTRY")
            root (System/getenv "BEAGLE_TEST_ROOT")
            candidate (.getAbsolutePath
                        (java.io.File. (System/getenv "BEAGLE_TEST_CANDIDATE")))
            real-exists rt/file-exists?
            probes (atom 0)]
        (with-redefs [rt/file-exists?
                      (fn [path]
                        (if (= candidate
                               (.getAbsolutePath (java.io.File. path)))
                          (> (swap! probes inc) 1)
                          (real-exists path)))]
          (main/-main "check" "--target" "js"
            "--module-root" (str "late=" root) "--" entry))
        (when-not (= 1 @probes)
          (throw (ex-info "module-root edge was resolved more than once"
                   {:probes @probes}))))
    ' >"$scratch/resolution-edge-probe.stdout" \
      2>"$scratch/resolution-edge-probe.stderr"
resolution_edge_status=$?
set -e
expect_status resolution-edge-probe 0 "$resolution_edge_status"

# Exercise bin/beagle itself with a sealed fake native executable.  The fake
# controls only command statuses; the seed cases above prove the semantic
# string/symbol decision.  This half proves that the one real native graph walk
# runs exactly once, status 200 alone reaches Racket, and every other failure is
# final.
project="$scratch/project"
mkdir -p "$project/bin" "$project/share" "$project/self-host/native"
cp "$root/bin/beagle" "$root/bin/_beagle-hosted-dispatch" "$project/bin/"
cp "$root/share/targets.sh" "$project/share/targets.sh"

cat >"$project/self-host/native/stage0-select.sh" <<'EOF'
beagle_select_stage0() {
    STAGE0=native
    NATIVE_BIN="${BEAGLE_NATIVE_BIN:?}"
    STAGE0_REASON="test-sealed native"
}
EOF

native_log="$scratch/native.log"
oracle_log="$scratch/oracle.log"
nix_log="$scratch/nix-instantiate.log"
cat >"$scratch/fake-native" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
    printf '<%s>' "$argument" >>"${BEAGLE_TEST_NATIVE_LOG:?}"
done
printf '\n' >>"${BEAGLE_TEST_NATIVE_LOG:?}"
status="${BEAGLE_TEST_FINAL_STATUS:?}"
if [[ "$status" -eq 0 && "${1:-}" == emit ]]; then
    printf 'emitted-by-native\n'
fi
exit "$status"
EOF

cat >"$project/bin/_beagle-racket" <<'EOF'
printf 'racket-setup\n' >>"${BEAGLE_TEST_ORACLE_LOG:?}"
EOF
cat >"$project/bin/oracle-command" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
command_name="$(basename "$0")"
printf '%s %s\n' "$command_name" "$*" >>"${BEAGLE_TEST_ORACLE_LOG:?}"
if [[ "$command_name" == beagle-build ]]; then
    printf 'emitted-by-oracle\n' >"${!#}"
fi
EOF
mkdir -p "$scratch/test-bin"
real_cp="$(command -v cp)"
real_mv="$(command -v mv)"
cat >"$scratch/test-bin/cp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
status="${BEAGLE_TEST_CP_STATUS:-0}"
[[ "$status" -eq 0 ]] || exit "$status"
exec "${BEAGLE_TEST_REAL_CP:?}" "$@"
EOF
cat >"$scratch/test-bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
status="${BEAGLE_TEST_MV_STATUS:-0}"
[[ "$status" -eq 0 ]] || exit "$status"
exec "${BEAGLE_TEST_REAL_MV:?}" "$@"
EOF
cat >"$scratch/test-bin/nix-instantiate" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${BEAGLE_TEST_NIX_LOG:?}"
exit "${BEAGLE_TEST_NIX_INSTANTIATE_STATUS:-0}"
EOF
for command in check ast build; do
    ln -s oracle-command "$project/bin/beagle-$command"
done
chmod +x "$project/bin/beagle" "$scratch/fake-native" \
    "$project/bin/oracle-command" "$scratch/test-bin/cp" \
    "$scratch/test-bin/mv" "$scratch/test-bin/nix-instantiate"

public_source="$scratch/public.bjs"
cat >"$public_source" <<'EOF'
#lang beagle/js
(ns preflight.public)
(def value Int 1)
EOF

run_public() {
    local label="$1" final_status="$2" expected_status="$3" status
    shift 3
    : >"$native_log"
    : >"$oracle_log"
    : >"$nix_log"
    set +e
    BEAGLE_NATIVE_BIN="$scratch/fake-native" \
    _BEAGLE_SELFHOST_EXACT_NATIVE_BIN="$scratch/fake-native" \
    BEAGLE_TEST_NATIVE_LOG="$native_log" \
    BEAGLE_TEST_ORACLE_LOG="$oracle_log" \
    BEAGLE_TEST_NIX_LOG="$nix_log" \
    BEAGLE_TEST_FINAL_STATUS="$final_status" \
    BEAGLE_TEST_REAL_CP="$real_cp" \
    BEAGLE_TEST_REAL_MV="$real_mv" \
    BEAGLE_TEST_CP_STATUS="${BEAGLE_TEST_CP_STATUS:-0}" \
    BEAGLE_TEST_MV_STATUS="${BEAGLE_TEST_MV_STATUS:-0}" \
    BEAGLE_TEST_NIX_INSTANTIATE_STATUS="${BEAGLE_TEST_NIX_INSTANTIATE_STATUS:-0}" \
    PATH="$scratch/test-bin:$PATH" \
        "$project/bin/beagle" "$@" \
        >"$scratch/$label.stdout" 2>"$scratch/$label.stderr"
    status=$?
    set -e
    expect_status "$label" "$expected_status" "$status"
}

run_public native-check 0 0 check "$public_source"
expect_log native-check-native "$native_log" \
    "<check><--target><js><--><$public_source>"
expect_log native-check-oracle "$oracle_log"

run_public native-ast 0 0 ast "$public_source"
expect_log native-ast-native "$native_log" \
    "<ast><--target><js><--><$public_source>"
expect_log native-ast-oracle "$oracle_log"

native_output="$scratch/native-output.mjs"
run_public native-build 0 0 build "$public_source" "$native_output"
expect_log native-build-native "$native_log" \
    "<emit><--target><js><--><$public_source>"
expect_log native-build-oracle "$oracle_log"
grep -Fqx 'emitted-by-native' "$native_output" ||
    fail "supported native build did not publish the native artifact"

run_public foreign-check 200 0 check "$public_source"
expect_log foreign-check-native "$native_log" \
    "<check><--target><js><--><$public_source>"
expect_log foreign-check-oracle "$oracle_log" \
    "racket-setup" "beagle-check $public_source"
[[ ! -s "$scratch/foreign-check.stdout" && ! -s "$scratch/foreign-check.stderr" ]] ||
    fail "quiet native admission status 200 leaked public stdout or stderr"

run_public foreign-ast 200 0 ast "$public_source"
expect_log foreign-ast-native "$native_log" \
    "<ast><--target><js><--><$public_source>"
expect_log foreign-ast-oracle "$oracle_log" \
    "racket-setup" "beagle-ast $public_source"

oracle_output="$scratch/oracle-output.mjs"
run_public foreign-build 200 0 build "$public_source" "$oracle_output"
expect_log foreign-build-native "$native_log" \
    "<emit><--target><js><--><$public_source>"
expect_log foreign-build-oracle "$oracle_log" \
    "racket-setup" "beagle-build $public_source $oracle_output"
grep -Fqx 'emitted-by-oracle' "$oracle_output" ||
    fail "status-200 build did not publish the oracle artifact"

run_public final-failure 17 17 check "$public_source"
expect_log final-failure-native "$native_log" \
    "<check><--target><js><--><$public_source>"
expect_log final-failure-oracle "$oracle_log"

failed_copy_output="$scratch/failed-copy-output.mjs"
BEAGLE_TEST_CP_STATUS=200 run_public copy-status-200 0 2 \
    build "$public_source" "$failed_copy_output"
expect_log copy-status-200-native "$native_log" \
    "<emit><--target><js><--><$public_source>"
expect_log copy-status-200-oracle "$oracle_log"
[[ ! -e "$failed_copy_output" ]] ||
    fail "status-200 copy failure left an output artifact"

failed_publish_output="$scratch/failed-publish-output.mjs"
BEAGLE_TEST_MV_STATUS=200 run_public move-status-200 0 2 \
    build "$public_source" "$failed_publish_output"
expect_log move-status-200-native "$native_log" \
    "<emit><--target><js><--><$public_source>"
expect_log move-status-200-oracle "$oracle_log"
[[ ! -e "$failed_publish_output" ]] ||
    fail "status-200 move failure left an output artifact"

nix_source="$scratch/public.bnix"
cat >"$nix_source" <<'EOF'
#lang beagle/nix
(ns preflight.public-nix)
(def value Int 1)
EOF
nix_output="$scratch/public.nix"
BEAGLE_NIX_EVAL_CHECK=1 \
BEAGLE_TEST_NIX_INSTANTIATE_STATUS=200 \
    run_public nix-evaluation-status-200 0 2 \
        build "$nix_source" "$nix_output"
expect_log nix-evaluation-status-200-native "$native_log" \
    "<emit><--target><nix><--><$nix_source>"
expect_log nix-evaluation-status-200-oracle "$oracle_log"
expect_log nix-evaluation-status-200-evaluator "$nix_log" \
    "--parse -- $nix_output"
grep -Fqx 'emitted-by-native' "$nix_output" ||
    fail "post-publication Nix evaluation failure lost the atomic native artifact"

mkdir -p "$scratch/leading-nix-output"
(
    cd "$scratch/leading-nix-output"
    BEAGLE_NIX_EVAL_CHECK=1 \
        run_public leading-dash-nix-output 0 0 build -- \
            "$nix_source" --public.nix
)
expect_log leading-dash-nix-output-native "$native_log" \
    "<emit><--target><nix><--><$nix_source>"
expect_log leading-dash-nix-output-oracle "$oracle_log"
expect_log leading-dash-nix-output-evaluator "$nix_log" \
    "--parse -- $scratch/leading-nix-output/--public.nix"
grep -Fqx 'emitted-by-native' \
    "$scratch/leading-nix-output/--public.nix" ||
    fail "leading-dash Nix output did not stay positional through validation"

module_root_argument="pkg=$scratch/module root"
run_public module-root-boundary 0 0 check \
    --module-root "$module_root_argument" "$public_source"
expect_log module-root-boundary-native "$native_log" \
    "<check><--target><js><--module-root><$module_root_argument><--><$public_source>"
expect_log module-root-boundary-oracle "$oracle_log"

(
    cd "$scratch/sources"
    run_public double-dash-boundary 0 0 check -- --boundary.bjs
)
expect_log double-dash-boundary-native "$native_log" \
    '<check><--target><js><--><--boundary.bjs>'
expect_log double-dash-boundary-oracle "$oracle_log"

leading_dash_build_output="$scratch/leading-dash-output.mjs"
(
    cd "$scratch/sources"
    run_public double-dash-build-source 0 0 build -- \
        --boundary.bjs "$leading_dash_build_output"
)
expect_log double-dash-build-source-native "$native_log" \
    "<emit><--target><js><--><$scratch/sources/--boundary.bjs>"
expect_log double-dash-build-source-oracle "$oracle_log"
grep -Fqx 'emitted-by-native' "$leading_dash_build_output" ||
    fail "leading-dash build source did not publish the native artifact"

mkdir -p "$scratch/leading-output"
(
    cd "$scratch/leading-output"
    run_public materializer-after-double-dash 0 0 build -- \
        "$public_source" --materializer
)
expect_log materializer-after-double-dash-native "$native_log" \
    "<emit><--target><js><--><$public_source>"
expect_log materializer-after-double-dash-oracle "$oracle_log"
grep -Fqx 'emitted-by-native' "$scratch/leading-output/--materializer" ||
    fail "post-boundary --materializer output did not stay positional"

printf '%s\n' \
    'hosted-preflight-routing: one-snapshot identity, rename grammar, transitive routing, atomic publication, and final failures PASS'
