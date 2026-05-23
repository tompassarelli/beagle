# Plan: schema-typed paths — extend beyond Nix + SQL

## Thesis

When a typed authoring language ingests its target domain's **authoritative
external schema**, typos against that schema become compile errors with
"did you mean: X?" suggestions instead of runtime mysteries.

This is the line that separates beagle from "yet another typed Lisp" —
the type system isn't just checking what *beagle* knows; it's checking
against what the *domain* knows, surfaced through machine-readable specs.

## State

- **Nix** (done, v0.13) — `.beagle-cache/schema.json` (NixOS options, ~16k paths).
  `config.services.openshh.enable` → compile error with suggestion.
- **SQL** (done, v0.14) — `.beagle-cache/sql-schema.json` (tables, columns,
  FKs). `posts.author_id` typo → compile error with suggestion.

Same code shape both times. Two proof points; the pattern is real and the
infrastructure (cache walk-up, Levenshtein suggest, current-X-schema
parameter) is reusable.

## Backlog

### P0 — TypeScript declarations for JS

**Schema:** `.d.ts` files from DefinitelyTyped (thousands of npm libraries
already typed by the community).

**What it enables:** type the entire typed JS ecosystem. An agent writing
`Object.kies(o)` gets "did you mean: keys?"; using a React component with
the wrong prop shape gets a compile error.

**Effort:** medium. Need a `.d.ts` parser (or wrap `tsc --declaration` /
the official TypeScript compiler API via subprocess) → emit
`.beagle-cache/js-types.json`. Wire into beagle's existing stdlib-js
catalog as an extra layer (per-library, opt-in via `(require library-name)`).

**Why P0:** schema source is enormous, mature, free. ROI per hour of work
is the highest of any item here. Stdlib-js currently has 102 entries —
this would push it past 10,000 with no per-entry hand-typing.

**Dependencies:** none.

---

### P0 — `(import math)` style stdlib catalog per language

**Schema:** Python's own `inspect` / `typing` stubs (PEP 561), or the
`typeshed` project (community Python type stubs, mirrors DefinitelyTyped
in shape).

**What it enables:** same as the JS/TS case, but for Python. `import
requests` and `requests.get(url, timeout=5)` becomes typed automatically.

**Effort:** medium. Read typeshed `.pyi` files → emit
`.beagle-cache/py-types.json`. Stdlib-py grows from 348 hand-typed entries
to "everything in PyPI that has stubs."

**Why P0:** same logic as TS. typeshed is the Python equivalent of
DefinitelyTyped and is similarly mature. Pairs well with the TS work
(same conceptual approach, different parser).

**Dependencies:** TS work first (reuses the per-library catalog pattern).

---

### P1 — OpenAPI / Swagger for HTTP code

**Schema:** OpenAPI 3.x YAML/JSON specs (REST endpoints with paths,
methods, request/response shapes).

**What it enables:** any beagle target making HTTP calls types its
endpoint references. An agent writing `(api-call :get "/api/usrs/:id")`
gets "did you mean: /api/users/{id}?"; sending a body with the wrong
shape errors at compile time.

**Effort:** medium-high. OpenAPI YAML parser + schema struct for path
patterns + parametric type for request/response shapes. Needs a beagle
surface form for HTTP calls (e.g. `(http-get :endpoint-name {:params})`)
that targets resolve to actual fetch/requests/curl calls per emit target.

**Why P1:** *the* biggest source of agent bugs in real-world
service-to-service code is API drift. This would be huge for that
audience. But the effort is higher because beagle needs a new surface
form (HTTP-call abstraction) in addition to the schema ingestion.

**Dependencies:** none directly, but benefits from having an established
"add-a-schema" pattern (which TS work would solidify).

---

### P1 — JSON Schema for arbitrary data documents

**Schema:** JSON Schema files describing the shape of any JSON
document (webhooks, API responses, config files, telemetry events).

**What it enables:** when a beagle file processes a JSON payload of
known shape, `payload.pull_request.head.ref` becomes a typed string,
not a string-typed string. Typos against the payload structure error
at compile time.

**Effort:** medium. JSON Schema parser → recursive type construction →
inject into beagle's check phase via a `(declare-json-shape payload
"schemas/github-webhook.json")` form.

**Why P1:** generic. Many existing schemas use it (GitHub webhooks,
Stripe events, AWS service models). Once this lands, agents processing
any well-documented JSON shape get full path validation.

**Dependencies:** none. Could be done independently of TS/OpenAPI work.

---

### P2 — GraphQL schemas for client code

**Schema:** GraphQL SDL files (the introspectable schema of a GraphQL
endpoint).

**What it enables:** GraphQL queries authored in beagle get field
validation at compile time. Mistyped field names or wrong argument types
fail to compile.

**Effort:** medium. GraphQL SDL parser + query-as-AST representation.

**Why P2 (not P1):** GraphQL is a narrower domain than REST/OpenAPI;
fewer projects use it. But for projects that do, this is high-value.

---

### P2 — Protobuf / Avro for binary data

**Schema:** `.proto` / `.avsc` files describing binary message shapes.

**What it enables:** typed access to gRPC/Kafka/event-sourcing payloads.

**Effort:** medium. Protobuf reflection is well-defined; AVSC is JSON-ish.

**Why P2:** narrower audience (mostly backend services with binary
RPC/messaging). High-value for those, but smaller addressable set.

---

### P2 — Kubernetes CRDs

**Schema:** Custom Resource Definitions (CRDs) shipped by every K8s
operator describe the shape of `kind: MyResource` documents.

**What it enables:** authoring K8s manifests in beagle gets per-CRD
field validation. `spec.scaleTargetRef.kind` becomes a typed reference
to the operator's declared options.

**Effort:** medium. CRDs are OpenAPI schemas embedded in YAML, so the
OpenAPI work (above) does most of this for free.

**Why P2:** beagle/nix already handles a lot of K8s use cases via the
NixOS schema overlap. Adding direct CRD ingestion is incremental.

**Dependencies:** OpenAPI work above.

---

### P2 — Cargo.toml / package.json / pyproject.toml manifest schemas

**Schema:** the published JSON Schema for each package-manager manifest
format.

**What it enables:** authoring or modifying manifests in beagle gets
field-name validation. Subsumed by the general JSON Schema work but
useful as a high-impact concrete demo.

**Why P2:** narrow utility on its own, but a good demo of "JSON Schema
ingestion works for any schema'd file."

**Dependencies:** JSON Schema work above.

---

## Cross-cutting work (prereqs / accelerators)

These aren't standalone deliverables but make multiple items above
cheaper:

- **Levenshtein suggestion polish** — the current "did you mean: X?" is
  Top-1 from a Levenshtein scan. For very large schemas (TS could have
  10k+ candidate names) the threshold heuristic in `nixos-schema.rkt`
  may need tuning. Worth a quick pass before the big ingestion drops.
- **Schema cache invalidation** — current `.beagle-cache/*.json` cache
  uses mtime-keyed in-process memoization. Daemon already shares
  process state; double-check that schema-cache invalidation propagates
  through `bin/beagle-daemon` correctly.
- **Document the pattern** — write a how-to-add-a-schema-ingestion section
  in `beagle-doc/scribblings/` so future targets follow the same shape.

## What success looks like

When the first three (TS, typeshed, OpenAPI) land, beagle's positioning
changes from "typed Lisp for Nix" to "typed authoring language with the
biggest pre-typed library surface of any Lisp-family language." The
pitch becomes:

> beagle types not just its own forms but the schemas of every domain
> you author against — NixOS options, SQL columns, npm package APIs,
> Python library calls, REST endpoints. Wrong identifier → compile
> error → "did you mean: X?" Never run-and-find-out at the boundary.

That's a real story for agents and the humans who deploy them.
