#!/usr/bin/env bash
# move 3 — code can be claim-canonical.
#
# Proves the loop
#   .bclj --import--> lossless claims --(through a Fram store)--> claims --export--> .bclj'
# is both:
#   (a) DATUM-IDENTICAL through the engine   (the program survives the canonical store)
#   (b) RECOMPILE-IDENTICAL                   (beagle build of the regenerated tree ==
#                                              beagle build of the original, byte-for-byte)
# (b) is the killer proof: a Beagle program can live as canonical claims and the
# regenerated text compiles to the IDENTICAL program — claims-canonical loses
# nothing for the compiler. Import = claims-roundtrip --emit-edn; the canonical
# store = a real Fram store (through-fram.clj); export = byte-stable datum->pretty
# (--render). Needs racket + bb + fram's classpath (FRAM_OUT).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
RT="$ROOT/beagle-lib/private/claims-roundtrip.rkt"
FRAM_OUT="${FRAM_OUT:-$HOME/code/fram/out}"
SRC="${CODE_AS_CLAIMS_CORPUS:-$HOME/code/fram/src}"
fail=0

echo "================ move 3 — code as canonical claims ================"
echo "corpus: $SRC"
if [ ! -d "$FRAM_OUT" ]; then echo "  (need FRAM_OUT — fram classpath)"; exit 3; fi

WORK="$(mktemp -d)"; REGEN="$WORK/regen"; mkdir -p "$REGEN"
trap 'rm -rf "$WORK"' EXIT

# 1. import -> through Fram -> export, per file, into a mirrored tree.
n=0; rtfail=0
while IFS= read -r f; do
  rel="${f#"$SRC"/}"
  mkdir -p "$REGEN/$(dirname "$rel")"
  racket "$RT" --emit-edn "$f" 2>/dev/null > "$WORK/a.edn"
  bb -cp "$FRAM_OUT" "$HERE/through-fram.clj" "$WORK/a.edn" 2>/dev/null > "$WORK/b.edn"
  racket "$RT" --render "$WORK/b.edn" 2>/dev/null > "$REGEN/$rel"
  if ! racket "$RT" --verify "$WORK/b.edn" "$f" 2>/dev/null | grep -q 'reconstructs datum-identically'; then
    echo "  DATUM round-trip FAIL: $rel"; rtfail=$((rtfail+1)); fail=1
  fi
  n=$((n+1))
done < <(find "$SRC" \( -name '*.bclj' -o -name '*.bjs' -o -name '*.bcljs' -o -name '*.bnix' \) | sort)
echo "--- $n files imported→(Fram)→exported; datum round-trip failures: $rtfail ---"

# Bonus, the strongest possible result: is the regenerated SOURCE byte-identical?
srcid=0; srctot=0
while IFS= read -r f; do
  rel="${f#"$SRC"/}"; srctot=$((srctot+1))
  cmp -s "$f" "$REGEN/$rel" && srcid=$((srcid+1))
done < <(find "$SRC" \( -name '*.bclj' -o -name '*.bjs' -o -name '*.bcljs' -o -name '*.bnix' \) | sort)
echo "--- regenerated SOURCE byte-identical to original: $srcid/$srctot files ---"

# 2. recompile-identity: the emitted PROGRAM must be identical, modulo srcloc debug
# pointers (^{:line N :file "..."} reflect text layout/location, not the program; in
# the flipped world they point at the canonical regenerated text). STRICT: beagle
# emission is byte-deterministic (match temps + parse lowering temps are per-program
# counters — gated by bin/test/build-reproducible), so EVERY module byte-compares;
# no double-build nondeterminism guard. A mismatch means the loop changed the program.
echo "--- recompile-identity (beagle build orig vs regen, modulo srcloc; strict byte-compare) ---"
"$ROOT/bin/beagle-build-all" "$SRC"   --out "$WORK/o1" >/dev/null 2>&1
"$ROOT/bin/beagle-build-all" "$REGEN" --out "$WORK/rg" >/dev/null 2>&1
STRIP='s/\^\{:line [0-9]+ :file "[^"]*"\} ?//g'
for d in o1 rg; do find "$WORK/$d" -name '*.clj' -exec sed -i -E "$STRIP" {} + ; done
total=0; mismatch=0
while IFS= read -r oclj; do
  rel="${oclj#"$WORK/o1/"}"
  total=$((total+1))
  if ! diff -q "$WORK/o1/$rel" "$WORK/rg/$rel" >/dev/null 2>&1; then
    echo "  MISMATCH — loop changed the program: $rel"; mismatch=$((mismatch+1)); fail=1
  fi
done < <(find "$WORK/o1" -name '*.clj')
echo "  modules byte-compared: $total (all of them)"
[ "$mismatch" = 0 ] && echo "  PASS — every module recompiles to the IDENTICAL program"

echo
if [ "$fail" = 0 ]; then
  echo "RESULT: PASS — code is losslessly claim-canonical (datum-identical through the Fram store + recompile-identical)."
else
  echo "RESULT: FAIL"; exit 1
fi
