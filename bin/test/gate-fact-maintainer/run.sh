#!/usr/bin/env bash
# Hermetic shadow-parity driver.  It runs the real bin/beagle-test control path
# against a tiny fixture root, so seven candidates and four negative
# substitutions fit inside the routine gate bound.  The repository's one full
# active gate remains a separate exact-commit release check.

set -euo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$ROOT/bin/_beagle-racket"

SUPERVISOR="$ROOT/native-core/bin/run-bounded.rkt"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/gate-fact-maintainer.XXXXXX")"
DRIVER_PIDS=()

driver_cleanup() {
    local status=$?
    local pid
    for pid in "${DRIVER_PIDS[@]:-}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done
    for pid in "${DRIVER_PIDS[@]:-}"; do
        wait "$pid" 2>/dev/null || true
    done
    if [[ "$status" -eq 0 ]]; then
        rm -rf "${scratch:?}"
    else
        echo "gate-fact-maintainer parity: preserved failure artifacts at $scratch" >&2
    fi
    exit "$status"
}
trap driver_cleanup EXIT

fail() {
    echo "gate-fact-maintainer parity: $*" >&2
    exit 1
}

RUN_STATUS=0
run_bounded() {
    local label="$1"
    local deadline="$2"
    local output="$3"
    shift 3
    local receipt="$output.receipt"
    local expected
    echo "gate-fact-maintainer parity: $label START deadline=${deadline}s"
    set +e
    BEAGLE_BOUNDED_COMPLETION_RECEIPT="$receipt" \
        nice -n 19 "$RACKET" "$SUPERVISOR" "$deadline" 2 -- "$@" \
        >"$output" 2>&1
    RUN_STATUS=$?
    set -e
    if [[ "$RUN_STATUS" -eq 124 ]]; then
        expected="subtree-reaped-v0 timeout status=124"
    else
        expected="subtree-reaped-v0 exit status=$RUN_STATUS"
    fi
    [[ -f "$receipt" && "$(<"$receipt")" == "$expected" ]] ||
        fail "$label supervisor receipt mismatch"
    echo "gate-fact-maintainer parity: $label END status=$RUN_STATUS"
}

fixture_template="$scratch/template"
mkdir -p \
    "$fixture_template/native-core/bin" \
    "$fixture_template/beagle-lib/private" \
    "$fixture_template/beagle-test/tests" \
    "$fixture_template/bin/test/racket-scope" \
    "$fixture_template/bin/test/checkout-first" \
    "$fixture_template/bin/test/qualified-ref-scaffold" \
    "$fixture_template/bin/test/consumer-smoke" \
    "$fixture_template/candidate"

cp "$ROOT/native-core/bin/run-bounded.rkt" \
    "$fixture_template/native-core/bin/run-bounded.rkt"
cp "$ROOT/beagle-lib/private/tier-runner.rkt" \
    "$fixture_template/beagle-lib/private/tier-runner.rkt"

cat >"$fixture_template/bin/fixture-phase" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
phase="$(basename "$(dirname "$0")")"
printf '%s:phase:%s\n' "$BEAGLE_GATE_FACT_TEST_SIDE" "$phase" \
    >>"$BEAGLE_GATE_FACT_TEST_AUDIT"
printf 'fixture phase %s\n' "$phase"
if [[ ! -f "$BEAGLE_GATE_FACT_REPO_ROOT/candidate/selected.txt" ]]; then
    echo "fixture: selected source is missing" >&2
    exit 1
fi
EOF
chmod +x "$fixture_template/bin/fixture-phase"
for phase in racket-scope checkout-first qualified-ref-scaffold consumer-smoke; do
    cp "$fixture_template/bin/fixture-phase" \
        "$fixture_template/bin/test/$phase/run.sh"
done

cat >"$fixture_template/beagle-test/tiers.rktd" <<'EOF'
#hash((active . ("unit.rkt")) (demoted . ()) (gated . ()))
EOF
cat >"$fixture_template/candidate/module.rkt" <<'EOF'
#lang racket/base
(provide answer)
(define (answer x) (+ x 1))
EOF
cat >"$fixture_template/beagle-test/tests/unit.rkt" <<'EOF'
#lang racket/base
(require rackunit
         "../../candidate/module.rkt")
(define audit (getenv "BEAGLE_GATE_FACT_TEST_AUDIT"))
(when audit
  (call-with-output-file audit #:exists 'append
    (lambda (out)
      (fprintf out "~a:unit:unit.rkt\n"
               (getenv "BEAGLE_GATE_FACT_TEST_SIDE")))))
(check-equal? (answer 1) 2)
EOF
printf '%s\n' selected >"$fixture_template/candidate/selected.txt"
printf '%s\n' toolchain-v1 >"$fixture_template/candidate/toolchain.txt"
printf '%s\n' policy-v1 >"$fixture_template/candidate/policy.txt"

git -C "$fixture_template" init -q -b main
git -C "$fixture_template" config user.name "Beagle gate fact fixture"
git -C "$fixture_template" config user.email "beagle-gate-facts@example.invalid"
git -C "$fixture_template" add \
    native-core/bin/run-bounded.rkt \
    beagle-lib/private/tier-runner.rkt \
    beagle-test/tiers.rktd \
    beagle-test/tests/unit.rkt \
    bin/fixture-phase \
    bin/test/racket-scope/run.sh \
    bin/test/checkout-first/run.sh \
    bin/test/qualified-ref-scaffold/run.sh \
    bin/test/consumer-smoke/run.sh \
    candidate/module.rkt \
    candidate/selected.txt \
    candidate/toolchain.txt \
    candidate/policy.txt
git -C "$fixture_template" -c commit.gpgsign=false commit -qm "fixture base"
BASE_COMMIT="$(git -C "$fixture_template" rev-parse HEAD)"

case_names=(
    no-op
    whitespace-only-source-edit
    implementation-body-edit
    public-interface-edit
    test-only-edit
    toolchain-policy-substitution
    selected-file-removal
)

mutate_case() {
    local name="$1"
    local repo="$2"
    case "$name" in
        no-op) ;;
        whitespace-only-source-edit)
            printf '\n' >>"$repo/candidate/module.rkt"
            ;;
        implementation-body-edit)
            sed -i 's/(+ x 1)/(+ 1 x)/' "$repo/candidate/module.rkt"
            ;;
        public-interface-edit)
            sed -i 's/answer/answer-v2/g' "$repo/candidate/module.rkt"
            ;;
        test-only-edit)
            sed -i 's/(answer 1) 2/(answer 1) 3/' \
                "$repo/beagle-test/tests/unit.rkt"
            ;;
        toolchain-policy-substitution)
            printf '%s\n' toolchain-v2 >"$repo/candidate/toolchain.txt"
            printf '%s\n' policy-v2 >"$repo/candidate/policy.txt"
            ;;
        selected-file-removal)
            git -C "$repo" rm -q candidate/selected.txt
            ;;
        *) fail "unknown candidate $name" ;;
    esac
}

GATE_ENV=()
set_gate_environment() {
    local repo="$1"
    local observations="$2"
    local side="$3"
    local audit="$4"
    GATE_ENV=(
        env
        BEAGLE_NO_ZO_GATE=1
        BEAGLE_GATE_NO_CACHE=1
        BEAGLE_TEST_JOBS=1
        BEAGLE_TEST_LOCKED=1
        BEAGLE_GATE_FACT_TEST_MODE=1
        "BEAGLE_GATE_FACT_TEST_ROOT=$repo"
        "BEAGLE_GATE_FACT_REPO_ROOT=$repo"
        "BEAGLE_GATE_FACT_BASE_COMMIT=$BASE_COMMIT"
        BEAGLE_GATE_FACT_POLICY=fixture-gate-policy-v1
        BEAGLE_GATE_FACT_VERIFIER=fixture-bin-beagle-test-v1
        "BEAGLE_GATE_FACT_OBSERVATION_DIR=$observations"
        BEAGLE_GATE_FACT_KEEP_OBSERVATIONS=1
        "BEAGLE_GATE_FACT_TEST_SIDE=$side"
        "BEAGLE_GATE_FACT_TEST_AUDIT=$audit"
    )
}

compare_observations() {
    local label="$1"
    local expected="$2"
    local actual="$3"
    local expected_list="$scratch/$label.expected-files"
    local actual_list="$scratch/$label.actual-files"
    find "$expected" -maxdepth 1 -type f \
        \( -name 'phase-*.claim' -o -name 'phase-*.observation' \
           -o -name 'tier-claims.rktd' -o -name 'tier-units.rktd' \) \
        -printf '%f\n' | LC_ALL=C sort >"$expected_list"
    find "$actual" -maxdepth 1 -type f \
        \( -name 'phase-*.claim' -o -name 'phase-*.observation' \
           -o -name 'tier-claims.rktd' -o -name 'tier-units.rktd' \) \
        -printf '%f\n' | LC_ALL=C sort >"$actual_list"
    cmp -s "$expected_list" "$actual_list" ||
        fail "$label required phase/unit set differs"
    while IFS= read -r file; do
        cmp -s "$expected/$file" "$actual/$file" ||
            fail "$label differs at $file"
    done <"$expected_list"
    if [[ -f "$actual/tier-units.rktd" ]] && rg -q '#t' "$actual/tier-units.rktd"; then
        fail "$label observed a cached tier unit"
    fi
}

compare_oracle_runs() {
    local label="$1"
    local audit="$2"
    local left="$3"
    local right="$4"
    local left_file="$scratch/$label.$left.audit"
    local right_file="$scratch/$label.$right.audit"
    rg "^$left:" "$audit" | sed "s/^$left://" >"$left_file"
    rg "^$right:" "$audit" | sed "s/^$right://" >"$right_file"
    cmp -s "$left_file" "$right_file" ||
        fail "$label did not execute the same oracle commands for $left and $right"
}

facts_root="$scratch/facts"
mkdir -p "$facts_root"

run_candidate() {
    local name="$1"
    local repo="$scratch/cases/$name"
    local audit="$scratch/$name.oracle.log"
    local old_observations="$scratch/$name.old-observations"
    local first_observations="$scratch/$name.fact-first-observations"
    local second_observations="$scratch/$name.fact-second-observations"
    local store="$facts_root/$name.framlog"
    local old_status first_status second_status
    echo "gate-fact-maintainer parity: candidate $name"
    mkdir -p "$(dirname "$repo")"
    cp -a "$fixture_template" "$repo"
    mutate_case "$name" "$repo"

    mkdir -p "$old_observations" "$first_observations" "$second_observations"

    set_gate_environment "$repo" "$old_observations" old "$audit"
    run_bounded "$name old claim plan" 10 "$scratch/$name.old-plan.log" \
        "${GATE_ENV[@]}" \
        env BEAGLE_GATE_FACT_PLAN_ONLY=1 "$ROOT/bin/beagle-test" --active-only
    [[ "$RUN_STATUS" -eq 0 ]] || fail "$name old claim plan failed"

    run_bounded "$name old gate" 30 "$scratch/$name.old.log" \
        "${GATE_ENV[@]}" "$ROOT/bin/beagle-test" --active-only
    old_status="$RUN_STATUS"

    set_gate_environment "$repo" "$first_observations" fact-first "$audit"
    run_bounded "$name first fact shadow" 30 "$scratch/$name.fact-first.log" \
        "${GATE_ENV[@]}" env BEAGLE_GATE_FACT_STORE="$store" \
        "$ROOT/bin/beagle-test-facts" --active-only
    first_status="$RUN_STATUS"

    set_gate_environment "$repo" "$second_observations" fact-second "$audit"
    run_bounded "$name cold-reopen fact shadow" 30 "$scratch/$name.fact-second.log" \
        "${GATE_ENV[@]}" env BEAGLE_GATE_FACT_STORE="$store" \
        "$ROOT/bin/beagle-test-facts" --active-only
    second_status="$RUN_STATUS"

    [[ "$old_status" -eq "$first_status" && "$old_status" -eq "$second_status" ]] ||
        fail "$name exit mismatch old=$old_status first=$first_status second=$second_status"
    compare_observations "$name-first" "$old_observations" "$first_observations"
    compare_observations "$name-second" "$old_observations" "$second_observations"
    compare_oracle_runs "$name-first" "$audit" old fact-first
    compare_oracle_runs "$name-second" "$audit" old fact-second
    rg -q 'GateFactMaintainerResultV1' "$scratch/$name.fact-second.log" ||
        fail "$name has no cold maintainer result"
    echo "gate-fact-maintainer parity: candidate $name MATCH exit=$old_status claims=exact units=exact counts=exact cold-reopen=yes cache=disabled"
}

no_op_repo="$scratch/cases/no-op"
no_op_store="$facts_root/no-op.framlog"
no_op_audit="$scratch/no-op.oracle.log"
no_op_observations="$scratch/no-op.old-observations"

run_miss_case() {
    local label="$1"
    local expected_class="$2"
    shift 2
    local observations="$scratch/miss-$label-observations"
    local audit="$scratch/miss-$label.oracle.log"
    local output="$scratch/miss-$label.log"
    local expected_audit="$scratch/miss-$label.expected-audit"
    local actual_audit="$scratch/miss-$label.actual-audit"
    local miss_store="$facts_root/miss-$label.framlog"
    mkdir -p "$observations"
    cp "$no_op_store" "$miss_store"
    set_gate_environment "$no_op_repo" "$observations" "miss-$label" "$audit"
    run_bounded "miss substitution $label" 30 "$output" \
        "${GATE_ENV[@]}" env BEAGLE_GATE_FACT_STORE="$miss_store" "$@" \
        "$ROOT/bin/beagle-test-facts" --active-only
    [[ "$RUN_STATUS" -eq 0 ]] || fail "$label fallback did not preserve old PASS"
    rg -q "misses=.*$expected_class" "$output" ||
        fail "$label did not report durable $expected_class miss"
    prepare_line="$(rg -n "misses=.*$expected_class" "$output" | head -n 1 | cut -d: -f1)"
    fallback_line="$(rg -n 'beagle-test: phase .* START' "$output" | head -n 1 | cut -d: -f1)"
    [[ -n "$prepare_line" && -n "$fallback_line" && "$prepare_line" -lt "$fallback_line" ]] ||
        fail "$label miss was not durable before fallback"
    compare_observations "miss-$label" "$no_op_observations" "$observations"
    rg '^old:' "$no_op_audit" | sed 's/^old://' >"$expected_audit"
    rg "^miss-$label:" "$audit" | sed "s/^miss-$label://" >"$actual_audit"
    cmp -s "$expected_audit" "$actual_audit" ||
        fail "$label did not execute the identical conservative oracle commands"
    echo "gate-fact-maintainer parity: miss $label DURABLE-BEFORE-FALLBACK class=$expected_class"
}

declare -A WORKER_LABEL WORKER_OUTPUT WORKER_RECEIPT

launch_worker() {
    local label="$1"
    local deadline="$2"
    shift 2
    local slug="${label//[^a-zA-Z0-9_-]/_}"
    local output="$scratch/worker-$slug.log"
    local receipt="$scratch/worker-$slug.receipt"
    local pid
    echo "gate-fact-maintainer parity: $label LAUNCH deadline=${deadline}s"
    BEAGLE_BOUNDED_COMPLETION_RECEIPT="$receipt" \
        nice -n 19 "$RACKET" "$SUPERVISOR" "$deadline" 2 -- \
        "$BASH" -c 'set -euo pipefail; "$@"' bash "$@" \
        >"$output" 2>&1 &
    pid=$!
    DRIVER_PIDS+=("$pid")
    WORKER_LABEL["$pid"]="$label"
    WORKER_OUTPUT["$pid"]="$output"
    WORKER_RECEIPT["$pid"]="$receipt"
}

wait_workers() {
    local pid status expected label output receipt
    local -a waiting=("${DRIVER_PIDS[@]}")
    for pid in "${waiting[@]}"; do
        label="${WORKER_LABEL[$pid]}"
        output="${WORKER_OUTPUT[$pid]}"
        receipt="${WORKER_RECEIPT[$pid]}"
        set +e
        wait "$pid"
        status=$?
        set -e
        if [[ "$status" -eq 124 ]]; then
            expected="subtree-reaped-v0 timeout status=124"
        else
            expected="subtree-reaped-v0 exit status=$status"
        fi
        sed -n '1,$p' "$output"
        [[ -f "$receipt" && "$(<"$receipt")" == "$expected" ]] ||
            fail "$label outer supervisor receipt mismatch"
        [[ "$status" -eq 0 ]] || fail "$label failed status=$status"
        echo "gate-fact-maintainer parity: $label COMPLETE"
    done
    DRIVER_PIDS=()
}

export ROOT RACKET SUPERVISOR scratch fixture_template BASE_COMMIT facts_root
export no_op_repo no_op_store no_op_audit no_op_observations
export -f fail run_bounded mutate_case set_gate_environment
export -f compare_observations compare_oracle_runs run_candidate run_miss_case

started_seconds=$SECONDS
for name in "${case_names[@]}"; do
    launch_worker "candidate $name" 90 run_candidate "$name"
done
wait_workers

[[ -f "$no_op_store" && -f "$no_op_audit" &&
   -d "$no_op_observations" ]] || fail "no-op evidence missing"

launch_worker "miss unresolved-route" 45 run_miss_case \
    unresolved-route route-unresolved \
    BEAGLE_GATE_FACT_QUERY_STORE="$facts_root/unresolved-route.framlog"
launch_worker "miss unknown-kind" 45 run_miss_case \
    unknown-kind unknown-fact-kind \
    BEAGLE_GATE_FACT_QUERY_INJECT_UNKNOWN_KIND=1
launch_worker "miss stale-policy" 45 run_miss_case \
    stale-policy stale \
    BEAGLE_GATE_FACT_STORED_POLICY=fixture-stale-policy-v0
launch_worker "miss omitted-dependency" 45 run_miss_case \
    omitted-dependency omitted-dependency \
    BEAGLE_GATE_FACT_OMIT_DEPENDENCY=source:unit.rkt
wait_workers

wall_seconds=$((SECONDS - started_seconds))
echo "gate-fact-maintainer parity: 7/7 candidates matched after cold reopen; 4/4 planted misses durable before identical fallback; real bin control paths; hermetic fixture oracle; cache disabled; wall=${wall_seconds}s"
