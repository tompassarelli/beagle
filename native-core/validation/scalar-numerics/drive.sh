#!/usr/bin/env bash
# Freezes native-scalar-v0 against one Native program and two strict C17
# frontends. Every external phase and corpus case has its own deadline.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="${NATIVE_SCALAR_REPO:-$(cd "$here/../../.." && pwd)}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/native-scalar-numerics.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT
export BEAGLE_CORE_BUILD_CACHE="$scratch/build-cache"

die() {
  echo "scalar-numerics/drive.sh: $*" >&2
  exit 1
}

phase() {
  echo "scalar-numerics: phase $1"
}

for command in awk bash cmp gcc rg sed sort tail timeout tr; do
  command -v "$command" >/dev/null 2>&1 \
    || die "required command is unavailable: $command"
done

find_clang() {
  if command -v clang >/dev/null 2>&1; then
    command -v clang
    return 0
  fi
  local candidate
  candidate="$(compgen -G '/nix/store/*-clang-wrapper-*/bin/clang' \
    | sort -V | tail -1)"
  [[ -n "$candidate" ]] && printf '%s\n' "$candidate"
}

clang_bin="$(find_clang || true)"
[[ -n "$clang_bin" ]] || die "required command is unavailable: clang"

corpus="$here/corpus.tsv"
fixture="$here/fixture.bgl"
artifacts="$scratch/artifacts"
build_log="$scratch/build.log"

trap_evidence_exact() {
  local status="$1" expected="$2" stderr_path="$3" stdout_path="$4"
  [[ "$status" -eq 134 && ! -s "$stdout_path" ]] || return 1
  cmp -s "$stderr_path" <(printf 'trap\t%s\n' "$expected")
}

run_with_isolated_stderr() {
  local deadline="$1" kill_after="$2" stdout_path="$3"
  local child_stderr="$4" supervisor_stderr="$5"
  shift 5
  (ulimit -c 0; timeout --foreground --kill-after="$kill_after" "$deadline" \
    bash -c 'child_stderr=$1; shift; exec "$@" 2>"$child_stderr"' \
      _ "$child_stderr" "$@" >"$stdout_path" 2>"$supervisor_stderr") \
    2>>"$supervisor_stderr"
}

harness_regression() {
  local forged_stdout="$scratch/forged.stdout"
  local forged_stderr="$scratch/forged.stderr"
  local forged_shell_stderr="$scratch/forged.shell-stderr"
  local term_stdout="$scratch/term-ignore.stdout"
  local term_stderr="$scratch/term-ignore.stderr"
  local term_shell_stderr="$scratch/term-ignore.shell-stderr"
  local term_pid_file="$scratch/term-ignore.pid"
  local status term_pid

  phase "harness regression (deadline 0.2s, kill-after 0.2s)"
  set +e
  run_with_isolated_stderr 0.2s 0.2s "$forged_stdout" "$forged_stderr" \
    "$forged_shell_stderr" bash -c \
    'printf "trap\t2\n" >&2; kill -s SEGV "$$"'
  status=$?
  set -e
  [[ $status -eq 139 ]] \
    || die "forged-trap regression did not terminate by SIGSEGV (status $status)"
  cmp -s "$forged_stderr" <(printf 'trap\t2\n') \
    || die "forged-trap regression did not produce exact forged evidence"
  if trap_evidence_exact "$status" 2 "$forged_stderr" "$forged_stdout"; then
    die "harness accepted forged trap evidence from SIGSEGV"
  fi

  set +e
  run_with_isolated_stderr 0.2s 0.2s "$term_stdout" "$term_stderr" \
    "$term_shell_stderr" bash -c \
    'trap "" TERM; printf "%s\n" "$$" >"$1"; while :; do :; done' \
    _ "$term_pid_file"
  status=$?
  set -e
  [[ $status -ne 0 ]] || die "TERM-ignore regression escaped its deadline"
  if trap_evidence_exact "$status" 2 "$term_stderr" "$term_stdout"; then
    die "harness accepted a timed-out TERM-ignoring process as a trap"
  fi
  [[ -s "$term_pid_file" ]] \
    || die "TERM-ignore regression did not publish its child pid"
  read -r term_pid <"$term_pid_file"
  [[ "$term_pid" =~ ^[0-9]+$ ]] || die "TERM-ignore regression published an invalid pid"
  if kill -0 "$term_pid" 2>/dev/null; then
    kill -KILL "$term_pid" 2>/dev/null || true
    die "TERM-ignore regression left child $term_pid alive"
  fi
  echo "scalar-numerics: forged SIGSEGV rejected; TERM-ignore rejected and reaped"
}

awk -F '\t' '
  !/^#/ && NF > 0 && NF != 9 {
    printf "corpus.tsv:%d: expected 9 tab-separated fields, got %d\n", NR, NF
    bad = 1
  }
  END { exit bad }
' "$corpus" || die "malformed corpus"

harness_regression

phase "freeze + C17 materialization (deadline 180s, kill-after 10s)"
if ! timeout --foreground --kill-after=10s 180s "$repo/bin/beagle" build \
    --materializer c17 --out "$artifacts" "$fixture" \
    >"$build_log" 2>&1; then
  sed -n '1,240p' "$build_log" >&2
  die "Native build failed or exceeded 180s"
fi

report="$artifacts/report.txt"
for expected in \
  'stage source-to-typed ACCEPTED' \
  'stage typed-to-native COMPLETE' \
  'native-lowering-result NativeLoweringCompleteV0' \
  'materialize-c17 OK module_0.h module_0.c' \
  'result PASS'; do
  rg -Fx "$expected" "$report" >/dev/null \
    || die "build report is missing: $expected"
done
[[ "$(rg -c '^obligation-projection PASS ' "$report")" -eq 10 ]] \
  || die "Native program did not pass all ten obligations"
if rg -q '^pending ' "$report"; then
  rg '^pending ' "$report" >&2
  die "fixture left a Native lowering root"
fi

function_index() {
  local name="$1"
  awk -v name="$name" \
    '$1 == "lowered" && $3 == name { sub(/^fn_/, "", $2); print $2 }' \
    "$report"
}

definitions=()
while IFS=$'\t' read -r macro name; do
  index="$(function_index "$name")"
  [[ "$index" =~ ^[0-9]+$ ]] || die "unresolved function index: $name"
  definitions+=("-D${macro}=native_m0_fn_${index}")
done <<'FUNCTIONS'
I64_ADD_FN	i64-add
I64_SUBTRACT_FN	i64-subtract
I64_MULTIPLY_FN	i64-multiply
I64_NEGATE_FN	i64-negate
I64_ADD_THREE_LEFT_FN	i64-add-three-left
I64_ADD_THREE_RIGHT_FN	i64-add-three-right
I64_QUOTIENT_FN	i64-quotient
I64_REMAINDER_FN	i64-remainder
I64_MODULUS_FN	i64-modulus
F64_TO_BITS_FN	f64-to-bits
F64_FROM_BITS_FN	f64-from-bits
I64_TRUNCATE_BITS_FN	i64-truncate-bits
F64_ADD_BITS_FN	f64-add-bits
F64_SUBTRACT_BITS_FN	f64-subtract-bits
F64_MULTIPLY_BITS_FN	f64-multiply-bits
F64_DIVIDE_BITS_FN	f64-divide-bits
F64_EQUAL_BITS_FN	f64-equal-bits?
F64_LESS_BITS_FN	f64-less-bits?
F64_LESS_EQUAL_BITS_FN	f64-less-equal-bits?
F64_ADD_LEFT_BITS_FN	f64-add-left-bits
F64_ADD_RIGHT_BITS_FN	f64-add-right-bits
F64_MULTIPLY_THEN_ADD_BITS_FN	f64-multiply-then-add-bits
F64_KERNEL_FN	f64-kernel
FUNCTIONS

run_corpus() {
  local label="$1" runner="$2"
  local id guarantee operation arg0 arg1 arg2 expected abs_tol rel_tol
  local actual status total=0 exact=0 tolerance=0 traps=0
  local stdout="$scratch/$label.stdout" stderr="$scratch/$label.stderr"
  local shell_stderr="$scratch/$label.shell-stderr"

  while IFS=$'\t' read -r id guarantee operation arg0 arg1 arg2 expected \
      abs_tol rel_tol; do
    [[ -z "$id" || "$id" == \#* ]] && continue
    total=$((total + 1))
    : >"$stdout"
    : >"$stderr"
    case "$guarantee" in
      i64-exact|f64-bits-exact|bool-exact)
        if ! timeout --foreground --kill-after=1s 5s "$runner" "$operation" \
            "$arg0" "$arg1" "$arg2" >"$stdout" 2>"$stderr"; then
          sed -n '1,20p' "$stderr" >&2
          die "$label case $id failed or exceeded 5s"
        fi
        actual="$(tr -d '\r\n' <"$stdout")"
        [[ "$actual" == "$expected" ]] \
          || die "$label case $id: expected $expected, got $actual"
        [[ ! -s "$stderr" ]] || die "$label case $id wrote unexpected stderr"
        exact=$((exact + 1))
        ;;
      trap-exact)
        set +e
        run_with_isolated_stderr 5s 1s "$stdout" "$stderr" "$shell_stderr" \
          "$runner" "$operation" "$arg0" "$arg1" "$arg2"
        status=$?
        set -e
        trap_evidence_exact "$status" "$expected" "$stderr" "$stdout" \
          || { sed -n '1,20p' "$stderr" >&2
               sed -n '1,20p' "$shell_stderr" >&2
               die "$label case $id requires exit 134 and exact trap code $expected"; }
        traps=$((traps + 1))
        ;;
      f64-tolerance)
        if ! timeout --foreground --kill-after=1s 5s "$runner" "$operation" \
            "$arg0" "$arg1" "$arg2" >"$stdout" 2>"$stderr"; then
          sed -n '1,20p' "$stderr" >&2
          die "$label case $id failed or exceeded 5s"
        fi
        actual="$(tr -d '\r\n' <"$stdout")"
        awk -v actual="$actual" -v expected="$expected" \
            -v abs_tol="$abs_tol" -v rel_tol="$rel_tol" '
          function abs(value) { return value < 0 ? -value : value }
          BEGIN {
            difference = abs(actual - expected)
            limit = abs_tol + rel_tol * abs(expected)
            exit !((actual == actual) && (difference <= limit))
          }
        ' || die "$label case $id: $actual exceeds $abs_tol + $rel_tol relative"
        [[ ! -s "$stderr" ]] || die "$label case $id wrote unexpected stderr"
        tolerance=$((tolerance + 1))
        ;;
      *) die "$label case $id has unknown guarantee: $guarantee" ;;
    esac
  done <"$corpus"
  echo "scalar-numerics: $label $total cases PASS ($exact exact, $traps traps, $tolerance tolerance)"
}

compile_and_run() {
  local label="$1" compiler="$2"
  local runner="$scratch/scalar-$label"
  phase "$label strict compile (deadline 60s, kill-after 5s)"
  timeout --foreground --kill-after=5s 60s "$compiler" \
    -std=c17 -pedantic -Wall -Wextra -Werror -O2 \
    -fno-fast-math -ffp-contract=off \
    "${definitions[@]}" -I"$artifacts" -o "$runner" \
    "$artifacts/module_0.c" "$artifacts/native_shim.c" "$here/main.c" -lm \
    || die "$label compilation failed or exceeded 60s"
  phase "$label corpus (5s per case)"
  run_corpus "$label" "$runner"
}

compile_and_run gcc gcc
compile_and_run clang "$clang_bin"

cat "$report"
echo "scalar-numerics: native-scalar-v0 frozen program + GCC/Clang corpus PASS"
