+++
id = "beagle-dsl-candidates"
title = "Small-DSL candidates after hygienic macros and syntax-match"
shape = "proposal"
life = "active"
updated_at = "2026-08-18T00:00:00+08:00"
owners = ["codex:/root"]
depends_on = []
+++

# DSL candidates

## Decision

Propose one small notation: a typed, framed binary-record declaration for the
store's native wire, snapshot, and log codecs. Do not start a general schema
language, a Nix-module wrapper, a test-gate language, an authority-journal
language, or a brief language. The latter four are either already compact or
their remaining complexity is semantic policy that a notation would only hide.

This is deliberately a one-proposal memo. Hygienic macros and syntax-match make
the proposed expansion feasible, but they are not themselves evidence that a
new surface is warranted.

## Proposal: `defwire` for framed tagged byte records

Scope it to private Beagle codec implementation. It declares byte order,
fixed/header fields, bounded text, optional fields, and tagged record cases;
it expands to typed encode/decode helpers and a schema descriptor used by
round-trip and malformed-input tests. It does **not** own domain predicates,
stream recovery, storage, receipts, or public RPC types.

Evidence for repetition:

- `beagle:store/src/store/native_wire_codec.bgl:444` reads the seven-field
  request body in field order, while `beagle:store/src/store/native_wire_codec.bgl:533`
  independently writes the response body and `:559` independently writes its
  common frame header. The decoder separately checks magic, version, kind,
  flags, declared length, and trailing bytes at `:474`–`:516`.
- `beagle:store/src/store/snapshot_codec.bgl:27`–`:41` manually assigns five
  record tags, six atom tags, and two action tags. It separately maintains
  fixed record sizes at `:143`–`:150`, then repeats the frame length/CRC
  discipline in `start-record!`/`finish-record!` at `:152`–`:165` and dispatches
  record tags during read at `:560`–`:572`.
- `beagle:store/src/store/log_codec.bgl:181`–`:238` spells a transaction frame
  layout and its validation as a hand-paired byte walk. The shared primitive
  library already has 53 definitions in `native_wire_codec.bgl`, while
  `log_codec.bgl` and `snapshot_codec.bgl` add protocol-specific layout code.
  That is repeated layout knowledge, not merely repeated arithmetic.

Before (today, abbreviated):

```clojure
;; tag definitions + field order + bounds + encode path + decode path
(def record-triple Int 2)
(def triple-record-bytes Int 25)
(append-u8! out record-triple)
(append-i64-le! out (t/triplerow-t1 row))
;; elsewhere: read tag, select case, read three i64s, reject bad length/CRC
```

After (illustrative surface, not a fixed design):

```clojure
(defwire snapshot-record
  (framed :u32le :crc32)
  (tagged :u8
    [1 atom    ...]
    [2 triple  [(t1 :i64le) (t2 :i64le) (t3 :i64le)]]
    [3 tx      [(sequence :i64le) (first-op :i64le) (count :i64le)]]))
```

The expansion supplies the positional byte walk, declared fixed-size
calculation where applicable, tag dispatch, and exact trailing-byte refusal.
The handwritten caller still says, for example, that a transaction count is
positive, an image trailer is last, or a sidecar agrees with a log: those are
policy, not schema.

Why a function library is not enough: the dangerous duplication is one
declaration's *correspondence* across encoder order, decoder order, tag values,
sizes, and generated test cases. Functions can reduce individual `append-u32!`
and `read-u32!` calls—the repository already does that—but cannot make a field
appearing in one direction obligatorily appear in the other. A hygienic macro
can accept the field syntax once and generate both typed directions plus
schema-derived negative cases; syntax-match can reject malformed declarations
at expansion time.

Cost and containment:

- Tooling: compiler expansion support, useful diagnostics pointing to a field,
  and a small schema-derived test fixture mechanism. Debuggers must still show
  expanded source clearly.
- Learnability: codec authors learn a second, intentionally narrow vocabulary.
  Keep it private until two codecs migrate without escape hatches; do not make
  it a general-purpose serialization product.
- Risk: a too-clever DSL could conceal limits and canonicalization. Require
  explicit bounds and leave every semantic validation branch in ordinary
  Beagle. Migrate one layout at a time behind existing codec tests.

## Rejections

### Nix module surface — reject

`beagle:examples/nix-module.bnix:4` already has the small boundary notation
`nix/module`; its module body is direct typed data. The more involved options
example at `beagle:beagle-test/tests/fixtures/nix-options.bnix:4`–`:15` is only
12 body lines and necessarily exposes real Nix constructs (`mkEnableOption`,
`mkOption`, `mkIf`, nested service configuration). A new module DSL would add a
second vocabulary while either leaking those constructs unchanged or falsely
restricting the live Nix surface. Helpers and the existing `nix/module` form
are enough because the remaining variation is Nix's public module API, not a
repeated local protocol.

### Test-gate phase declarations — reject

`beagle:bin/beagle-test:33`–`:37` contains four ordered prerequisite gates and
then delegates tier scheduling to the Racket runner. The tier manifest is
already a data declaration (`beagle:beagle-test/tiers.rktd:49`), and phase
sharding already uses literal `(phase-test "name" ...)` blocks derived from
source rather than a copied list (`beagle:beagle-lib/private/tier-runner.rkt:88`–`:121`).
Only `wasm-materializer.rkt` is registered as sharded (`:125`–`:129`). There is
no repeated declaration family large enough to offset another language or a
macro whose output must remain executable Racket tests.

### Store receipt schemas — reject a receipt DSL; retain the binary-layout proposal above

The word “receipt” does not identify one structural family. Capacity evidence
is a canonical JSON report with domain-specific boolean claims
(`beagle:store/clients/cloudflare-do/capacity/receipt.test.mjs:150`–`:176`),
whereas the binary RPC code enforces a hostile-input protocol
(`beagle:store/src/store/native_wire_codec.bgl:474`–`:516`) and snapshot boot
has its own recovery policy (`beagle:store/src/store/snapshot_codec.bgl:687`–`:718`).
A generic receipt notation would either be a record constructor library or
erase the evidence semantics. The accepted `defwire` proposal targets only the
real common shape: binary layouts needing a paired encoder/decoder.

### Game authority journal rules — reject

The journal has one append schema with twelve required fields
(`greywrought:tools/authority-journal.mjs:373`–`:420`), but its complexity is
not field spelling. It is exact-next-order, consumed-head, and monotonic
revision policy (`:395`–`:403`), then durable CAS/history agreement
(`:421`–`:452`) and revision-pinned chain verification on reads (`:457`–`:515`).
Its tests cover ordered durable history, stale claims, and concurrent appends
(`greywrought:tests/authority-journal.test.mjs:157`, `:218`, `:236`). A function
library is sufficient here—the existing `exactObject`, `token`, `uint64`, and
value-envelope functions already factor mechanics—because there is only one
protocol and the load-bearing work is bespoke authority policy. A DSL would
make critical rules less visible without eliminating a recurring declaration.

### North orchestration briefs — reject

The orchestration request already has a machine-checked, eight-field contract
and a generator (`north:orchestration/scripts/build-agents.mjs:146`–`:199`).
The human brief layer intentionally remains prose because it must convey
task-specific outcome, authority, done criteria, and the nearest existing
check; those are explicitly authoring norms (`north:orchestration/docs/method.md:106`–`:143`).
The tasking rules likewise require definitions and authority floors that vary
with each job (`north:orchestration/docs/artifacts/conduct-strong.md:90`–`:109`).
A brief DSL would duplicate the structured spawn envelope while compressing the
context workers actually need. Existing functions/templates and the current
contract are enough; do not turn instructions into a second scheduler.

## Adoption bar

Start only if the next store codec change must modify paired encode/decode
field layouts or tagged cases in at least two of the current codec families.
Prototype against one fixed-size snapshot record and one bounded/optional RPC
body field. Keep the existing malformed-input and round-trip tests as the
acceptance evidence; abandon the notation if ordinary semantic checks dominate
the expansion or its diagnostics obscure byte offsets.

DSL-PLAN-DONE — proposal count: 1
