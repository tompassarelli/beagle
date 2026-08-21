+++
id = "beagle-oracle-rejection-inventory"
title = "Inventory remaining Beagle self-compiler oracle rejection sites"
shape = "task"
life = "active"
updated_at = "2026-08-18T20:30:00+08:00"
owners = ["codex:/root"]
depends_on = []
realizes = "beagle-stage1-bootstrap"
assigned_to = "codex:/root"
delegated_by = "operator"
+++

# Oracle rejection inventory

Read-only sweep completed against the captured worker snapshot
`beagle:worktrees/stage1b-core-admission` at
`6080915a11c9bae57726adb89bc75b1b8ee9c699`. The scope boundary is the ordered
input set in `beagle:self-host/full-compiler-closure.manifest` at manifest
commit `02dd1a20`. The live worker may advance after this snapshot; this report
does not write compiler source.

The initial six sites and the five later sites are excluded from the remaining
count because their landed repair shapes are already present: nullable index
results use `(U Int Nil)`, `Any` string keys are first bound as `String`,
range-driven vector consumers use `(vec (range ...))`, and deterministic proof
traversals use sorted key vectors. The later range-carrier commits also
materialize local `(Vec Int)` index carriers before `mapv` or `reduce`.

## Counts

There are 23 counted remaining sites: 11 nullable-index sites, 11
vector-required sequence sites, and 1 deterministic-order site. Two of the
nullable-index sites are explicitly marked unsure below; they are included in
the total rather than silently dropped.

## Class 1 — nullable string-index result: 11 sites

Repair shape: annotate each string-index result as `(U Int Nil)` at the local
binding. Where the source value is `Any` after `string?`, first bind it as
`(text String) key`, then annotate the index. Preserve the existing `some?` or
`nil?` guard before arithmetic or `subs`.

1. `beagle:self-host/src/selfhost/check.bclj:469` — strong. The expression is
   `(let [idx (str/index-of name "/")] (if (some? idx) (let [(offset Int) idx] (subs name (+ offset 1))) name))`.
   Repair: `(let [(idx (U Int Nil)) (str/index-of name "/")] ...)`.
2. `beagle:self-host/src/selfhost/check.bclj:4024` — strong. The expression is
   `(let [i (str/index-of s ".")] (if (or (nil? i) (= i 0)) nil (subs s 0 i)))`.
   Repair: annotate `i` as `(U Int Nil)` at the index call.
3. `beagle:self-host/src/selfhost/emit-clj.bclj:573` — strong. The expression is
   `(let [idx (str/last-index-of s ".")] (if (nil? idx) s (let [(offset Int) idx] (subs s (+ offset 1)))))`.
   Repair: annotate `idx` as `(U Int Nil)`.
4. `beagle:self-host/src/selfhost/emit-clj.bclj:594` — strong. The expression is
   `(let [idx (str/last-index-of class-name ".")] (if (nil? idx) class-name (let [(offset Int) idx] (str "[" (subs class-name 0 offset) " " (subs class-name (+ offset 1)) "]"))))`.
   Repair: annotate `idx` as `(U Int Nil)`.
5. `beagle:self-host/src/selfhost/emit-clj.bclj:637` — strong. The expression is
   `(let [index (str/last-index-of name "/")] (if (nil? index) name (let [(offset Int) index] (subs name (+ offset 1)))))`.
   Repair: annotate `index` as `(U Int Nil)`.
6. `beagle:self-host/src/selfhost/emit-js.bclj:2570` — strong. The expression is
   `(let [idx (str/last-index-of s ".")] (if (nil? idx) s (let [(offset Int) idx] (subs s (+ offset 1)))))`.
   Repair: annotate `idx` as `(U Int Nil)`.
7. `beagle:self-host/src/selfhost/emit-js.bclj:2726` — strong. `left-index` is
   produced by `(str/index-of text left)` and then consumed by the guarded
   comparison in `appears-before?`.
   Repair: bind `left-index` as `(U Int Nil)`.
8. `beagle:self-host/src/selfhost/emit-js.bclj:2727` — strong. `right-index` is
   produced by `(str/index-of text right)` and then consumed by the same `<`.
   Repair: bind `right-index` as `(U Int Nil)`.
9. `beagle:self-host/src/selfhost/facts-roundtrip.bclj:1027` — strong. The
   expression is `(let [idx (str/last-index-of text "\n")] (if (nil? idx) (+ initial (count text)) (let [(line-break Int) idx] (- (count text) (+ line-break 1)))))`.
   Repair: annotate `idx` as `(U Int Nil)`.
10. `beagle:self-host/src/selfhost/parse.bclj:151` — unsure. The helper
    `(let [r (str/index-of s sub)] (if (nil? r) -1 r))` returns an `Int` and
    does not perform arithmetic on the raw result. It may already be accepted
    by branch narrowing; annotate `r` as `(U Int Nil)` if Core retains `Any`.
11. `beagle:self-host/src/selfhost/types.bclj:31` — unsure. The helper has the
    same shape, `(let [result (str/index-of s sub)] (if (nil? result) -1 result))`.
    Apply the same `(U Int Nil)` annotation only if the oracle does not narrow
    this return expression.

## Class 2 — vector-required sequence consumer: 11 sites

The grep-sound rule is a raw sequence producer (`keys` or `vals`) flowing into
`reduce`, `filterv`, or `sort`, whose Core contract requires a vector. The
worked repair shape is to materialize the producer before the consumer:
`(vec (keys ...))`, `(vec (vals ...))`, or, for sorting, `(vec (sort (vec (keys ...))))`.
There are no remaining direct `(range ...)` → `mapv` or `(range ...)` → `reduce`
sites in the captured closure; all such direct range sites are already wrapped
or use an order-insensitive consumer such as `every?` or `doseq`.

1. `beagle:self-host/src/selfhost/ast.bclj:565` — `(reduce (fn [(out Any) (key Any)] Any ...) {} (keys value))`.
2. `beagle:self-host/src/selfhost/check.bclj:117` — `(vec (sort (keys table)))`; the
   raw key sequence reaches vector-requiring `sort` before the outer `vec`.
3. `beagle:self-host/src/selfhost/check.bclj:5316` — `(vec (sort (keys table)))` in
   `sorted-names`, with the same producer/consumer shape.
4. `beagle:self-host/src/selfhost/check.bclj:4048` — `(reduce (fn [(a Any) (v Any)] Any ...) acc2 (vals x))`.
5. `beagle:self-host/src/selfhost/check.bclj:4114` — `(reduce (fn [(a Any) (v Any)] Any ...) acc1 (vals x))`.
6. `beagle:self-host/src/selfhost/emit-clj.bclj:93` — `(reduce (fn [(out Any) (key Any)] Any ...) {} (keys table))`.
7. `beagle:self-host/src/selfhost/emit-js.bclj:262` — `(reduce (fn [(out Any) (key Any)] Any ...) {} (keys table))`.
8. `beagle:self-host/src/selfhost/emit-nix.bclj:2132` — `(reduce (fn [(names Any) (name String)] Any ...) {} (keys imported-fields))`.
9. `beagle:self-host/src/selfhost/parse.bclj:1152` — the final reducer input in
   `merge-binding-target-tables!` is `(keys right)`.
10. `beagle:self-host/src/selfhost/parse.bclj:4514` — the final reducer input in
    `qualify-provider-type` is `(keys bounds)`.
11. `beagle:self-host/src/selfhost/parse.bclj:4562` — the final reducer input in
    `module-type-aliases-with-imports!` is `(keys local-aliases)`.

## Class 3 — unordered traversal consumed in deterministic order: 1 site

Repair shape: materialize a deterministic key vector, normally
`(vec (sort (keys ...)))`, before the order-sensitive consumer.

1. `beagle:self-host/src/selfhost/emit-clj.bclj:1008` —
   `(filterv (fn [(key Any)] Bool (= rec-name (reference-key-leaf key))) (keys (deref record-fields)))`,
   followed by `(nth candidates 0)`. Choosing the first matching record field
   makes the unordered key traversal observable; sort the keys before filtering.

## Unsure and reviewed sites

The two class-1 helper returns are counted above but may already be accepted by
Core branch narrowing. The raw-key reducers at `ast:565`, `emit-clj:93`,
`emit-js:262`, `emit-nix:2132`, `parse:1152`, `parse:4514`, and `parse:4562`
are counted under Class 2; whether their accumulated map order is also an
oracle determinism rejection is uncertain, but the vector mismatch is a
separate, concrete repair candidate. Raw `keys` passed only to `count`,
order-insensitive `every?`, or `doseq` were reviewed and not counted as Class 3:
`beagle:self-host/src/selfhost/main.bclj:624`,
`beagle:self-host/src/selfhost/main.bclj:672`, and
`beagle:self-host/src/selfhost/parse.bclj:4183`.

## Closure boundary used

The manifest contains 39 ordered inputs at `02dd1a20`:

### self-host (13)

- `beagle:self-host/src/selfhost/ast.bclj`
- `beagle:self-host/src/selfhost/check.bclj`
- `beagle:self-host/src/selfhost/emit-clj.bclj`
- `beagle:self-host/src/selfhost/emit-js.bclj`
- `beagle:self-host/src/selfhost/emit-nix.bclj`
- `beagle:self-host/src/selfhost/facts-roundtrip.bclj`
- `beagle:self-host/src/selfhost/macros.bclj`
- `beagle:self-host/src/selfhost/main.bclj`
- `beagle:self-host/src/selfhost/parse.bclj`
- `beagle:self-host/src/selfhost/probe.bclj`
- `beagle:self-host/src/selfhost/reader.bclj`
- `beagle:self-host/src/selfhost/rt.clj`
- `beagle:self-host/src/selfhost/types.bclj`

### native-core (13)

- `beagle:native-core/src/native/core.bclj`
- `beagle:native-core/src/native/stages.bclj`
- `beagle:native-core/src/native/simd.bclj`
- `beagle:native-core/src/native/lower.bclj`
- `beagle:native-core/src/native/obligations.bclj`
- `beagle:native-core/src/native/c11.bclj`
- `beagle:native-core/src/native/slice.bclj`
- `beagle:native-core/src/native/unit_reuse.bclj`
- `beagle:native-core/src/native/unit_compile.bclj`
- `beagle:native-core/src/native/fold_c17.bclj`
- `beagle:native-core/src/native/body_c17.bclj`
- `beagle:native-core/src/native/body_slice.bclj`
- `beagle:native-core/src/native/qbe.bclj`

### driver (11)

- `beagle:bin/beagle`
- `beagle:bin/beagle-build`
- `beagle:bin/beagle-build-all`
- `beagle:bin/beagle-build-core`
- `beagle:bin/beagle-native-exe`
- `beagle:bin/beagle-materialize-wasm`
- `beagle:native-core/bin/source-facts.clj`
- `beagle:native-core/bin/verify-checked-ast.rkt`
- `beagle:native-core/validation/build-finalize.clj`
- `beagle:native-core/bin/run-bounded.rkt`
- `beagle:beagle-lib/private/module-source-root-cli.rkt`

The two toolchain-file inputs, `beagle:flake.nix` and `beagle:flake.lock`, were
also included in the manifest boundary and contain none of the three source
patterns.

## Verification

Static checks only: manifest enumeration, source-snapshot `git grep` for all
string-index calls, raw `range` forms, raw `keys`/`vals` traversals, and
multiline consumer-context inspection. No compiler check, build, Racket
process, source edit, lane creation, commit, or `/tmp/beagle-gate.lock` access
was performed.
