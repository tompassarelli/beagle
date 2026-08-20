#!/usr/bin/env bash
# move 3 — code can be fact-canonical.
#
# Proves the loop
#   .bclj --import--> lossless facts --(through a Beagle Store store)--> facts --export--> .bclj'
# is both:
#   (a) DATUM-IDENTICAL through the engine   (the program survives the canonical store)
#   (b) RECOMPILE-IDENTICAL                   (beagle build of the regenerated tree ==
#                                              beagle build of the original, byte-for-byte)
# (b) is the killer proof: a Beagle program can live as canonical facts and the
# regenerated text compiles to the IDENTICAL program — facts-canonical loses
# nothing for the compiler. Import = facts-roundtrip --emit-edn; the canonical
# store = Beagle Store's real roundtrip-store module; export = byte-stable datum->pretty
# (--render). Needs racket + bb + store's classpath (BEAGLE_STORE_OUT).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
RT="$ROOT/beagle-lib/private/facts-roundtrip.rkt"
source "$ROOT/bin/_beagle-racket"
BEAGLE_STORE_ROOT="$ROOT/store"
BEAGLE_STORE_OUT="${BEAGLE_STORE_OUT:-$BEAGLE_STORE_ROOT/out}"
SRC="${CODE_AS_FACTS_CORPUS:-$BEAGLE_STORE_ROOT/src}"
fail=0

echo "================ move 3 — code as canonical facts ================"
echo "corpus: $SRC"
if [ ! -d "$BEAGLE_STORE_OUT" ]; then echo "  (need BEAGLE_STORE_OUT — store classpath)"; exit 3; fi

WORK="$(mktemp -d)"; REGEN="$WORK/regen"; mkdir -p "$REGEN"
trap 'rm -rf "${WORK:?}"' EXIT

mapfile -d '' SOURCES < <(
  find "$SRC" -type f \( -name '*.bclj' -o -name '*.bjs' -o -name '*.bnix' \) -print0 | sort -z
)
if [ "${#SOURCES[@]}" -eq 0 ]; then
  echo "  FAIL — corpus contains no Beagle source files" >&2
  exit 1
fi
mapfile -d '' COMPILE_SOURCES < <(
  find "$SRC" -type f \( -name '*.bgl' -o -name '*.bclj' -o -name '*.bjs' -o -name '*.bnix' \) -print0 | sort -z
)

# Generic-target .bgl modules are compile-time dependencies of the projected
# target-specific corpus. They are not part of this gate's fact round-trip, so
# mirror them unchanged into the regenerated module root.
for f in "${COMPILE_SOURCES[@]}"; do
  rel="${f#"$SRC"/}"
  if [[ "$f" == *.bgl ]]; then
    mkdir -p "$REGEN/$(dirname "$rel")"
    cp -- "$f" "$REGEN/$rel"
  fi
done

# 1. import -> through Beagle Store -> export, per file, into a mirrored tree.
n=0; rtfail=0
for f in "${SOURCES[@]}"; do
  rel="${f#"$SRC"/}"
  mkdir -p "$REGEN/$(dirname "$rel")"
  if ! "$RACKET" "$RT" --emit-edn "$f" > "$WORK/a.edn"; then
    echo "  IMPORT FAIL: $rel" >&2; exit 1
  fi
  if ! bb -cp "$BEAGLE_STORE_OUT" -m roundtrip-store "$WORK/a.edn" > "$WORK/b.edn"; then
    echo "  Beagle Store STORE FAIL: $rel" >&2; exit 1
  fi
  if ! "$RACKET" "$RT" --render "$WORK/b.edn" > "$REGEN/$rel"; then
    echo "  EXPORT FAIL: $rel" >&2; exit 1
  fi
  if ! "$RACKET" "$RT" --verify "$WORK/b.edn" "$f" | grep -q 'reconstructs datum-identically'; then
    echo "  DATUM round-trip FAIL: $rel"; rtfail=$((rtfail+1)); fail=1
  fi
  n=$((n+1))
done
echo "--- $n files imported→(Beagle Store)→exported; datum round-trip failures: $rtfail ---"

# Bonus, the strongest possible result: is the regenerated SOURCE byte-identical?
srcid=0; srctot=0
for f in "${SOURCES[@]}"; do
  rel="${f#"$SRC"/}"; srctot=$((srctot+1))
  cmp -s "$f" "$REGEN/$rel" && srcid=$((srcid+1))
done
echo "--- regenerated SOURCE byte-identical to original: $srcid/$srctot files ---"

# 2. recompile-identity: the emitted PROGRAM must be identical, modulo srcloc debug
# pointers (^{:line N :file "..."} reflect text layout/location, not the program; in
# the flipped world they point at the canonical regenerated text). STRICT: beagle
# emission is byte-deterministic (match temps + parse lowering temps are per-program
# counters — gated by bin/test/build-reproducible), so EVERY module byte-compares;
# no double-build nondeterminism guard. A mismatch means the loop changed the program.
echo "--- recompile-identity (beagle build orig vs regen, modulo srcloc; strict byte-compare) ---"
if ! "$ROOT/bin/beagle-build-all" "${SOURCES[@]}" \
    --module-root "corpus=$SRC" --out "$WORK/o1"; then
  echo "  FAIL — original corpus did not compile" >&2; exit 1
fi
REGEN_SOURCES=()
for f in "${SOURCES[@]}"; do REGEN_SOURCES+=("$REGEN/${f#"$SRC"/}"); done
if ! "$ROOT/bin/beagle-build-all" "${REGEN_SOURCES[@]}" \
    --module-root "corpus=$REGEN" --out "$WORK/rg"; then
  echo "  FAIL — regenerated corpus did not compile" >&2; exit 1
fi
STRIP='s/\^\{:line [0-9]+ :file "[^"]*"\} ?//g'
for d in o1 rg; do find "$WORK/$d" -name '*.clj' -exec sed -i -E "$STRIP" {} + ; done
mapfile -d '' ORIGINAL_OUTPUTS < <(find "$WORK/o1" -type f -print0 | sort -z)
mapfile -d '' REGENERATED_OUTPUTS < <(find "$WORK/rg" -type f -print0 | sort -z)
if [ "${#ORIGINAL_OUTPUTS[@]}" -eq 0 ] || [ "${#ORIGINAL_OUTPUTS[@]}" -ne "${#REGENERATED_OUTPUTS[@]}" ]; then
  echo "  FAIL — compiled output sets are empty or differ in size" >&2; exit 1
fi
total=0; mismatch=0
for oclj in "${ORIGINAL_OUTPUTS[@]}"; do
  rel="${oclj#"$WORK/o1/"}"
  total=$((total+1))
  if [ ! -f "$WORK/rg/$rel" ] || ! diff -q "$WORK/o1/$rel" "$WORK/rg/$rel" >/dev/null 2>&1; then
    echo "  MISMATCH — loop changed the program: $rel"; mismatch=$((mismatch+1)); fail=1
  fi
done
echo "  modules byte-compared: $total (all of them)"
[ "$mismatch" = 0 ] && echo "  PASS — every module recompiles to the IDENTICAL program"

echo
if [ "$fail" = 0 ]; then
  echo "RESULT: PASS — code is losslessly fact-canonical (datum-identical through the Beagle Store store + recompile-identical)."
else
  echo "RESULT: FAIL"; exit 1
fi
