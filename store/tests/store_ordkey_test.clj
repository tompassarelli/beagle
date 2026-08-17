;; ============================================================================
;; store_ordkey_test.clj — Stage A: the CRDT order-key library, unit-tested standalone
;;   bb store_ordkey_test.clj
;; A position = (path, tie): path = logoot int-vector (dense; a path strictly between
;; any two always exists), tie = the node's atomic name-int (unique -> concurrent
;; same-gap inserts get DISTINCT keys -> commute). Encoded in the child-edge predicate
;; "f<p0.p1...>~<tie>". Compare lexicographically on path, then tie.
;; Confirm correct HERE before wiring into resolve.clj.
;; ============================================================================
(require '[clojure.string :as str])

(def ORD-STEP 65536)
(defn ord-parse [p]
  (when-let [[_ ps ts] (re-matches #"f(\d+(?:\.\d+)*)~(\d+)" p)]
    {:path (mapv #(Long/parseLong %) (str/split ps #"\.")) :tie (Long/parseLong ts)}))
(defn ord-str [path tie] (str "f" (str/join "." path) "~" tie))
(defn veccmp [a b]
  (loop [a (seq a) b (seq b)]
    (cond (and (nil? a) (nil? b)) 0
          (nil? a) -1 (nil? b) 1
          :else (let [c (compare (long (first a)) (long (first b)))]
                  (if (zero? c) (recur (next a) (next b)) c)))))
(defn ord-cmp [x y]
  (let [c (veccmp (:path x) (:path y))] (if (zero? c) (compare (:tie x) (:tie y)) c)))
(defn ord-append [last-path]                       ; a path strictly AFTER last (same depth, +STEP)
  (if (empty? last-path) [ORD-STEP] (conj (vec (butlast last-path)) (+ (long (last last-path)) ORD-STEP))))
(defn ord-between [lo hi]                           ; a path strictly between lo and hi (nil = open end)
  (cond
    (and (nil? lo) (nil? hi)) [ORD-STEP]
    (nil? hi) (ord-append lo)
    :else (let [lo (or lo [0])]
            (loop [i 0 acc []]
              (let [a (long (get lo i 0)) b (long (get hi i (+ a (* 2 ORD-STEP))))]
                (if (> (- b a) 1) (conj acc (quot (+ a b) 2)) (recur (inc i) (conj acc a))))))))

;; ---- tests ----
(def fails (atom 0))
(defn chk [label ok] (println (if ok "  ok  " "  FAIL") label) (when-not ok (swap! fails inc)))
(defn lt? [pa ta pb tb] (neg? (ord-cmp {:path pa :tie ta} {:path pb :tie tb})))

(println "=== Stage A — CRDT order-key library ===")
;; round-trip
(chk "parse/str round-trip" (= {:path [98304] :tie 7} (ord-parse (ord-str [98304] 7))))
(chk "parse multi-seg" (= {:path [5 65536] :tie 12} (ord-parse "f5.65536~12")))
;; ingest spacing sorts numerically (f10 after f2 — the old lexicographic trap is gone)
(let [paths (mapv #(vector (* (inc %) ORD-STEP)) (range 12))]
  (chk "ingest paths strictly increasing" (apply < (map first paths)))
  (chk "12th sorts after 2nd (no f10<f2 trap)" (lt? (paths 2) 0 (paths 11) 0)))
;; append is strictly after
(chk "append > last" (let [a (ord-append [(* 5 ORD-STEP)])] (lt? [(* 5 ORD-STEP)] 0 a 0)))
;; middle-insert: between two spaced siblings
(let [m (ord-between [ORD-STEP] [(* 2 ORD-STEP)])]
  (chk "between spaced: lo<mid<hi" (and (lt? [ORD-STEP] 0 m 0) (lt? m 0 [(* 2 ORD-STEP)] 0))))
;; adjacent middle-insert: descends, still strictly between
(let [m (ord-between [5] [6])]
  (chk "between adjacent [5][6]: lo<mid<hi" (and (lt? [5] 0 m 0) (lt? m 0 [6] 0))))
;; CONCURRENT same-gap: same path, distinct ties -> distinct, both between, sorted by tie
(let [m (ord-between [ORD-STEP] [(* 2 ORD-STEP)])]
  (chk "same-gap concurrent: distinct by tie"     (not= (ord-cmp {:path m :tie 100} {:path m :tie 200}) 0))
  (chk "same-gap concurrent: A<B by tie"          (lt? m 100 m 200))
  (chk "same-gap concurrent: both > lo"           (and (lt? [ORD-STEP] 0 m 100) (lt? [ORD-STEP] 0 m 200)))
  (chk "same-gap concurrent: both < hi"           (and (lt? m 100 [(* 2 ORD-STEP)] 0) (lt? m 200 [(* 2 ORD-STEP)] 0))))
;; dense: 60 successive inserts into one shrinking gap always find a strictly-between path
(let [ok (loop [lo [ORD-STEP] hi [(* 2 ORD-STEP)] n 0]
           (if (= n 60) true
             (let [m (ord-between lo hi)]
               (if (and (lt? lo 0 m 0) (lt? m 0 hi 0)) (recur lo m (inc n)) false))))]
  (chk "dense: 60 nested inserts all strictly-between" ok))

(println (if (zero? @fails) "\n=== Stage A PASS — order-key library correct ===" (str "\n=== Stage A FAIL: " @fails " ===")))
