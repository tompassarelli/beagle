# Graph-native cascade — the proof

`beagle-cascade` predicts the blast radius of a code change: change a function,
which callers (and which test assertions) break? This is the first repair tool
moved **off text and onto the Fram fact graph**.

## Why it had to change

The old cascade built its call graph by **regex over source text**, keyed by bare
function name. That is structurally incapable of being correct: if `helper` is
defined in two modules, the bare name `helper` matches both, and a change to one
module's `helper` is reported as breaking callers of the *other* module's `helper`
— a function it never touched. No amount of polish fixes this; text doesn't know
what calls what.

The new cascade derives its call graph from the fact graph (`beagle-callgraph` →
`beagle-facts` → Fram store → Datalog transitive closure). Every call binds the
defn in its **own module** (module-local lexical scope; else a unique global; else
dropped). The blast radius is a `reaches(_, X)` query, not a text scan.

## The fixture

`corpus/mod_a.bclj` and `corpus/mod_b.bclj` each define `helper`, each with its own
caller chain (`midA → helper`, `topA → midA`; same in B). `verify.bclj` ties
`a-result` to `topA` and `b-result` to `topB`. We change **only `mod_a`'s `helper`.**

## The receipt (same fixture, same change, two engines)

```
QUERY: change `helper` in mod_a.

REGEX (pre-migration, bare-symbol):
    direct callers: midA, midB
    a-result  (via topA in mod_a)
    b-result  (via topB in mod_b)        ← WRONG: mod_b never touched
    Summary: changing helper affects 5 functions and risks 2 assertions

GRAPH (scope-correct, off the Fram calls-graph):
    direct callers: mod_a/midA
    a-result  (via mod_a/topA)
    Summary: changing mod_a/helper affects 2 function(s) and risks 1 assertion(s)
```

`mod_b/midB` is **absent** from the graph result. The regex engine corrupts the
blast radius of a function it never touched; the graph engine leaves `mod_b` alone.
That is *correct where regex is structurally incapable of being correct* — not
"faster than regex."

## Run it

```
bin/test/cascade-graph/run.sh      # asserts scope-correctness; prints the receipt
```

Requires the Fram engine (`FRAM_OUT`, default `~/code/fram/out`) — graph-native
repair runs on the fact store. The scope-correctness assertions gate in CI; the
side-by-side receipt is rendered when the pre-migration cascade is reachable in git.

## Scope (what this is and isn't)

This is **move 1** of graph-native repair: repair *reasoning* runs on the graph.
The call graph is 100% graph-derived; the only remaining text-parse is mapping
verify-script assertion labels to function names (a test-harness boundary, not the
call graph). The **type checker is untouched** — it stays the Racket leaf oracle
that types one node. Graph-native *repair*, never graph-native *inference*.
