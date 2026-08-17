;; A branch ref is boot-critical mutable state: it must round-trip exactly and
;; refuse every shape it cannot vouch for, rather than fold a guessed chain.
;; Run from the repository root: bb -cp out tests/framref_codec_test.clj
(require '[fram.branch :as branch])

(load-file "database.clj")

(def checks (atom []))
(defn check! [label ok]
  (println (str (if ok "  [PASS] " "  [FAIL] ") label))
  (swap! checks conj [label ok]))

(defn error-code [f]
  (try
    (f)
    nil
    (catch clojure.lang.ExceptionInfo error
      (or (:fram/code (ex-data error)) (:type (ex-data error))))))

(def hash-a (apply str (repeat 64 "a")))
(def hash-b (apply str (repeat 64 "b")))
(def hash-c (apply str (repeat 64 "c")))

;; Hand-built ref and marker text needs the same CRC the codec writes, or every
;; refusal below would be the CRC's rather than the one under test.
(defn- sealed-text [body]
  (let [digest (java.util.zip.CRC32.)]
    (.update digest (.getBytes body java.nio.charset.StandardCharsets/UTF_8))
    (str body (format "crc %08x\n" (.getValue digest)))))

(def document
  (branch/->RefDocument
   "ref-codec-space"
   [(branch/->SegmentRecord hash-a 1 8 4096)
    (branch/->SegmentRecord hash-b 9 11 128)]))

(def text (branch/print-ref document))

(println "branch ref codec:")
(println (str "  printed:\n" text))

(check! "a printed ref parses back to the identical document"
        (= document (branch/parse-ref text)))
(check! "an empty chain round-trips"
        (let [empty-doc (branch/empty-ref "ref-codec-space")]
          (= empty-doc (branch/parse-ref (branch/print-ref empty-doc)))))
(check! "the printed ref names its format, space, segments, and CRC"
        (= ["framref/v1"
            "space ref-codec-space"
            (str "segment " hash-a " 1 8 4096")
            (str "segment " hash-b " 9 11 128")]
           (vec (butlast (clojure.string/split-lines text)))))
(check! "the chain's end sequence is its last segment's recorded end"
        (= [11 0]
           [(branch/chain-end-sequence document)
            (branch/chain-end-sequence (branch/empty-ref "ref-codec-space"))]))
(check! "an empty terminal segment does not erase the chain's last transaction"
        (= 11
           (branch/chain-end-sequence
            (branch/->RefDocument
             "ref-codec-space"
             (conj (branch/refdocument-segments document)
                   (branch/->SegmentRecord hash-c 0 0 32))))))

(def revision
  (branch/branch-revision!
   "ref-codec-space" hash-c 14))

(check! "a branch revision is exactly repeatable"
        (= revision
           (branch/branch-revision!
            "ref-codec-space" hash-c 14)))
(check! "the canonical branch revision has its stable v2 digest"
        (= "sha256:34c985a63c3baffac8de78e908933381f5ef53c10d53f4ea0ae0de3b83fd6881"
           (branch/branchrevision-identity revision)))
(check! "committed history bytes are part of branch revision identity"
        (not= (branch/branchrevision-identity revision)
              (branch/branchrevision-identity
               (branch/branch-revision!
                "ref-codec-space" hash-a 14))))
(check! "history and sequence are independent revision inputs"
        (= 3
           (count
            (set
             (mapv branch/branchrevision-identity
                   [revision
                    (branch/branch-revision!
                     "ref-codec-space" hash-a 14)
                    (branch/branch-revision!
                     "ref-codec-space" hash-c 15)])))))
(check! "a malformed history identity is refused"
        (= :invalid-branch-revision
           (error-code
            #(branch/branch-revision!
              "ref-codec-space" (subs hash-c 1) 14))))

(check! "an unknown ref format is refused by name"
        (= :unsupported-branch-ref-version
           (error-code
            #(branch/parse-ref
              (clojure.string/replace text "framref/v1" "framref/v2")))))
(check! "a duplicate segment line is refused"
        (= :invalid-branch-ref
           (error-code
            #(branch/parse-ref
              (branch/print-ref
               (branch/->RefDocument
                "ref-codec-space"
                [(branch/->SegmentRecord hash-a 1 8 4096)
                 (branch/->SegmentRecord hash-a 12 14 128)]))))))
;; The four-field segment line is the shape this ref format had before it
;; recorded an end sequence; a ref that still carries it must be refused rather
;; than read as a shorter chain.
(check! "a ref in the four-field segment shape is refused, not misread"
        (= :invalid-branch-ref
           (error-code
            #(branch/parse-ref
              (sealed-text (str "framref/v1\nspace ref-codec-space\n"
                                "segment " hash-a " 1 4096\n"))))))
(check! "a segment that ends before it begins is refused"
        (= :invalid-branch-ref
           (error-code
            #(branch/parse-ref
              (branch/print-ref
               (branch/->RefDocument
                "ref-codec-space"
                [(branch/->SegmentRecord hash-a 8 1 4096)]))))))
(check! "a malformed segment name is refused"
        (= :invalid-branch-ref
           (error-code
            #(branch/parse-ref
              (clojure.string/replace text hash-a (str "z" (subs hash-a 1)))))))
(check! "a truncated segment name is refused"
        (= :invalid-branch-ref
           (error-code
            #(branch/parse-ref
              (clojure.string/replace text hash-a (subs hash-a 1))))))
(check! "a non-decimal byte count is refused"
        (= :invalid-branch-ref
           (error-code
            #(branch/parse-ref
              (sealed-text
               (clojure.string/replace
                (clojure.string/join
                 "\n" (conj (vec (butlast (clojure.string/split-lines text)))
                            ""))
                "8 4096" "8 4096x"))))))
(check! "an edited ref whose CRC no longer matches is refused"
        (= :invalid-branch-ref
           (error-code
            #(branch/parse-ref
              (clojure.string/replace text "11 128" "11 129")))))
(check! "a missing CRC line is refused"
        (= :invalid-branch-ref
           (error-code
            #(branch/parse-ref
              (clojure.string/join
               "\n" (conj (vec (butlast (clojure.string/split-lines text)))
                          ""))))))
(check! "an unknown line is refused"
        (= :invalid-branch-ref
           (error-code
            #(branch/parse-ref
              (clojure.string/replace text "space ref-codec-space"
                                      "space ref-codec-space\nworld w1")))))
(check! "an empty SpaceId is refused"
        (= :invalid-branch-ref
           (error-code
            #(branch/parse-ref (branch/print-ref (branch/empty-ref ""))))))

;; A ref and the segments it names must agree about their space before any
;; fold begins; the chain is otherwise two stores' bytes in one order.
(defn- member [start end bytes continuation space torn]
  (branch/->ChainMember start end bytes continuation space torn))

(check! "a sound chain reports no fault"
        (nil? (database/branch-chain-fault
               document
               [(member 1 8 4096 false "ref-codec-space" false)
                (member 9 11 128 true "ref-codec-space" false)]
               (member 12 14 96 true "ref-codec-space" false))))
(check! "a segment from another SpaceId is refused"
        (= "FRAMLOG segment belongs to a different SpaceId"
           (database/branch-chain-fault
            document
            [(member 1 8 4096 false "other-space" false)
             (member 9 11 128 true "ref-codec-space" false)]
            (member 12 14 96 true "ref-codec-space" false))))
(check! "a tail from another SpaceId is refused"
        (= "FRAMLOG tail belongs to a different SpaceId"
           (database/branch-chain-fault
            document
            [(member 1 8 4096 false "ref-codec-space" false)
             (member 9 11 128 true "ref-codec-space" false)]
            (member 12 14 96 true "other-space" false))))
(check! "a segment whose end sequence differs from its record is refused"
        (= "FRAMLOG segment does not end at its recorded transaction sequence"
           (database/branch-chain-fault
            document
            [(member 1 7 4096 false "ref-codec-space" false)
             (member 9 11 128 true "ref-codec-space" false)]
            (member 12 14 96 true "ref-codec-space" false))))
(check! "a segment whose size differs from its record is refused"
        (= "FRAMLOG segment size does not match its branch ref record"
           (database/branch-chain-fault
            document
            [(member 1 8 4095 false "ref-codec-space" false)
             (member 9 11 128 true "ref-codec-space" false)]
            (member 12 14 96 true "ref-codec-space" false))))
(check! "a chain the ref does not name is refused"
        (= "FRAMLOG branch ref does not name the segments that were read"
           (database/branch-chain-fault
            document
            [(member 1 8 4096 false "ref-codec-space" false)]
            (member 12 14 96 true "ref-codec-space" false))))
(check! "a segment that does not continue the previous one is refused"
        (= "FRAMLOG chain segment does not continue the previous transaction sequence"
           (database/branch-chain-fault
            (branch/->RefDocument
             "ref-codec-space"
             [(branch/->SegmentRecord hash-a 1 8 4096)
              (branch/->SegmentRecord hash-b 12 14 128)])
            [(member 1 8 4096 false "ref-codec-space" false)
             (member 12 14 128 true "ref-codec-space" false)]
            (member 15 15 96 true "ref-codec-space" false))))
(check! "a tail that does not continue the sealed chain is refused"
        (= "FRAMLOG branch tail does not continue the sealed chain"
           (database/branch-chain-fault
            document
            [(member 1 8 4096 false "ref-codec-space" false)
             (member 9 11 128 true "ref-codec-space" false)]
            (member 40 41 96 true "ref-codec-space" false))))
(check! "a torn sealed segment is refused"
        (= "FRAMLOG segment ends inside a transaction frame"
           (database/branch-chain-fault
            document
            [(member 1 8 4096 false "ref-codec-space" true)
             (member 9 11 128 true "ref-codec-space" false)]
            (member 12 14 96 true "ref-codec-space" false))))
(check! "a chained segment without the continuation flag is refused"
        (= "FRAMLOG chain segment after the base segment must carry the continuation flag"
           (database/branch-chain-fault
            document
            [(member 1 8 4096 false "ref-codec-space" false)
             (member 9 11 128 false "ref-codec-space" false)]
            (member 12 14 96 true "ref-codec-space" false))))
(check! "a base segment carrying the continuation flag is refused"
        (= "FRAMLOG base chain segment must not carry the continuation flag"
           (database/branch-chain-fault
            document
            [(member 1 8 4096 true "ref-codec-space" false)
             (member 9 11 128 true "ref-codec-space" false)]
            (member 12 14 96 true "ref-codec-space" false))))
(check! "a chained tail without the continuation flag is refused"
        (= "FRAMLOG branch tail must carry the continuation flag"
           (database/branch-chain-fault
            document
            [(member 1 8 4096 false "ref-codec-space" false)
             (member 9 11 128 true "ref-codec-space" false)]
            (member 12 14 96 false "ref-codec-space" false))))

(check! "a fork plan appends the sealed segment to the parent chain"
        (= [hash-a hash-b]
           (mapv branch/segmentrecord-sha256
                 (branch/refdocument-segments
                  (branch/forkplan-document
                   (branch/fork-plan
                    (branch/->RefDocument
                     "ref-codec-space"
                     [(branch/->SegmentRecord hash-a 1 8 4096)])
                    (branch/->SegmentRecord hash-b 9 11 128)
                    11))))))
(check! "a fork plan refuses a segment the parent chain already names"
        (= :segment-already-sealed
           (error-code
            #(branch/fork-plan
              document (branch/->SegmentRecord hash-b 20 22 64) 19))))

;; A fork marker is read only after a crash, so it must name the exact fork it
;; belongs to or be refused; a guessed parent renames the wrong log.
(def marker (branch/->ForkMarker "default" "lane" hash-a))
(def marker-text (branch/print-fork-marker marker))

(check! "a printed fork marker parses back to the identical marker"
        (= marker (branch/parse-fork-marker marker-text)))
(check! "the printed marker names its format, parent, child, segment, and CRC"
        (= ["framfork/v1" "parent default" "child lane" (str "segment " hash-a)]
           (vec (butlast (clojure.string/split-lines marker-text)))))
(check! "an unknown marker format is refused by name"
        (= :unsupported-fork-marker-version
           (error-code
            #(branch/parse-fork-marker
              (clojure.string/replace marker-text
                                      "framfork/v1" "framfork/v2")))))
(check! "an edited marker whose CRC no longer matches is refused"
        (= :invalid-fork-marker
           (error-code
            #(branch/parse-fork-marker
              (clojure.string/replace marker-text "child lane"
                                      "child other")))))
(check! "a marker naming one branch twice is refused"
        (= :invalid-fork-marker
           (error-code
            #(branch/parse-fork-marker
              (sealed-text
               (str "framfork/v1\nparent lane\nchild lane\nsegment "
                    hash-a "\n"))))))
(check! "a marker whose segment is not a digest is refused"
        (= :invalid-fork-marker
           (error-code
            #(branch/parse-fork-marker
              (sealed-text
               (str "framfork/v1\nparent default\nchild lane\nsegment "
                    (subs hash-a 1) "\n"))))))
(check! "a marker missing a field is refused"
        (= :invalid-fork-marker
           (error-code
            #(branch/parse-fork-marker
              (sealed-text "framfork/v1\nparent default\nchild lane\n")))))

(def reseal-marker
  (branch/->ResealMarker "lane" hash-b
                         (str "sha256:" hash-c)))
(def reseal-marker-text (branch/print-reseal-marker reseal-marker))

(check! "a printed reseal marker parses back to the identical marker"
        (= reseal-marker
           (branch/parse-reseal-marker reseal-marker-text)))
(check! "the reseal marker binds its branch, segment, ref, and CRC"
        (= ["framreseal/v1" "branch lane" (str "segment " hash-b)
            (str "ref sha256:" hash-c)]
           (vec (butlast (clojure.string/split-lines reseal-marker-text)))))
(check! "an edited reseal marker whose CRC no longer matches is refused"
        (= :invalid-reseal-marker
           (error-code
            #(branch/parse-reseal-marker
              (clojure.string/replace reseal-marker-text
                                      "branch lane" "branch other")))))
(check! "a reseal marker without a valid candidate ref is refused"
        (= :invalid-reseal-marker
           (error-code
            #(branch/parse-reseal-marker
              (sealed-text
               (str "framreseal/v1\nbranch lane\nsegment " hash-b
                    "\nref sha256:" (subs hash-c 1) "\n"))))))
(check! "a reseal marker missing a field is refused"
        (= :invalid-reseal-marker
           (error-code
            #(branch/parse-reseal-marker
              (sealed-text
               (str "framreseal/v1\nbranch lane\nsegment " hash-b
                    "\n"))))))

(check! "branch names that cannot address a ref file are refused"
        (= [false false false false false true true]
           (mapv branch/valid-branch-name?
                 ["" "a/b" ".." "a..b" "-lead" "default" "lane-2.a"])))
(check! "layout puts segments, refs, and branch tails beside the store"
        (= ["/s/log.segments" "/s/log.refs" "/s/log.branches"
            (str "/s/log.segments/" hash-a)
            "/s/log.refs/child" "/s/log.branches/child" "/s/log"
            "/s/log.snapshot"]
           [(branch/segments-directory "/s/log")
            (branch/refs-directory "/s/log")
            (branch/branches-directory "/s/log")
            (branch/segment-path "/s/log" hash-a)
            (branch/ref-path! "/s/log" "child")
            (branch/branch-tail-path! "/s/log" "child")
            (branch/branch-tail-path! "/s/log" branch/default-branch)
            (branch/snapshot-path "/s/log")]))

(let [failures (remove second @checks)]
  (if (empty? failures)
    (do
      (println "\nbranch ref codec:" (count @checks) "/" (count @checks) "PASS")
      (shutdown-agents))
    (do
      (println "\nbranch ref codec:" (count failures) "FAILED")
      (shutdown-agents)
      (System/exit 1))))
