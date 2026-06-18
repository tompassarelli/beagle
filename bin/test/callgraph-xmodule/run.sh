#!/usr/bin/env bash
# Reasoning call-graph — CROSS-MODULE completeness.
#
# beagle-callgraph derives the call graph from chartroom's CONVERGED resolver
# (resolve.clj refers_to), so a qualified cross-module call (a/f, fully-qualified m/f)
# is resolved by binding identity — not dropped, the way a bare-callname index does.
# A dropped cross-module edge silently EMPTIES the blast radius ("changing this is
# safe, nothing depends on it") — the dangerous failure this gate guards against.
#
# Corpus: xm.lib defines target; xm.mid calls it via (:as l) -> l/target; xm.top calls
# xm.mid/relay fully-qualified. A transitive cross-module chain. blast(target) must
# include relay AND (transitively) use-it. Needs racket + bb + fram out/ + chartroom.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FRAM_OUT="${FRAM_OUT:-$HOME/code/fram/out}"
CHARTROOM="${CHARTROOM:-$HOME/code/chartroom}"
export FRAM_OUT CHARTROOM
CG="$(cd "$HERE/../../.." && pwd)/bin/beagle-callgraph"
fail=0

echo "================ reasoning call-graph — cross-module completeness ================"
[ -d "$FRAM_OUT" ] || { echo "  (need FRAM_OUT)"; exit 3; }
[ -f "$CHARTROOM/src/resolve.clj" ] || { echo "  (need CHARTROOM resolve.clj)"; exit 3; }

JSON="$("$CG" "$HERE/corpus" 2>/dev/null)"
chk() { if eval "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fail=1; fi; }

# blast(target) — its transitive callers — must contain BOTH relay (:as caller) and
# use-it (fully-qualified, two hops). Names are unique here, so grep the JSON by name.
got="$(python3 - "$JSON" <<'PY'
import json,sys
d=json.loads(sys.argv[1])
nm={x['key']:x['name'] for x in d['defns']}
edges=sorted((nm[a],nm[b]) for a,b in d['edges'])
blast={nm[k]:sorted(nm[x] for x in v) for k,v in d['blast'].items()}
print("EDGES", edges)
print("BLAST_TARGET", blast.get('target', []))
PY
)"
echo "  $got" | tr '\n' ' '; echo
chk ":as cross-module edge (relay -> target)"          "grep -q \"('relay', 'target')\" <<<\"\$got\""
chk "fully-qualified cross-module edge (use-it -> relay)" "grep -q \"('use-it', 'relay')\" <<<\"\$got\""
chk "transitive blast(target) includes relay AND use-it (cross-module, 2 hops)" \
    "grep -qE \"BLAST_TARGET \\['relay', 'use-it'\\]\" <<<\"\$got\""

echo
[ "$fail" = 0 ] && echo "RESULT: PASS — cross-module + transitive blast radius complete (not silently dropped)." || { echo "RESULT: FAIL"; exit 1; }
