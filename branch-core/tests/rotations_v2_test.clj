;; FRI2-backed covering rotations preserve occurrence coordinates.
;;   env -u FRAM_TELEMETRY_LOG bb -cp out tests/rotations_v2_test.clj
(require '[fri :as fri]
         '[fram.store :as store]
         '[fram.types :as t])
(load-file "rotations.clj")

(def path "/tmp/fram-rotations-v2.fri2")
(def fingerprint (apply str (repeat 64 "c")))
(def cache-source (fri/source-binding "rotation-space" fingerprint 8192))
(def proposition (t/triple (t/triple :id "A" 1)
                           (t/triple :slot :material 2)
                           (t/triple "steel" :unit :text)))
(def context (store/new-term-store "rotation-space"))
(store/commit-transaction!
 context [(store/assert-operation proposition)
          (store/assert-operation proposition)])
(def dump-before-withdrawal (store/dump-term-store context))
(store/commit-transaction! context [(store/retract-operation proposition)])
(def dump-after-withdrawal (store/dump-term-store context))

(rotations/write-set! path dump-before-withdrawal cache-source)
(def opened-before (rotations/open-set! path cache-source))
(def index-before (:index opened-before))
(def events-before (:events index-before))
(def first-event (first events-before))
(def second-event (second events-before))
(def triple0 (t/triple-t1 proposition))
(def triple1 (t/triple-t2 proposition))
(def triple2 (t/triple-t3 proposition))

(rotations/close-set! opened-before)
(.delete (java.io.File. path))
(rotations/write-set! path dump-after-withdrawal cache-source)
(def opened-after (rotations/open-set! path cache-source))
(def index-after (:index opened-after))

(def subset-patterns
  [[nil nil nil]
   [triple0 nil nil] [nil triple1 nil] [nil nil triple2]
   [triple0 triple1 nil] [nil triple1 triple2] [triple0 nil triple2]
   [triple0 triple1 triple2]])

(def checks
  [["equal propositions retain two distinct occurrence coordinates"
    (and (= 2 (rotations/occurrence-count index-before))
         (= [proposition proposition]
            (rotations/matching-propositions index-before [nil nil nil]))
         (not= (t/operationoccurrence-coordinate first-event)
               (t/operationoccurrence-coordinate second-event)))]
   ["all eight bound-slot subsets use exact covering buckets"
    (every? #(= events-before (rotations/matching index-before %)) subset-patterns)]
   ["deleting one occurrence does not delete equal content at another coordinate"
    (let [reduced (rotations/del index-before second-event)]
      (and (= [first-event] (:events reduced))
           (= [proposition]
              (rotations/matching-propositions reduced
                                                [triple0 triple1 triple2]))))]
   ["FRI rebuild after deletion derives the later live occurrence set"
    (and (= 1 (rotations/occurrence-count index-after))
         (= [proposition]
            (rotations/matching-propositions index-after
                                              [triple0 triple1 triple2])))]
   ["rotation summary repeats the FRI source binding"
    (let [summary (rotations/set-summary opened-after)]
      (and (= "rotation-space" (:space-id summary))
           (= fingerprint (:source-fingerprint summary))
           (= 8192 (:source-position summary))
           (= 1 (:occurrences summary))))]] )

(rotations/close-set! opened-after)
(.delete (java.io.File. path))

(let [failures (remove second checks)]
  (doseq [[label ok] checks]
    (println (if ok "  [PASS]" "  [FAIL]") label))
  (if (empty? failures)
    (println "\nFRI2 rotations:" (count checks) "/" (count checks) "PASS")
    (do
      (println "\nFRI2 rotations:" (count failures) "FAILED")
      (System/exit 1))))
