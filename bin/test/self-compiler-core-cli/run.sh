#!/usr/bin/env bash
# SELF-COMPILER-CORE-CLI: Core CLI contract plus every live source emitter.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
gate="SELF-COMPILER-CORE-CLI"
deadline="${BEAGLE_SELF_COMPILER_CORE_CLI_DEADLINE_SECONDS:-240}"
kill_grace="${BEAGLE_SELF_COMPILER_CORE_CLI_KILL_GRACE_SECONDS:-5}"
[[ "$deadline" =~ ^[1-9][0-9]*$ ]] || {
    printf '%s: invalid deadline: %s\n' "$gate" "$deadline" >&2
    exit 2
}
[[ "$kill_grace" =~ ^[1-9][0-9]*$ ]] || {
    printf '%s: invalid kill grace: %s\n' "$gate" "$kill_grace" >&2
    exit 2
}

source "$root/bin/_beagle-racket"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/beagle-self-compiler-core-cli.XXXXXX")"
cleanup() { rm -rf "${scratch:?}"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

fixture_args=(
    --entry native.zero-variant-fixture/-main
    native-core/validation/zero-variant/action.bgl
    native-core/validation/zero-variant/fixture.bgl
)

compare_output_tree() {
    local label="$1" native_out="$2" oracle_out="$3"
    local native_files="$scratch/$label.native.files"
    local oracle_files="$scratch/$label.oracle.files"
    find "$native_out" -type f ! -name .beagle-publish.lock -printf '%P\n' \
        2>/dev/null | LC_ALL=C sort >"$native_files"
    find "$oracle_out" -type f ! -name .beagle-publish.lock -printf '%P\n' \
        2>/dev/null | LC_ALL=C sort >"$oracle_files"
    cmp -s "$native_files" "$oracle_files" || {
        printf '%s: %s output file set differs\n' "$gate" "$label" >&2
        diff -u "$oracle_files" "$native_files" >&2 || true
        return 1
    }
    while IFS= read -r relative; do
        [[ -n "$relative" ]] || continue
        cmp -s "$native_out/$relative" "$oracle_out/$relative" || {
            printf '%s: %s output differs: %s\n' "$gate" "$label" "$relative" >&2
            return 1
        }
    done <"$oracle_files"
}

extract_report() {
    local input="$1" output="$2"
    awk '
        /^beagle-native-report\/v1$/ { found = 1 }
        found { print }
        /^result / && found { exit }
    ' "$input" >"$output"
}

run_case() {
    local label="$1" native_out="$2" oracle_out="$3" expected="$4"
    local native_rc oracle_rc
    printf '%s: %s START deadline=%ss\n' "$gate" "$label" "$deadline"

    set +e
    env -u BEAGLE_NATIVE_BIN \
        BEAGLE_SELF_COMPILER_COMPILED_OUT="$scratch/compiled" \
        timeout --foreground --kill-after="${kill_grace}s" "$deadline" \
        "$root/bin/beagle-self-compiler-core" \
        --materializer c17 --out "$native_out" "${fixture_args[@]}" \
        >"$scratch/$label.native.stdout" 2>"$scratch/$label.native.stderr"
    native_rc=$?
    BEAGLE_CORE_COMPILED_OVERRIDE="$scratch/compiled" \
        timeout --foreground --kill-after="${kill_grace}s" "$deadline" \
        "$root/bin/beagle-build-core" \
        --materializer c17 --out "$oracle_out" "${fixture_args[@]}" \
        >"$scratch/$label.oracle.stdout" 2>"$scratch/$label.oracle.stderr"
    oracle_rc=$?
    set -e

    [[ "$native_rc" == "$expected" ]] || {
        printf '%s: %s self-host status=%s expected=%s\n' \
            "$gate" "$label" "$native_rc" "$expected" >&2
        return 1
    }
    [[ "$oracle_rc" == "$expected" ]] || {
        printf '%s: %s oracle status=%s expected=%s\n' \
            "$gate" "$label" "$oracle_rc" "$expected" >&2
        return 1
    }
    cmp -s "$scratch/$label.native.stdout" "$scratch/$label.oracle.stdout" || {
        printf '%s: %s stdout differs\n' "$gate" "$label" >&2
        return 1
    }
    extract_report "$scratch/$label.native.stderr" "$scratch/$label.native.report"
    extract_report "$scratch/$label.oracle.stderr" "$scratch/$label.oracle.report"
    cmp -s "$scratch/$label.native.report" \
        "$scratch/$label.oracle.report" || {
        printf '%s: %s report stream differs\n' "$gate" "$label" >&2
        diff -u "$scratch/$label.oracle.report" \
            "$scratch/$label.native.report" >&2 || true
        return 1
    }
    compare_output_tree "$label" "$native_out" "$oracle_out"
    printf '%s: %s END status=%s\n' "$gate" "$label" "$expected"
}

cd "$root"
run_case c17 "$scratch/c17-native" "$scratch/c17-oracle" 0

# The same fixture is intentionally outside the QBE materializer slice. The
# refusal is part of the public contract and must agree in the report stream
# and in the absence of published artifacts.
printf '%s: qbe-refusal START deadline=%ss\n' "$gate" "$deadline"
set +e
env -u BEAGLE_NATIVE_BIN \
    BEAGLE_SELF_COMPILER_COMPILED_OUT="$scratch/compiled" \
    timeout --foreground --kill-after="${kill_grace}s" "$deadline" \
    "$root/bin/beagle-self-compiler-core" \
    --materializer c17 --materializer qbe --out "$scratch/qbe-native" \
    "${fixture_args[@]}" \
    >"$scratch/qbe.native.stdout" 2>"$scratch/qbe.native.stderr"
native_qbe_rc=$?
BEAGLE_CORE_COMPILED_OVERRIDE="$scratch/compiled" \
    timeout --foreground --kill-after="${kill_grace}s" "$deadline" \
    "$root/bin/beagle-build-core" \
    --materializer c17 --materializer qbe --out "$scratch/qbe-oracle" \
    "${fixture_args[@]}" \
    >"$scratch/qbe.oracle.stdout" 2>"$scratch/qbe.oracle.stderr"
oracle_qbe_rc=$?
set -e
[[ "$native_qbe_rc" == 1 && "$oracle_qbe_rc" == 1 ]] || {
    printf '%s: qbe-refusal status mismatch oracle=%s native=%s\n' \
        "$gate" "$oracle_qbe_rc" "$native_qbe_rc" >&2
    exit 1
}
cmp -s "$scratch/qbe.native.stdout" "$scratch/qbe.oracle.stdout" || {
    printf '%s: qbe-refusal stdout differs\n' "$gate" >&2
    exit 1
}
extract_report "$scratch/qbe.native.stderr" "$scratch/qbe.native.report"
extract_report "$scratch/qbe.oracle.stderr" "$scratch/qbe.oracle.report"
cmp -s "$scratch/qbe.native.report" "$scratch/qbe.oracle.report" || {
    printf '%s: qbe-refusal report stream differs\n' "$gate" >&2
    diff -u "$scratch/qbe.oracle.report" "$scratch/qbe.native.report" >&2 || true
    exit 1
}
compare_output_tree qbe-refusal "$scratch/qbe-native" "$scratch/qbe-oracle"
printf '%s: qbe-refusal END status=1\n' "$gate"

# These are the focused suites for every live source emission target. Keep the
# Nix rows explicit: a Core-only gate previously missed Nix regressions.
suites=(
    beagle-test/tests/emit.rkt
    beagle-test/tests/emit-clj-behavioral.rkt
    beagle-test/tests/emit-js.rkt
    beagle-test/tests/emit-js-behavioral.rkt
    beagle-test/tests/emit-nix.rkt
    beagle-test/tests/nix-emit-errors.rkt
    beagle-test/tests/emit-matrix.rkt
)
for suite in "${suites[@]}"; do
    printf '%s: suite %s START deadline=%ss\n' "$gate" "$suite" "$deadline"
    timeout --foreground --kill-after="${kill_grace}s" "$deadline" \
        "$RACO" test "$root/$suite"
    printf '%s: suite %s END\n' "$gate" "$suite"
done

printf '%s: passed Core status/report/C17/QBE parity and all source emission suites\n' "$gate"
