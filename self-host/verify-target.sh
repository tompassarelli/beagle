#!/usr/bin/env bash
# verify-target: byte-parity gate for a NON-clj emit target of the self-hosted
# compiler (js today; the same pattern serves nix/cljs/…).
#
#   self-host/verify-target.sh <target>        # e.g. js
#
# Rungs:
#   1. module self-test (selfhost.emit-<target> under bb)
#   2. conformance EMIT goldens (expected/<target>/*.js) — selfhost
#      parse->emit byte-identical to the committed oracle golden (norm-text)
#   3. conformance REJECT rows (expected/<target>/*.diag) — selfhost check
#      rejects (nonzero), in parity with the oracle
#   4. self-host/fixtures/*.bclj forced to <target> — selfhost parse->emit
#      byte-identical to the oracle's <target> emission, for every fixture the
#      oracle can emit to <target> (clj-only forms are skipped, logged)
#
# WHY parse->emit (ast | emit-from-ast) and not the full `emit` command:
# the selfhost CHECKER has a pre-existing arithmetic divergence (types
# (+ Float Float) as Int) that is orthogonal to emission and out of the emit
# port's lane (reported to the coordinator). Isolating parse->emit gates THIS
# deliverable — the emitter + target-specific parse — exactly. Once the checker
# Float-arith bug is fixed, the full `emit --target <t>` chain passes too.
set -uo pipefail

TARGET="${1:-js}"
WT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$WT"
SEED=self-host/seed
EXPECT="beagle-test/conformance/expected/$TARGET"

case "$TARGET" in
  js)  EXT="bjs";  LANG="#lang beagle/js" ;;
  nix) EXT="bnix"; LANG="#lang beagle/nix" ;;
  cljs) EXT="bcljs"; LANG="#lang beagle/cljs" ;;
  *) echo "verify-target: unknown target '$TARGET'"; exit 2 ;;
esac

command -v bb >/dev/null 2>&1 || { echo "verify-target: bb (babashka) not on PATH"; exit 2; }

# Stage0 compiler: prefer the native binary (self-host/native/beagle-selfhost)
# when present + executable; fall back to the bb-run seed otherwise. The bb path
# is the dev fallback and stays fully working. BEAGLE_NATIVE_BIN overrides the
# native binary path (same convention as verify-native.sh); empty forces bb.
NATIVE_BIN="${BEAGLE_NATIVE_BIN-self-host/native/beagle-selfhost}"
if [ -n "$NATIVE_BIN" ] && [ -x "$NATIVE_BIN" ]; then STAGE0=native; else STAGE0=bb; fi
sh_main() { # selfhost CLI: <subcommand> [args...]
  if [ "$STAGE0" = native ]; then "$NATIVE_BIN" "$@"; else bb -cp "$SEED" -m selfhost.main "$@"; fi
}
[ "$STAGE0" = native ] && echo "=== stage0: native ($NATIVE_BIN) ===" || echo "=== stage0: bb seed ($SEED) ==="

have_oracle=1
if [ -f bin/_beagle-racket ]; then source bin/_beagle-racket 2>/dev/null || have_oracle=0; else have_oracle=0; fi

LAB=.lab; mkdir -p "$LAB"
PASS=0; FAIL=0; SKIP=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
skip() { echo "  SKIP: $1"; SKIP=$((SKIP+1)); }

# collapse a run of trailing blank lines to a single newline (certify norm-text)
norm() { awk 'BEGIN{RS="\0"} {sub(/\n*$/,"\n"); printf "%s", $0}' "$1"; }

# selfhost parse -> emit for TARGET, isolated from the checker
selfhost_emit() { # <src> <out>
  sh_main ast --target "$TARGET" "$1" 2>/dev/null \
    | sh_main emit-from-ast --target "$TARGET" > "$2" 2>"$2.err"
}

# find a corpus source by golden id (tests/fixtures or conformance/corpus)
find_src() { # <id>
  for d in beagle-test/tests/fixtures beagle-test/conformance/corpus; do
    if [ -f "$d/$1.$EXT" ]; then echo "$d/$1.$EXT"; return 0; fi
  done
  return 1
}

echo "=== 1. module self-test: selfhost.emit-$TARGET ==="
mod="selfhost.emit-$TARGET"
if bb -cp "$SEED" -e "(require '[$mod :as m]) (System/exit (m/run-tests!))" >/dev/null 2>&1; then
  ok "emit-$TARGET self-tests"
else
  bad "emit-$TARGET self-tests"
fi

echo "=== 2. conformance EMIT goldens ($TARGET) ==="
if [ -d "$EXPECT" ]; then
  for gold in "$EXPECT"/*."$( [ "$TARGET" = js ] && echo js || echo "$TARGET" )"; do
    [ -f "$gold" ] || continue
    id="$(basename "$gold")"; id="${id%.*}"
    src="$(find_src "$id")" || { bad "$id (no source .$EXT found)"; continue; }
    selfhost_emit "$src" "$LAB/$id.$TARGET"
    if diff <(norm "$gold") <(norm "$LAB/$id.$TARGET") >/dev/null 2>&1; then
      ok "$id emit byte-parity"
    else
      bad "$id emit byte-parity — diff $gold $LAB/$id.$TARGET"
    fi
  done
fi

echo "=== 3. conformance REJECT rows ($TARGET) ==="
if [ -d "$EXPECT" ]; then
  for diag in "$EXPECT"/*.diag; do
    [ -f "$diag" ] || continue
    id="$(basename "$diag" .diag)"
    src="$(find_src "$id")" || { bad "$id (no source .$EXT found)"; continue; }
    if sh_main check --target "$TARGET" "$src" >/dev/null 2>&1; then
      bad "$id selfhost accepted (should reject)"
    else
      ok "$id selfhost rejects (nonzero)"
    fi
  done
fi

echo "=== 4. self-host/fixtures/*.bclj forced to $TARGET (vs oracle) ==="
if [ "$have_oracle" -eq 1 ]; then
  for src in self-host/fixtures/*.bclj; do
    [ -f "$src" ] || continue
    name="$(basename "$src" .bclj)"
    # force the oracle to emit TARGET: temp copy with the target #lang + ext
    tmp="$LAB/$name.$EXT"
    { echo "$LANG"; tail -n +2 "$src"; } > "$tmp"
    oracle="$LAB/$name-oracle.$TARGET"
    if BEAGLE_EMIT_SRCLOC=0 bin/beagle-build "$tmp" "$oracle" >/dev/null 2>"$oracle.err"; then
      selfhost_emit "$src" "$LAB/$name-self.$TARGET"
      if diff <(norm "$oracle") <(norm "$LAB/$name-self.$TARGET") >/dev/null 2>&1; then
        ok "$name fixture->$TARGET byte-parity"
      else
        bad "$name fixture->$TARGET byte-parity — diff $oracle $LAB/$name-self.$TARGET"
      fi
    else
      skip "$name (oracle cannot emit $TARGET — clj-only forms)"
    fi
  done
else
  skip "fixtures rung (no oracle / _beagle-racket unavailable)"
fi

echo ""
echo "=== verify-target $TARGET: $PASS passed, $FAIL failed, $SKIP skipped ==="
[ "$FAIL" -eq 0 ]
