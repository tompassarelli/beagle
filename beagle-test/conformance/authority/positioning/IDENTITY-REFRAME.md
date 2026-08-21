# README identity reframe (operator + review 3, executive-accepted) — fires after README-ROUTER-DONE
CANONICAL SENTENCE: "Beagle is an independent typed Lisp built from a
Clojure-derived core."
- KILL every "subset of Clojure" / "strict typed subset" framing: subset =
  Clojure minus things = descriptively false and caps the thesis.
- THE CONSTITUTION RULE, verbatim in the README as the design principle:
  "If Clojure already has a form whose semantics are correct for Beagle,
  inherit it. If the semantics differ, name the difference." (Same law as the
  conformance alarm-bell lens — cite nothing, just state it.)
- INHERITANCE BOUNDARY stated explicitly: derived = Clojure's vocabulary and
  structural authoring model (form library, s-expressions, data literals,
  defn/let/destructuring/threading ergonomics). Independent = types, effects,
  execution model, memory/data model (no JVM, no lazy seqs, no dynamic vars,
  no GC-backed persistence — the store and arenas instead).
- Layering line available if useful: "Clojure vocabulary + Beagle type system
  + Beagle execution/data model."
- Preservation clause: "Beagle preserves Clojure where preservation has
  semantic value, never for compatibility's sake."
