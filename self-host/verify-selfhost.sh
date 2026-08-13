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
#   default corpus: every tracked fixture under self-host/fixtures/, plus
#   $FRAM_REPO/src/fram/fold.bclj when that checkout exists
set -uo pipefail
WT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$WT"
OUT="${SELFHOST_OUT:-self-host/seed}"
LAB=.lab
mkdir -p "$LAB"

# A checkout-local native is mutable build output. Use it only when its seed
# provenance sidecar matches this checkout; otherwise use the current seed.
source self-host/native/stage0-select.sh
beagle_select_stage0 "$OUT" self-host/native/beagle-selfhost || exit $?
# selfhost CLI dispatch — only the main-driver subcommands (emit/check/ast) route
# to native; the stage-isolated -e evals below stay bb (native exposes only the CLI).
sh_main() { # <subcommand> [args...]
  if [ "$STAGE0" = native ]; then "$NATIVE_BIN" "$@"; else bb -cp "$OUT" -m selfhost.main "$@"; fi
}
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
  if bb -cp "$OUT" -e "(require '[$ns :as m]) (System/exit (m/run-tests!))" >/dev/null 2>&1; then
    ok "$m self-tests"
  else
    bad "$m self-tests"
  fi
done

for src in "${MODULES[@]}"; do
  name="$(basename "$src" .bclj)"
  oracle="$LAB/$name-oracle.clj"
  astj="$LAB/$name-ast.json"

  echo "=== oracle mint: $name ==="
  BEAGLE_EMIT_SRCLOC=0 bin/beagle-build "$src" "$oracle" >/dev/null 2>&1 || { bad "$name racket emit (oracle mint)"; continue; }
  bin/beagle-ast "$src" > "$astj" 2>/dev/null || { bad "$name racket AST (oracle mint)"; continue; }

  echo "=== 2. emit parity (racket AST -> self emit) : $name ==="
  bb -cp "$OUT" -e "(require '[selfhost.emit-clj :as e] '[cheshire.core :as json]) (print (e/emit-program! (json/parse-string (slurp \"$astj\") false)))" > "$LAB/$name-stage2.clj" 2>"$LAB/$name-stage2.err"
  if diff -q "$oracle" "$LAB/$name-stage2.clj" >/dev/null 2>&1; then
    ok "$name emit byte-parity (stage-isolated)"
  else
    bad "$name emit byte-parity (stage-isolated) — diff $oracle $LAB/$name-stage2.clj"
  fi

  echo "=== 3. AST parity (self reader+parse vs beagle-ast) : $name ==="
  bb -cp "$OUT" -e "(require '[selfhost.reader :as r] '[selfhost.parse :as p] '[cheshire.core :as json]) (print (json/generate-string (p/parse-program! (r/read-program (slurp \"$src\")))))" > "$LAB/$name-self-ast.json" 2>"$LAB/$name-stage3.err"
  if python3 - "$LAB/$name-self-ast.json" "$astj" <<'EOF' >/dev/null 2>&1
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
same_forms = parser_shape(a.get("forms")) == parser_shape(b.get("forms"))
same_meta = all(a.get(k) == b.get(k) for k in ["requires","imports","namespace","mode","target"])
sys.exit(0 if same_forms and same_meta else 1)
EOF
  then
    ok "$name AST parity (forms/requires/imports/namespace/mode/target)"
  else
    bad "$name AST parity — compare $LAB/$name-self-ast.json vs $astj"
  fi

  echo "=== 4. full self-hosted chain ($STAGE0) vs racket emit : $name ==="
  sh_main emit "$src" > "$LAB/$name-chain.clj" 2>"$LAB/$name-chain.err"
  if diff -q "$oracle" "$LAB/$name-chain.clj" >/dev/null 2>&1; then
    ok "$name FULL-CHAIN byte-parity"
  else
    bad "$name FULL-CHAIN byte-parity — diff $oracle $LAB/$name-chain.clj"
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
    if BEAGLE_EMIT_SRCLOC=0 bin/beagle-build "$inv" "$oracle_out" \
        >"$oracle_stdout" 2>"$oracle_stderr"; then
      bad "$iname oracle accepted (should reject) — emitted $oracle_out"
      continue
    fi
    # selfhost must exit nonzero
    if sh_main check "$inv" >"$LAB/$iname-inv.out" 2>&1; then
      bad "$iname selfhost accepted (should reject)"
    else
      ok "$iname selfhost rejects (exit nonzero)"
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
tail_core() { grep -aoE 'beagle: .*' | head -1 | sed -E 's|.*beagle: (beagle: )?||'; }
if [ -d "$TAIL_DIR" ]; then
  for rp in "$TAIL_DIR"/*.bclj; do
    rname="$(basename "$rp" .bclj)"
    BEAGLE_EMIT_SRCLOC=0 bin/beagle check "$rp" >/dev/null 2>"$LAB/$rname-tail-o.err"; o_exit=$?
    sh_main check "$rp" >"$LAB/$rname-tail-s.err" 2>&1; s_exit=$?
    [ $o_exit -eq 0 ] && o_acc=A || o_acc=R
    [ $s_exit -eq 0 ] && s_acc=A || s_acc=R
    o_core="$(tail_core <"$LAB/$rname-tail-o.err")"
    s_core="$(tail_core <"$LAB/$rname-tail-s.err")"
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
purity_verdict() { # purity_verdict <oracle|selfhost> <fixture> <stdout+stderr path>
  if [ "$1" = oracle ]; then
    bin/beagle check --profile "${BEAGLE_CHECK_PROFILE:-3}" "$2" >"$3" 2>&1
  else
    sh_main check "$2" >"$3" 2>&1
  fi
}
purity_names() { # purity_names <stdout+stderr path>
  python3 - "$1" <<'EOF'
import re, sys
with open(sys.argv[1], encoding="utf-8", errors="replace") as stream:
    print("\n".join(re.findall(r"purity leak: '([^']+)'", stream.read())))
EOF
}
purity_expected_names() { # purity_expected_names <fixture stem>
  case "$1" in
    borrowed-transient-reject) printf '%s\n' append-one ;;
    destructure-shadow-default-reject) printf '%s\n' default-then-shadow ;;
    direct-bang-reject) printf '%s\n' store ;;
    direct-set-reject) printf '%s\n' replace-local ;;
    export-reject) printf '%s\n' store ;;
    mixed-transient-reject) printf '%s\n' mixed ;;
    multi-arity-reject) printf '%s\n' write ;;
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
    (
      unset BEAGLE_PURITY BEAGLE_CHECK_PROFILE
      purity_verdict oracle "$fixture" "$LAB/$pname-purity-o.err"
    ); o_exit=$?
    (
      unset BEAGLE_PURITY BEAGLE_CHECK_PROFILE
      purity_verdict selfhost "$fixture" "$LAB/$pname-purity-s.err"
    ); s_exit=$?
    [ $o_exit -eq 0 ] && o_verdict=A || o_verdict=R
    [ $s_exit -eq 0 ] && s_verdict=A || s_verdict=R
    o_names="$(purity_names "$LAB/$pname-purity-o.err")"
    s_names="$(purity_names "$LAB/$pname-purity-s.err")"
    expected_names="$(purity_expected_names "$pname")" || {
      bad "$pname has no expected purity boundary list"
      continue
    }
    if [ "$o_verdict" != "$expected" ] || [ "$s_verdict" != "$expected" ]; then
      bad "$pname purity verdict (expected=$expected oracle=$o_verdict selfhost=$s_verdict)"
    elif [ "$expected" = R ] &&
         (! grep -q "purity leak" "$LAB/$pname-purity-o.err" ||
          ! grep -q "purity leak" "$LAB/$pname-purity-s.err"); then
      bad "$pname rejected for a non-purity reason"
    elif [ "$o_names" != "$s_names" ]; then
      bad "$pname purity definitions diverge | O: $o_names | S: $s_names"
    elif [ "$o_names" != "$expected_names" ]; then
      bad "$pname purity definitions differ from contract | expected: $expected_names | got: $o_names"
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
    BEAGLE_PURITY="$purity" BEAGLE_CHECK_PROFILE="$profile" \
      purity_verdict oracle "$dial_fixture" "$LAB/$dial-purity-o.err"; o_exit=$?
    BEAGLE_PURITY="$purity" BEAGLE_CHECK_PROFILE="$profile" \
      purity_verdict selfhost "$dial_fixture" "$LAB/$dial-purity-s.err"; s_exit=$?
    [ $o_exit -eq 0 ] && o_verdict=A || o_verdict=R
    [ $s_exit -eq 0 ] && s_verdict=A || s_verdict=R
    o_names="$(purity_names "$LAB/$dial-purity-o.err")"
    s_names="$(purity_names "$LAB/$dial-purity-s.err")"
    if [ "$o_verdict" != "$expected" ] || [ "$s_verdict" != "$expected" ]; then
      bad "$dial purity dial (expected=$expected oracle=$o_verdict selfhost=$s_verdict)"
    elif [ "$warning" -eq 1 ] &&
         (! grep -q "warning: purity leak" "$LAB/$dial-purity-o.err" ||
          ! grep -q "warning: purity leak" "$LAB/$dial-purity-s.err"); then
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
    BEAGLE_EMIT_SRCLOC=0 bin/beagle-build "$src" "$oracle" >/dev/null 2>&1 || { bad "$name mod oracle emit"; continue; }
    bin/beagle-ast "$src" > "$oast" 2>/dev/null || { bad "$name mod oracle ast"; continue; }

    sh_main emit "$src" > "$LAB/$name-mod-chain.clj" 2>"$LAB/$name-mod-chain.err"
    if diff -q "$oracle" "$LAB/$name-mod-chain.clj" >/dev/null 2>&1; then
      ok "$name mod FULL-CHAIN byte-parity"
    else
      bad "$name mod FULL-CHAIN byte-parity — diff $oracle $LAB/$name-mod-chain.clj"
    fi

    sh_main ast "$src" > "$LAB/$name-mod-self.json" 2>/dev/null
    if python3 - "$LAB/$name-mod-self.json" "$oast" <<'EOF' >/dev/null 2>&1
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
same_meta = all(a.get(k) == b.get(k) for k in ["requires","imports","namespace","mode","target"])
core = same_forms and same_meta
sys.exit(0 if (an == bn and core) else 1)
EOF
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
    if BEAGLE_EMIT_SRCLOC=0 bin/beagle-build "$inv" "$LAB/$iname-modinv-o.clj" >/dev/null 2>&1; then
      bad "$iname oracle accepted (should reject)"
      continue
    fi
    if sh_main check "$inv" >"$LAB/$iname-modinv.out" 2>&1; then
      bad "$iname selfhost accepted (should reject)"
    else
      ok "$iname selfhost rejects (exit nonzero)"
    fi
  done
fi

echo ""
echo "=== verify-selfhost: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
