(require '[fram.program-inspection :as inspection])

(def checks (atom []))
(defn check! [label value]
  (println (str (if value "  [PASS] " "  [FAIL] ") label))
  (swap! checks conj [label (boolean value)]))

(def corpus "tests/fixtures/program-inspection/corpus.facts")
(def expected-version
  "sha256:f1c19550140c9f1aff497ba369fc7a1bfaa28592369c8a1a965c3a7cc082e490")
(def snapshot (inspection/read-snapshot! corpus))

(def read-target
  (inspection/execute-named
   snapshot "read_definition" {:semanticIdentity "src/a.bclj#20"}))
(check! "read_definition returns the exact pinned identity, anchor, and version"
        (= {:outcome "ok"
            :logicalVersion expected-version
            :semanticIdentity "src/a.bclj#20"
            :sourceAnchors [{:file "src/a.bclj" :nodeId 20
                             :kind "definition"}]
            :direction "self"
            :depth 0
            :definition {:identity "src/a.bclj#20" :name "target"
                         :module "a"
                         :root-facts [[20 "form-kind" "defn"]
                                      [20 "name" "target"]
                                      [20 "body" 21]
                                      [20 "child" 21]]}}
           (select-keys read-target
                        [:outcome :logicalVersion :semanticIdentity
                         :sourceAnchors :direction :depth :definition])))
(check! "read_definition resolves a natural name plus file to the exact identity"
        (= "src/a.bclj#20"
           (:semanticIdentity
            (inspection/execute-named
             snapshot "read_definition" {:name "target" :file "src/a.bclj"}))))

(def middle-references
  (inspection/execute-named
   snapshot "find_references"
   {:semanticIdentity "src/a.bclj#10" :direction "both"}))
(check! "find_references returns exact inbound/outbound identities and call anchors"
        (= [{:semanticIdentity "src/a.bclj#1"
             :referenceOf "src/a.bclj#10"
             :ownerIdentity "src/a.bclj#1"
             :relation "calls"
             :sourceAnchors [{:file "src/a.bclj" :nodeId 3
                              :kind "reference"}]
             :direction "inbound" :depth 1}
            {:semanticIdentity "src/a.bclj#20"
             :referenceOf "src/a.bclj#10"
             :ownerIdentity "src/a.bclj#10"
             :relation "calls"
             :sourceAnchors [{:file "src/a.bclj" :nodeId 12
                              :kind "reference"}]
             :direction "outbound" :depth 1}]
           (:references middle-references)))

(def impact
  (inspection/execute-named
   snapshot "trace_impact"
   {:semanticIdentity "src/a.bclj#20" :direction "inbound" :maxDepth 8}))
(check! "trace_impact returns deterministic inbound depth"
        (= [{:semanticIdentity "src/a.bclj#10"
             :sourceAnchors [{:file "src/a.bclj" :nodeId 10
                              :kind "definition"}]
             :direction "inbound" :depth 1}
            {:semanticIdentity "src/a.bclj#1"
             :sourceAnchors [{:file "src/a.bclj" :nodeId 1
                              :kind "definition"}]
             :direction "inbound" :depth 2}]
           (:impacts impact)))

(def history
  (inspection/execute-named
   snapshot "occurrence_history" {:semanticIdentity "src/a.bclj#20"}))
(check! "occurrence_history is source-ordered and snapshot-versioned"
        (and (= expected-version (:logicalVersion history))
             (= "snapshot-source-order" (:occurrenceScope history))
             (= [{:kind "reference" :semanticIdentity "src/a.bclj#20"
                  :ownerIdentity "src/a.bclj#10"
                  :sourceAnchor {:file "src/a.bclj" :nodeId 12
                                 :kind "reference"}
                  :direction "inbound" :depth 1}
                 {:kind "definition" :semanticIdentity "src/a.bclj#20"
                  :ownerIdentity "src/a.bclj#20"
                  :sourceAnchor {:file "src/a.bclj" :nodeId 20
                                 :kind "definition"}
                  :direction "self" :depth 0}]
                (:occurrences history))))

(def other-target
  (inspection/execute-named
   snapshot "find_references"
   {:semanticIdentity "src/b.bclj#10" :direction "inbound"}))
(check! "same-named definitions retain separate semantic identities"
        (= ["src/b.bclj#1"]
           (mapv :semanticIdentity (:references other-target))))

(def context
  (inspection/execute-named
   snapshot "program_context" {:semanticIdentity "src/a.bclj#20"}))
(check! "program_context carries the definition, direct relationships, and anchored impact summary"
        (and (= "src/a.bclj#20" (:semanticIdentity context))
             (= {:name "target" :module "a"}
                (get-in context [:definition :signature]))
             (= [[20 "form-kind" "defn"] [20 "name" "target"]
                 [20 "body" 21] [20 "child" 21]]
                (get-in context [:definition :bodySlice]))
             (= [{:semanticIdentity "src/a.bclj#10"
                  :relation "calls"
                  :sourceAnchors [{:file "src/a.bclj" :nodeId 12
                                   :kind "reference"}]
                  :depth 1}]
                (get-in context [:relationships :callers :neighbors]))
             (= [{:semanticIdentity "src/a.bclj#1"
                  :sourceAnchors [{:file "src/a.bclj" :nodeId 1
                                   :kind "definition"}]
                  :depth 2}]
                (rest (get-in context [:impactSummary :inbound
                                       :affectedIdentities])))))

(def hub-corpus
  (str "@file src/hub.bclj\n"
       (apply str
              (for [i (range 1 18)
                    :let [node (* i 10) call (inc node)]]
                (str "[" node " \"form-kind\" \"defn\"]\n"
                     "[" node " \"name\" \"caller" i "\"]\n"
                     "[" call " \"form-kind\" \"call\"]\n"
                     "[" call " \"calls\" \"hub\"]\n"
                     "[" node " \"child\" " call "]\n")))
       "[1000 \"form-kind\" \"defn\"]\n"
       "[1000 \"name\" \"hub\"]\n"))
(def hub-file (doto (java.io.File/createTempFile "program-context-hub" ".facts") .deleteOnExit))
(spit hub-file hub-corpus)
(def hub-snapshot (inspection/read-snapshot! hub-file))
(def hub-context
  (inspection/execute-named hub-snapshot "program_context"
                             {:semanticIdentity "src/hub.bclj#1000"
                              :tokenBudget 512}))
(def hub-full-context
  (inspection/execute-named hub-snapshot "program_context"
                             {:semanticIdentity "src/hub.bclj#1000"
                              :tokenBudget 8192}))
(check! "program_context deterministically truncates a token-bound hub with narrowing advice"
        (and (:truncated hub-context)
             (string? (:narrowingAdvice hub-context))
             (<= (count (pr-str hub-context)) (* 4 (:tokenBudget hub-context)))
             (= hub-context
                (inspection/execute-named hub-snapshot "program_context"
                                           {:semanticIdentity "src/hub.bclj#1000"
                                            :tokenBudget 512}))))
(check! "program_context curtails high-degree callers at the deterministic K"
        (let [callers (get-in hub-full-context [:relationships :callers])]
          (and (= 17 (:degree callers))
               (:suppressed callers)
               (= 8 (count (:neighbors callers)))
               (= {:semanticIdentity "src/hub.bclj#10"
                   :relation "calls"
                   :sourceAnchors [{:file "src/hub.bclj" :nodeId 11
                                    :kind "reference"}]
                   :depth 1}
                  (first (:neighbors callers))))))

(def batch
  (inspection/inspect-program
   snapshot
   {:requests
    [{:tag "definition" :request "read_definition"
      :arguments {:semanticIdentity "src/a.bclj#20"}}
     {:tag "references" :request "find_references"
      :arguments {:semanticIdentity "src/a.bclj#10" :direction "both"}}
     {:tag "impact" :request "trace_impact"
      :arguments {:semanticIdentity "src/a.bclj#20" :direction "inbound"}}
     {:tag "history" :request "occurrence_history"
      :arguments {:semanticIdentity "src/a.bclj#20"}}
     {:tag "context" :request "program_context"
      :arguments {:semanticIdentity "src/a.bclj#20"}}
     {:tag "missing" :request "read_definition"
      :arguments {:semanticIdentity "src/a.bclj#999"}}
     {:tag "invalid" :request "trace_impact"
      :arguments {:semanticIdentity "src/a.bclj#20" :direction "sideways"}}]}))
(check! "inspect_program preserves order, tags, and individual outcomes"
        (= [["definition" "read_definition" "ok"]
            ["references" "find_references" "ok"]
            ["impact" "trace_impact" "ok"]
            ["history" "occurrence_history" "ok"]
            ["context" "program_context" "ok"]
            ["missing" "read_definition" "not-found"]
            ["invalid" "trace_impact" "error"]]
           (mapv (juxt :tag :request :outcome) (:children batch))))
(check! "inspect_program pins every child to exactly one logical snapshot"
        (and (= expected-version (:logicalVersion batch))
             (= #{expected-version}
                (set (map :logicalVersion (:children batch))))))

(let [failures (remove second @checks)]
  (if (seq failures)
    (do (println "\nprogram inspection:" (count failures)
                 "FAILED of" (count @checks))
        (System/exit 1))
    (println "\nprogram inspection:" (count @checks) "/"
             (count @checks) "PASS")))
