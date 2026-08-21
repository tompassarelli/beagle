# Qualified-symbol ontology audit

Audit target: Beagle `424704d388021be9dd9e3e238c284ec0497876e6`
(2026-08-17), read-only inspection of `beagle:main`.

## Verdict

**Overall verdict: SLUDGE.** `x/y` is not pure reader notation that disappears
into a structural `{namespace, name}` representation. The native reader leaves
it as one Racket symbol, the parser normally places that same symbol directly
in the AST, the checked JSON projection turns it into one string, and
`source.facts` writes that compound string into one `name` or `callee` text
slot. JavaScript, JST, Nix, checker/type, self-host, and branch-core code then
detect, split, prefix, suffix-match, or replace `/` downstream.

The repository already has structural module data (`program.namespace`,
`require-entry.ns`, alias, refer lists, module-interface identity), so this is
not a limitation of the surrounding design. It is specifically a qualified
*reference/type-name* representation gap.

## Layer verdicts

| Layer | Verdict | Decisive evidence |
|---|---|---|
| Native reader | **SLUDGE** | `beagle:beagle-lib/lang/reader-impl.rkt:245-257` delegates ordinary atoms to Racket's reader; there is no `/` qualification reader. The readtable's documented structural rewrites cover containers and other reader macros, not qualified names (`:3-11`, `:47-79`). |
| Native parser / AST | **SLUDGE** | `parse-expr` returns any ordinary symbol unchanged (`beagle:beagle-lib/private/parse.rkt:2159-2185`). `call-form` contains a generic `fn` and there is no qualified-ref/name struct (`beagle:beagle-lib/private/ast.rkt:332-366`). `static-call.class+method` is also one atom (`:365`), selected by scanning the atom for `/` (`:281-293`; construction at `beagle:beagle-lib/private/parse.rkt:4300-4301`). |
| Type parser/checker | **SLUDGE** | Qualified types are recognized by regexp over `symbol->string` (`beagle:beagle-lib/private/types.rkt:125-132`); the parser separately slices prefix and member (`beagle:beagle-lib/private/parse.rkt:1120-1131`) and then rebuilds a slash symbol (`:1146-1149`, `:1201-1206`). Type equality later strips qualification again (`beagle:beagle-lib/private/types.rkt:439-454`; helper `:363-367`). |
| Checked AST JSON | **SLUDGE** | A symbol reference becomes exactly `{"node":"ref","name":"x/y"}`: `expr->json/raw` stores the complete `symbol->string` as one `name` (`beagle:beagle-lib/private/ast-json.rkt:421-437`). Program namespace and require data are separately structured (`:1130-1152`), proving the missing structure is local to references/names. |
| `_beagle-source-id` | **STRUCTURAL for source identity; not a name representation** | It computes one logical source path from physical path/repository root and never interprets a qualified symbol (`beagle:bin/_beagle-source-id:3-17`). It neither causes nor repairs the name sludge. |
| `source.facts` | **SLUDGE** | Module namespace is a separate module-root fact (`beagle:native-core/bin/source-facts.clj:716-741`), but a ref writes the whole checked-AST `name` into one text fact (`:467-487`), and a call writes the whole ref name into one `callee` text fact (`:275-278`, `:488-492`). |
| Clojure emitter | **SLUDGE** | It can print the opaque atom unchanged because Clojure accepts qualified symbols (`beagle:beagle-lib/private/emit-clj.rkt:608-628`), but it still constructs slash atoms (`:343-345`) and branches on slash presence while qualifying imported calls (`:930-940`) and validators (`:360-371`). It consumes spelling convention, not structure. |
| JavaScript emitter | **SLUDGE** | It repeatedly re-parses qualified atoms for imports, refs, static calls, constructors, and special calls; detailed inventory below. |
| JST emitter | **SLUDGE** | It converts a resolved name from `/` to `.` by inspecting the string (`beagle:beagle-lib/private/emit-jst.rkt:108-114`). |
| Nix emitter | **SLUDGE** | `mangle-qualified-name` splits the symbol on `/` and interprets the first part as the require prefix (`beagle:beagle-lib/private/emit-nix.rkt:60-73`); expression and call paths invoke it after slash tests (`:1050-1062`, `:1908-1915`). |
| Stdlib catalogs | **SLUDGE** | Catalog identity is keyed by compound slash symbols, e.g. Clojure (`beagle:beagle-lib/private/stdlib-clj.rkt:69-99`), JavaScript (`beagle:beagle-lib/private/stdlib-js.rkt:3-9`, `:20-40`), Nix (`beagle:beagle-lib/private/stdlib-nix.rkt:38-43`, `:236-249`), portable `bgl/promote` (`beagle:beagle-lib/private/stdlib-portable.rkt:172-178`), and Core host ops (`beagle:beagle-lib/private/stdlib-core.rkt:37-120`). The catalog files do not split the strings themselves, but they make compound atoms the lookup schema consumed by slash-scanning parser/checker code. |
| Self-host reader/parser/AST | **SLUDGE** | The reader contract says symbols are plain strings (`beagle:self-host/src/selfhost/reader.bclj:12-18`) and `read-symbol-text` returns the entire token (`:245-260`). The AST ref has one `name` string (`beagle:self-host/src/selfhost/ast.bclj:87-94`, `:132-133`), and the parser preserves `k/single?` exactly as that one string (`beagle:self-host/src/selfhost/parse.bclj:2873-2903`, test at `:3609-3613`). |
| Self-host checker/emitters | **SLUDGE** | Type/parser/checker and JS/Nix/CLJ emission re-parse or pass through compound strings; detailed inventory below. |
| Explicit-source-roots resolver | **STRUCTURAL** | Requires carry namespace, alias, and refer as fields (`beagle:beagle-lib/private/ast.rkt:587-590`). The closure indexes providers by exact declared namespace (`beagle:beagle-lib/private/module-source-root.rkt:284-316`) and the resolver receives the namespace separately (`:387-444`). The dot-to-directory projection at `:126-133` is an output-boundary namespace-to-path policy, not recovery of namespace/name from an `x/y` reference. Explicit enumeration is demonstrably namespace-not-path (`beagle:beagle-test/tests/fixtures/module-resolution/enumerated/toolkit.bclj:3-7`). |
| branch-core store / resolver | **SLUDGE** | A source symbol is minted as one `v` string (`beagle:branch-core/src/resolve_mint.bclj:123-147`). Cross-module resolution later detects `/` and splits that stored text into alias and public name (`beagle:branch-core/src/resolve_corpus.bclj:90-124`). It then adds structural `refers_to` and `qualifier` facts (`beagle:branch-core/src/resolve_walk.bclj:166-186`), but retains the original compound `v`; rendering reassembles from qualifier plus target name (`beagle:branch-core/src/resolve_render.bclj:55-67`). That is dual representation, not “one fact, one representation.” |

## Reader/parser finding

There is no qualification decomposition in the native reader. The reader
structuralizes brackets/maps/sets and dedicated reader macros, then ordinary
symbols fall through to Racket (`beagle:beagle-lib/lang/reader-impl.rkt:3-11`,
`:252-257`). `parse-expr` validates and returns the symbol itself
(`beagle:beagle-lib/private/parse.rkt:2183-2185`). Consequently an expression
like `provider/f` is literally the symbol `'provider/f` in a `call-form.fn` or
as a bare AST expression.

Parser-adjacent slash handling does exist, but it proves the problem rather
than curing it:

- Static-call recognition scans the symbol spelling for `/` and stores the
  unsplit `class+method` atom (`beagle:beagle-lib/private/ast.rkt:281-293`,
  `:365`).
- Candidate qualified types split prefix/member with regexp and substring,
  then rebuild a canonical slash symbol (`beagle:beagle-lib/private/parse.rkt:1120-1131`,
  `:1146-1149`).
- Imported interface spellings are manufactured with `string-append "/"`
  (`beagle:beagle-lib/private/parse.rkt:235-237`, `:1373-1379`).
- Record-pattern classification takes the last slash-separated segment solely
  to test capitalization, while `pat-record.type-name` retains the opaque atom
  (`beagle:beagle-lib/private/parse.rkt:4731-4758`).

These are not a one-time reader lowering into structure. They are local
interpretations of a convention whose compound value survives.

## Facts-layer emitted shape

The checked JSON boundary first preserves the compound spelling:

```json
{"node":"ref","name":"provider/f"}
```

That exact shape is emitted by
`beagle:beagle-lib/private/ast-json.rkt:432-437`. The source-fact projector then
emits the following logical TSV shapes (subjects vary):

```text
<module>  form-kind  t  module-root
<module>  namespace  t  consumer.ns

<ref>     form-kind  t  ref
<ref>     name       t  provider/f

<call>    form-kind  t  call
<call>    callee     t  provider/f
```

The module rows come from
`beagle:native-core/bin/source-facts.clj:733-741`; ref rows from `:482-487`;
call/callee rows from `:488-492`. There is no `namespace`, `qualifier`, or
member-name fact on a ref/call. `source.facts` therefore has separate module
namespace identity but **one compound string for a qualified reference**.

`_beagle-source-id` only ensures `sourceId` is the repository-relative logical
path where possible (`beagle:bin/_beagle-source-id:3-17`), and the projector
checks that path against checked JSON (`beagle:native-core/bin/source-facts.clj:100-122`).
It does not encode qualified-name structure.

## Emitter hit classification

“Reader-adjacent legitimate” here means a single parse-boundary decomposition
whose output is structural and which no later consumer must repeat. **No
qualified-reference emitter hit meets that definition.** Namespace-to-output-
path conversion, namespaced keyword quoting, regex literal escaping, numeric
ratio detection, and target-language `#lang beagle/clj` slashes are not
qualified-reference parsing and are listed separately as out of scope.

### Native JavaScript (`emit-js.rkt`) — DOWNSTREAM RE-PARSE

- `:1330-1342`: tests validator symbols for `/` and manufactures qualified
  binding atoms with `prefix/name`.
- `:1416-1427`: finds the last slash in a scalar constructor and slices the
  namespace back onto a transformed member.
- `:1530-1545`: `qualified-import-reference` scans and slices an authored atom
  into prefix and member, then looks up the prefix in the module-binding table.
- `:1980-1997`: bare symbol emission detects slash and rewrites it to JS dot
  access; `js/` is stripped by fixed offset.
- `:2483-2499`: static-call emission re-parses `js/member`, `ns/->Ctor`, or
  generic `ns/member` to target syntax.
- `:2732-2747`: regex suffix matches `/replace$` and `/split$` to select special
  target lowering.
- `:2759-2791`: call emission detects `/->`, splits constructor calls, and
  replaces remaining `/` with `.`.

Related but not qualified-reference re-parsing:

- `:99-101` quotes slash-bearing keyword/property keys.
- `:1656-1680`, `:1749-1775` map structured module namespace/specifier data to
  output paths. That is an emitter boundary projection and does not recover an
  `x/y` reference relation.

### Native JST (`emit-jst.rkt`) — DOWNSTREAM RE-PARSE

- `:108-114`: `jst-resolved-name` checks the resolved string for `/` and
  replaces it with `.`. The JST AST has no qualifier/member fields to consume.

### Native Nix (`emit-nix.rkt`) — DOWNSTREAM RE-PARSE

- `:60-73`: splits a qualified symbol on `/`, interprets part zero as a module
  prefix, and joins target-side selected attributes with `.`.
- `:118-129`: tests record-validator symbols for slash qualification.
- `:1050-1062`: symbol emission selects `mangle-qualified-name` by searching
  the atom for `/`.
- `:1908-1915`: call emission repeats the slash test and split/mangle path.

Related but not qualified-reference re-parsing: `:75-99` derives an output file
path from already separate module namespace values; keyword, attribute-path,
and Nix-string operations elsewhere in the file operate on their own surface
types.

### Native Clojure (`emit-clj.rkt`) — OPAQUE PASS-THROUGH PLUS CONVENTION TESTS

- `:608-628`: a reference is emitted by `symbol->string` unchanged. This is not
  a re-split, but it confirms the emitter receives no structure.
- `:343-345`: constructs `prefix/name` symbols.
- `:360-371`: detects slash-bearing record validators.
- `:930-940`: uses slash presence to decide whether an imported module prefix
  must be prepended.

The target happens to share the source spelling, so fewer splits are needed;
the representation remains opaque. Default-alias extraction from dotted module
namespace (`:420-427`) is module metadata handling, not qualified-reference
parsing.

### Native helper emitters and stdlib

- `emit-js-quote.rkt` and `emit-nix-strings.rkt`: **no relevant qualified-symbol
  slash operation**. Their symbol conversions are property/operator rendering
  and their regexp operations are string escaping.
- `stdlib-clj.rkt`, `stdlib-js.rkt`, `stdlib-nix.rkt`, `stdlib-portable.rkt`,
  and `stdlib-core.rkt`: no local split routine, but **SLUDGE schema**: qualified
  callable/type identities are hash keys whose single atom embeds `/`. The JS
  catalog states explicitly that the emitter “translates the `/` back to `.`”
  (`beagle:beagle-lib/private/stdlib-js.rkt:3-9`).

### Self-host — DOWNSTREAM RE-PARSE

- Reader: `read-symbol-text` returns the complete token (`beagle:self-host/src/selfhost/reader.bclj:245-260`);
  the AST stores one ref `name` string (`beagle:self-host/src/selfhost/ast.bclj:132-133`).
- Parser/type: static-call recognition searches for `/`
  (`beagle:self-host/src/selfhost/parse.bclj:210-214`), type diagnostics split
  qualified names (`:358-360`), and imported interfaces manufacture
  `prefix/name` keys (`:3308`, `:3391-3392`, `:3421`, `:3449-3460`,
  `:3553`, `:3571`).
- Checker/types: unqualification slices after `/`
  (`beagle:self-host/src/selfhost/types.bclj:160-175` and
  `beagle:self-host/src/selfhost/check.bclj:361-375`); resolution diagnostics
  inspect prefixes by slash (`beagle:self-host/src/selfhost/check.bclj:3981-4005`).
- JS emitter: qualified names are split/replaced at
  `beagle:self-host/src/selfhost/emit-js.bclj:980-1022`.
- Nix emitter: qualified names are split/rejoined and selected by slash tests at
  `beagle:self-host/src/selfhost/emit-nix.bclj:84-85`, `:1249-1254`, and
  `:1838-1852`.
- Clojure emitter: refs and callees pass the one name string through unchanged
  (`beagle:self-host/src/selfhost/emit-clj.bclj:1095-1096`, `:1238-1251`), while
  validator generation strips a qualifier by last slash (`:574-582`).
- Driver extern authorization compares and prefix-matches constructed compound
  strings (`beagle:self-host/src/selfhost/main.bclj:241-261`).

Out-of-scope slash hits: numeric-ratio recognition in
`beagle:self-host/src/selfhost/facts-roundtrip.bclj:603-613`, module path output
in the JS/Nix emitters, arithmetic `/`, regex delimiters, and target language
names are not qualified-reference re-parsing.

## Resolver finding

The explicit-source-roots resolver is the clean layer in this audit. A require
is already a structured `require-entry(ns, alias, refer)`. Source snapshots
carry source ID, physical path, bytes, declared module source, target, and
explicitness as separate fields
(`beagle:beagle-lib/private/module-source-root.rkt:16-23`). Providers are
indexed by exact declared namespace (`:284-316`); explicit providers win, and
root lookup is only used when no provider with that namespace is already in the
closure (`:387-444`). The provider is then checked to declare the requested
namespace (`:257-267`).

The namespace-to-path transform (`.` to `/`, `-` to `_`) at `:126-133` is a
declared root layout policy. It does not parse an `x/y` symbol to discover a
relation, and explicit enumeration proves namespace identity does not depend
on path. Resolver verdict: **STRUCTURAL** for the ontology being audited.

## branch-core finding

branch-core has two relevant compound-name paths, both non-structural at
ingress:

1. Its authoring graph mints any symbol as one `kind = "symbol"`, `v = (str d)`
   leaf (`beagle:branch-core/src/resolve_mint.bclj:123-147`). Thus `x/y` begins
   as one string slot.
2. Its program-inspection fact model likewise indexes names and call spellings
   as scalar triple objects (`beagle:branch-core/src/fram/program_inspection.clj:100-145`)
   and resolves them by whole-string grouping/equality (`:147-177`). This is a
   separate branch-core fact path from Native Core's `source.facts`, but it has
   the same one-string ontology.

The richer graph resolver does add correct semantic edges after ingress:
`make-xresolve` splits the stored string into `[alias public-name]`
(`beagle:branch-core/src/resolve_corpus.bclj:108-124`), and `bind-xmod!` records
both binding identity and `qualifier` (`beagle:branch-core/src/resolve_walk.bclj:171-186`).
But the original compound `v` remains and is used as fallback; the projection
later suppresses internal qualifier/ref facts and emits a reconstituted `v`
(`beagle:branch-core/src/resolve_mint.bclj:580-617`). branch-core therefore has
**one compound source slot plus a derived structural overlay**, not one
structural representation. Verdict: **SLUDGE**.

## Bounded work orders

All work orders preserve `x/y` surface syntax. The rule is: split once at the
reader/parser boundary; every later layer consumes fields; only textual
rendering joins them.

### QSA-1 — Native qualified-name IR

Introduce one canonical qualified-name representation with at least authored
`qualifier` and leaf `name`, plus resolved provider namespace/identity where
known. Lower ordinary unquoted `x/y` tokens to it in the parser; quoted symbols
remain literal data. Replace `symbol` fields in ref, call head, static-call,
dynamic-var, pattern type, and type-name positions where qualification is
semantic. Delete parser/checker slash scanners that merely recover those
fields. Acceptance: AST inspection of `x/y` shows separate fields and no
ordinary expression AST node contains a slash-qualified opaque symbol.

### QSA-2 — Checker, types, interfaces, and stdlib catalogs

Key environments and catalogs by the canonical qualified-name value (or nested
`namespace -> name` maps), not `ns/name` symbols. Interface imports must map an
authored qualifier to provider identity structurally. Replace regexp/prefix/
suffix qualification tests in `types.rkt`, `check.rkt`, and `parse.rkt` with
accessors. Acceptance: a tracked-tree search finds no slash split/regexp used
to interpret a qualified ref/type; catalog lookups do not concatenate `/`.

### QSA-3 — Checked JSON and `source.facts`

Project a ref as separate fields, e.g.
`{"node":"ref","qualifier":"provider","name":"f"}`, and carry resolved
namespace/binding identity separately when available. In `source.facts`, emit
`name` as the leaf, `qualifier`/`namespace` as separate facts, and make a call's
callee a ref node/identity rather than a duplicate compound text field. Update
Native Core lowering and branch-core program inspection to consume that shape.
Acceptance: no `name` or `callee` text object contains semantic qualification;
round-trip output still prints `provider/f`.

### QSA-4 — Hosted emitters

Make CLJ, JS/JST, and Nix emitters accept only the structured representation.
CLJ joins `qualifier + "/" + name` at its final text boundary; JS/JST emits
module binding/member access from fields; Nix emits attr selection from fields.
Replace constructor/special-call suffix regexes with checked semantic tags or
leaf-name comparisons. Acceptance: the emitter inventory above has no
qualified-symbol split, substring, regexp, or slash-presence branch.

### QSA-5 — Self-host parity

Change self-host reader/parser AST maps to the same qualified-name schema, then
migrate self-host check/types/emit/main together. Its plain-string datum
encoding needs a distinct qualified-ref map at parse time; quoted/data symbols
must stay strings. Acceptance: native and self-host checked JSON agree on the
structured ref shape, and neither self-host emitter searches a ref name for
`/`.

### QSA-6 — branch-core one-representation migration

Mint qualified source references with separate leaf-name and qualifier facts
from the structural checked/source-fact input; do not retain `v = "x/y"` on
semantic reference nodes. `refers_to` remains the semantic identity edge;
qualifier remains source rendering sugar. Remove `make-xresolve`'s string split
and the compound-`v` fallback. Acceptance: querying a qualified reference
returns `name`, `qualifier`, and `refers_to` without any compound slot, and
projection reconstructs `x/y` only at render time.

## `(js call)` alternative

Making qualification an explicit source form such as `(js call)` everywhere
would impose a real reference-site tax: a value reference, higher-order
argument, call head, type head, constructor, pattern, metadata value, and
target intrinsic would all become nested syntax instead of one identifier
token, and macros/destructuring would need to distinguish that reference form
from an ordinary call/list. The audit does not justify that cost. Boundary
structure plus reference sugar is sufficient: keep authored `js/call`, have
the reader/parser lower it once to a qualified-name/ref node, carry
qualifier/name/provider identity separately through checking and facts, and
join only in a textual emitter. What is insufficient is the current version of
“sugar,” where the slash survives as data and every consumer rediscovers its
meaning.

SYMBOL-AUDIT-DONE
