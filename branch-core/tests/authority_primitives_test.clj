;; Pure authority-v1 contract tests. No filesystem, server, MCP, or Nix IO.
;;   bb -cp out tests/authority_primitives_test.clj
(require '[fram.authority :as a]
         '[fram.tools :as tools]
         '[cheshire.core :as json])

(def checks (atom []))
(defn chk [name ok] (swap! checks conj [name (boolean ok)]))
(defn rejected? [f]
  (try (f) false
       (catch clojure.lang.ExceptionInfo _ true)))
(defn chk-reject [name f] (chk name (rejected? f)))

(defn input-schema [params]
  {"type" "object"
   "properties" (reduce (fn [m p]
                            (assoc m (:name p)
                                   {"type" (:type p)
                                    "description" (:name p)}))
                          {} params)
   "required" (vec (keep (fn [p] (when (:required p) (:name p))) params))})

(def edit-tool-names (set a/expected-tool-order))
(def served-tools
  (->> (tools/catalog [])
       (filterv (fn [spec] (contains? edit-tool-names (:name spec))))
       (mapv (fn [spec]
               {"name" (:name spec)
                "description" (:desc spec)
                "inputSchema" (input-schema (:params spec))}))))
(def catalog {"catalogVersion" "fram.graph-edit-tools/v1"
              "tools" served-tools})
(def digest-x (a/sha256-text "x"))

;; Closed JSON domain and the explicitly bounded RFC 8785/JCS subset.
(chk "JSON booleans admitted" (and (a/json-subset-value? true)
                                    (a/json-subset-value? false)))
(chk "JSON strings/arrays/objects admitted"
     (a/json-subset-value? {"a" [true "x"]}))
(chk "JSON numbers rejected" (not (a/json-subset-value? 1)))
(chk "JSON null rejected" (not (a/json-subset-value? nil)))
(chk "JSON keyword keys rejected" (not (a/json-subset-value? {:a "x"})))
(chk "JSON lists rejected" (not (a/json-subset-value? '("x"))))
(chk "JSON sets rejected" (not (a/json-subset-value? #{"x"})))
(chk "Unicode scalar strings admitted" (a/unicode-scalar-string? "A😀é"))
(chk "lone high surrogate rejected" (not (a/unicode-scalar-string? (String. (char-array [(char 0xd800)])))))
(chk "lone low surrogate rejected" (not (a/unicode-scalar-string? (String. (char-array [(char 0xdc00)])))))
(chk "schema text requires NFC" (and (a/clean-authority-string? "é")
                                       (not (a/clean-authority-string? (str "e" "\u0301")))))
(chk "schema text rejects controls" (not (a/clean-authority-string? "a\u0000b")))
(chk "JCS true/false" (and (= "true" (a/jcs-json-no-number-no-null-canonical! true))
                            (= "false" (a/jcs-json-no-number-no-null-canonical! false))))
(chk-reject "JCS rejects number" #(a/jcs-json-no-number-no-null-canonical! 1))
(chk-reject "JCS rejects null" #(a/jcs-json-no-number-no-null-canonical! nil))
(chk "JCS control/string escaping golden"
     (= "\"\\b\\t\\n\\f\\r\\u0000\\\"\\\\/\""
        (a/jcs-json-no-number-no-null-canonical!
         (str "\b" "\t" "\n" "\f" "\r" "\u0000" "\"" "\\" "/"))))
(def unicode-order-object
  {"€" "Euro Sign"
   "\r" "Carriage Return"
   "דּ" "Hebrew Letter Dalet With Dagesh"
   "1" "One"
   "😀" "Emoji: Grinning Face"
   "\u0080" "Control"
   "ö" "Latin Small Letter O With Diaeresis"})
(chk "RFC8785 UTF-16 property ordering golden"
     (= (str "{\"\\r\":\"Carriage Return\",\"1\":\"One\","
             "\"\u0080\":\"Control\",\"ö\":\"Latin Small Letter O With Diaeresis\","
             "\"€\":\"Euro Sign\",\"😀\":\"Emoji: Grinning Face\","
             "\"דּ\":\"Hebrew Letter Dalet With Dagesh\"}")
        (a/jcs-json-no-number-no-null-canonical! unicode-order-object)))
(chk "object insertion order invariant"
     (= (a/digest-json-no-number-no-null! (array-map "b" "2" "a" "1"))
        (a/digest-json-no-number-no-null! (array-map "a" "1" "b" "2"))))
(chk "array order remains significant"
     (not= (a/digest-json-no-number-no-null! ["a" "b"])
           (a/digest-json-no-number-no-null! ["b" "a"])))
(chk "JCS does not normalize Unicode"
     (not= (a/jcs-json-no-number-no-null-canonical! "é")
           (a/jcs-json-no-number-no-null-canonical! (str "e" "\u0301"))))
(chk "lowercase prefixed SHA-256 golden"
     (= "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        (a/sha256-text "abc")))
(def cross-runtime-fixture
  (json/parse-string
   (slurp (str (System/getProperty "user.dir")
               "/tests/fixtures/authority_jcs_v1.json"))))
(chk "cross-runtime fixture is itself in the closed domain"
     (a/json-subset-value? cross-runtime-fixture))
(doseq [vector (get cross-runtime-fixture "vectors")]
  (chk (str "cross-runtime canonical: " (get vector "name"))
       (= (get vector "canonical")
          (a/jcs-json-no-number-no-null-canonical! (get vector "value"))))
  (chk (str "cross-runtime digest: " (get vector "name"))
       (= (get vector "sha256")
          (a/digest-json-no-number-no-null! (get vector "value")))))

;; Raw JSON must be validated before object construction so duplicate names are
;; observable recursively instead of being silently collapsed by a host map.
(def raw-json-fixture
  (json/parse-string
   (slurp (str (System/getProperty "user.dir")
               "/tests/fixtures/authority_raw_json_v1.json"))))
(doseq [vector (get raw-json-fixture "vectors")]
  (if (get vector "reject")
    (chk-reject (str "strict raw JSON rejects: " (get vector "name"))
                #(a/decode-json-no-number-no-null! (get vector "raw")))
    (chk (str "strict raw JSON accepts: " (get vector "name"))
         (= (get vector "expected")
            (a/decode-json-no-number-no-null! (get vector "raw"))))))

;; Canonical decimal strings are unsigned 64-bit and never JSON numbers.
(doseq [[label value expected]
        [["decimal zero" "0" true]
         ["decimal one" "1" true]
         ["decimal u64 max" "18446744073709551615" true]
         ["decimal empty" "" false]
         ["decimal leading zero" "01" false]
         ["decimal plus" "+1" false]
         ["decimal minus" "-1" false]
         ["decimal overflow" "18446744073709551616" false]
         ["decimal numeric input" 1 false]]]
  (chk label (= expected (a/canonical-u64-decimal? value))))

;; Exact ordered five-tool envelope and mutation sensitivity.
(chk "served tool order exact" (= a/expected-tool-order (mapv #(get % "name") served-tools)))
(chk "catalog validates" (= catalog (a/validate-tool-catalog! catalog)))
(chk "catalog fixture digest"
     (= "sha256:226f40e6da724f8a8b38e58f490bf4f0ae09b2bc9991ba93c2b9fb04697eedad"
        (a/tool-catalog-digest! catalog)))
(chk-reject "catalog rejects unknown key" #(a/validate-tool-catalog! (assoc catalog "extra" "x")))
(chk-reject "catalog rejects reorder"
            #(a/validate-tool-catalog!
              (update catalog "tools" (fn [items] (vec (reverse items))))))
(chk-reject "catalog rejects wrong version" #(a/validate-tool-catalog! (assoc catalog "catalogVersion" "v2")))
(def description-mutant (assoc-in catalog ["tools" 0 "description"] "changed"))
(chk "description change changes catalog digest"
     (not= (a/digest-json-no-number-no-null! catalog)
           (a/digest-json-no-number-no-null! description-mutant)))
(chk-reject "description change rejected by exact fixture"
            #(a/tool-catalog-digest! description-mutant))
(def required-order-mutant
  (update-in catalog ["tools" 0 "inputSchema" "required"] #(vec (reverse %))))
(chk "required-array order changes catalog digest"
     (not= (a/digest-json-no-number-no-null! catalog)
           (a/digest-json-no-number-no-null! required-order-mutant)))
(chk-reject "required-array reorder rejected by exact fixture"
            #(a/tool-catalog-digest! required-order-mutant))
(def optionality-mutant
  (update-in catalog ["tools" 4 "inputSchema" "required"] conj "within"))
(chk "optionality changes catalog digest"
     (not= (a/digest-json-no-number-no-null! catalog)
           (a/digest-json-no-number-no-null! optionality-mutant)))
(chk-reject "optionality change rejected by exact fixture"
            #(a/tool-catalog-digest! optionality-mutant))
(chk-reject "property type mutation rejected"
            #(a/validate-tool-catalog! (assoc-in catalog ["tools" 0 "inputSchema" "properties" "module" "type"] "number")))
(chk-reject "property unknown key rejected"
            #(a/validate-tool-catalog! (assoc-in catalog ["tools" 0 "inputSchema" "properties" "module" "extra"] "x")))
(chk-reject "property description/name mismatch rejected"
            #(a/validate-tool-catalog! (assoc-in catalog ["tools" 0 "inputSchema" "properties" "module" "description"] "other")))

;; Pure module-manifest normalization: registered roots may have no AST, but AST
;; modules may never exist without a registered root.
(def entry-a {"moduleId" "src.fram.authority" "sourcePath" "src/fram/authority.bclj"})
(def entry-z {"moduleId" "z.x" "sourcePath" "z/x.bclj"})
(def entry-e {"moduleId" "é.x" "sourcePath" "é/x.bclj"})
(def manifest-empty (a/normalize-module-manifest! "" "0" [] []))
(def manifest-one (a/normalize-module-manifest! "" "1" [entry-a] []))
(chk "empty manifest allowed" (= [] (get manifest-empty "entries")))
(chk "root-only module allowed" (= [entry-a] (get manifest-one "entries")))
(chk-reject "orphan AST rejected"
            #(a/normalize-module-manifest! "" "1" [] ["src.fram.orphan"]))
(chk-reject "duplicate module rejected"
            #(a/normalize-module-manifest! "" "1" [entry-a entry-a] []))
(chk-reject "case-colliding module/path rejected"
            #(a/normalize-module-manifest! "" "1"
                                           [{"moduleId" "A.x" "sourcePath" "A/x.bclj"}
                                            {"moduleId" "a.x" "sourcePath" "a/x.bclj"}] []))
(chk "alias folding is explicitly ASCII-only"
     (= "iİé😀" (a/ascii-case-alias "Iİé😀")))
(def locale-manifests (atom []))
(def original-locale (java.util.Locale/getDefault))
(try
  (doseq [tag ["tr-TR" "az-AZ"]]
    (java.util.Locale/setDefault (java.util.Locale/forLanguageTag tag))
    (swap! locale-manifests conj
           (a/normalize-module-manifest!
            "" "1"
            [{"moduleId" "İ.x" "sourcePath" "İ/x.bclj"}
             {"moduleId" "i.x" "sourcePath" "i/x.bclj"}] []))
    (chk-reject (str "ASCII alias collision rejected under " tag)
                #(a/normalize-module-manifest!
                  "" "1"
                  [{"moduleId" "I.x" "sourcePath" "I/x.bclj"}
                   {"moduleId" "i.x" "sourcePath" "i/x.bclj"}] [])))
  (finally
    (java.util.Locale/setDefault original-locale)))
(chk "manifest aliases are invariant under Turkish and Azeri defaults"
     (apply = @locale-manifests))
(chk-reject "target alias collision rejected"
            #(a/normalize-module-manifest! "" "1"
                                           [{"moduleId" "a.x" "sourcePath" "a/x.bclj"}
                                            {"moduleId" "a.x" "sourcePath" "a/x.bcljs"}] []))
(chk-reject "invalid source extension rejected"
            #(a/normalize-module-manifest! "" "1" [{"moduleId" "a.x" "sourcePath" "a/x.clj"}] []))
(chk-reject "uppercase extension alias rejected"
            #(a/normalize-module-manifest! "" "1" [{"moduleId" "a.x" "sourcePath" "a/x.BCLJ"}] []))
(chk-reject "module/path mismatch rejected"
            #(a/normalize-module-manifest! "" "1" [{"moduleId" "a.y" "sourcePath" "a/x.bclj"}] []))
(chk-reject "absolute source path rejected"
            #(a/normalize-module-manifest! "" "1" [{"moduleId" ".a.x" "sourcePath" "/a/x.bclj"}] []))
(chk-reject "backslash source path rejected"
            #(a/normalize-module-manifest! "" "1" [{"moduleId" "a\\x" "sourcePath" "a\\x.bclj"}] []))
(chk-reject "dot segment rejected"
            #(a/normalize-module-manifest! "" "1" [{"moduleId" "a..x" "sourcePath" "a/./x.bclj"}] []))
(chk-reject "parent segment rejected"
            #(a/normalize-module-manifest! "" "1" [{"moduleId" "a...x" "sourcePath" "a/../x.bclj"}] []))
(chk-reject "control in source path rejected"
            #(a/normalize-module-manifest! "" "1" [{"moduleId" "a.\u0001x" "sourcePath" "a/\u0001x.bclj"}] []))
(chk-reject "non-NFC source path rejected"
            #(let [nfd (str "e" "\u0301")]
               (a/normalize-module-manifest! "" "1"
                                             [{"moduleId" (str nfd ".x")
                                               "sourcePath" (str nfd "/x.bclj")}] [])))
(chk-reject "unknown module-entry key rejected"
            #(a/normalize-module-manifest! "" "1" [(assoc entry-a "target" "clj")] []))
(chk-reject "duplicate AST module ids rejected"
            #(a/normalize-module-manifest! "" "1" [entry-a]
                                           ["src.fram.authority" "src.fram.authority"]))
(def order-a (a/normalize-module-manifest! "" "7" [entry-e entry-z entry-a] []))
(def order-b (a/normalize-module-manifest! "" "7" [entry-a entry-z entry-e] []))
(chk "manifest insertion order invariant" (= order-a order-b))
(chk "manifest unsigned UTF-8 ordering"
     (= ["src.fram.authority" "z.x" "é.x"]
        (mapv #(get % "moduleId") (get order-a "entries"))))
(def manifest-v1 (a/normalize-module-manifest! "src" "10" [entry-a] []))
(def manifest-v2 (a/normalize-module-manifest! "src" "11" [entry-a] []))
(chk "graph snapshot does not change mapping digest"
     (= (get manifest-v1 "mappingDigest") (get manifest-v2 "mappingDigest")))
(chk "graph snapshot changes snapshot digest"
     (not= (get manifest-v1 "snapshotDigest") (get manifest-v2 "snapshotDigest")))
(chk "normalized manifest validates" (= manifest-v1 (a/validate-normalized-module-manifest! manifest-v1)))
(chk-reject "tampered mapping digest rejected"
            #(a/validate-normalized-module-manifest! (assoc manifest-v1 "mappingDigest" digest-x)))
(chk-reject "numeric graph version rejected"
            #(a/normalize-module-manifest! "" 1 [entry-a] []))

;; Descriptor and stable binding fixtures.
(defn manifest-in-descriptor [manifest]
  (select-keys manifest ["manifestVersion" "mappingDigest" "snapshotDigest" "entries"]))
(defn unsigned-descriptor [manifest]
  {"descriptorVersion" "fram.graph-edit-authority/v1"
   "candidateProtocol" "graph-edit-candidate-v2"
   "coordinator"
   {"instanceId" "instance-1"
    "endpoint" {"transport" "mtls-tcp" "host" "127.0.0.1" "port" "41454"
                "serverSpkiSha256" digest-x}
    "lease" {"id" "lease-1" "epoch" "3" "clientSpkiSha256" digest-x
             "expiresAtUnixMs" "18446744073709551615" "state" "active"}}
   "runtime" {"sealVersion" "fram.runtime-seal/v1" "system" "x86_64-linux"
              "roots" ["/nix/store/runtime"] "closureDigest" digest-x}
   "corpus"
   {"checkoutRoot" "/checkout" "sourceRoot" "/checkout/src"
    "sourceRootRelativeToCheckout" (get manifest "sourceRootRelativeToCheckout")
    "codeLog" "/checkout/.fram/code.log"
    "identity" {"checkoutFileKey" "dev:1:ino:2"
                "sourceFileKey" "dev:1:ino:3"
                "logFileKey" "dev:1:ino:4"}
    "snapshot" {"graphVersion" (get manifest "graphVersion")
                "logPrefixBytes" "100" "logPrefixSha256" digest-x
                "moduleManifest" (manifest-in-descriptor manifest)}}
   "tools" {"catalogVersion" (get catalog "catalogVersion")
            "catalogDigest" (a/tool-catalog-digest! catalog)
            "tools" (get catalog "tools")}
   "lifecycle" {"durability" {"state" "clean"}
                "projection" {"state" "current" "generation" "1"}}})
(def descriptor-1 (a/seal-authority-descriptor! (unsigned-descriptor manifest-v1)))
(def descriptor-2 (a/seal-authority-descriptor! (unsigned-descriptor manifest-v2)))
(chk "sealed descriptor validates" (= descriptor-1 (a/validate-authority-descriptor! descriptor-1)))
(chk "descriptor digest has lowercase sha256 form" (.matches (get descriptor-1 "descriptorDigest") "sha256:[0-9a-f]{64}"))
(chk "graph snapshot preserves binding digest"
     (= (get descriptor-1 "bindingDigest") (get descriptor-2 "bindingDigest")))
(chk "graph snapshot changes descriptor digest"
     (not= (get descriptor-1 "descriptorDigest") (get descriptor-2 "descriptorDigest")))
(def descriptor-later-expiry
  (a/seal-authority-descriptor!
   (assoc-in (unsigned-descriptor manifest-v1)
             ["coordinator" "lease" "expiresAtUnixMs"] "18446744073709551614")))
(chk "lease expiry excluded from stable binding"
     (= (get descriptor-1 "bindingDigest") (get descriptor-later-expiry "bindingDigest")))
(chk "lease expiry remains descriptor-bound"
     (not= (get descriptor-1 "descriptorDigest") (get descriptor-later-expiry "descriptorDigest")))
(def manifest-more
  (a/normalize-module-manifest! "src" "10"
                                [entry-a {"moduleId" "src.fram.extra" "sourcePath" "src/fram/extra.bclj"}] []))
(def descriptor-more (a/seal-authority-descriptor! (unsigned-descriptor manifest-more)))
(chk "module mapping changes binding"
     (not= (get descriptor-1 "bindingDigest") (get descriptor-more "bindingDigest")))
(chk "binding projection validates"
     (let [binding (a/authority-binding-from-descriptor descriptor-1)]
       (= (get descriptor-1 "bindingDigest") (a/authority-binding-digest! binding))))
(chk-reject "binding rejects unknown keys"
            #(a/validate-authority-binding!
              (assoc (a/authority-binding-from-descriptor descriptor-1) "expiresAtUnixMs" "1")))
(chk-reject "descriptor rejects unknown top key"
            #(a/validate-authority-descriptor! (assoc descriptor-1 "extra" "x")))
(chk-reject "descriptor rejects tampered descriptor digest"
            #(a/validate-authority-descriptor! (assoc descriptor-1 "descriptorDigest" digest-x)))
(chk-reject "descriptor rejects inactive lease"
            #(a/seal-authority-descriptor!
              (assoc-in (unsigned-descriptor manifest-v1) ["coordinator" "lease" "state"] "expired")))
(chk-reject "descriptor rejects numeric expiry"
            #(a/seal-authority-descriptor!
              (assoc-in (unsigned-descriptor manifest-v1) ["coordinator" "lease" "expiresAtUnixMs"] 1)))

;; Closed receipt algebra. Each phase is a tagged, closed variant: phases that
;; did not run carry no fabricated counters, hashes, or candidate identifiers.
(def not-run-phase {"status" "not_run"})
(def rejected-prepare {"status" "rejected"})
(def accepted-prepare
  {"status" "accepted" "candidateId" "candidate-1"
   "baseGraphVersion" "10" "manifestSnapshotDigest" (get manifest-v1 "snapshotDigest")
   "opsDigest" digest-x "ednDigest" digest-x
   "ops" "2" "asserts" "1" "retracts" "1" "newNodes" "1"})
(def committed-commit
  {"status" "committed" "graphVersionBefore" "10" "graphVersionAfter" "12"
   "installed" "2" "coordinatorReceiptDigest" digest-x})
(def rejected-stale-commit
  {"status" "rejected_stale" "observedGraphVersion" "11"
   "coordinatorReceiptDigest" digest-x})
(def failed-restored-commit
  {"status" "failed_restored" "graphVersionBefore" "10" "graphVersionAfter" "10"
   "installed" "0" "coordinatorReceiptDigest" digest-x})
(def indeterminate-commit
  {"status" "indeterminate" "graphVersionBefore" "10"
   "coordinatorReceiptDigest" digest-x})
(def published-projection
  {"status" "published" "expectedSha256" digest-x "actualSha256" digest-x
   "coordinatorReceiptDigest" digest-x})
(def stale-projection
  {"status" "stale" "expectedSha256" digest-x
   "coordinatorReceiptDigest" digest-x})
(def indeterminate-projection
  {"status" "indeterminate" "expectedSha256" digest-x
   "coordinatorReceiptDigest" digest-x})

(def receipt-cases
  [{"outcome" "completed" "prepare" accepted-prepare "commit" committed-commit
    "projection" published-projection "canonicalMutation" "committed"
    "retry" "never"}
   {"outcome" "rejected_input" "prepare" not-run-phase "commit" not-run-phase
    "projection" not-run-phase "canonicalMutation" "none"
    "retry" "same-session-after-correction" "detailCode" "invalid-input"}
   {"outcome" "rejected_prepare" "prepare" rejected-prepare "commit" not-run-phase
    "projection" not-run-phase "canonicalMutation" "none"
    "retry" "same-session-after-correction" "detailCode" "candidate-rejected"}
   {"outcome" "rejected_stale" "prepare" accepted-prepare "commit" rejected-stale-commit
    "projection" not-run-phase "canonicalMutation" "none"
    "retry" "same-session-reprepare" "detailCode" "stale-version"}
   {"outcome" "commit_failed_restored" "prepare" accepted-prepare "commit" failed-restored-commit
    "projection" not-run-phase "canonicalMutation" "none"
    "retry" "new-session-after-recovery" "detailCode" "durability-failure"}
   {"outcome" "committed_projection_stale" "prepare" accepted-prepare "commit" committed-commit
    "projection" stale-projection "canonicalMutation" "committed"
    "retry" "new-session-after-repair" "detailCode" "projection-stale"}
   {"outcome" "committed_projection_indeterminate" "prepare" accepted-prepare "commit" committed-commit
    "projection" indeterminate-projection "canonicalMutation" "committed"
    "retry" "new-session-after-repair" "detailCode" "projection-indeterminate"}
   {"outcome" "canonical_indeterminate" "prepare" accepted-prepare "commit" indeterminate-commit
    "projection" not-run-phase "canonicalMutation" "indeterminate"
    "retry" "new-session-after-recovery" "detailCode" "commit-response-unknown"}
   {"outcome" "authority_stopped" "prepare" not-run-phase "commit" not-run-phase
    "projection" not-run-phase "canonicalMutation" "none"
    "retry" "lifecycle-specific-new-session" "detailCode" "durability-poisoned"}
   {"outcome" "protocol_violation" "prepare" not-run-phase "commit" not-run-phase
    "projection" not-run-phase "canonicalMutation" "indeterminate"
    "retry" "new-session-after-recovery" "detailCode" "protocol-violation"}])

(defn unsigned-receipt [row]
  (cond->
   {"receiptVersion" "fram.graph-edit-phase-receipt/v1"
    "operationId" (str "op-" (get row "outcome"))
    "authority" {"bindingDigest" (get descriptor-1 "bindingDigest")
                 "descriptorDigest" (get descriptor-1 "descriptorDigest")
                 "instanceId" "instance-1" "leaseId" "lease-1" "leaseEpoch" "3"}
    "request" {"tool" "add-def"
               "argumentsDigest" (a/digest-json-no-number-no-null!
                                  {"module" "src.fram.authority" "form" "(def x 1)"})}
    "module" entry-a
    "prepare" (get row "prepare") "commit" (get row "commit")
    "projection" (get row "projection") "outcome" (get row "outcome")
    "canonicalMutation" (get row "canonicalMutation") "retry" (get row "retry")
    "automaticRetryable" false}
    (contains? row "detailCode") (assoc "detailCode" (get row "detailCode"))))

(defn row-for [outcome]
  (first (filter #(= outcome (get % "outcome")) receipt-cases)))

(chk "receipt outcome vocabulary is exactly ten rows"
     (= (set (keys a/receipt-transition-table))
        (set (map #(get % "outcome") receipt-cases))))
(doseq [row receipt-cases]
  (let [outcome (get row "outcome")
        unsigned (unsigned-receipt row)
        sealed (a/seal-phase-receipt! unsigned)
        spec (get a/receipt-transition-table outcome)]
    (chk (str "receipt row validates: " outcome)
         (= sealed (a/validate-phase-receipt! sealed)))
    (chk (str "receipt row transition exact: " outcome)
         (= {"prepare" (get-in row ["prepare" "status"])
             "commit" (get-in row ["commit" "status"])
             "projection" (get-in row ["projection" "status"])
             "canonicalMutation" (get row "canonicalMutation")
             "retry" (get row "retry")}
            (select-keys spec ["prepare" "commit" "projection" "canonicalMutation" "retry"])))
    (chk (str "receipt detail presence exact: " outcome)
         (= (= outcome "completed") (not (contains? sealed "detailCode"))))))

(def completed-unsigned (unsigned-receipt (row-for "completed")))
(def completed (a/seal-phase-receipt! completed-unsigned))
(def rejected-input-unsigned (unsigned-receipt (row-for "rejected_input")))
(def rejected-stale-unsigned (unsigned-receipt (row-for "rejected_stale")))
(def restored-unsigned (unsigned-receipt (row-for "commit_failed_restored")))
(def canonical-indeterminate-unsigned (unsigned-receipt (row-for "canonical_indeterminate")))
(def projection-stale-unsigned (unsigned-receipt (row-for "committed_projection_stale")))

(chk "receipt digest has lowercase sha256 form"
     (.matches (get completed "receiptDigest") "sha256:[0-9a-f]{64}"))
(chk "projection failure preserves committed canonical mutation"
     (and (= "committed" (get projection-stale-unsigned "canonicalMutation"))
          (= "new-session-after-repair" (get projection-stale-unsigned "retry"))))
(chk-reject "receipt rejects unknown top-level key"
            #(a/seal-phase-receipt! (assoc completed-unsigned "extra" "x")))
(chk-reject "completed receipt rejects detailCode"
            #(a/seal-phase-receipt! (assoc completed-unsigned "detailCode" "protocol-violation")))
(chk-reject "non-completed receipt requires detailCode"
            #(a/seal-phase-receipt! (dissoc rejected-input-unsigned "detailCode")))
(chk-reject "detailCode is closed per outcome"
            #(a/seal-phase-receipt! (assoc rejected-input-unsigned "detailCode" "candidate-rejected")))
(chk-reject "unknown outcome rejected"
            #(a/seal-phase-receipt! (assoc rejected-input-unsigned "outcome" "rejected")))
(chk-reject "unknown prepare status rejected"
            #(a/seal-phase-receipt! (assoc-in completed-unsigned ["prepare" "status"] "prepared")))
(chk-reject "unknown commit status rejected"
            #(a/seal-phase-receipt! (assoc-in completed-unsigned ["commit" "status"] "installed")))
(chk-reject "unknown projection status rejected"
            #(a/seal-phase-receipt! (assoc-in completed-unsigned ["projection" "status"] "installed")))
(chk-reject "not_run prepare rejects fabricated candidate fields"
            #(a/seal-phase-receipt!
              (assoc-in rejected-input-unsigned ["prepare" "candidateId"] "fake")))
(chk-reject "not_run commit rejects fabricated version fields"
            #(a/seal-phase-receipt!
              (assoc-in rejected-input-unsigned ["commit" "graphVersionBefore"] "10")))
(chk-reject "not_run projection rejects fabricated hashes"
            #(a/seal-phase-receipt!
              (assoc-in rejected-input-unsigned ["projection" "expectedSha256"] digest-x)))
(chk-reject "indeterminate commit rejects fake graphVersionAfter"
            #(a/seal-phase-receipt!
              (assoc-in canonical-indeterminate-unsigned ["commit" "graphVersionAfter"] "10")))
(chk-reject "stale projection rejects fake actualSha256"
            #(a/seal-phase-receipt!
              (assoc-in projection-stale-unsigned ["projection" "actualSha256"] digest-x)))
(chk-reject "completed tuple rejects noncanonical marker"
            #(a/seal-phase-receipt! (assoc completed-unsigned "canonicalMutation" "none")))
(chk-reject "rejected tuple cannot claim canonical commit"
            #(a/seal-phase-receipt! (assoc rejected-input-unsigned "canonicalMutation" "committed")))
(chk-reject "completed tuple rejects alternate retry policy"
            #(a/seal-phase-receipt! (assoc completed-unsigned "retry" "new-session-after-repair")))
(chk-reject "completed tuple rejects alternate prepare variant"
            #(a/seal-phase-receipt! (assoc completed-unsigned "prepare" not-run-phase)))
(chk-reject "completed tuple rejects alternate projection variant"
            #(a/seal-phase-receipt! (assoc completed-unsigned "projection" stale-projection)))
(chk-reject "automaticRetryable true is never valid"
            #(a/seal-phase-receipt! (assoc rejected-input-unsigned "automaticRetryable" true)))
(chk-reject "automaticRetryable must be boolean"
            #(a/seal-phase-receipt! (assoc completed-unsigned "automaticRetryable" nil)))
(chk-reject "committed graph-version arithmetic contradiction"
            #(a/seal-phase-receipt!
              (assoc-in completed-unsigned ["commit" "graphVersionAfter"] "13")))
(chk-reject "committed installed-count contradiction"
            #(a/seal-phase-receipt!
              (assoc-in completed-unsigned ["commit" "installed"] "1")))
(chk-reject "accepted prepare count contradiction"
            #(a/seal-phase-receipt! (assoc-in completed-unsigned ["prepare" "ops"] "3")))
(chk-reject "accepted prepare newNodes contradiction"
            #(a/seal-phase-receipt! (assoc-in completed-unsigned ["prepare" "newNodes"] "2")))
(chk-reject "commit base must match prepared base"
            #(a/seal-phase-receipt!
              (assoc-in completed-unsigned ["prepare" "baseGraphVersion"] "9")))
(chk-reject "rejected_stale requires a changed graph version"
            #(a/seal-phase-receipt!
              (assoc-in rejected-stale-unsigned ["commit" "observedGraphVersion"] "10")))
(chk-reject "failed_restored must restore graph version"
            #(a/seal-phase-receipt!
              (assoc-in restored-unsigned ["commit" "graphVersionAfter"] "11")))
(chk-reject "indeterminate commit records prepared base"
            #(a/seal-phase-receipt!
              (assoc-in canonical-indeterminate-unsigned ["commit" "graphVersionBefore"] "9")))
(chk-reject "published projection hashes must match"
            #(a/seal-phase-receipt!
              (assoc-in completed-unsigned ["projection" "actualSha256"]
                        (a/sha256-text "other"))))
(chk-reject "projection must cite committed server receipt"
            #(a/seal-phase-receipt!
              (assoc-in completed-unsigned ["projection" "coordinatorReceiptDigest"]
                        (a/sha256-text "other"))))
(chk-reject "receipt counters cannot be JSON numbers"
            #(a/seal-phase-receipt! (assoc-in completed-unsigned ["prepare" "ops"] 2)))
(chk-reject "receipt rejects tampered digest"
            #(a/validate-phase-receipt! (assoc completed "receiptDigest" digest-x)))

(let [results @checks
      failures (filterv (fn [[_ ok]] (not ok)) results)]
  (doseq [[name ok] results]
    (println (if ok "  [PASS] " "  [FAIL] ") name))
  (if (empty? failures)
    (println "\nfram.authority primitives:" (count results) "/" (count results) "PASS")
    (do
      (println "\nfram.authority primitives:" (count failures) "FAILED of" (count results))
      (System/exit 1))))
