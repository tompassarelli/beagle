;; A branch may live past the former 64-segment ceiling. Crossing the threshold
;; automatically reseals physical storage while v2 keeps logical revision
;; identity stable.
;; Run from the repository root: bb -cp out tests/branch_reseal_test.clj
(require '[fram.branch :as branch]
         '[fram.store :as store]
         '[fram.types :as t])

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

(defn read-all ^bytes [path]
  (java.nio.file.Files/readAllBytes (.toPath (java.io.File. (str path)))))

(defn write-all! [path ^bytes content]
  (java.nio.file.Files/write
   (.toPath (java.io.File. (str path))) content
   (into-array java.nio.file.OpenOption
               [java.nio.file.StandardOpenOption/CREATE
                java.nio.file.StandardOpenOption/WRITE
                java.nio.file.StandardOpenOption/TRUNCATE_EXISTING])))

(defn move-replace! [source target]
  (java.nio.file.Files/move
   (.toPath (java.io.File. (str source)))
   (.toPath (java.io.File. (str target)))
   (into-array java.nio.file.CopyOption
               [java.nio.file.StandardCopyOption/REPLACE_EXISTING])))

(def scratch
  (.toFile
   (java.nio.file.Files/createTempDirectory
    "fram-branch-reseal-"
    (make-array java.nio.file.attribute.FileAttribute 0))))
(def log (.getPath (java.io.File. scratch "long-lived.framlog")))
(def space "branch-reseal-space")

(database/create-triple-log! log space)
(database/assert! (database/open-database! log space)
                  (t/triple "history" :step 0) {})

(def boundary (atom nil))
(def current
  (loop [index 1 parent branch/default-branch]
    (if (> index 70)
      parent
      (let [child (format "branch-%02d" index)
            before-ref (database/read-branch-ref log parent)
            before-revision
            (when (= index 65) (database/branch-revision! log parent))
            receipt (database/fork-store! log parent child)
            after-revision
            (when (= index 65) (database/branch-revision! log child))]
        (when (= index 65)
          (reset! boundary
                  {:before-segments
                   (count (branch/refdocument-segments before-ref))
                   :after-segments (count (:chain receipt))
                   :before-revision before-revision
                   :after-revision after-revision}))
        (database/assert! (database/open-branch! log child space)
                          (t/triple "history" :step index) {})
        (recur (inc index) child)))))

(println "branch reseal:")
(check! "the fixture reaches the 64-segment reseal threshold"
        (= branch/reseal-chain-length (:before-segments @boundary)))
(check! "the next fork compacts instead of rejecting the long-lived branch"
        (= 2 (:after-segments @boundary)))
(check! "v2 revision identity survives physical reseal and fork"
        (= (:before-revision @boundary) (:after-revision @boundary)))

(def final-ref (database/read-branch-ref log current))
(def final-db (database/open-branch! log current space))
(def live (set (database/live-propositions final-db)))
(check! "the branch continues beyond 64 physical segment generations"
        (and (= 70 (Long/parseLong (subs current 7)))
             (< (count (branch/refdocument-segments final-ref))
                branch/reseal-chain-length)))
(check! "cold open after reseal retains every committed proposition"
        (= (set (map #(t/triple "history" :step %) (range 71))) live))
(check! "the final v2 revision is stable across a repeated cold read"
        (= (database/branch-revision! log current)
           (database/branch-revision! log current)))

(defn interrupted-reseal! [name phase]
  (let [path (.getPath (java.io.File. scratch name))
        root-fact (t/triple name :step 0)
        tail-fact (t/triple name :step 1)]
    (database/create-triple-log! path space)
    (database/assert! (database/open-database! path space) root-fact {})
    (database/fork-store! path "seed")
    (database/assert!
     (database/open-branch! path branch/default-branch space) tail-fact {})
    ;; Materialize the old watch anchor so recovery can prove one exact
    ;; post-durable transition from the pre-reseal ref.
    (database/branch-transitions-since! path branch/default-branch 0)
    (let [tail path
          ref (branch/ref-path! path branch/default-branch)
          watch (str path ".watches/" branch/default-branch)
          old-tail (read-all tail)
          old-ref (read-all ref)
          old-watch (read-all watch)
          revision (database/branch-revision! path)
          receipt (database/reseal-branch! path)
          marker
          (branch/->ResealMarker
           branch/default-branch (:segment receipt) (:ref-identity receipt))]
      (case phase
        :prepared
        (do
          (move-replace! tail (str tail ".reseal-new"))
          (move-replace! ref (str ref ".reseal-new"))
          (write-all! tail old-tail)
          (write-all! ref old-ref))

        :tail-installed
        (do
          (move-replace! ref (str ref ".reseal-new"))
          (write-all! ref old-ref))

        :ref-installed nil)
      (write-all! watch old-watch)
      (write-all! (str path ".reseal")
                  (.getBytes (branch/print-reseal-marker marker)
                             java.nio.charset.StandardCharsets/UTF_8))
      {:path path :tail tail :ref ref :watch watch
       :revision revision :root-fact root-fact :tail-fact tail-fact
       :receipt receipt :marker marker
       :old-tail old-tail :old-ref old-ref})))

(def recovered
  (mapv (fn [phase]
          (let [fixture (interrupted-reseal!
                         (str "recover-" (name phase) ".framlog") phase)
                blocked
                (error-code
                 #(database/open-branch!
                   (:path fixture) branch/default-branch space))
                receipt (database/reseal-branch! (:path fixture))
                opened
                (database/open-branch!
                 (:path fixture) branch/default-branch space)
                events
                (:transitions
                 (database/branch-transitions-since!
                  (:path fixture) branch/default-branch 0))]
            (assoc fixture :phase phase :blocked blocked
                   :recovery-receipt receipt :opened opened :events events)))
        [:prepared :tail-installed :ref-installed]))

(check! "every durable reseal interruption is fenced before recovery"
        (every? #(= :reseal-incomplete (:blocked %)) recovered))
(check! "recovery resumes prepared, tail-installed, and ref-installed phases"
        (every? #(true? (:recovered? (:recovery-receipt %))) recovered))
(check! "every recovered phase preserves revision identity and committed facts"
        (every?
         (fn [fixture]
           (and (= (:revision fixture)
                   (database/branch-revision! (:path fixture)))
                (= #{(:root-fact fixture) (:tail-fact fixture)}
                   (set (database/live-propositions (:opened fixture))))))
         recovered))
(check! "reseal recovery publishes one transition only after the ref is durable"
        (every? #(= 1 (count (:events %))) recovered))
(check! "recovered reseals leave no marker or pending routing file"
        (every?
         (fn [fixture]
           (not-any? #(.exists (java.io.File. (str %)))
                     [(str (:path fixture) ".reseal")
                      (str (:tail fixture) ".reseal-new")
                      (str (:ref fixture) ".reseal-new")]))
         recovered))

(def corrupt-marker
  (interrupted-reseal! "corrupt-marker.framlog" :prepared))
(write-all!
 (str (:path corrupt-marker) ".reseal")
 (.getBytes
  (clojure.string/replace
   (branch/print-reseal-marker (:marker corrupt-marker))
   "branch main" "branch other")
  java.nio.charset.StandardCharsets/UTF_8))
(check! "a corrupt reseal marker fails before replacing either live file"
        (and (= :invalid-reseal-marker
                (error-code #(database/reseal-branch! (:path corrupt-marker))))
             (java.util.Arrays/equals ^bytes (:old-tail corrupt-marker)
                                      ^bytes (read-all (:tail corrupt-marker)))
             (java.util.Arrays/equals ^bytes (:old-ref corrupt-marker)
                                      ^bytes (read-all (:ref corrupt-marker)))))

(def corrupt-segment
  (interrupted-reseal! "corrupt-segment.framlog" :prepared))
(let [segment-path
      (branch/segment-path
       (:path corrupt-segment) (:segment (:receipt corrupt-segment)))
      content (read-all segment-path)
      changed (java.util.Arrays/copyOf content (alength content))
      offset (dec (alength changed))]
  (aset-byte changed offset
             (unchecked-byte (bit-xor 1 (bit-and 255 (aget changed offset)))))
  (write-all! segment-path changed))
(check! "a corrupt reseal segment fails before replacing either live file"
        (and (contains?
              #{:corrupt-triple-log :segment-digest-mismatch}
              (error-code #(database/reseal-branch! (:path corrupt-segment))))
             (java.util.Arrays/equals ^bytes (:old-tail corrupt-segment)
                                      ^bytes (read-all (:tail corrupt-segment)))
             (java.util.Arrays/equals ^bytes (:old-ref corrupt-segment)
                                      ^bytes (read-all (:ref corrupt-segment)))))

(let [failures (remove second @checks)]
  (if (empty? failures)
    (do
      (println "\nbranch reseal:" (count @checks) "/" (count @checks) "PASS")
      (shutdown-agents))
    (do
      (println "\nbranch reseal:" (count failures) "FAILED")
      (shutdown-agents)
      (System/exit 1))))
