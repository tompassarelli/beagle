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
CHARTROOM="${CHARTROOM:-$HOME/code/fram/chartroom}"
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

# --- call ATTRIBUTION completeness: a blast edge is ANY reference to a defn, not just a
#     list-HEAD call — value-passes (mapv f), threading (-> x f), and extend-type impl
#     bodies are real dependencies that head-only counting silently dropped.
echo "--- call attribution: value-pass / threading / extend-type bodies ---"
ATT="$(mktemp -d)"; mkdir -p "$ATT/c"
cat > "$ATT/c/m.bclj" <<'EOF'
#lang beagle/clj
(ns att.m)
(defn dbl [x :- Int] :- Int (* x 2))
(defn inc1 [x :- Int] :- Int (+ x 1))
(defn thread-it [x :- Int] :- Int (-> x dbl inc1))
(defn hof-it [xs :- (Vec Int)] :- (Vec Int) (mapv dbl xs))
EOF
cat > "$ATT/c/e.bclj" <<'EOF'
#lang beagle/clj
(ns att.e)
(defrecord Box [(w :- Int)])
(defn wrap [n :- Int] :- Int (+ n 1))
(defprotocol Show (render [self] : Int))
(extend-type Box Show (render [self] (wrap (box-w self))))
EOF
AJ="$("$CG" "$ATT/c" 2>/dev/null)"
agot="$(python3 - "$AJ" <<'PY'
import json,sys
d=json.loads(sys.argv[1]); nm={x['key']:x['name'] for x in d['edges'] and [] or []}
nm={x['key']:x['name'] for x in d['defns']}
print("EDGES", sorted((nm[a],nm[b]) for a,b in d['edges']))
PY
)"
echo "  $agot"
chk "threading (-> x dbl inc1) edges to both steps" "grep -q \"('thread-it', 'dbl')\" <<<\"\$agot\" && grep -q \"('thread-it', 'inc1')\" <<<\"\$agot\""
chk "value-pass (mapv dbl) is an edge"              "grep -q \"('hof-it', 'dbl')\" <<<\"\$agot\""
chk "extend-type impl body call (render -> wrap)"   "grep -q \"('render', 'wrap')\" <<<\"\$agot\""
rm -rf "$ATT"

echo
[ "$fail" = 0 ] && echo "RESULT: PASS — cross-module + transitive blast radius complete (edges = all refs, not just head calls)." || { echo "RESULT: FAIL"; exit 1; }
