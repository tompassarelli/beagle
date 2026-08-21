# Native Core compiler-capability plan

Date: 2026-08-18

## Closure recount — complete 2026-08-19

**Verdict: newly exposed work needs its own seams. Do not trigger the stage-1
binary build from this recount.** The exact pinned base is
`fb190c9e077bc15aeeb189c2f0025819a4d04337`. Its Native Core
source-to-typed closure has **1,140 rejection occurrences in 1,092 distinct
reported function labels**, with **49 literal diagnostic shapes**. Of those,
**59 occurrences / 53 labels are KNOWN** S4, S5, or S8 work and **1,081
occurrences / 1,042 labels are NEWLY EXPOSED** work not covered by a landed or
in-flight seam. Category function counts are unions; two labels occur in more
than one newly exposed category.

The 59 known occurrences are S4 atom flow (**51 occurrences / 45 labels**), S5
callback result typing (**6 / 6**), and S8 environment typing (**2 / 2**). The
S4 diagnostic family therefore contains six more occurrences than its earlier
45-occurrence inventory, but those are additional occurrences of the explicitly
in-flight S4 shapes and remain KNOWN. S7 has no remaining rejection at this
boundary. The 1,081 newly exposed occurrences occupy 44 shapes. Twenty of those
44 diagnostic strings are literally new relative to the prior 50-shape
inventory; the other 24 are re-exposed or expanded instances of old diagnostic
strings whose landed owner no longer covers the observed context.

### Recount execution and evidence

- **Phase 1 — 75-minute box: complete in 66 minutes including extraction.**
  The build ran from 02:08:33 to 03:09:00 Asia/Taipei (60m27s) in a detached
  checkout pinned before execution. Build-start load was 5.56/7.63/6.74 on 24
  cores with 79,238,628 KiB `MemAvailable`; the earlier phase-start sample was
  5.77/5.80/5.90 with 77,308,392 KiB available. Full-subtree cumulative CPU
  advanced throughout source-facts and compiler lowering. The route ended
  normally at `source-to-typed REJECTED`; it never entered native
  materialization.
- **Phase 2 — 40-minute box: complete.** The rejection log was partitioned
  mechanically into the known S4/S5/S8 shapes and the uncovered shapes below.
  The exact occurrence-to-function rows are preserved in
  `~/.local/state/beagle/native-core-recount/fb190c9e077bc15aeeb189c2f0025819a4d04337/rejections.tsv`.
- **Phase 3 — 25-minute box: complete.** This document records the distance and
  one independently checkable worker seam per implementation boundary. No
  compiler source was edited and this recount did not run the stage-1 binary
  build.

The mechanically projected 12-module source, build log, checksums, histogram,
and exhaustive per-shape function-label lists are under
`~/.local/state/beagle/native-core-recount/fb190c9e077bc15aeeb189c2f0025819a4d04337/`.
In particular, `shape-functions.tsv` contains, for every row below, occurrence
count, unique affected-label count, the exact diagnostic shape, and every
affected label. Synthetic `$closure$...` labels are counted exactly as the
compiler reported them rather than guessed back to a parent source function.
A separately supervised concurrent attempt at
`20f4a8d3f9de2ed962ea0bb71b36e685c51c96ab` produced the identical 1,097-row
grouped code/reason/function ledger; its metadata and build are recorded later
in this document, but it is not the pinned base of this report. Beagle main
subsequently advanced again, so this recount makes no zero-closure claim for an
unpinned later commit.

### Exact recount inventory and classification

Counts are rejection occurrences followed by distinct reported function
labels. The example identifies one affected source function or expression;
the exhaustive affected functions are in `shape-functions.tsv`.

| Status / owner | Exact diagnostic shape | Occurrences / functions | Example |
|---|---|---:|---|
| NEW C2 / S12 | `TODO-NATIVE-GET-OPERANDS: get lowers a closed map, key, and optional typed default` | **566 / 543** | `beagle:self-host/src/selfhost/emit-nix.bclj:2171` (`add-form-constrained-record-types`) |
| NEW C2 / S13 | `TODO-NATIVE-CALL-nth: no native lowering for this callee` | **142 / 137** | `beagle:self-host/src/selfhost/facts-roundtrip.bclj:865` (`arity-clause?`) |
| NEW C1 / S11 | `TODO-NATIVE-EMPTY-MAP-LITERAL: an empty literal names no key or value type` | **130 / 125** | `beagle:self-host/src/selfhost/main.bclj:831` (`-main`) |
| KNOWN S4 | `TODO-NATIVE-ATOM-TYPE: atom needs a closed (Atom T) annotation for its initial value type` | **41 / 35** | `beagle:self-host/src/selfhost/emit-js.bclj:70` (`ajs-block*`) |
| NEW C2 / S12 | `TODO-NATIVE-ASSOC-OPERANDS: assoc lowers one key/value pair on a closed map` | **35 / 35** | `beagle:self-host/src/selfhost/emit-nix.bclj:2139` (`add-record-type`) |
| NEW C1 / S11 | `TODO-NATIVE-EMPTY-VECTOR-LITERAL: an empty literal names no element type` | **27 / 27** | `beagle:self-host/src/selfhost/check.bclj:2150` (`canonical-union-member-name`) |
| NEW C2 / S12 | `TODO-NATIVE-CONTAINS-OPERANDS: contains? lowers a closed map key or set element` | **25 / 25** | `beagle:self-host/src/selfhost/emit-nix.bclj:371` (`binding-declaration?`) |
| NEW C2 / S14 | `TODO-NATIVE-STR-OPERANDS: str operands must be Text, Int, or acyclic closed native values` | **20 / 19** | `beagle:self-host/src/selfhost/parse.bclj:244` (`binding-datum->src`) |
| NEW C2 / S13 | `TODO-NATIVE-CONJ-OPERANDS: conj lowers a native vector push or closed set insertion` | **12 / 12** | `beagle:self-host/src/selfhost/facts-roundtrip.bclj:41` (`build-codepoint-offsets`) |
| NEW C2 / S13 | `TODO-NATIVE-REDUCE-COLLECTION: reduce needs a native Vec or closed insertion-order Set` | **12 / 12** | `beagle:self-host/src/selfhost/emit-js.bclj:77` (`add-names`) |
| NEW C2 / S13 | `TODO-NATIVE-VEC-OPERAND: vec lowers a native vector or a closed insertion-order set` | **10 / 10** | `beagle:self-host/src/selfhost/emit-js.bclj:1800` (`build-sequential-binding-contexts`) |
| NEW C3 / S15 | `TODO-NATIVE-WIDEN-TARGET: the declared type is not a closed union` | **8 / 8** | `beagle:self-host/src/selfhost/emit-clj.bclj:739` (`emit-variant-defrecord`) |
| KNOWN S4 | `TODO-NATIVE-ATOM-DEREF-CELL: deref operand is not an Atom` | **8 / 8** | `beagle:self-host/src/selfhost/types.bclj:486` (`apply-type-bindings`) |
| NEW C2 / S13 | `TODO-NATIVE-VECTOR-EDGE-OPERAND: first takes one closed native vector` | **8 / 8** | `beagle:self-host/src/selfhost/reader.bclj:132` (`decode-char-lit`) |
| NEW C2 / S12 | `TODO-NATIVE-MAP-KEYS-OPERAND: keys lowers one closed map` | **8 / 5** | `beagle:self-host/src/selfhost/main.bclj:566` (`exact-checked-program-keys?`) |
| NEW C2 / S13 | `TODO-NATIVE-SUBVEC-OPERANDS: subvec takes a native vector and one or two Int bounds` | **6 / 6** | `beagle:self-host/src/selfhost/parse.bclj:171` (`bracket-body`) |
| KNOWN S5 | `TODO-NATIVE-SOME-RESULT-TYPE: the callback type has no nullable native result` | **6 / 6** | `beagle:self-host/src/selfhost/check.bclj:1199` (`constraint-value-synchronous?`) |
| NEW C2 / S13 | `TODO-NATIVE-DOSEQ-COLLECTION: v0 iterates one closed native Vec` | **6 / 6** | `beagle:self-host/src/selfhost/check.bclj:4089` (`check-field-declarations!`) |
| NEW C5 / S16 | `TODO-NATIVE-FREE-REFERENCE: indent is not a parameter or local binding` | **5 / 5** | `beagle:self-host/src/selfhost/emit-clj.bclj:393` (capturing callback in `emit-body-with-context`) |
| NEW C3 / S15 | `TODO-NATIVE-JOIN-TYPE: live arms have no declared native union` | **5 / 5** | `beagle:self-host/src/selfhost/parse.bclj:482` (`binder-target-names`) |
| NEW C8 / S19 | `TODO-NATIVE-CALL-merge: no native lowering for this callee` | **4 / 4** | `beagle:self-host/src/selfhost/macros.bclj:448` (capture merge) |
| NEW C3 / S15 | `TODO-NATIVE-WIDEN-SOURCE: no target alternative carries this type and the source is not a closed union` | **4 / 4** | `beagle:self-host/src/selfhost/emit-js.bclj:1548` (`emit-for-body!`) |
| NEW C5 / S16 | `LOWER-APPLY-CALLABLE: apply target must have a closed native signature` | **4 / 4** | `beagle:self-host/src/selfhost/emit-js.bclj:710` (`binding-names-from-params`) |
| NEW C2 / S14 | `TODO-NATIVE-TEXT-SEARCH-OPERANDS: str/starts-with? takes two native Text operands` | **4 / 4** | `beagle:self-host/src/selfhost/emit-js.bclj:1084` (`emit-call-fn-name`) |
| NEW C5 / S16 | `TODO-NATIVE-FREE-REFERENCE: anyb is not a parameter or local binding` | **3 / 3** | `beagle:self-host/src/selfhost/emit-js.bclj:556` (capturing callback in `expr-has-await?`) |
| NEW C2 / S14 | `TODO-NATIVE-TEXT-JOIN-OPERANDS: str/join takes Text and Vec Text` | **3 / 3** | `beagle:self-host/src/selfhost/check.bclj:1175` (`binding-target->string`) |
| NEW C2 / S12 | `TODO-NATIVE-DISSOC-OPERANDS: dissoc lowers one key on a closed map` | **3 / 3** | `beagle:self-host/src/selfhost/facts-roundtrip.bclj:229` (`js-node`) |
| NEW C2 / S14 | `TODO-NATIVE-TEXT-SPLIT-OPERANDS: str/split takes Text and Regex` | **3 / 3** | `beagle:self-host/src/selfhost/ast.bclj:511` (`binding-id-output-name`) |
| NEW C1 / S11 | `TODO-NATIVE-SET-LITERAL-TYPE: the module declares no set of this element type` | **3 / 3** | `beagle:self-host/src/selfhost/facts-roundtrip.bclj:883` (`bare-arity-vector-indexes`) |
| NEW C3 / S15 | `TODO-NATIVE-MAP-LITERAL-ITEMS: values have no unique declared closed union` | **3 / 3** | `beagle:self-host/src/selfhost/check.bclj:3973` (`finalize-callable-definition-types!`) |
| NEW C7 / S18 | `TODO-NATIVE-CALL-selfhost.rt/exit: no native lowering for this callee` | **3 / 3** | `beagle:self-host/src/selfhost/main.bclj:727` (`invalid-projection!`) |
| NEW C8 / S19 | `TODO-NATIVE-CALL-map-indexed: no native lowering for this callee` | **3 / 3** | `beagle:self-host/src/selfhost/emit-js.bclj:781` (`emit-js-params!`) |
| NEW C5 / S16 | `TODO-NATIVE-FREE-REFERENCE: key-of is not a parameter or local binding` | **2 / 2** | `beagle:self-host/src/selfhost/emit-clj.bclj:1076` (capturing callback in enum projection) |
| KNOWN S8 | `TODO-NATIVE-HOST-ENVIRONMENT-TYPE: environment lookup needs a nullable Text result` | **2 / 2** | `beagle:self-host/src/selfhost/check.bclj:5292` (`check-purity!`) |
| KNOWN S4 | `TODO-NATIVE-ATOM-SWAP-CELL: swap! first operand is not an Atom` | **2 / 2** | `beagle:self-host/src/selfhost/facts-roundtrip.bclj:400` (`add-fact!`) |
| NEW C2 / S13 | `TODO-NATIVE-VECTOR-EDGE-OPERAND: peek takes one closed native vector` | **1 / 1** | `beagle:self-host/src/selfhost/facts-roundtrip.bclj:511` (segment coalescing callback) |
| NEW C2 / S14 | `TODO-NATIVE-TEXT-LOWER-OPERAND: str/lower-case takes one native Text operand` | **1 / 1** | `beagle:self-host/src/selfhost/parse.bclj:259` (qualified-name validation) |
| NEW C2 / S14 | `TODO-NATIVE-REGEX-REPLACE-OPERANDS: str/replace takes Text, Regex, Text` | **1 / 1** | `beagle:self-host/src/selfhost/ast.bclj:517` (path normalization) |
| NEW C2 / S13 | `TODO-NATIVE-INTO-OPERANDS: into lowers two native vectors of the same type` | **1 / 1** | `beagle:self-host/src/selfhost/facts-roundtrip.bclj:127` (synthetic list node) |
| NEW C5 / S16 | `TODO-NATIVE-FREE-REFERENCE: lower-name is not a parameter or local binding` | **1 / 1** | `beagle:self-host/src/selfhost/ast.bclj:529` (`lower-binding-target-output`) |
| NEW C5 / S16 | `TODO-NATIVE-FREE-REFERENCE: else? is not a parameter or local binding` | **1 / 1** | `beagle:self-host/src/selfhost/emit-js.bclj:1686` (`emit-stmt-inline!`) |
| NEW C8 / S19 | `TODO-NATIVE-CALL-get-in: no native lowering for this callee` | **1 / 1** | `beagle:self-host/src/selfhost/check.bclj:307` (`inference-binding`) |
| NEW C1 / S11 | `TODO-NATIVE-VECTOR-LITERAL-TYPE: the module declares no vector of this element type` | **1 / 1** | `beagle:self-host/src/selfhost/reader.bclj:423` (`build-source-locations`) |
| NEW C3 / S15 | `TODO-NATIVE-VECTOR-LITERAL-ELEMENTS: the items do not share one native type` | **1 / 1** | `beagle:self-host/src/selfhost/facts-roundtrip.bclj:455` (`source-lines`) |
| NEW C2 / S14 | `TODO-NATIVE-TEXT-ENDS-WITH-OPERANDS: str/ends-with? takes two native Text operands` | **1 / 1** | `beagle:self-host/src/selfhost/check.bclj:4362` (`bang-name?`) |
| NEW C2 / S13 | `TODO-NATIVE-SET-OPERAND: set lowers one finite native vector` | **1 / 1** | `beagle:self-host/src/selfhost/ast.bclj:121` (`scope-set-member?`) |
| NEW C7 / S18 | `TODO-NATIVE-CALL-selfhost.rt/read-source-snapshot: no native lowering for this callee` | **1 / 1** | `beagle:self-host/src/selfhost/main.bclj:476` (`parse-file-target!`) |
| NEW C7 / S18 | `TODO-NATIVE-CALL-selfhost.rt/parse-json: no native lowering for this callee` | **1 / 1** | `beagle:self-host/src/selfhost/main.bclj:798` (`cmd-emit-from-ast!`) |
| NEW C6 / S17 | `TODO-NATIVE-CALL-format: no native lowering for this callee` | **1 / 1** | `beagle:self-host/src/selfhost/emit-clj.bclj:1166` (`emit-char-lit`) |

The row arithmetic is exact: **1,140 = 59 known + 1,081 newly exposed**.
The 1,081 newly exposed occurrences route to C1 **161**, C2 **869**, C3
**21**, C5 **16**, C6 **1**, C7 **5**, and new C8 **8**. C8 is a genuine new
class: compound portable collection combinators (`merge`, `map-indexed`, and
`get-in`) have no Native Core callee lowering; they are not merely failed
projection of an already supported primitive.

### New seams required before another closure recount

One worker owns each seam and its focused acceptance check. These are additive
S11-S19 seams; they do not reopen the acceptance of landed S1-S10 work.

| Seam / owner class | Occurrences / functions | Acceptance check |
|---|---:|---|
| **S11 — contextual closed-literal replay (C1)** | **161 / 156** | A source fixture places empty map/vector and typed set/vector literals in named functions and nested closures carried through `Any`; it reaches `source-to-typed ACCEPTED` and materializes with none of the four S11 shapes. |
| **S12 — dynamic map projection after closure conversion (C2)** | **637 / 611** | A closed map carried through named and anonymous calls is narrowed, read, updated, queried, keyed, and dissociated; the fixture materializes with no `get`, `assoc`, `contains?`, `keys`, or `dissoc` operand rejection. |
| **S13 — dynamic sequential carrier operations (C2)** | **199 / 194** | A dynamic vector/set crosses a closure boundary and exercises `nth`, `reduce`, `conj`, `vec`, `first`/`peek`, `subvec`, `doseq`, `set`, and `into`; the fixture materializes with none of the nine S13 shapes. |
| **S14 — dynamic text operand specialization (C2)** | **33 / 32** | `Text`, `Int`, regex, and `Vec Text` values cross the same dynamic/closure boundaries and exercise `str`, starts/ends-with, split, join, lower-case, and regex replace; the fixture materializes with none of the seven S14 shapes. |
| **S15 — post-closure closed joins and coercions (C3)** | **21 / 21** | Nested callbacks return heterogeneous closed values through declared unions and construct heterogeneous map/vector literals; source-to-typed accepts with no join, widen, or literal-element rejection and one backend materializes it. |
| **S16 — captured environment completeness and callable apply (C5)** | **16 / 16** | Nested callbacks capture each named outer binding, escape, and are invoked directly and through `apply`; the frozen program has no free-reference or apply-signature rejection and materializes. |
| **S17 — portable `format` primitive (C6)** | **1 / 1** | A typed fixture covers the exact integer formatting form used by `emit-char-lit`, freezes, materializes, and matches the hosted output without a missing-callee rejection. |
| **S18 — remaining self-host runtime adapters (C7)** | **5 / 5** | Typed adapters for exit, source-snapshot input, and JSON parsing cover success and malformed/terminal paths; the frozen fixture exposes the declared effects and materializes without ordinary missing-callee diagnostics. |
| **S19 — portable compound collection combinators (new C8)** | **8 / 8** | Typed map merge, nested lookup, and indexed mapping fixtures preserve closed key/value/callback types, reach source-to-typed acceptance, and materialize with no missing-callee diagnostic. |

After S4, pending S5/S8 materialization proofs, and S11-S19 land, rerun this
exact pinned closure route. Stage 1 remains gated on a zero recount from the
exact eventual candidate commit; the present result is neither ZERO nor
NEAR-ZERO.

## Outcome

The preserved stage-1 failure is **806 rejection occurrences in 749 reported
functions**, correcting the stated occurrence total by one. Those occurrences
have 50 literal diagnostic shapes. They reduce to **seven compiler capability classes covering 802
occurrences**, plus **one four-occurrence compiler-source portability repair**.
This is not a 749-function annotation campaign.

The dominant fact is concrete in `beagle:native-core/src/native/lower.bclj`:
source `Any` is closed to `SliceValue`, but `slice-value-variants` currently
contains scalar values and record references only. It contains no vector, map,
set, atom, or callable carrier. The compiler source legitimately uses `Any` for
reader datums, checked AST nodes, type terms, environments, and emitter trees,
so the downstream exact-map, exact-vector, literal-context, and widening
failures are repeated consequences of that missing closed dynamic-value
representation and its projections.

The shortest credible route is therefore to build the recursive closed carrier
first, then land its projection/narrowing, closed-join, and atom consumers in
parallel while independent callable, primitive, host-service, and portability
workers proceed. A new full stage-1 run is warranted only after the focused
seams are green; its job is to expose the next first failures, not to serve as a
per-worker test.

## Timeboxes and evidence boundary

- **Phase 1 — extract and count (40-minute box): complete.** Parsed only
  `~/.local/state/beagle/stage1-bootstrap/b1d781d8bbe7aea041f6e0042240d1c82fb78844/oracle-native-build.log`.
- **Phase 2 — capability clustering (60-minute box): complete.** Traced each of
  the 50 messages to its emitting rule in
  `beagle:native-core/src/native/lower.bclj` and inspected representative source
  sites in `beagle:self-host/src/selfhost/`.
- **Phase 3 — seam split (30-minute box): complete.** Ten independently
  verifiable seams are proposed below, ordered by dependency and payoff.
- **Phase 4 — write (25-minute box): complete in this document.**

No build was started or disturbed, no compiler source was edited, and no fact
was re-derived outside the preserved rejection log where the mission supplied
the result as authoritative.

## Exact totals

| Measure | Result | Interpretation |
|---|---:|---|
| `TODO-NATIVE-FUNCTION-BODY` diagnostics | **805** | The actionable body-rejection occurrences. |
| `LOWER-VARIADIC-FUNCTION-ABI` diagnostics | **1** | A separate fatal signature rejection for `-main`; this is the occurrence the stated 805 omitted. |
| Total rejection diagnostics | **806** | The true rejection inventory. |
| Reported affected function labels | **749** | Includes `emit-loop-stmt-with!`, whose diagnostic embeds the function name instead of ending in brackets. |
| Literal rejection-message shapes | **50** | The exact inventory follows. |
| `LOWER-CLOSED-RAW-ANY` diagnostics | **1,555** | Informational closures to `SliceValue`; not rejection occurrences and not part of 806. |
| All typing diagnostics | **2,361** | 806 rejections plus 1,555 raw-`Any` closure notices. |
| Current-main stage-1 blocking diagnostics | **1,140** | The exact build at `20f4a8d3f9de2ed962ea0bb71b36e685c51c96ab` passed source projection/freeze, then rejected at `source-to-typed`; 44 diagnostic codes, 49 exact code/reason shapes, and 1,092 affected function labels are recorded in `~/.local/state/beagle/stage1-bootstrap/20f4a8d3f9de2ed962ea0bb71b36e685c51c96ab/remaining-rejection-inventory.tsv`. |
| Current-main stage-1 wall time | **3,709 s (61m49s)** | Load was 4.66/5.62/6.07 at launch and 3.45/3.72/4.12 at completion; whole-subtree CPU advanced throughout. |
| Current-main stage-1 binary | **Absent** | No `beagle-compiler-native` materialized, so `SELF-COMPILER-STAGE1`, its standalone-child observation, and native compile timing were not run. |

Function identity in the log is an unqualified label. In the inventory, `xN`
means that label owns N occurrences of that same shape; it does not invent a
namespace that the log did not report. The 749 total is obtained by parsing the
non-bracketed closure-ABI and variadic-ABI diagnostics explicitly and otherwise
taking the bracketed function label. `-main` already has a body rejection, so
the corrected occurrence count does not increase the function count.

## Capability classes

The affected-function counts below are unions inside a class. Ten functions
appear in two classes, so class-level function counts intentionally do not sum
to 749. Occurrence counts are an exact partition and do sum to 806 after the
separate source class is included.

| Class | Capability Native Core must gain | Occurrences | Functions | Difficulty | Dependency | Representative rejection and source |
|---|---|---:|---:|---|---|---|
| C1. Recursive closed carriers and contextual literals | Materialize closed `Vec`, `Map`, `Set`, nullable, and recursive `SliceValue` carrier types on demand, and use expected/use context to type empty literals rather than requiring a coincidental annotation elsewhere in the module. | **173** | **168** | **Large.** This changes the finite dynamic-value layout, type-definition closure, value semantics, and literal context together; it is the representation foundation for 567 later occurrences. | Foundation. | `TODO-NATIVE-EMPTY-MAP-LITERAL: an empty literal names no key or value type` at `beagle:self-host/src/selfhost/check.bclj:299` (`fresh-inference-var!`). |
| C2. Flow-sensitive `Any` projection and collection specialization | Project a checked `SliceValue`/union to the exact scalar or collection carrier proved by `map?`, `vector?`, `set?`, `string?`, checked inferred facts, and control flow, then preserve that specialization through calls, loops, and collection primitives. | **417** | **389** | **Large.** The primitive lowerers already exist; the missing common machinery is safe extraction and refinement across `and`, `if`, `cond`, local bindings, and generic collection uses. It is the single largest direct payoff. | Requires C1 carrier variants. | `TODO-NATIVE-GET-OPERANDS: get lowers a closed map, key, and optional typed default` at `beagle:self-host/src/selfhost/ast.bclj:108` (`scope-id?`). |
| C3. Closed joins and boundary coercions | Compute a finite closed join for heterogeneous literal/branch values and emit correct widening, boxing, or checked extraction in either boundary direction. | **105** | **98** | **Medium.** `lower-widen` and union-path machinery already exist; the gaps are join selection and several unsupported source/target paths. | Requires C1; can proceed parallel with C2 afterward. | `TODO-NATIVE-MAP-LITERAL-ITEMS: values have no unique declared closed union` at `beagle:self-host/src/selfhost/ast.bclj:219` (`make-source-span!`). |
| C4. `Atom T` construction and flow | Infer or synthesize a closed `Atom T` from its initializer/context and preserve the cell type through globals, `deref`, `reset!`, `swap!`, and callable cells. | **45** | **39** | **Medium.** Native atom instructions and effects already exist, but cell-type construction and flow are not connected to dynamic/global source types. | Concrete atoms require C1; function cells also require C5. | `TODO-NATIVE-ATOM-TYPE: atom needs a closed (Atom T) annotation for its initial value type` at `beagle:self-host/src/selfhost/ast.bclj:99` (`reset-scope-counter!`). |
| C5. First-class statically typed callables | Represent callable values, lower direct named callbacks and closures, and support the callable-bearing forms actually used by the compiler: vector HOFs, `reduce`, `apply`, `letfn`, escaping `fn`, function-bearing signatures, and variadic entry-point packing. | **33** | **33** | **Large.** Twenty sites can use statically known callback calls; the remaining thirteen require a real closure/function-pointer or variadic call ABI and captured-environment lifetime rules. | Direct callback half is independently buildable; full compiler closure later intersects C1/C4. | `TODO-NATIVE-VECTOR-HOF-CALLBACK: every? requires an anonymous function literal` at `beagle:self-host/src/selfhost/ast.bclj:118` (`scope-set?`). |
| C6. Missing pure scalar/text primitives | Give Native Core typed, materializable operations for `str/last-index-of`, `double?`, and integer-codepoint-to-text `char`. | **14** | **13** | **Medium.** `last-index-of` can mirror existing text index machinery and `double?` extends scalar predicates; `char` must preserve Unicode/codepoint semantics through IR and materializers. | Independent. | `TODO-NATIVE-CALL-str/last-index-of: no native lowering for this callee` at `beagle:self-host/src/selfhost/check.bclj:69` (`string-qualified-reference`). |
| C7. Self-host runtime extern bridge | Resolve the declared `selfhost.rt` compiler services to typed Native Core host effects and ABIs instead of treating them as ordinary missing callees. | **15** | **15** | **Medium, with one ruling.** Stderr, environment, path queries, and existence checks have close native counterparts; whole-file and stdin reads do not yet share a decided boundedness contract. | Mostly independent; the input half waits on the ruling below. | `TODO-NATIVE-CALL-selfhost.rt/getenv: no native lowering for this callee` at `beagle:self-host/src/selfhost/check.bclj:5265` (`purity-severity`). |

### Separate source portability class — not a compiler type capability

Four occurrences in four functions use JVM instance methods while being fed to
Native Core:

- `hex-encode-utf8`
- `surrogate-pair-at?`
- `edn-string`
- `decode-char-lit`

All report `TODO-NATIVE-METHOD-CALL: v0 lowers only
String.toLowerCase(Locale.ROOT)`. The representative site is
`beagle:self-host/src/selfhost/emit-nix.bclj:68`, where
`hex-encode-utf8` calls `.getBytes`. Native Core already has `utf8-encode`, and
the source has portable string helpers. Expanding Native Core into general JVM
interop would violate its target boundary. These **4 occurrences / 4
functions** are source portability work and must not be credited to a type
system repair.

## What the clustering proves

The predecessor judgment is substantially correct: **802 of 806 occurrences
are compiler capability gaps**, not requests for annotations. The largest 740
are all closed-data work: carriers/context (173), projections/specialization
(417), joins/coercions (105), and atoms (45). The apparent diversity of `get`,
`nth`, empty literals, widening, collection loops, and atom messages is mostly
the surface area of one currently scalar-only `SliceValue` design.

It would still be wrong to call this one small patch. C1 establishes a recursive
closed representation; C2, C3, and C4 are independently testable consumers of
that representation. C5 is a separate runtime/type-system axis. C6 and C7 are
finite catalog/ABI gaps. The four JVM-method sites are genuinely source work.

The estimates are exact for the preserved first-failure inventory, but they are
not a promise that the next run contains zero new diagnostics. A function stops
at its first Native Core body failure, so closing one seam can reveal a second
failure in the same function. Each worker owns the named current shapes; the
campaign owner recounts after each dependency wave instead of silently adding
new acceptance criteria to already-landed seams.

## Commander ruling

**Should the native compiler preserve the unbounded semantics of
`selfhost.rt/slurp-file` and `selfhost.rt/read-stdin`, or must the compiler
source adopt Native Core's bounded host-input APIs with explicit byte limits?**

This is a real semantic choice. Native Core exposes `host.fs/read-text-bounded`;
the hosted self-host shims expose unbounded whole-input strings. The plan does
not invent a bound or add an unbounded native service. This ruling controls
three current occurrences: two `slurp-file` and one `read-stdin`.

## Independently verifiable seam split

There are **ten seams**. One worker owns each seam and its focused fixture. A
worker proves its seam at the lowest deterministic layer with a minimal Core
fixture that reaches `stage source-to-typed ACCEPTED` and materializes through
one existing backend; the full compiler closure is a wave gate, not a worker
loop. Separate lanes that touch the shared lowerer land in dependency order and
rebase before landing.

| Order | Seam / owner assignment | Current payoff | Dependency | Acceptance check | Exact current shapes closed |
|---:|---|---:|---|---|---|
| 1 | **S1 — recursive `SliceValue` carriers and contextual type-family instantiation** | **173 direct; unlocks 567 more** | None | A focused Core fixture carries empty and non-empty `Vec`, `Map`, and `Set` values through `Any`, includes a nullable Float parse, reaches `source-to-typed ACCEPTED`, and materializes; its report contains none of the seven C1 shapes. | Both empty-map shapes, both empty-vector shapes, set-literal carrier, vector-literal carrier, parse-Float nullable carrier. |
| 2 | **S2 — dynamic projection, predicate narrowing, and collection specialization** | **417** | S1 | A focused fixture proves direct and short-circuit narrowing (`and`/`if`/`cond`) for `map?`, `vector?`, `set?`, and `string?`, then executes representative `get`, `nth`, `subvec`, `assoc`, `keys`, `contains?`, `doseq`, `reduce`, `vec`, `into`, and text consumers. It materializes with none of the 17 C2 shapes. | The 17 operand/collection shapes assigned to C2. |
| 3 | **S3 — heterogeneous closed joins and bidirectional boundary coercion** | **105** | S1; parallel with S2 | A focused fixture builds a heterogeneous map and mixed branch result whose finite union is deterministic, then widens and checked-extracts it across declared boundaries. It materializes with no map-literal-items, widen-target, or widen-source rejection. | Map-literal-items (64), widen-target (32), widen-source (9). |
| 4 | **S4 — `Atom T` inference and cell flow** | **45** | S1; callable-cell subcase also S6 | A focused fixture creates concrete and `Any`-carried atoms and proves create/deref/reset/swap/CAS type identity. After S6 it adds the existing parser callable-cell pattern. No atom-type, atom-deref-cell, or atom-swap-cell rejection remains. | Atom type (38), deref cell (5), swap cell (2). |
| 5 | **S5 — statically known HOF callbacks** | **20** | Implementation independent; compiler-source closure also needs S2 | **PROVEN — native C17 materialization: 265.39s wall; load 3.24/6.01/6.25 at start, 5.34/6.22/6.28 at end.** A typed `Vec` fixture passes named functions to `mapv`, `filterv`, `every?`, `some`, and `reduce`, materializes, and emits direct calls in the loop rather than requiring an inline anonymous literal. | Four vector-HOF callback shapes (19) and reduce-callback (1). |
| 6 | **S6 — closure ABI, escaping callables, `apply`, `letfn`, and variadic packing** | **13** | Independent representation work; integrates with S1/S4 | A fixture passes and returns a capturing callable, stores and calls it, exercises one recursive `letfn`, spreads a typed argument vector through `apply`, and invokes a typed rest-parameter entry point; the frozen program validates and one materializer runs it. | Fn-escapes (7), apply (3), unsupported-letfn (1), function-bearing-signature ABI (1), variadic-function ABI (1). |
| 7 | **S7 — pure primitive completion** | **14** | Independent | **PROVEN — native C17 materialization: 268.23s wall; load 3.24/6.01/6.25 at start, 5.34/6.22/6.28 at end.** Focused value fixtures compare `str/last-index-of` found/not-found results, distinguish Float with `double?`, and round-trip ASCII plus non-ASCII codepoints through `char`; frozen output materializes identically through the selected backend. | `str/last-index-of` (10), `double?` (2), `char` (2). |
| 8 | **S8 — decided self-host host adapters** | **12** | Independent | **PROVEN — native C17 materialization: 276.63s wall; load 3.24/6.01/6.25 at start, 5.34/6.22/6.28 at end.** A compiler-runtime fixture resolves `selfhost.rt/eprint`, `getenv`, `file-exists?`, and `abs-path` to explicit effects/ABIs, materializes, and shows the expected stderr/environment/filesystem capabilities in the frozen program. | eprint (8), getenv (2), file-exists? (1), abs-path (1). |
| 9 | **S9 — whole-input host services** | **3** | Commander ruling | Implement exactly the chosen bounded or unbounded contract, then prove EOF, empty input, non-ASCII input, and the selected bound/overflow behavior in a focused host fixture. | slurp-file (2), read-stdin (1). |
| 10 | **S10 — portable self-host text operations** | **4** | Independent source seam | Replace the four JVM-method uses with existing portable Beagle operations, run the nearest self-host check/remint, and build the four functions through Native Core with no method-call rejection. | Method-call (4). |

S1 is first despite S2's larger direct count because S1 is the highest-leverage
ready seam: its 173 direct closures establish the representation required by
S2, S3, and the dynamic part of S4, a 740-occurrence closed-data frontier.

### Parallel landing waves

1. **Foundation wave:** S1 starts first. In parallel, S5, S6, S7, S8, and S10
   can build against concrete types or source-only surfaces; S9 begins only
   after the ruling.
2. **Carrier-consumer wave:** once S1 lands, S2, S3, and S4 run in parallel.
   Their focused fixtures are disjoint even though implementation changes may
   converge in `beagle:native-core/src/native/lower.bclj`; each lane rebases and reruns only its named
   check before landing.
3. **Closure recount:** run the source-to-typed compiler closure once and
   regenerate this exact 50-shape inventory. Route newly exposed diagnostics
   to the existing semantic owner. Do not annotate individual compiler
   functions unless a rejection is proven to be source-invalid.
4. **Stage-1 run: BLOCKED at source typing.** The exact supervised build from
   `20f4a8d3f9de2ed962ea0bb71b36e685c51c96ab` ran 3,709 seconds with advancing
   whole-subtree CPU, passed source projection/freeze, and rejected at
   `source-to-typed` with 1,140 blocking occurrences. No binary materialized.
   The complete per-shape/per-function ledger is
   `~/.local/state/beagle/stage1-bootstrap/20f4a8d3f9de2ed962ea0bb71b36e685c51c96ab/remaining-rejection-inventory.tsv`.

## C9 open-type-grammar overlap

`beagle:beagle-test/conformance/authority/positioning/C9-REPAIR-PLAN.md` repairs the **self-host parser** so invalid
return-type datums and unknown lowercase type names fail closed. It neither
adds a `SliceValue` carrier nor changes Native Core source-to-typed lowering.
The present stage-1 path already cleared oracle admission, so **C9 closes zero
of these 806 current Native Core rejections**. It may prevent malformed type
syntax from reaching a later self-hosted stage, but no S1-S10 estimate credits
it. There is no implementation overlap and no reason to serialize C9 with this
campaign.

## Shortest credible path to a materialized binary

Land S1, while independently landing S5-S8 and S10 and obtaining the one host
input ruling. Then land S2-S4 in parallel plus S9. Recount the preserved
source-to-typed failure shapes at the compiler-closure boundary; fix only newly
exposed failures under their existing seam owners. Once the count is zero, run
the supervised stage-1 build on that exact commit after the materializer
synchronization fix is available. This path builds seven capabilities, one
finite source repair, and ten verifiable seams; it never turns 749 functions
into an annotation queue.

## Exact rejection inventory

The following is in first-seen log order. Counts are occurrences first and
distinct reported function labels second.

1. `TODO-NATIVE-CALL-nth: no native lowering for this callee` — **86 occurrences / 82 functions**. `bracketed?` x2, `map-tagged?` x2, `set-tagged?`, `string-literal-datum?` x2, `inert-atom-datum?`, `datum->beagle-syntax!`, `callable-body-tail-synchronous?`, `reference-key-leaf`, `emit-constrained-callable`, `emit-let-bindings!`, `emit-with-open-chain!`, `emit-dynamic-binding-chain!`, `emit-for-clauses!` x2, `emit-quoted-top`, `emit-record-constructor-guards`, `metadata-reference`, `emit-core-call!`, `emit-body-return!`, `emit-eq-pairs!`, `default-index-for`, `emit-param-binders`, `wrap-constraint-thunks`, `wrap-default-thunks`, `emit-sequential-param-bindings`, `emit-body`, `flattenable-map?`, `flatten-dot-path`, `emit-nix-attrs`, `emit-let-binding-chain*!`, `loop-cond`, `loop-match`, `loop-for!`, `emit-record-guards`, `emit-record-predicates`, `source-loc`, `in-span?`, `line-number`, `nearest-preceding`, `nearest-following`, `tagged-string?`, `edn-value`, `parse-triple`, `slot-key`, `datum-list?`, `head-is?`, `prefix-text`, `hash-prefix-text`, `datum-source`, `grammar-vector-pretty`, `arity-clause?`, `first-bracket-index`, `contains-index?`, `symbol-owner-vector?`, `children-need-layout?`, `head-keep`, `pretty-context-items`, `signature-pretty`, `datum-pretty-context`, `render-edn!`, `run!`, `module-declared-ns`, `flag-value`, `first-positional`, `validate-reserved-type-declaration!`, `index-of-item`, `string-datum?`, `extract-string`, `scope-meta-syntax?!`, `map-destructure-form?`, `parse-map-destructure!`, `structured-binding?`, `parse-structured-binding!`, `parse-rest-param!`, `meta-name?`, `meta-form?`, `decode-require-libspec!`, `parse-import-spec!`, `import-strip-export`, `import-strip-doc`, `member-type-name`, `syntax-span!`, `has-define-target?`

2. `TODO-NATIVE-SUBVEC-OPERANDS: subvec takes a native vector and one or two Int bounds` — **6 occurrences / 4 functions**. `bracket-body` x2, `map-body` x2, `set-body`, `datum-tail`

3. `TODO-NATIVE-ATOM-TYPE: atom needs a closed (Atom T) annotation for its initial value type` — **38 occurrences / 32 functions**. `reset-scope-counter!`, `fresh-scope-id!`, `emit-expr*` x2, `checked-binding-constraint`, `emit-body-with-loop-context!`, `fresh-match-sym!` x2, `record-update-contract` x3, `record-field-access-contract` x3, `emit-expr*!`, `emit-body-return*`, `emit-stmt-inline*`, `emit-form*`, `ajs-stmt*`, `ajs-block*`, `next-constrained-binding-id!`, `with-pattern-default-env!`, `binding-constraint`, `emit-pattern-binding-statements!`, `emit-expr-stmt!`, `emit-recur-stmts!`, `fresh-logical-sym!`, `install-refs!`, `checked-keyword-selection-field`, `require-synchronous-constraint`, `emit-loop!`, `emit-expr!`, `emit-program!`, `reset-lowering-counter!`, `parse-type*`, `parse-expr*`, `scope-walk*`, `module-declared-contract!`

4. `TODO-NATIVE-GET-OPERANDS: get lowers a closed map, key, and optional typed default` — **268 occurrences / 250 functions**. `scope-id?`, `binding-id?`, `binding-id-stable`, `source-span?`, `structural-name?`, `structural-name->symbol`, `ensure-syntax-context!`, `beagle-syntax?`, `beagle-syntax-span`, `beagle-syntax-origin`, `beagle-syntax-properties`, `beagle-syntax-scopes`, `beagle-syntax->datum!`, `lower-binding-target-output`, `qualified-reference?` x4, `named-reference?`, `resolved-reference?`, `structural-reference-key`, `reference-key` x3, `reference-providerless-key`, `reference-map-ref`, `reference->string`, `reference-leaf`, `binder-binding-id`, `local-reference-key`, `prim?`, `fn-type?`, `app-type?`, `union-type?`, `var-type?`, `poly-type?`, `any-type?`, `dynamic-type?`, `nil-type?`, `type-contains-any?`, `inference-var?`, `inference-var-occurs?`, `unify-inference-types!`, `type->string`, `type-invariant-equal?`, `type-equal?`, `remove-from-union`, `infer-literal-type`, `numeric-class`, `param-binding-target` x3, `destructure-bound-names`, `binding-constraint`, `callable-form-clauses`, `callable-clause-synchronous?`, `function-valued-type?`, `callable-value-synchronous?`, `program-returns-synchronous-callable`, `constraint-synchronization-proof`, `constraint-callable-resolution!`, `destructure-default-exprs`, `resolve-parametric-field-type!`, `destructure-type-error!`, `vec-aggregate-type?`, `inference-rest-call-element-type!`, `rest-param-body-type`, `check-rest-annotation!`, `extend-with-let-bindings!`, `type-matches-predicate?`, `type-could-be-false?`, `call-fn-name` x2, `call-fn-ref`, `instance-narrowings`, `test-narrowings`, `narrow-env-for-condition`, `resolve-poly-call-expected!`, `bare-swallowed-ref?`, `emit-enum-member-violation!`, `check-args!`, `check-hvec-literal!`, `fresh-value-compatible?!`, `check-atom-ctor!`, `js-selector-name`, `js-vec-type?`, `js-builtin-receiver-name`, `infer-expr-expected!`, `value-definition?`, `unwrap-definition`, `callable-definition?`, `callable-clauses`, `signature-alternatives`, `constrain-callable-definitions!`, `check-core-function-abis!`, `declared-return-compatible?`, `check-method-body!`, `check-extend-type!`, `check-js-class!`, `check-form!`, `nix-collect-bound`, `nix-free-dotted-walk!`, `check-nix-free-dotted!`, `collect-references`, `check-qualified-resolution!`, `purity-note`, `purity-fresh-id`, `purity-bind-name`, `purity-owner-status`, `purity-set-origin-status`, `purity-direct-transient-call?`, `purity-direct-primitive-call?`, `purity-copy-path-state`, `purity-analyze-and-escape`, `purity-analyze-js-member`, `purity-analyze-comprehension`, `purity-pattern-bound-names`, `purity-definition-form`, `tag-semantic-node-ids`, `substitute-contract-vars`, `implementation-refines-declared?!`, `check-program!`, `reference->clj`, `qualified-reference=?` x3, `emit-binding-form`, `emit-param`, `binding-target` x2, `emit-loop-with-constraints!`, `emit-require`, `emit-ns-form`, `emit-record-form`, `emit-defenum` x2, `emit-defunion!` x2, `emit-deferror!` x2, `scalar-backing-label`, `emit-defscalar` x2, `emit-protocol-wrapper`, `emit-protocol`, `emit-type-impl!`, `emit-extend-type`, `case-foldable-pattern?`, `emit-pat-literal-value`, `emit-pat-literal-test`, `emit-match!` x3, `else-less-if?` x2, `qualified-member-constructor?`, `emit-qualified-reference`, `record-fields-ref`, `js-postfix-base?`, `emit-js-member!`, `emit-js-unary-operand!`, `expr-has-await?`, `poly-read-type?`, `coll-kind`, `names-from-target`, `emit-destructure!`, `emit-binding-target!`, `emit-record!`, `emit-call-fn-name`, `emit-pat-literal-test-js`, `emit-with!`, `emit-let-binding-stmts!`, `stmt-inline?`, `extend-for-binding-env`, `emit-for-binding-setup!`, `logical-call?`, `expr-contains-recur?`, `emit-context-install!`, `ajs-expr!`, `ajs-function-decl`, `ajs-method`, `ajs-class-decl!`, `ajs-stmt!`, `ajs-block`, `emit-js-ast-node!`, `emit-require-line`, `emit-module-header`, `mangle-qualified-name`, `inferred-type-name`, `direct-record-constructor-name`, `kw-access-has-default?`, `paren-wrap`, `param-constraint`, `nix-param-pattern*`, `binding-target-label`, `map-defaults`, `emit-map-projections`, `emit-datum-nix`, `emit-key`, `map-node?`, `map-pairs`, `emit-nix-fn-set`, `emit-let!`, `cond-test-else?`, `emit-cond`, `emit-for!`, `get-is-keyword?`, `emit-call!`, `kw-key-string`, `rewrite-cfg-ref`, `emit-nix-with-cfg`, `emit-flake-input`, `emit-record-defs`, `emit-top-defenum`, `emit-top-defunion`, `emit-top-deferror`, `scalar-pred-to-nix`, `scalar-backing-check`, `emit-top-defscalar`, `emit-top-def`, `top-def-form?`, `add-form-record-types`, `program-record-types`, `add-form-constrained-record-types`, `replace-loc`, `map-context-node`, `relative-loc`, `result-leaf`, `metadata-node`, `conditional-node`, `symbolic-value-node`, `syntax-quote-node`, `regex-node`, `set-node`, `fn-placeholder-index`, `max-placeholder-index`, `rest-placeholder?`, `rewrite-fn-placeholders`, `anonymous-fn-node`, `scan-datum`, `located-program`, `emit-loc!`, `emit-node!`, `build-datum`, `canonical-layout-needed?`, `syntax-source-bytes`, `macro-datum`, `syntax-list?`, `syntax-vector?`, `datum-car`, `resolve-imports!`, `checked-projection`, `validate-checked-projection!`, `cmd-ast!`, `cmd-check!`, `cmd-emit!`, `binder-target-names`, `syntax-add-scope!`, `binding-target-bound-names`, `qualify-provider-type`, `import-fn-ptypes!`, `import-fn-rest!`, `read-hash-dispatch`, `read-datum`, `read-syntax-hash-dispatch!`, `read-syntax-datum!`, `read-all`, `read-program`

5. `TODO-NATIVE-VECTOR-HOF-CALLBACK: every? requires an anonymous function literal` — **5 occurrences / 5 functions**. `scope-set?`, `make-syntax-list!`, `make-syntax-vector!`, `bindings-complete?`, `constraint-schema-complete?`

6. `TODO-NATIVE-SET-OPERAND: set lowers one finite native vector` — **1 occurrence / 1 function**. `scope-set-member?`

7. `TODO-NATIVE-VEC-OPERAND: vec lowers a native vector or a closed insertion-order set` — **10 occurrences / 10 functions**. `scope-set-add`, `extend-with-effective-params!`, `purity-bind-params`, `params+rest`, `case-foldable-match?`, `emit-case-folded-match`, `params-have-constraint-await?`, `param-bindings`, `build-sequential-binding-contexts`, `indexed-defaults`

8. `TODO-NATIVE-MAP-LITERAL-ITEMS: values have no unique declared closed union` — **64 occurrences / 62 functions**. `make-source-span!`, `make-reader-metadata`, `make-structural-name!`, `make-syntax-value!`, `make-qualified-ref`, `make-prim` x2, `make-fn`, `make-app`, `make-union` x2, `make-var`, `make-poly`, `merge-types`, `merge-types-list`, `nullable-type`, `collection-elem-type`, `numeric-refine`, `js-target-form-name`, `hosted-require-contracts`, `jvm-instance-position-method?`, `program-callable-synchronization`, `binding-constraint-error!`, `check-binding-constraint!`, `bind-destructure-any!`, `bind-destructure-type!`, `param-type-or-any`, `inference-param-type!`, `rest-param-call-element-type`, `collection-element-type`, `predicate-narrowing-type`, `extract-narrowing`, `narrow-env-for-match`, `lookup-kw-field-type`, `last-expr-type-expected!`, `infer-cond-clauses!`, `register-record!`, `register-union!`, `lookup-js-static-member!`, `infer-js-member-call!`, `infer-js-member!`, `infer-js-new-expected!`, `infer-expr!`, `build-initial-env!`, `finalize-callable-definition-types!`, `purity-result`, `purity-conj-pipeline-root`, `purity-binding-acquires-owner?`, `purity-analyze-call`, `emit-callable-signature+body`, `mangle-str`, `js-infix?`, `js-unary?`, `emit-ref-name`, `pos-loc`, `make-node`, `sequence-parts`, `make-fn-type`, `make-param!`, `make-map-destructure`, `make-seq-destructure`, `make-result`, `syntax-properties`, `parse-lang-line`

9. `TODO-NATIVE-TEXT-SEARCH-OPERANDS: str/starts-with? takes two native Text operands` — **1 occurrence / 1 function**. `introduced-binding-id?`

10. `TODO-NATIVE-TEXT-SPLIT-OPERANDS: str/split takes Text and Regex` — **2 occurrences / 2 functions**. `binding-id-output-name`, `emit-indented-string`

11. `TODO-NATIVE-VECTOR-HOF-CALLBACK: mapv requires an anonymous function literal` — **9 occurrences / 9 functions**. `lower-binding-output-identities`, `prune-inference-type`, `extend-with-params!`, `emit-params-with-rest`, `emit-body`, `emit-args`, `emit-args-list`, `nix-static-attr-path`, `binding-datum->src`

12. `TODO-NATIVE-CALL-str/last-index-of: no native lowering for this callee` — **10 occurrences / 9 functions**. `string-qualified-reference`, `unqualified-member-name`, `metadata-reference-key` x2, `last-dot-segment`, `emit-import`, `unqualify-name`, `last-seg`, `current-col`, `surface-name-leaf`

13. `TODO-NATIVE-ASSOC-OPERANDS: assoc lowers one key/value pair on a closed map` — **4 occurrences / 4 functions**. `reference-map-assoc`, `binder-env-assoc`, `purity-restore-scope`, `add-record-type`

14. `TODO-NATIVE-MAP-KEYS-OPERAND: keys lowers one closed map` — **7 occurrences / 4 functions**. `ordered-keys`, `sorted-names`, `exact-object-keys?` x4, `map-children-complete?`

15. `TODO-NATIVE-EMPTY-MAP-LITERAL: an empty literal names no key or value type` — **104 occurrences / 99 functions**. `fresh-inference-var!`, `inference-binding`, `bind-inference-var!`, `nominal-union-has-member?`, `parametric-member-view?`, `type-compatible?`, `emit-diag!`, `invalid-js-target-form?`, `remember-binding-constraint-proof!`, `parametric-def-for-app`, `record-field-map-for-type`, `nominal-union-members`, `record-field-type-for!`, `closed-union-members`, `subtract-union-member`, `unstable-binding-keys`, `stable-scrutinee-key`, `check-match-exhaustiveness!`, `enum-member-violation`, `install-imported-record-contracts!`, `install-imported-union-contracts!`, `register-record-validator!`, `remember-record-update!`, `remember-record-field-access!`, `definition-type-table`, `generalize-inference-type!`, `infer-value-definition-types!`, `infer-definition-types!`, `purity-join-states`, `analyze-expression-effects`, `purity-global-bindings`, `derive-effectful-defs`, `decorate-tagged-value`, `freshen-contract-implementation!`, `rigid-declared-contract`, `named-surface`, `check-declared-module-contract!`, `type-check!`, `decorate-checked-program!`, `export-checked-record-contracts!`, `export-checked-callable-synchronization!`, `structuralize-reference-table` x2, `clj-tag-for-type`, `emit-match-arm!` x2, `emit-expr!` x2, `register-tables!` x2, `emit-program!` x2, `bound?`, `with-bound!`, `with-emission-env!`, `qualified-module-binding`, `resolved-name`, `classify-rep`, `callable-param-renames`, `emit-js-param-setup!`, `shadows-inline?`, `emit-let-bind-info!`, `emit-for!`, `emit-doseq!`, `emit-stmt-inline!`, `emit-return-position!`, `emit-fn!`, `emit-call!`, `emit-form!`, `collect-top-names`, `build-module-bindings`, `mangle-qualified-parts`, `record-valued-expr?`, `nominal-record-param?`, `emit-with-form`, `build-nix-require-prefixes`, `emit-comments!`, `triples-props`, `root-id`, `comment-text`, `make-macro-registry`, `install-module-resolution!`, `root-candidate-paths`, `resolve-required-source!`, `surface-type-aliases`, `checked-module-surface!`, `import-parametric-arities!`, `imported-record-field-order`, `imported-record-namespaces`, `-main`, `consume-binder-id!`, `decorate-binder-identities!`, `enqueue-syntax!`, `index-resolved-identities!`, `install-resolved-identities!`, `parse-program!`, `parse-program-with-syntax-and-imports!`, `module-local-type-names`, `module-local-type-aliases-with-imports!`, `module-type-aliases-with-imports!`, `inferred-module-surface*!`, `import-module-surface-with-aliases!`, `qualify-imported-record-contracts`, `qualify-imported-callable-synchronization`

16. `TODO-NATIVE-VECTOR-HOF-CALLBACK: some requires an anonymous function literal` — **1 occurrence / 1 function**. `type-contains-inference-var?`

17. `TODO-NATIVE-SET-LITERAL-TYPE: the module declares no set of this element type` — **8 occurrences / 8 functions**. `infer-type-var-bindings-context!`, `check-scalar-predicate-declarations!`, `js-constructor-reference?`, `mangle-name`, `nix-static-attr-segment`, `emit-nix-derivation`, `emit-nix-flake`, `bare-arity-vector-indexes`

18. `TODO-NATIVE-ATOM-DEREF-CELL: deref operand is not an Atom` — **5 occurrences / 5 functions**. `apply-type-bindings`, `register-macro-with-syntax!`, `lookup-macro`, `consume-identity!`, `enqueue-identity!`

19. `TODO-NATIVE-TEXT-JOIN-OPERANDS: str/join takes Text and Vec Text` — **2 occurrences / 2 functions**. `binding-target->string`, `purity-message`

20. `TODO-NATIVE-WIDEN-TARGET: the declared type is not a closed union` — **32 occurrences / 30 functions**. `constraint-value-synchronous?`, `definition-returns-callable?`, `string-in?`, `fields-have-constraints?`, `marker-add`, `purity-origins-live?`, `same-name-set?`, `has-clojure-string?`, `field-names-of` x3, `param-type-entries`, `contains-await?`, `bindings-have-constraints?`, `emit-record-validator!`, `emit-body-stmts`, `body-contains-recur?`, `indent-str`, `ajs-params`, `emit-interp-string`, `emit-interp-string-inline`, `emit-multiline-string`, `emit-nix-list`, `emit-nix-rec-attrs`, `classify-comments`, `joined-source`, `logical-item-source`, `comments-with`, `extern-authorized-require?`, `has-define-target?`, `params-complete?`, `conformed-module-surface!`

21. `TODO-NATIVE-EMPTY-VECTOR-LITERAL: an empty literal names no element type` — **26 occurrences / 26 functions**. `member-view-type`, `canonical-union-member-name`, `purity-analyze-branches`, `collect-purity-defs`, `definition-effect-markers`, `tag-semantic-node-ids-from`, `local-record-names`, `relative-js-path`, `emit-tagged-type-defs`, `codepoint-offset`, `line-col`, `line-comments`, `comment-segments`, `projection-lines!`, `read-triples`, `ordered-children`, `grammar-child-context`, `macro-errors`, `reset-macro-errors!`, `declared-extern-names`, `load-import-surfaces*!`, `parse-errors`, `reset-errors!`, `err!`, `discover-requires!`, `source-line-column`

22. `TODO-NATIVE-FN-ESCAPES: anonymous functions lower only as an eager inline callback` — **7 occurrences / 7 functions**. `check-enum-comparison!`, `hidden-binding-renames`, `emit-js-params!`, `emit-tagged-factory!`, `emit-match-body!`, `emit-for-body!`, `emit-loop-stmt!`

23. `TODO-NATIVE-WIDEN-SOURCE: no target alternative carries this type and the source is not a closed union` — **9 occurrences / 6 functions**. `rewrite-inference-vars!`, `nix-qualified?`, `valid-record-update-contract?` x4, `build-codepoint-offsets`, `exact-checked-program-keys?`, `valid-record-field-access-contract?`

24. `TODO-NATIVE-DOSEQ-COLLECTION: v0 iterates one closed native Vec` — **5 occurrences / 5 functions**. `check-parameter-declarations!`, `check-field-declarations!`, `check-purity-with-severity!`, `check-or-die!`, `module-parametric-arities!`

25. `TODO-NATIVE-TEXT-ENDS-WITH-OPERANDS: str/ends-with? takes two native Text operands` — **1 occurrence / 1 function**. `bang-name?`

26. `TODO-NATIVE-REDUCE-COLLECTION: reduce needs a native Vec or closed insertion-order Set` — **12 occurrences / 12 functions**. `origins-union`, `purity-bind-target`, `purity-analyze-defaults`, `purity-analyze-bindings`, `purity-analyze-unknown`, `purity-bind-names`, `add-names`, `add-types`, `walk-set!`, `rendered-block`, `join-comma`, `module-target-from-datums`

27. `TODO-NATIVE-EMPTY-MAP-LITERAL: the contextual type is not an exact native map type` — **4 occurrences / 4 functions**. `purity-analyze-sequence`, `purity-analyze`, `dedup-externs`, `expand-and-resolve-program-syntax!`

28. `TODO-NATIVE-EMPTY-VECTOR-LITERAL: the contextual type is not an exact native vector type` — **27 occurrences / 27 functions**. `purity-analyze-cond-clauses`, `purity-unknown-children`, `collect-set!-syms!`, `index-params`, `constrained-field-entries`, `child-values`, `list-node`, `scan-delimited`, `fn-param-nodes`, `form-spans`, `source-lines`, `raw-comment-segments`, `logical-vector-items`, `list-items`, `node-comments`, `split-dots`, `parse-file-target!`, `flag-values`, `unwrap-items`, `install-program-syntaxes!`, `syntax-for-datum!`, `parse-seq-destructure!`, `parse-params!`, `parse-record-fields!`, `syntax-head!`, `attach-syntax!`, `read-program-with-syntax!`

29. `TODO-NATIVE-APPLY: no frozen Beagle Store function requires dynamic argument spreading` — **3 occurrences / 3 functions**. `purity-map-pair-children`, `binding-names-from-params`, `let-names-of`

30. `TODO-NATIVE-CALL-selfhost.rt/getenv: no native lowering for this callee` — **2 occurrences / 2 functions**. `purity-severity`, `check-purity!`

31. `TODO-NATIVE-VECTOR-EDGE-OPERAND: first takes one closed native vector` — **3 occurrences / 3 functions**. `escape-char`, `js-escape-char`, `module-namespace`

32. `TODO-NATIVE-CONTAINS-OPERANDS: contains? lowers a closed map key or set element` — **5 occurrences / 5 functions**. `param-binding-target`, `qualified-set-member?`, `binding-declaration?`, `complete-binding?`, `callable-shape-complete?`

33. `TODO-NATIVE-VECTOR-HOF-CALLBACK: filterv requires an anonymous function literal` — **4 occurrences / 4 functions**. `bindings-have-constraints?`, `constraint-contains-async?`, `emit-sequential-param-chain`, `record-fields-constrained?`

34. `TODO-NATIVE-CALL-double?: no native lowering for this callee` — **2 occurrences / 2 functions**. `datum-clj`, `emit-quoted`

35. `TODO-NATIVE-INTO-OPERANDS: into lowers two native vectors of the same type` — **2 occurrences / 2 functions**. `emit-variant-defrecord`, `tagged-node`

36. `TODO-NATIVE-CALL-char: no native lowering for this callee` — **2 occurrences / 2 functions**. `emit-char-lit`, `encoded-value`

37. `TODO-NATIVE-FORM-unsupported-letfn: no native lowering for this source form` — **1 occurrence / 1 function**. `binding-target-label`

38. `<function> has a function-bearing parameter or return type; v0 has no closure ABI` — **1 occurrence / 1 function**. `emit-loop-stmt-with!`

39. `TODO-NATIVE-METHOD-CALL: v0 lowers only String.toLowerCase(Locale.ROOT)` — **4 occurrences / 4 functions**. `hex-encode-utf8`, `surrogate-pair-at?`, `edn-string`, `decode-char-lit`

40. `TODO-NATIVE-REDUCE-CALLBACK: v0 requires an anonymous function literal` — **1 occurrence / 1 function**. `program-constrained-record-types`

41. `TODO-NATIVE-VECTOR-LITERAL-TYPE: the module declares no vector of this element type` — **2 occurrences / 2 functions**. `build-line-cols`, `build-source-locations`

42. `TODO-NATIVE-DISSOC-OPERANDS: dissoc lowers one key on a closed map` — **2 occurrences / 2 functions**. `prefixed-node`, `js-node`

43. `TODO-NATIVE-ATOM-SWAP-CELL: swap! first operand is not an Atom` — **2 occurrences / 2 functions**. `add-fact!`, `fresh-id!`

44. `TODO-NATIVE-CALL-selfhost.rt/slurp-file: no native lowering for this callee` — **2 occurrences / 2 functions**. `emit-edn-file!`, `declared-ns-of-source`

45. `TODO-NATIVE-PARSE-F64-TYPE: parse-double needs a nullable Float in the source program` — **2 occurrences / 2 functions**. `decode-number`, `num-value`

46. `TODO-NATIVE-CALL-selfhost.rt/eprint: no native lowering for this callee` — **8 occurrences / 8 functions**. `parse-module-root-spec!`, `invalid-projection!`, `note-capitalized-binding!`, `read-string-literal`, `read-regex-literal`, `read-raw-string`, `read-delimited`, `read-syntax-delimited!`

47. `LOWER-VARIADIC-FUNCTION-ABI: <function> has a rest parameter; Native v0 has no call-site packing ABI` — **1 occurrence / 1 function**. `-main`

48. `TODO-NATIVE-CALL-selfhost.rt/file-exists?: no native lowering for this callee` — **1 occurrence / 1 function**. `register-bundle-source!`

49. `TODO-NATIVE-CALL-selfhost.rt/abs-path: no native lowering for this callee` — **1 occurrence / 1 function**. `load-import-surfaces!`

50. `TODO-NATIVE-CALL-selfhost.rt/read-stdin: no native lowering for this callee` — **1 occurrence / 1 function**. `cmd-emit-from-ast!`

## Commander ruling — DECIDED 2026-08-19

**The compiler source adopts Native Core's BOUNDED host-input APIs. Beagle does
not gain an unbounded native whole-input service.**

Applies to the three occurrences: two `selfhost.rt/slurp-file` and one
`selfhost.rt/read-stdin`.

Rationale. Unbounded input is an unbounded failure mode, and in a native binary
that failure is an out-of-memory death rather than a diagnostic. Native Core
already decided this contract by exposing `host.fs/read-text-bounded`; adding an
unbounded native service would be inventing a capability solely to match a
hosted shim's convenience. The hosted shim is not the more honest of the two —
every machine has a bound, and the shim merely hides it until it explodes. The
bound also belongs at the host boundary specifically, which is exactly where the
ruled trust-domain discipline says a guarantee change must be made explicit.

Binding conditions, all required:

1. **Exceeding the bound FAILS LOUDLY. It must never truncate.** A silently
   truncated read compiles half a source file and emits a plausible wrong
   artifact — the worst outcome available here, and strictly worse than either
   an out-of-memory crash or a refusal. The failure is a structured diagnostic
   naming the input, its observed size, and the limit.
2. **The bound is generous and named, not a scattered magic number.** Real
   Beagle sources are kilobytes; the default must sit orders of magnitude above
   any legitimate input so that it is unreachable in practice and parity with
   the oracle is preserved for every real compile.
3. **The bound is configurable** through the normal configuration surface, so a
   genuine large-input case is a setting rather than a recompile.
4. **No unbounded escape hatch** is added alongside it. If a future case truly
   needs one, that is a new ruling with its own evidence, not a flag added to
   dodge this one.
