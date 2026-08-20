# Graph-native cascade scope check

`beagle-cascade` predicts the blast radius of a code change from recursive
triples in Beagle Store's store. Calls bind to definitions in their own module, and the
blast radius comes from a transitive `reaches(_, X)` query.

The fixture defines `helper` in both `mod_a` and `mod_b`, each with its own
caller chain. Changing `mod_a/helper` must include `mod_a/midA` and `a-result`,
must exclude every `mod_b` caller, and must risk exactly one assertion.

Run:

```sh
bin/test/cascade-graph/run.sh
```

The check requires the Beagle Store engine (`BEAGLE_STORE_OUT`, default
`store/out`). It proves module-local call-graph scope; the type
checker remains the Racket leaf that checks one node.
