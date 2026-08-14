#!/usr/bin/env bash
# verify-selfhost: oracle ladder for the .bclj self-hosted compiler (tranche 1).
#
# Rungs (each isolates one stage against the Racket compiler as oracle):
#   1. module self-tests under bb
#   2. emit parity, stage-isolated: Racket AST -> self emit-clj vs Racket emit
#   3. AST parity: self reader+parse vs bin/beagle-ast (parser-shape-identical
#      after removing fields added only by the oracle checker projection)
#   4. full chain: self reader -> parse -> check -> emit-clj vs Racket emit (byte diff)
#
# Usage: self-host/verify-selfhost.sh [MODULE.bclj ...]
#   SELFHOST_OUT=/tmp/stage runs the ladder against an isolated authored-source
#   compilation without changing the checked-in seed.
#   default corpus: every tracked fixture under self-host/fixtures/, plus the
#   $FRAM_REPO/src/fram modules listed below that exist in that checkout
#   BEAGLE_ORACLE_ROOT=/path selects the oracle binaries to compare against.
set -uo pipefail
WT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$WT"
ORACLE_ROOT="${BEAGLE_ORACLE_ROOT:-$WT}"
ORACLE_BEAGLE="$ORACLE_ROOT/bin/beagle"
ORACLE_BUILD="$ORACLE_ROOT/bin/beagle-build"
ORACLE_AST="$ORACLE_ROOT/bin/beagle-ast"
OUT="${SELFHOST_OUT:-self-host/seed}"
LAB=.lab
mkdir -p "$LAB"

PHASE_FAST="${BEAGLE_SELFHOST_FAST_DEADLINE:-30}"
PHASE_CHECK="${BEAGLE_SELFHOST_CHECK_DEADLINE:-60}"
PHASE_BUILD="${BEAGLE_SELFHOST_BUILD_DEADLINE:-120}"
PHASE_JSON="${BEAGLE_SELFHOST_JSON_DEADLINE:-30}"
PHASE_KILL_GRACE="${BEAGLE_SELFHOST_KILL_GRACE:-5}"
exec 3>&2
source bin/_beagle-racket
RUN_BOUNDED=(unshare --user --map-current-user --pid --fork --kill-child \
             --forward-signals "$RACKET" native-core/bin/run-bounded.rkt)
BEAGLE_PHASE_SERIAL=0
RUN_PHASE_INFRA=0
RUN_PHASE_STATUS=0

run_phase() { # <name> <deadline-seconds> <command...>
  local phase_name="$1" deadline="$2" state_base status_path receipt_path
  local supervisor_status raw_status expected_receipt receipt
  shift 2
  BEAGLE_PHASE_SERIAL=$((BEAGLE_PHASE_SERIAL + 1))
  state_base="$LAB/.beagle-phase-$$-$BEAGLE_PHASE_SERIAL"
  status_path="$state_base.status"
  receipt_path="$state_base.receipt"
  rm -f "$status_path" "$receipt_path"
  RUN_PHASE_INFRA=0
  RUN_PHASE_STATUS=0
  printf '  START: %s (deadline=%ss)\n' "$phase_name" "$deadline" >&3

  BEAGLE_BOUNDED_COMPLETION_RECEIPT="$receipt_path" \
    "${RUN_BOUNDED[@]}" "$deadline" "$PHASE_KILL_GRACE" -- \
    bash -c '
      status_path=$1
      shift
      "$@"
      status=$?
      printf "%s\n" "$status" >"$status_path"
      exit "$status"
    ' bash "$status_path" "$@"
  supervisor_status=$?

  if [[ -s "$status_path" ]]; then
    read -r raw_status <"$status_path"
    expected_receipt="subtree-reaped-v0 exit status=$raw_status"
    if [[ -f "$receipt_path" ]]; then
      receipt="$(<"$receipt_path")"
    else
      receipt=""
    fi
    if [[ "$receipt" != "$expected_receipt" ]] ||
       ((supervisor_status != raw_status)); then
      rm -f "$status_path" "$receipt_path"
      RUN_PHASE_INFRA=1
      RUN_PHASE_STATUS="$supervisor_status"
      printf '  ERROR: %s (outcome receipt mismatch; command=%s supervisor=%s receipt=%s)\n' \
        "$phase_name" "$raw_status" "$supervisor_status" "${receipt:-missing}" >&3
      return 125
    fi
    rm -f "$status_path" "$receipt_path"
    RUN_PHASE_STATUS="$raw_status"
    if [[ ! "$raw_status" =~ ^[0-9]+$ ]] || ((raw_status >= 128)) ||
       ((raw_status == 126)) || ((raw_status == 127)); then
      RUN_PHASE_INFRA=1
      printf '  ERROR: %s (command-status=%s)\n' "$phase_name" "$raw_status" >&3
    else
      printf '  END: %s (status=%s)\n' "$phase_name" "$raw_status" >&3
    fi
    return "$raw_status"
  fi

  if [[ -f "$receipt_path" ]]; then
    receipt="$(<"$receipt_path")"
  else
    receipt=""
  fi
  rm -f "$status_path" "$receipt_path"
  RUN_PHASE_INFRA=1
  RUN_PHASE_STATUS="$supervisor_status"
  if ((supervisor_status == 124)) &&
     [[ "$receipt" == "subtree-reaped-v0 timeout status=124" ]]; then
    printf '  ERROR: %s (deadline exceeded; status=124)\n' "$phase_name" >&3
  elif ((supervisor_status == 2)) && [[ -z "$receipt" ]]; then
    printf '  ERROR: %s (supervisor setup failure; status=2)\n' \
      "$phase_name" >&3
  else
    printf '  ERROR: %s (supervisor contract status=%s receipt=%s)\n' \
      "$phase_name" "$supervisor_status" "${receipt:-missing}" >&3
  fi
  return "$supervisor_status"
}

# A checkout-local native is mutable build output. Use it only when its seed
# provenance sidecar matches this checkout; otherwise use the current seed.
source self-host/native/stage0-select.sh
beagle_select_stage0 "$OUT" self-host/native/beagle-selfhost || exit $?
# Self-host CLI dispatch — only main-driver subcommands route to native; the
# stage-isolated evals stay bb because native exposes only the CLI.
if [ "$STAGE0" = native ]; then
  SH_MAIN_CMD=("$NATIVE_BIN")
else
  SH_MAIN_CMD=(bb -cp "$OUT" -m selfhost.main)
fi
beagle_stage0_banner "$OUT"

FRAM_REPO="${FRAM_REPO:-$HOME/code/fram/main}"
MODULES=("$@")
if [ ${#MODULES[@]} -eq 0 ]; then
  MODULES=(self-host/fixtures/*.bclj)
  for fram_module in fold branch kernel_classify import provider_host tools; do
    [ -f "$FRAM_REPO/src/fram/$fram_module.bclj" ] && \
      MODULES+=("$FRAM_REPO/src/fram/$fram_module.bclj")
  done
fi

PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== 1. module self-tests (bb) ==="
for m in ast types macros reader parse check emit-clj; do
  ns="selfhost.$m"
  f="$OUT/selfhost/$(echo "$m" | tr '-' '_').clj"
  if [ ! -f "$f" ]; then bad "$m (not built: $f)"; continue; fi
  if run_phase "$m self-tests" "$PHASE_CHECK" \
       bb -cp "$OUT" -e "(require '[$ns :as m]) (System/exit (m/run-tests!))" \
       >/dev/null 2>&1; then
    ok "$m self-tests"
  else
    status=$?
    if ((RUN_PHASE_INFRA)); then
      bad "$m self-tests infrastructure failure (status $status)"
    else
      bad "$m self-tests"
    fi
  fi
done

for src in "${MODULES[@]}"; do
  name="$(basename "$src" .bclj)"
  oracle="$LAB/$name-oracle.clj"
  astj="$LAB/$name-ast.json"

  echo "=== oracle mint: $name ==="
  if run_phase "$name oracle emit" "$PHASE_BUILD" \
       env BEAGLE_EMIT_SRCLOC=0 "$ORACLE_BUILD" "$src" "$oracle" \
       >/dev/null 2>&1; then
    :
  else
    status=$?
    bad "$name racket emit (oracle mint; status $status)"
    continue
  fi
  if run_phase "$name oracle AST" "$PHASE_BUILD" \
       "$ORACLE_AST" "$src" > "$astj" 2>/dev/null; then
    :
  else
    status=$?
    bad "$name racket AST (oracle mint; status $status)"
    continue
  fi

  echo "=== 2. emit parity (racket AST -> self emit) : $name ==="
  if run_phase "$name stage-2 self emit" "$PHASE_CHECK" \
       bb -cp "$OUT" -e "(require '[selfhost.emit-clj :as e] '[cheshire.core :as json]) (print (e/emit-program! (json/parse-string (slurp \"$astj\") false)))" \
       > "$LAB/$name-stage2.clj" 2>"$LAB/$name-stage2.err"; then
    if run_phase "$name stage-2 byte compare" "$PHASE_FAST" \
         diff -q "$oracle" "$LAB/$name-stage2.clj" >/dev/null 2>&1; then
      ok "$name emit byte-parity (stage-isolated)"
    else
      bad "$name emit byte-parity (stage-isolated) — diff $oracle $LAB/$name-stage2.clj"
    fi
  else
    status=$?
    bad "$name stage-2 self emit failed (status $status)"
  fi

  echo "=== 3. AST parity (self reader+parse vs beagle-ast) : $name ==="
  if run_phase "$name stage-3 self AST" "$PHASE_CHECK" \
       bb -cp "$OUT" -e "(require '[selfhost.reader :as r] '[selfhost.parse :as p] '[cheshire.core :as json]) (print (json/generate-string (p/parse-program! (r/read-program (slurp \"$src\")))))" \
       > "$LAB/$name-self-ast.json" 2>"$LAB/$name-stage3.err"; then
    :
  else
    status=$?
    bad "$name self AST generation failed (status $status)"
    continue
  fi
  if run_phase "$name stage-3 JSON compare" "$PHASE_JSON" \
       python3 -c '
import json, sys
a = json.load(open(sys.argv[1])); b = json.load(open(sys.argv[2]))
checked_only = {"provenance", "inferredType", "effectiveType", "raises",
                "constraintSynchronous", "recordUpdate", "recordFieldAccess"}
def parser_shape(value):
    if isinstance(value, dict):
        return {
            key: parser_shape(item)
            for key, item in value.items()
            if key not in checked_only and not (key == "doc" and item is False)
        }
    if isinstance(value, list):
        return [parser_shape(item) for item in value]
    return value
# Externs need driver-level module resolution and are checked in rung 6.
# NOTE: this block is single-quoted shell — no apostrophes below this line.
same_forms = parser_shape(a.get("forms")) == parser_shape(b.get("forms"))
same_meta = all(a.get(k) == b.get(k) for k in ["requires","imports","namespace","target"])
sys.exit(0 if same_forms and same_meta else 1)
' "$LAB/$name-self-ast.json" "$astj" >/dev/null 2>&1
  then
    ok "$name AST parity (forms/requires/imports/namespace/target)"
  else
    bad "$name AST parity — compare $LAB/$name-self-ast.json vs $astj"
  fi

  echo "=== 4. full self-hosted chain ($STAGE0) vs racket emit : $name ==="
  if run_phase "$name full self-host emit" "$PHASE_CHECK" \
       "${SH_MAIN_CMD[@]}" emit "$src" \
       > "$LAB/$name-chain.clj" 2>"$LAB/$name-chain.err"; then
    if run_phase "$name full-chain byte compare" "$PHASE_FAST" \
         diff -q "$oracle" "$LAB/$name-chain.clj" >/dev/null 2>&1; then
      ok "$name FULL-CHAIN byte-parity"
    else
      bad "$name FULL-CHAIN byte-parity — diff $oracle $LAB/$name-chain.clj"
    fi
  else
    status=$?
    bad "$name full self-host emit failed (status $status)"
  fi

  # These fixtures exercise the two regressions where byte differences were
  # immediately product-breaking: a lost :import left CRC32 unresolved, and
  # Racket-only string escapes made kernel_classify unreadable by Clojure.
  case "$name" in
    branch|kernel_classify|imports|control-strings)
      if bb "$LAB/$name-chain.clj" >/dev/null 2>"$LAB/$name-load.err"; then
        ok "$name emitted Clojure loads under bb"
      else
        bad "$name emitted Clojure is unreadable/unloadable — see $LAB/$name-load.err"
      fi
      ;;
  esac
done

echo "=== 5. invalid fixtures — selfhost must exit 1 with pointed error ==="
VALID_ORACLE_CONTROL=self-host/fixtures/mixed-binding-vector.bclj
oracle_builder_ready=0
if [ -f "$VALID_ORACLE_CONTROL" ]; then
  control_out="$LAB/valid-mixed-binding-oracle.clj"
  control_stdout="$LAB/valid-mixed-binding-oracle.out"
  control_stderr="$LAB/valid-mixed-binding-oracle.err"
  if BEAGLE_EMIT_SRCLOC=0 bin/beagle-build "$VALID_ORACLE_CONTROL" "$control_out" \
      >"$control_stdout" 2>"$control_stderr"; then
    ok "known-valid mixed-binding oracle control emits"
    oracle_builder_ready=1
  else
    bad "known-valid mixed-binding oracle control failed — inspect $control_stderr"
    sed -n '1,8p' "$control_stderr" >&2
  fi
else
  bad "known-valid mixed-binding oracle control missing: $VALID_ORACLE_CONTROL"
fi
if [ -d "self-host/fixtures/invalid" ]; then
  for inv in self-host/fixtures/invalid/*.bclj; do
    iname="$(basename "$inv" .bclj)"
    if [ "$oracle_builder_ready" -ne 1 ]; then
      bad "$iname oracle rejection not evaluated (known-valid build control failed)"
      continue
    fi
    oracle_out="$LAB/$iname-inv-oracle.clj"
    oracle_stdout="$LAB/$iname-inv-oracle.out"
    oracle_stderr="$LAB/$iname-inv-oracle.err"
    # oracle must also reject
    if run_phase "$iname invalid oracle" "$PHASE_BUILD" \
         env BEAGLE_EMIT_SRCLOC=0 "$ORACLE_BUILD" "$inv" "$oracle_out" \
         >"$oracle_stdout" 2>"$oracle_stderr"; then
      o_exit=0
    else
      o_exit=$?
    fi
    o_infra=$RUN_PHASE_INFRA
    if ((o_infra)); then
      bad "$iname invalid oracle infrastructure failure (status $o_exit)"
      continue
    elif ((o_exit == 0)); then
      bad "$iname oracle accepted (should reject) — emitted $oracle_out"
      continue
    elif ((o_exit != 1)); then
      bad "$iname oracle rejection status (expected=1 got=$o_exit; see $oracle_stderr)"
      continue
    fi
    if run_phase "$iname invalid self-host" "$PHASE_CHECK" \
         "${SH_MAIN_CMD[@]}" check "$inv" >"$LAB/$iname-inv.out" 2>&1; then
      s_exit=0
    else
      s_exit=$?
    fi
    if ((RUN_PHASE_INFRA)); then
      bad "$iname invalid self-host infrastructure failure (status $s_exit)"
    elif ((s_exit != 1)); then
      bad "$iname self-host rejection status (expected=1 got=$s_exit)"
    else
      ok "$iname oracle/self-host reject (status 1)"
    fi
  done
fi

echo "=== 5b. checker-tail repros — accept/reject + error-core parity vs oracle ==="
# The differential-fuzz checker-precision tail (union-member narrowing family):
# each repro must produce the SAME accept/reject verdict AND, when both reject,
# the SAME error core (the message after the last `beagle:` marker) as the Racket
# oracle. This is the regression wall for the root fix — a re-widened union, a
# lost narrowing, or a reverted lint re-opens a divergence here.
TAIL_DIR=fuzz/repros/checker-tail-20260704
if [ -d "$TAIL_DIR" ]; then
  for rp in "$TAIL_DIR"/*.bclj; do
    rname="$(basename "$rp" .bclj)"
    if run_phase "$rname tail oracle" "$PHASE_CHECK" \
         env BEAGLE_EMIT_SRCLOC=0 "$ORACLE_BEAGLE" check "$rp" \
         >/dev/null 2>"$LAB/$rname-tail-o.err"; then
      o_exit=0
    else
      o_exit=$?
    fi
    o_infra=$RUN_PHASE_INFRA
    if run_phase "$rname tail self-host" "$PHASE_CHECK" \
         "${SH_MAIN_CMD[@]}" check "$rp" \
         >"$LAB/$rname-tail-s.err" 2>&1; then
      s_exit=0
    else
      s_exit=$?
    fi
    s_infra=$RUN_PHASE_INFRA
    if ((o_infra || s_infra)); then
      bad "$rname tail infrastructure failure (oracle=$o_exit selfhost=$s_exit)"
      continue
    fi
    [ $o_exit -eq 0 ] && o_acc=A || o_acc=R
    [ $s_exit -eq 0 ] && s_acc=A || s_acc=R
    if run_phase "$rname tail error-core extraction" "$PHASE_JSON" \
         python3 -c '
import re, sys
for path in sys.argv[1:]:
    with open(path, encoding="utf-8", errors="replace") as stream:
        match = re.search(r"beagle: (?:beagle: )?(.*)", stream.read())
    print(match.group(1) if match else "")
' "$LAB/$rname-tail-o.err" "$LAB/$rname-tail-s.err" \
         >"$LAB/$rname-tail-cores" 2>/dev/null
    then
      mapfile -t tail_cores <"$LAB/$rname-tail-cores"
      o_core="${tail_cores[0]:-}"
      s_core="${tail_cores[1]:-}"
    else
      bad "$rname tail error-core extraction failed"
      continue
    fi
    if [ "$o_acc" != "$s_acc" ]; then
      bad "$rname accept/reject diverges (oracle=$o_acc selfhost=$s_acc)"
    elif [ "$o_acc" = R ] && [ "$o_core" != "$s_core" ]; then
      bad "$rname error-core diverges | O: $o_core | S: $s_core"
    else
      ok "$rname tail parity ($o_acc)"
    fi
  done
fi

echo "=== 5c. purity contract — oracle/selfhost verdict parity ==="
PURITY_DIR=self-host/fixtures/purity
purity_extract() { # purity_extract <phase> <diagnostic path> <output prefix>
  run_phase "$1 purity diagnostic extraction" "$PHASE_JSON" \
    python3 -c '
import re, sys
pattern = re.compile(
    r"purity leak: \x27([^\x27]+)\x27 has no \x27!\x27 suffix but its body uses (.*?)"
    r" — rename to")
with open(sys.argv[1], encoding="utf-8", errors="replace") as stream:
    signatures = pattern.findall(stream.read())
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    stream.write("\n".join(name for name, _ in signatures))
with open(sys.argv[3], "w", encoding="utf-8") as stream:
    stream.write("\n".join(name + "|" + markers
                           for name, markers in signatures))
' "$2" "${3}.names" "${3}.signatures" >/dev/null 2>&1
}
purity_expected_names() { # purity_expected_names <fixture stem>
  case "$1" in
    borrowed-transient-reject) printf '%s\n' append-one ;;
    destructure-shadow-default-reject) printf '%s\n' default-then-shadow ;;
    direct-bang-reject) printf '%s\n' store ;;
    direct-set-reject) printf '%s\n' replace-local ;;
    dynamic-binding-reject) printf '%s\n' invoke ;;
    export-reject) printf '%s\n' store ;;
    mixed-transient-reject) printf '%s\n' mixed ;;
    multi-arity-reject) printf '%s\n' write ;;
    multi-arity-witness-reject) printf '%s\n' write-twice ;;
    nested-reject) printf '%s\n' make-writer ;;
    source-order-reject) printf '%s\n' outer middle inner ;;
    target-case-reject) printf '%s\n' route ;;
    transient-after-persistent-reject) printf '%s\n' mutate-after-persistent ;;
    transient-alias-reject) printf '%s\n' alias-result ;;
    transient-closure-reject) printf '%s\n' escape-closure ;;
    transient-conditional-reject) printf '%s\n' conditional-owned ;;
    transient-context-escape-reject)
      printf '%s\n' container-escape unknown-call-escape default-alias-escape nested-definition-escape
      ;;
    transient-default-reject) printf '%s\n' default-effect ;;
    transient-direct-escape-reject) printf '%s\n' expose ;;
    transient-escape-reject) printf '%s\n' escape ;;
    transient-lifetime-reject)
      printf '%s\n' borrowed global-mutation consumed-in-one-branch shadowed-allocator shadowed-owner
      ;;
    transient-propagation-reject) printf '%s\n' caller wrapper borrowed-mutator ;;
    transient-result-escape-reject) printf '%s\n' expose-result ;;
    *-accept) : ;;
    *) return 1 ;;
  esac
}
purity_expected_signatures() { # only deterministic source/definition surfaces
  case "$1" in
    dynamic-binding-reject) printf '%s\n' 'invoke|writer!' ;;
    multi-arity-witness-reject) printf '%s\n' 'write-twice|reset!, reset!' ;;
    *) return 1 ;;
  esac
}
if [ -d "$PURITY_DIR" ]; then
  for fixture in "$PURITY_DIR"/*.bclj "$PURITY_DIR"/*.bjs; do
    [ -e "$fixture" ] || continue
    pname="$(basename "$fixture")"
    pname="${pname%.*}"
    case "$pname" in
      *-accept) expected=A ;;
      *-reject) expected=R ;;
      *) bad "$pname purity fixture name must end in -accept or -reject"; continue ;;
    esac
    if run_phase "$pname purity oracle" "$PHASE_CHECK" \
         env -u BEAGLE_PURITY -u BEAGLE_CHECK_PROFILE \
         "$ORACLE_BEAGLE" check --profile 3 "$fixture" \
         >"$LAB/$pname-purity-o.err" 2>&1; then
      o_exit=0
    else
      o_exit=$?
    fi
    o_infra=$RUN_PHASE_INFRA
    if run_phase "$pname purity self-host" "$PHASE_CHECK" \
         env -u BEAGLE_PURITY -u BEAGLE_CHECK_PROFILE \
         "${SH_MAIN_CMD[@]}" check "$fixture" \
         >"$LAB/$pname-purity-s.err" 2>&1; then
      s_exit=0
    else
      s_exit=$?
    fi
    s_infra=$RUN_PHASE_INFRA
    if ((o_infra || s_infra)); then
      bad "$pname purity infrastructure failure (oracle=$o_exit selfhost=$s_exit)"
      continue
    fi
    [ $o_exit -eq 0 ] && o_verdict=A || o_verdict=R
    [ $s_exit -eq 0 ] && s_verdict=A || s_verdict=R
    if ! purity_extract "$pname oracle" "$LAB/$pname-purity-o.err" \
         "$LAB/$pname-purity-o"; then
      bad "$pname oracle purity diagnostic extraction failed"
      continue
    fi
    if ! purity_extract "$pname self-host" "$LAB/$pname-purity-s.err" \
         "$LAB/$pname-purity-s"; then
      bad "$pname self-host purity diagnostic extraction failed"
      continue
    fi
    o_names="$(<"$LAB/$pname-purity-o.names")"
    s_names="$(<"$LAB/$pname-purity-s.names")"
    o_signatures="$(<"$LAB/$pname-purity-o.signatures")"
    s_signatures="$(<"$LAB/$pname-purity-s.signatures")"
    expected_names="$(purity_expected_names "$pname")" || {
      bad "$pname has no expected purity boundary list"
      continue
    }
    if [ "$o_verdict" != "$expected" ] || [ "$s_verdict" != "$expected" ]; then
      bad "$pname purity verdict (expected=$expected oracle=$o_verdict selfhost=$s_verdict)"
    elif [ "$expected" = R ] && { [ -z "$o_names" ] || [ -z "$s_names" ]; }; then
      bad "$pname rejected for a non-purity reason"
    elif [ "$o_names" != "$s_names" ]; then
      bad "$pname purity definitions diverge | O: $o_names | S: $s_names"
    elif [ "$o_names" != "$expected_names" ]; then
      bad "$pname purity definitions differ from contract | expected: $expected_names | got: $o_names"
    elif expected_signatures="$(purity_expected_signatures "$pname")"; then
      if [ "$o_signatures" != "$s_signatures" ]; then
        bad "$pname purity witnesses diverge | O: $o_signatures | S: $s_signatures"
      elif [ "$o_signatures" != "$expected_signatures" ]; then
        bad "$pname purity witnesses differ from contract | expected: $expected_signatures | got: $o_signatures"
      else
        ok "$pname exact purity witness parity ($expected)"
      fi
    else
      ok "$pname purity boundary parity ($expected)"
    fi
  done

  dial_fixture="$PURITY_DIR/direct-bang-reject.bclj"
  for dial in off warn-profile-2 warn-profile-3 error-profile-0; do
    case "$dial" in
      off) purity=off; profile=2; expected=A; warning=0 ;;
      warn-profile-2) purity=warn; profile=2; expected=A; warning=1 ;;
      warn-profile-3) purity=warn; profile=3; expected=R; warning=0 ;;
      error-profile-0) purity=error; profile=0; expected=A; warning=0 ;;
    esac
    if run_phase "$dial purity dial oracle" "$PHASE_CHECK" \
         env BEAGLE_PURITY="$purity" BEAGLE_CHECK_PROFILE="$profile" \
         "$ORACLE_BEAGLE" check --profile "$profile" "$dial_fixture" \
         >"$LAB/$dial-purity-o.err" 2>&1; then
      o_exit=0
    else
      o_exit=$?
    fi
    o_infra=$RUN_PHASE_INFRA
    if run_phase "$dial purity dial self-host" "$PHASE_CHECK" \
         env BEAGLE_PURITY="$purity" BEAGLE_CHECK_PROFILE="$profile" \
         "${SH_MAIN_CMD[@]}" check "$dial_fixture" \
         >"$LAB/$dial-purity-s.err" 2>&1; then
      s_exit=0
    else
      s_exit=$?
    fi
    s_infra=$RUN_PHASE_INFRA
    if ((o_infra || s_infra)); then
      bad "$dial purity dial infrastructure failure (oracle=$o_exit selfhost=$s_exit)"
      continue
    fi
    [ $o_exit -eq 0 ] && o_verdict=A || o_verdict=R
    [ $s_exit -eq 0 ] && s_verdict=A || s_verdict=R
    if ! purity_extract "$dial oracle" "$LAB/$dial-purity-o.err" \
         "$LAB/$dial-purity-o"; then
      bad "$dial oracle purity diagnostic extraction failed"
      continue
    fi
    if ! purity_extract "$dial self-host" "$LAB/$dial-purity-s.err" \
         "$LAB/$dial-purity-s"; then
      bad "$dial self-host purity diagnostic extraction failed"
      continue
    fi
    o_names="$(<"$LAB/$dial-purity-o.names")"
    s_names="$(<"$LAB/$dial-purity-s.names")"
    if [ "$o_verdict" != "$expected" ] || [ "$s_verdict" != "$expected" ]; then
      bad "$dial purity dial (expected=$expected oracle=$o_verdict selfhost=$s_verdict)"
    elif [ "$warning" -eq 1 ] &&
         { [[ "$(<"$LAB/$dial-purity-o.err")" != *"warning: purity leak"* ]] ||
           [[ "$(<"$LAB/$dial-purity-s.err")" != *"warning: purity leak"* ]]; }; then
      bad "$dial accepted without matching purity warnings"
    elif [ "$o_names" != "$s_names" ]; then
      bad "$dial purity definitions diverge | O: $o_names | S: $s_names"
    else
      ok "$dial purity dial parity ($expected)"
    fi
  done
fi

echo "=== 6. multi-module fixtures (driver: require resolution + externs import) ==="
# The driver (selfhost.main) resolves (require ...) across sibling files and
# imports each dep's typed surface as externs — the module-resolution port.
# Two checks per fixture: (a) full-chain emit byte-identical to the oracle
# (resolution must not perturb bytes), (b) AST + externs parity, externs
# compared as a SET (ast-json serializes them in hash order, so order is not
# meaningful — the pre-port rung excluded externs entirely; now they must match).
if [ -d "self-host/fixtures/modules" ]; then
  for src in self-host/fixtures/modules/*.bclj; do
    [ -e "$src" ] || continue
    name="$(basename "$src" .bclj)"
    oracle="$LAB/$name-mod-oracle.clj"; oast="$LAB/$name-mod-oracle.json"
    if ! run_phase "$name mod oracle emit" "$PHASE_BUILD" \
         env BEAGLE_EMIT_SRCLOC=0 "$ORACLE_BUILD" "$src" "$oracle" \
         >/dev/null 2>&1; then
      bad "$name mod oracle emit"
      continue
    fi
    if ! run_phase "$name mod oracle AST" "$PHASE_BUILD" \
         "$ORACLE_AST" "$src" > "$oast" 2>/dev/null; then
      bad "$name mod oracle ast"
      continue
    fi

    if ! run_phase "$name mod self-host emit" "$PHASE_CHECK" \
         "${SH_MAIN_CMD[@]}" emit "$src" \
         > "$LAB/$name-mod-chain.clj" 2>"$LAB/$name-mod-chain.err"; then
      bad "$name mod self-host emit"
      continue
    fi
    if run_phase "$name mod byte compare" "$PHASE_FAST" \
         diff -q "$oracle" "$LAB/$name-mod-chain.clj" >/dev/null 2>&1; then
      ok "$name mod FULL-CHAIN byte-parity"
    else
      bad "$name mod FULL-CHAIN byte-parity — diff $oracle $LAB/$name-mod-chain.clj"
    fi

    if ! run_phase "$name mod self-host AST" "$PHASE_CHECK" \
         "${SH_MAIN_CMD[@]}" ast "$src" \
         > "$LAB/$name-mod-self.json" 2>/dev/null; then
      bad "$name mod self-host AST"
      continue
    fi
    if run_phase "$name mod externs JSON compare" "$PHASE_JSON" \
         python3 -c '
import json, sys
a = json.load(open(sys.argv[1])); b = json.load(open(sys.argv[2]))
checked_only = {"provenance", "inferredType", "effectiveType", "raises",
                "constraintSynchronous", "recordUpdate", "recordFieldAccess"}
def parser_shape(value):
    if isinstance(value, dict):
        return {
            key: parser_shape(item)
            for key, item in value.items()
            if key not in checked_only and not (key == "doc" and item is False)
        }
    if isinstance(value, list):
        return [parser_shape(item) for item in value]
    return value
an = {(e["name"], json.dumps(e["type"], sort_keys=True)) for e in a.get("externs", [])}
bn = {(e["name"], json.dumps(e["type"], sort_keys=True)) for e in b.get("externs", [])}
same_forms = parser_shape(a.get("forms")) == parser_shape(b.get("forms"))
same_meta = all(a.get(k) == b.get(k) for k in ["requires","imports","namespace","target"])
core = same_forms and same_meta
sys.exit(0 if (an == bn and core) else 1)
' "$LAB/$name-mod-self.json" "$oast" >/dev/null 2>&1
    then
      ok "$name mod externs+AST parity (driver, externs set-compare)"
    else
      bad "$name mod externs/AST parity — compare $LAB/$name-mod-self.json vs $oast"
    fi
  done
fi

echo "=== 7. invalid module fixtures — unresolved alias must exit 1 both sides ==="
if [ -d "self-host/fixtures/modules/invalid" ]; then
  for inv in self-host/fixtures/modules/invalid/*.bclj; do
    [ -e "$inv" ] || continue
    iname="$(basename "$inv" .bclj)"
    if run_phase "$iname invalid module oracle" "$PHASE_BUILD" \
         env BEAGLE_EMIT_SRCLOC=0 "$ORACLE_BUILD" \
         "$inv" "$LAB/$iname-modinv-o.clj" >/dev/null 2>&1; then
      o_exit=0
    else
      o_exit=$?
    fi
    o_infra=$RUN_PHASE_INFRA
    if ((o_infra)); then
      bad "$iname invalid module oracle infrastructure failure (status $o_exit)"
      continue
    elif ((o_exit != 1)); then
      bad "$iname module oracle rejection status (expected=1 got=$o_exit)"
      continue
    fi
    if run_phase "$iname invalid module self-host" "$PHASE_CHECK" \
         "${SH_MAIN_CMD[@]}" check "$inv" >"$LAB/$iname-modinv.out" 2>&1; then
      s_exit=0
    else
      s_exit=$?
    fi
    if ((RUN_PHASE_INFRA)); then
      bad "$iname invalid module self-host infrastructure failure (status $s_exit)"
    elif ((s_exit != 1)); then
      bad "$iname module self-host rejection status (expected=1 got=$s_exit)"
    else
      ok "$iname module oracle/self-host reject (status 1)"
    fi
  done
fi

echo ""
echo "=== verify-selfhost: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
