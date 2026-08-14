#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

command -v bb >/dev/null 2>&1 || {
  echo "checked_program_ingress.sh: babashka (bb) is required" >&2
  exit 2
}

bb -e '
  (load-file (first *command-line-args*))
  (require (quote [native.checked-program :as checked]))
  (let [escape-payload {"control" "\u000b"
                        "literal" "\\u000B"}
        escape-digest (checked/projection-digest escape-payload)
        literal-lower-digest
        (checked/projection-digest (assoc escape-payload "literal" "\\u000b"))
        base {"kind" "beagle.checked-program"
              "schemaVersion" 3
              "phase" "checked"
              "namespace" "native.ingress-λ"
              "forms" [{"node" "defn"
                         "name" "constrained"
                         "params" [{"type" "param"
                                    "name" "value"
                                    "ann" {"kind" "prim" "name" "Float"}
                                    "constraintSynchronous" true
                                    "constraint" {"node" "ref"
                                                  "name" "finite?"}}]
                         "body" [{"node" "literal"
                                  "kind" "float"
                                  "value" 1.25}
                                 {"node" "with"
                                  "recordUpdate" {"recordName" "Score"
                                                  "fieldOrder" [":value"]
                                                  "validator" nil}}
                                 {"node" "kw-access"
                                  "recordFieldAccess" {"recordName" "Score"}}]}]}
        authentic (checked/with-projection-digest base)
        tampered (assoc-in authentic ["forms" 0 "params" 0 "constraint"] nil)
        inconsistent (checked/with-projection-digest tampered)
        repaired (checked/with-projection-digest
                   (assoc-in tampered
                     ["forms" 0 "params" 0 "constraintSynchronous"] false))
        missing-proof (checked/with-projection-digest
                        (update-in base ["forms" 0 "params" 0]
                          dissoc "constraintSynchronous"))
        malformed-record-update (checked/with-projection-digest
                                  (assoc-in base
                                    ["forms" 0 "body" 1 "recordUpdate"]
                                    {"recordName" "Score"
                                     "fieldOrder" [":value"]
                                     "validator" nil
                                     "extra" true}))
        missing-field-access (checked/with-projection-digest
                               (update-in base ["forms" 0 "body" 2]
                                 dissoc "recordFieldAccess"))]
    (when-not (= "sha256:3ad47654810b8b6943504e237b4a929aac61c6b5d53731d2bcc366995e6dafdb"
                escape-digest)
      (throw (ex-info "JSON unicode escape canonicalization drifted"
               {:actual escape-digest})))
    (when (= escape-digest literal-lower-digest)
      (throw (ex-info "literal backslash-u payload was normalized" {})))
    (checked/require-checked-program! authentic "authentic" "test ingress")
    (try
      (checked/require-checked-program! tampered "tampered" "test ingress")
      (throw (ex-info "stale projection digest was accepted" {}))
      (catch clojure.lang.ExceptionInfo error
        (when-not (clojure.string/includes?
                    (ex-message error) "projectionSha256 does not match")
          (throw error))))
    (try
      (checked/require-checked-program! inconsistent "inconsistent" "test ingress")
      (throw (ex-info "constraint/proof mismatch was accepted" {}))
      (catch clojure.lang.ExceptionInfo error
        (when-not (clojure.string/includes?
                    (ex-message error) "null constraint requires")
          (throw error))))
    (try
      (checked/require-checked-program! missing-proof "missing-proof" "test ingress")
      (throw (ex-info "missing synchronous proof was accepted" {}))
      (catch clojure.lang.ExceptionInfo error
        (when-not (clojure.string/includes?
                    (ex-message error) "missing checker-owned")
          (throw error))))
    (checked/require-checked-program! repaired "repaired" "test ingress")
    (try
      (checked/require-checked-program!
        malformed-record-update "malformed-record-update" "test ingress")
      (throw (ex-info "non-exact recordUpdate was accepted" {}))
      (catch clojure.lang.ExceptionInfo error
        (when-not (clojure.string/includes? (ex-message error) "recordUpdate")
          (throw error))))
    (try
      (checked/require-checked-program!
        missing-field-access "missing-field-access" "test ingress")
      (throw (ex-info "missing recordFieldAccess was accepted" {}))
      (catch clojure.lang.ExceptionInfo error
        (when-not (clojure.string/includes? (ex-message error) "recordFieldAccess")
          (throw error))))
    (try
      (checked/require-checked-program!
        (checked/with-projection-digest (assoc base "schemaVersion" 2))
        "old-schema" "test ingress")
      (throw (ex-info "old checked-program schema was accepted" {}))
      (catch clojure.lang.ExceptionInfo error
        (when-not (clojure.string/includes?
                    (ex-message error) "schemaVersion 3")
          (throw error))))
    (println "checked-program ingress: cross-runtime escapes, authenticity, structural constraint proof, and schema gate PASS"))' \
  "$repo/native-core/bin/checked-program.clj"
