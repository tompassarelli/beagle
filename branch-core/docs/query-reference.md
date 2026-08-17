# Query reference

This document specifies the current structured Datalog plan, its relations, operators, temporal views, limits, and paging behavior.

The CLI accepts one EDN map and JSON adapters accept the equivalent JSON; both
lower [Terms](glossary.md#semantic-kernel), variables, and controls before
FRAMRPC v2. The evaluator never parses query text. Use
`bin/fram query '<edn>'` or MCP `ask`.

## Values and relations

Constants are Terms. Local EDN represents a recursive Triple as a three-element vector and an Instant as `{:instant [epoch-seconds nanos]}`. A variable is `{:var "name"}`; constants retain type.

```text
triple(t1, t2, t3)
occurrence(coordinate, action, proposition)
withdrawal(retraction, assertion)

text-match(entity, attribute, needle)
text-phrase(entity, attribute, needle)
text-substring(entity, attribute, needle)
text-stem(entity, attribute, needle)
text-search(entity, attribute, needle, score)
```

The live store is a multiset of assertion occurrences. Equal proposition
content may therefore be live more than once, and direct `rpc/scan` preserves
those duplicate Triple rows. Datalog relations instead have structural set
semantics: `triple` contains one row per distinct live proposition, so equal
live occurrences collapse to one `triple` row. `occurrence` exposes signed
history without losing acts because its coordinate makes each row distinct,
and `withdrawal` relates a successful retraction occurrence to the exact
earlier assertion occurrence it cancels. All three are materialized. `triple`
is position-neutral; the other two assign system roles to their columns. Every
cell remains a Term even though query relations may have arbitrary arity; a
query row is not another public Term form.

For every `withdrawal(R, A)`, `occurrence(A, :assert, P)` and
`occurrence(R, :retract, P)` exist in the same SpaceId, `A` precedes `R`, and
`A` was live immediately before `R`. A successful retraction targets the
newest live assertion with equal proposition content; older equal occurrences
may remain live. A no-match retraction still records a retraction occurrence,
advances the version, and reports `stateChanged = false`, but produces no
withdrawal row. The five text relations are positive virtual relations over
live String values in the third position and speak the
[EAV reading](ontology.md#profiles-and-anchoring) because that reading is what
a text search of a value assumes.

## Rules

This query derives each directly stated contact endpoint:

```edn
{:find "emails"
 :rules
 [{:head {:rel "emails" :args [{:var "who"} {:var "email"}]}
   :body [{:rel "triple"
           :args [{:var "who"} :contactable_at {:var "email"}]}]}]}
```

`:find` names a derived relation. Supply exactly one of `:rules` (one stratum) or `:strata` (ordered strata). Each rule has one head and an ordered body; the evaluator does not reorder clauses.

The optional `:order-by` vector applies stable result ordering by zero-based
output column. Each clause is `{:column N :direction :asc|:desc}`. Values use
natural order within their Term kind (including numeric score order), clauses
are applied left to right, and the canonical full-row key is the final tie
breaker. Optional `:limit` (1 through 100000) is applied after that global
ordering, so it is a deterministic top-K rather than a page-local truncation.
The Bun spelling is `orderBy: [{ column: N, direction: 'asc'|'desc' }]`.

Triple constants match in every position. Multiple rules with the same head recurse by semi-naive fixpoint:

```edn
{:find "reaches"
 :rules
 [{:head {:rel "reaches" :args [{:var "x"} {:var "y"}]}
   :body [{:rel "triple" :args [{:var "x"} :edge {:var "y"}]}]}
  {:head {:rel "reaches" :args [{:var "x"} {:var "z"}]}
   :body [{:rel "triple" :args [{:var "x"} :edge {:var "y"}]}
          {:rel "reaches" :args [{:var "y"} {:var "z"}]}]}]}
```

Set `:neg true` on a relation clause. All variables it reads must already be bound by positive clauses, and its dependency must be in an earlier stratum; unstratified negation is rejected.

## Text relations

All five examine the third position of live propositions and share one obligation set: the needle must be a String constant or an earlier-bound String variable, and negation, unbound needles, and empty or punctuation-only needles are rejected.

Tokenizer v0 takes maximal Unicode Letter/DecimalDigit runs, lowercases without locale, and treats punctuation, whitespace, `_`, and `-` as delimiters. Repeated tokens deduplicate.

- `text-match` — the tokens as an unordered conjunction; order-independent, and the released semantics are unchanged by everything below.
- `text-phrase` — the same tokens in order, across punctuation. `"quick brown fox"` matches where `"brown quick"` does not.
- `text-substring` — case-folded literal containment that keeps punctuation, so `OWN_FO` matches `quick-brown_fox`. Needles too short to index fall back to an exact scan.
- `text-stem` — English stemming, so one needle unifies inflected forms (`runs`, `runner`, `running` all stem to `run`). It does not change `text-match`.
- `text-search` — four arity: the fourth argument binds a score. Exact evidence outranks stem evidence, which outranks substring evidence.

One index serves all five. When every text-relation attribute is a constant,
FRAM builds that query's source from only those attributes; a variable
attribute conservatively retains the full live String corpus. The analyzers
behind phrase, substring, stem, and search realize on first use of their
relation, so a `text-match` query pays neither their build time nor their
bytes; a plan that names no text relation builds no index at all. An index
build is bounded at 64 MiB and fails typed `:query-text-index-limit`.

Retention differs by route. The JVM server retains the index per immutable snapshot and attribute scope in a single-flight LRU keyed by server generation, SpaceId, and version, holding four entries; version identity replaces TTL, and there is no scan fallback. The native engine builds the source per query and relies on the ordered-result cache below for repeats.

## Occurrence history and views

The native query payload carries exactly one selector:

```text
:query/current
:query/as-of U
:query/since L upper       upper := :query/current | :query/as-of U
```

Current pins head sequence `U` at request start; as-of reads state after
transaction `U`, inclusive. Both expose live `triple` state at `U`, occurrences
through `U`, and withdrawals whose retraction is through `U`. Since preserves
that upper state while restricting rows to what happened in `(L,U]`. On the
native engine this lower bound applies to **every** base relation, not only
`occurrence`: `withdrawal` keys its window to the retraction coordinate, while
`triple` and the text relations filter their candidates by the same lower
bound. The retained JVM server diverges: it lower-bounds `occurrence` and
`withdrawal`, but leaves `triple` and the text relations at the upper snapshot
`U`. Transaction sequence is the selector; wall clock remains metadata.

Negative, future, or reversed bounds fail as `:query-invalid-snapshot`. Missing sealed history is retryable `:query/archive-unavailable`; history explicitly removed by retention is non-retryable `:query/snapshot-expired`. Completed epochs are retained by default.

## Predicates, arithmetic, and aggregates

A comparison filters without binding:

```edn
{:pred :gt :args [{:var "count"} 100]}
```

Operations are `:eq`, `:ne`, `:lt`, `:le`, `:gt`, and `:ge`. Inputs must be bound; equality uses Term equality, while ordering requires numbers and drops nonnumeric rows.

Arithmetic binds one fresh variable: `{:fn :+ :args [{:var "count"} 1] :bind "next"}`. Operations are `:+`, `:-`, `:*`, `:/`, and `:mod`; invalid arithmetic drops the row. Recursive rules may not contain arithmetic.

Aggregate finds group a completed relation:

```edn
{:find {:rel "degree" :group [0]
        :agg [{:op :count}]
        :having [{:op :gt :agg 0 :val 5}]}
 :rules
 [{:head {:rel "degree" :args [{:var "node"} {:var "next"}]}
   :body [{:rel "triple" :args [{:var "node"} :edge {:var "next"}]}]}]}
```

Supported aggregates are `:count`, `:count-distinct`, `:sum`, `:avg`, `:min`, and `:max`. All but count require zero-based input `:arg`; numeric aggregates reject nonnumeric selected values. `:having` addresses aggregate entries by index. Aggregate results are not pageable.

## Validation, limits, and paging

Compilation rejects malformed Terms, unknown relations, arity disagreement, undefined derived relations, unbound variables, invalid strata, recursive arithmetic, and invalid text-match use. Execution enforces step, time, result-count, and wire-byte budgets.

Without `:order-by`, rows retain deterministic canonical Term ordering. An
opaque query cursor binds the last row, resolved upper sequence, and
lower-exclusive occurrence bound. Continuations stay on the same immutable
snapshot and preserve the plan's requested order.

Native read limits differ by operation:

- `rpc/query` refuses an unpaged result above 248 rows with typed
  `:term-depth-exceeded`. Page well under that codec-derived bound.
- `rpc/scan` accepts a maximum page limit of 200. An unpaged result above 200
  rows refuses `:rpc/native-page-required`; its cursor is tagged
  `:rpc/native-scan-cursor`.
- `rpc/occurrences` silently returns only the first 248 rows when unpaged, so
  page it whenever completeness matters.

Cursors are opaque and operation-specific: do not reuse a query, scan, or
occurrences cursor with either of the other operations.

The retained JVM server instead refuses unpaged query, scan, and occurrences
results above 248 rows with `:term-depth-exceeded`. It syntactically accepts
page limits through 4096, but the response codec still makes pages near 248
unsafe.

The server caches a complete ordered result by server generation, SpaceId, resolved view, operation, and canonical request digest. Selector-equivalent current/as-of requests share an entry; different since lower bounds do not. Continuation slices the cached vector rather than rerunning the plan. Eviction changes cost, never the pinned answer.

Historical state uses the newest valid prefix-bound FRI2 checkpoint at or before `U`, then replays its tail. Corrupt or stale derived state falls back to canonical replay; sealed epochs use the same prefix proof through a fingerprinted range manifest.

The evaluator contract is
[`../tests/triple_query_test.clj`](../tests/triple_query_test.clj). Despite its
name, [`../tests/native_rpc_server_test.clj`](../tests/native_rpc_server_test.clj)
loads the retained JVM server and is not evidence for native dispatch behavior.
Direct native query response bounds are exercised by
[`../tests/fram_wasm_embed_smoke.sh`](../tests/fram_wasm_embed_smoke.sh). Text,
cache, differential, and performance gates are the `text_match`,
`text_index_cache`, `datalog_diff`, and `text_index_perf` tests in that
directory.
