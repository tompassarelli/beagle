#!/usr/bin/env bash
# Build reproducibility — the same source compiles BYTE-IDENTICALLY every build.
#
# match's emit used (random 99999) for its `match__N` temp, so two builds of the
# same source produced different .clj (broke byte-reproducible builds + forced the
# code-as-facts recompile gate to guard around it). Now the temp is a deterministic
# per-program counter. This gate builds a match-using module TWICE and asserts the
# emitted .clj is byte-identical. Racket-only.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
fail=0

echo "================ build reproducibility (deterministic emit) ================"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
"$ROOT/bin/beagle-build-all" "$HERE/match-fixture.bclj" --out "$W/o1" >/dev/null 2>&1
"$ROOT/bin/beagle-build-all" "$HERE/match-fixture.bclj" --out "$W/o2" >/dev/null 2>&1
c="$(find "$W/o1" -name '*.clj' | head -1)"
if [ -z "$c" ]; then echo "  FAIL  fixture did not build"; exit 1; fi
rel="${c#"$W/o1/"}"
echo "  match temps emitted: $(grep -oE 'match__[0-9]+' "$c" | sort -u | tr '\n' ' ')(deterministic counter, not random)"
if diff -q "$W/o1/$rel" "$W/o2/$rel" >/dev/null 2>&1; then
  echo "  PASS  same source -> byte-identical .clj across two builds"
else
  echo "  FAIL  build is non-deterministic:"; diff "$W/o1/$rel" "$W/o2/$rel" | head; fail=1
fi

# --- js path: the match temp counter must RESET per program (parameterized box,
#     not a module-level box that leaks across programs in one invocation) --------
echo "================ build reproducibility — js match temps reset per program ================"
"$ROOT/bin/beagle-build-all" "$HERE/match-js-a.bjs" "$HERE/match-js-b.bjs" --out "$W/j1" >/dev/null 2>&1
"$ROOT/bin/beagle-build-all" "$HERE/match-js-a.bjs" "$HERE/match-js-b.bjs" --out "$W/j2" >/dev/null 2>&1
ja="$(find "$W/j1" -name 'match_js_a.js')"; jb="$(find "$W/j1" -name 'match_js_b.js')"
if [ -z "$ja" ] || [ -z "$jb" ]; then echo "  FAIL  js fixtures did not build"; fail=1; else
  ta="$(grep -oE '_match_[0-9]+' "$ja" | sort -u | tr '\n' ' ')"
  tb="$(grep -oE '_match_[0-9]+' "$jb" | sort -u | tr '\n' ' ')"
  echo "  module a temps: ${ta}/ module b temps: ${tb}"
  if [ "$(echo "$ta" | tr -d ' ')" = "_match_0" ] && [ "$(echo "$tb" | tr -d ' ')" = "_match_0" ]; then
    echo "  PASS  each program resets to _match_0 (counter is per-program, not a leaked process box)"
  else echo "  FAIL  js match counter leaked across programs (b should also start at _match_0)"; fail=1; fi
  rb="${jb#"$W/j1/"}"
  if diff -q "$W/j1/$rb" "$W/j2/$rb" >/dev/null 2>&1; then
    echo "  PASS  same js source -> byte-identical .js across two builds"
  else echo "  FAIL  js build is non-deterministic"; fail=1; fi
fi

# --- lowering temps: content-deterministic, never build-context-dependent -----
# parse.rkt lowers typed if-let / cond-> / some-> and macro-hygiene binder
# renames through minted temps. Those used Racket's process-global gensym, so
# the SAME module emitted different bytes depending on what else the process
# had parsed before it (daemon / build-all / standalone). Now a per-program
# counter (fresh-lowered-sym, parameterized in parse-program). Assert: module
# built ALONE == module built AFTER another module, byte-identical.
echo "================ build reproducibility — lowering temps content-deterministic ================"
"$ROOT/bin/beagle-build-all" "$HERE/lowering-fixture.bclj" --out "$W/l1" >/dev/null 2>&1
"$ROOT/bin/beagle-build-all" "$HERE/context-pad.bclj" "$HERE/lowering-fixture.bclj" --out "$W/l2" >/dev/null 2>&1
lf="$(find "$W/l1" -name 'lowering_repro.clj' | head -1)"   # output path = ns (demo.lowering-repro)
if [ -z "$lf" ]; then echo "  FAIL  lowering fixture did not build"; fail=1; else
  echo "  temps emitted: $(grep -oE '[A-Za-z-]+__[0-9]+' "$lf" | sort -u | tr '\n' ' ')(per-program counter, not process gensym)"
  rel="${lf#"$W/l1/"}"
  if [ -f "$W/l2/$rel" ] && diff -q "$W/l1/$rel" "$W/l2/$rel" >/dev/null 2>&1; then
    echo "  PASS  same module -> byte-identical .clj built alone vs after another module"
  else
    echo "  FAIL  lowering temps depend on build context:"; diff "$W/l1/$rel" "$W/l2/$rel" 2>&1 | head; fail=1
  fi
fi

echo
[ "$fail" = 0 ] && echo "RESULT: PASS — emit is byte-reproducible (match + lowering temps deterministic, per-program)." || { echo "RESULT: FAIL"; exit 1; }
