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

# 2. recompile-identity: build both trees and byte-compare the emitted PROGRAM,
# modulo srcloc debug metadata. beagle bakes ^{:line N :file "..."} pointers into
# the .clj; those necessarily reflect the source text's layout + location (not the
# program), and in the flipped world they correctly point at the canonical
# regenerated text. Strip them, and the actual emitted code must be byte-identical.
echo "--- recompile-identity (beagle build orig vs regen, modulo srcloc) ---"
"$ROOT/bin/beagle-build-all" "$SRC"   --out "$WORK/orig-out"  >/dev/null 2>&1
"$ROOT/bin/beagle-build-all" "$REGEN" --out "$WORK/regen-out" >/dev/null 2>&1
STRIP='s/\^\{:line [0-9]+ :file "[^"]*"\} ?//g'
find "$WORK/orig-out"  -name '*.clj' -exec sed -i -E "$STRIP" {} +
find "$WORK/regen-out" -name '*.clj' -exec sed -i -E "$STRIP" {} +
if diff -rq "$WORK/orig-out" "$WORK/regen-out" >/dev/null 2>&1; then
  echo "  PASS — regenerated tree compiles to the IDENTICAL program ($(find "$WORK/orig-out" -name '*.clj' | wc -l) modules; identical modulo srcloc debug pointers)"
else
  echo "  FAIL — emitted code differs beyond srcloc:"; diff -rq "$WORK/orig-out" "$WORK/regen-out" | head; fail=1
fi

echo
if [ "$fail" = 0 ]; then
  echo "RESULT: PASS — code is losslessly claim-canonical (datum-identical through the Fram store + recompile-identical)."
else
  echo "RESULT: FAIL"; exit 1
fi
