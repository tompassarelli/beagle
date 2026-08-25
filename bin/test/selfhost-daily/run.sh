#!/usr/bin/env bash
# Focused normal-hosted cutover check. The caller supplies the exact realized
# .#beagle-selfhost artifact; one exec trace proves that every supported public
# route selects those bytes and never starts Racket or Babashka.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
: "${BEAGLE_NATIVE_BIN:?set BEAGLE_NATIVE_BIN to the realized .#beagle-selfhost binary}"
command -v strace >/dev/null 2>&1 || {
    echo "hosted selfhost normal: strace is required for descendant evidence" >&2
    exit 2
}

native="$(realpath "$BEAGLE_NATIVE_BIN")"
[[ -x "$native" ]] || {
    echo "hosted selfhost normal: native artifact is not executable: $native" >&2
    exit 2
}

expected_hash="$(nix hash path "$ROOT/self-host/seed")"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-hosted-selfhost-normal.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

cat > "$scratch/known.bclj" <<'EOF'
#lang beagle/clj
(ns hosted.known)
(def answer Int 42)
EOF
cat > "$scratch/known.bjs" <<'EOF'
#lang beagle/js
(ns hosted.known-js)
(def answer Int 42)
EOF
cat > "$scratch/known.bnix" <<'EOF'
#lang beagle/nix
(ns hosted.known-nix)
(def answer Int 42)
EOF
cat > "$scratch/invalid.bclj" <<'EOF'
#lang beagle/clj
(ns hosted.invalid)
(def answer Int "wrong")
EOF

export ROOT scratch
export BEAGLE_NATIVE_BIN="$native"
export _BEAGLE_SELFHOST_EXACT_NATIVE_BIN="$native"

trace="$scratch/exec.trace"
strace -f -qq -e trace=execve -o "$trace" \
    bash -c '
        set -euo pipefail
        "$ROOT/bin/beagle" build "$scratch/known.bclj" "$scratch/out.clj"
        "$ROOT/bin/beagle" build "$scratch/known.bjs" "$scratch/out.js"
        "$ROOT/bin/beagle" build "$scratch/known.bnix" "$scratch/out.nix"
        "$ROOT/bin/beagle" check "$scratch/known.bclj" \
            >"$scratch/check.out" 2>"$scratch/check.err"
        "$ROOT/bin/beagle" ast "$scratch/known.bclj" \
            >"$scratch/ast.json" 2>"$scratch/ast.err"
        "$ROOT/bin/beagle" facts-roundtrip --emit-edn "$scratch/known.bclj" \
            >"$scratch/module.edn" 2>"$scratch/facts.err"
        "$ROOT/bin/beagle" facts-roundtrip --render "$scratch/module.edn" \
            >"$scratch/rendered.bclj" 2>"$scratch/render.err"
        if "$ROOT/bin/beagle" check "$scratch/invalid.bclj" \
            >"$scratch/invalid.out" 2>"$scratch/invalid.err"; then
            echo "hosted selfhost normal: invalid source unexpectedly passed" >&2
            exit 1
        fi
    '

passes=0
check() {
    local label="$1"
    shift
    if "$@"; then
        printf '  PASS: %s\n' "$label"
        passes=$((passes + 1))
    else
        printf '  FAIL: %s\n' "$label" >&2
        exit 1
    fi
}

check "Clojure build used native output" test -s "$scratch/out.clj"
check "JavaScript build used native output" test -s "$scratch/out.js"
check "Nix build used native output" test -s "$scratch/out.nix"
check "plain hosted check completed" grep -Fxq "ok" "$scratch/check.err"
check "plain hosted AST is checked-program v4" \
    grep -Fq '"kind":"beagle.checked-program"' "$scratch/ast.json"
check "facts projection completed" test -s "$scratch/module.edn"
check "facts render completed" test -s "$scratch/rendered.bclj"
check "native diagnostic was final" grep -Fq 'beagle [check]:' "$scratch/invalid.err"
check "exact realized Graal artifact executed" \
    grep -Fq "execve(\"$native\"" "$trace"
check "no Racket or Babashka descendant executed" \
    test -z "$(grep -E 'execve\("([^"]*/)?(racket|raco|bb|babashka)"' "$trace" || true)"

native_execs="$(grep -Fc "execve(\"$native\"" "$trace")"
check "all eight hosted decisions selected the Graal artifact" \
    test "$native_execs" -eq 8

printf 'hosted selfhost normal: %d passed, 0 failed; native=%s seed=%s\n' \
    "$passes" "$native" "$expected_hash"
