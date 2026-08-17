#!/usr/bin/env bash
# The codegraph modules EXECUTE (codegraph_seam_test.clj only reads their text).
# Tier 1 loads all six under bb and depends on nothing outside the repo; tier 2
# runs rename, roundtrip_fram and supersession_check against the in-tree fixtures
# with their real oracles, and self-gates on beagle. callgraph, codegraph and
# rep_jurisdiction stay tier 1: their goldens need the out-of-tree gjoa corpus.
set -uo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo" || exit 1

scratch="$(mktemp -d)"
trap 'rm -rf "${scratch:?}"' EXIT INT TERM

failures=0
pass() { echo "  [PASS] $*"; }
fail() { echo "  [FAIL] $*" >&2; failures=$((failures + 1)); }
skip() { echo "  [SKIP] $*"; }

# --- tier 1: every module loads ---------------------------------------------
echo "== codegraph exec: module load =="
for ns in callgraph codegraph rename rep-jurisdiction roundtrip-fram supersession-check; do
  if out="$(timeout 120 bb -cp out -e "(require '$ns)" 2>&1)"; then
    pass "$ns loads"
  else
    fail "$ns does not load: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
  fi
done

# --- oracle availability ------------------------------------------------------
beagle_home="${BEAGLE_HOME:-$HOME/code/beagle/main}"
roundtrip="$beagle_home/bin/beagle-roundtrip"

# faith.rkt loads beagle-lib directly, so it needs the racket beagle's bytecode
# was built with — the ambient one is only sometimes that. Beagle resolves it in
# bin/_beagle-racket (which also exports the PLTCOLLECTS scope the collection
# requires resolve through); the recompile gate is off because a test may read
# that checkout but must never rebuild it.
racket_run() {
  if [[ -r "$beagle_home/bin/_beagle-racket" ]]; then   # sourced, never executed
    BEAGLE_NO_ZO_GATE=1 bash -c \
      'source "$0/bin/_beagle-racket" >/dev/null 2>&1; exec "$RACKET" "$@"' \
      "$beagle_home" "$@"
  else
    racket "$@"
  fi
}

if [[ ! -x "$roundtrip" ]]; then
  skip "end-to-end runs — no beagle-roundtrip at $roundtrip (set BEAGLE_HOME)"
  [[ $failures -eq 0 ]] && { echo "codegraph exec: PASS (load tier only)"; exit 0; }
  echo "codegraph exec: FAIL ($failures)" >&2
  exit 1
fi

echo "== codegraph exec: end-to-end =="
trap_src="codegraph/test/trap.bjs"
trap_edn="$scratch/trap.edn"
if ! "$roundtrip" --emit-edn "$trap_src" > "$trap_edn" 2>"$scratch/emit.err"; then
  fail "beagle-roundtrip --emit-edn $trap_src: $(tail -2 "$scratch/emit.err" | tr '\n' ' ')"
  echo "codegraph exec: FAIL ($failures)" >&2
  exit 1
fi

# roundtrip_fram: source -> facts -> a real store -> facts, verified back to source.
if timeout 240 bb -cp out -m roundtrip-fram "$trap_edn" > "$scratch/rt.edn" 2>"$scratch/rt.err" &&
   "$roundtrip" --verify "$scratch/rt.edn" "$trap_src" > "$scratch/verify.out" 2>&1 &&
   grep -Fq 'DATUM IDENTITY through the persisted fact store: PASS' "$scratch/verify.out"; then
  pass "roundtrip_fram: trap.bjs round-trips through a Fram store (--verify)"
else
  fail "roundtrip_fram: $(tail -3 "$scratch/rt.err" "$scratch/verify.out" | tr '\n' ' ')"
fi

# 5 is the trap fixture's count: its substring binding, string literals and
# comment are the occurrences a textual rename would wrongly take too.
rename_out="$scratch/rename.out"
if timeout 240 bb -cp out -m rename red crimson trap "$trap_edn" > "$rename_out" 2>&1 &&
   grep -Fq 'renamed (target file): 5 symbol occurrences' "$rename_out"; then
  pass "rename: 5 symbol occurrences renamed on trap.bjs"
else
  fail "rename on trap.bjs: $(tail -3 "$rename_out" | tr '\n' ' ')"
fi

# The module writes its projection to a path it chooses.
mutated="/tmp/mutated-$(basename "$trap_src").edn"
if [[ -s "$mutated" ]]; then
  pass "rename projected $mutated"
else
  fail "rename wrote no projection at $mutated"
fi

# faith: the projection is the original tree with EXACTLY red->crimson applied.
if racket_run -e '(void (dynamic-require (build-path (or (getenv "BEAGLE_HOME") (build-path (find-system-path (quote home-dir)) "code" "beagle" "main")) "beagle-lib/private/parse.rkt") (quote read-beagle-syntax)))' \
     >/dev/null 2>&1; then
  if [[ -s "$mutated" ]] &&
     BEAGLE_HOME="$beagle_home" racket_run codegraph/test/faith.rkt \
       "$trap_src" "$mutated" red crimson > "$scratch/faith.out" 2>&1 &&
     grep -Fq 'PASS' "$scratch/faith.out"; then
    pass "faith: mutated tree == original with only red->crimson ($(head -1 "$scratch/faith.out"))"
  else
    fail "faith.rkt: $(tail -3 "$scratch/faith.out" 2>/dev/null | tr '\n' ' ')"
  fi
else
  skip "faith.rkt — no racket that can load $beagle_home/beagle-lib"
fi

# collision refusal: renaming onto an existing binding is refused, exit 3, no write.
coll_edn="$scratch/trap-collision.edn"
if "$roundtrip" --emit-edn codegraph/test/trap-collision.bjs > "$coll_edn" 2>/dev/null; then
  timeout 240 bb -cp out -m rename red crimson trap-collision "$coll_edn" > "$scratch/coll.out" 2>&1
  coll_status=$?
  if [[ $coll_status -eq 3 ]] && grep -Fq 'REJECTED' "$scratch/coll.out"; then
    pass "rename refuses a colliding rename (exit 3)"
  else
    fail "collision refusal: exit $coll_status, $(tail -2 "$scratch/coll.out" | tr '\n' ' ')"
  fi
else
  fail "beagle-roundtrip --emit-edn codegraph/test/trap-collision.bjs"
fi

# supersession_check reads this exact path; it is the module's own interface.
cp "$trap_edn" /tmp/trap.edn
if timeout 240 bb -cp out -m supersession-check > "$scratch/sup.out" 2>&1 &&
   grep -Fq 'Withdrawal is real: true' "$scratch/sup.out"; then
  pass "supersession_check: the withdrawn assertion survives, not-live, on the same node"
else
  fail "supersession_check: $(tail -3 "$scratch/sup.out" | tr '\n' ' ')"
fi

if [[ $failures -eq 0 ]]; then
  echo "codegraph exec: PASS"
  exit 0
fi
echo "codegraph exec: FAIL ($failures)" >&2
exit 1
