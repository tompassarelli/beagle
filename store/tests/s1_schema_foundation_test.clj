;; s1_schema_foundation_test.clj — the S1 tranche of the store-migration ruling
;; (North thread 019fc88b): live rotations, minted Term identities, the atomic
;; single-cardinality update compiler, and store.claims over the ported schema.
;;   bb -cp out tests/s1_schema_foundation_test.clj
(require '[store.store :as c] '[store.types :as t] '[store.rotation :as rot]
         '[store.txn :as txn] '[store.schema :as s] '[store.claims :as claims])

(def checks (atom []))
(defn check! [label ok] (swap! checks conj [label (boolean ok)]))

;; ---------------------------------------------------------------- A. covering
(def corpus-ctx (c/new-term-store "s1-covering"))
(def subjects ["a" "b" "c"])
(def predicates ["p" "q"])
(def objects [1 2 3])
(def corpus
  (vec (for [x subjects, p predicates, o objects] (t/triple x p o))))

(doseq [batch (partition-all 5 corpus)]
  (c/commit-transaction! corpus-ctx (mapv c/assert-operation batch)))
;; retract a third of them so the projection has to answer over live rows only
(c/commit-transaction!
 corpus-ctx (mapv c/retract-operation (take-nth 3 corpus)))

(def covering (rot/project! corpus-ctx))
(defn- brute [s p o]
  (filterv (fn [event]
             (let [prop (rot/proposition-of event)]
               (and (or (nil? s) (= s (t/triple-t1 prop)))
                    (or (nil? p) (= p (t/triple-t2 prop)))
                    (or (nil? o) (= o (t/triple-t3 prop))))))
           (rot/all-occurrences covering)))

(check! "covering: all 8 bound subsets match a brute-force filter"
        (every? (fn [[s p o]] (= (brute s p o) (rot/matching covering s p o)))
                (for [s [nil "a"], p [nil "p"], o [nil 2]] [s p o])))
(check! "covering: an unbound query is the whole live occurrence vector"
        (= (rot/all-occurrences covering) (rot/matching covering nil nil nil)))
(check! "covering: retracted propositions leave the projection"
        (= (- (count corpus) (count (take-nth 3 corpus)))
           (rot/occurrence-count covering)))

;; ------------------------------------------------- B. incremental == fresh
(def delta-ctx (c/new-term-store "s1-delta"))
(def pinned-empty (rot/project! delta-ctx))
(doseq [batch (partition-all 4 corpus)]
  (c/commit-transaction! delta-ctx (mapv c/assert-operation batch)))
(c/commit-transaction! delta-ctx (mapv c/retract-operation (take-nth 4 corpus)))
(def incremental (rot/refresh! pinned-empty delta-ctx))
(def fresh (rot/project! delta-ctx))
(check! "delta-updated rotation answers VALUE-equal to a from-scratch build"
        (and (= (rot/all-occurrences incremental) (rot/all-occurrences fresh))
             (= (rot/occurrence-count incremental) (rot/occurrence-count fresh))
             (every? (fn [[s p o]] (= (rot/matching incremental s p o)
                                      (rot/matching fresh s p o)))
                     (for [s [nil "a"], p [nil "p"], o [nil 2]] [s p o]))))
(check! "a refreshed rotation is pinned to the store it projects"
        (and (rot/pinned? incremental delta-ctx)
             (not (rot/pinned? pinned-empty delta-ctx))))

;; ------------------------------------------------- C. duplicate occurrences
(def dup-ctx (c/new-term-store "s1-duplicates"))
(def dup (t/triple "x" "same" "value"))
(c/commit-transaction! dup-ctx [(c/assert-operation dup) (c/assert-operation dup)])
(def dup-view (rot/project! dup-ctx))
(c/commit-transaction! dup-ctx [(c/retract-operation dup)])
(def dup-after (rot/refresh! dup-view dup-ctx))
(check! "two equal propositions are two live occurrences"
        (= 2 (count (rot/by-proposition dup-view dup))))
(check! "one retraction withdraws the NEWEST occurrence only"
        (= [(first (rot/by-proposition dup-view dup))]
           (rot/by-proposition dup-after dup)))

;; ------------------------------------------------------------ D. discipline
(check! "a rotation from another space is refused, not silently reused"
        (= :rotation-space-mismatch
           (try (rot/refresh! (rot/project! dup-ctx) delta-ctx) nil
                (catch clojure.lang.ExceptionInfo e (:type (ex-data e))))))
(check! "a rotation ahead of its store is refused"
        (= :rotation-ahead-of-store
           (try (rot/refresh! (assoc (rot/project! dup-ctx) :version 99) dup-ctx) nil
                (catch clojure.lang.ExceptionInfo e (:type (ex-data e))))))

;; ----------------------------------------------------------------- E. minting
(def mint-ctx (c/new-term-store "s1-mint"))
(def builder (txn/open mint-ctx))
(def minted (vec (repeatedly 3 #(txn/mint! builder))))
(check! "mint ordinals are monotonic within one transaction"
        (= minted (mapv #(txn/mint-coordinate (txn/coordinate builder) %) (range 3))))
(check! "a minted identity is the (tx-coordinate :mint-ordinal n) Term"
        (and (every? txn/mint-coordinate? minted)
             (every? t/term? minted)
             (every? #(t/transaction-coordinate? (t/triple-t1 %)) minted)))
(txn/assert! builder (t/triple (first minted) "kind" "node"))
(txn/commit! mint-ctx builder)
(def next-builder (txn/open mint-ctx))
(check! "the next transaction cannot re-mint a committed coordinate"
        (not (contains? (set minted) (txn/mint! next-builder))))

;; -------------------------------------------------- F. the update compiler
(def upd-ctx (c/new-term-store "s1-update"))
(def repeated (t/triple "n" "single-pred" "old"))
(c/commit-transaction!
 upd-ctx [(c/assert-operation repeated)
          (c/assert-operation (t/triple "n" "single-pred" "other"))
          (c/assert-operation repeated)])
(def upd-view (rot/project! upd-ctx))
(def compiled (txn/compile-single-update upd-view "n" "single-pred" "new"))
(check! "one live occurrence -> one retraction, duplicates included"
        (= 4 (count compiled)))
(check! "retractions come newest first, the assertion last"
        (and (= [:retract :retract :retract :assert]
                (mapv :action compiled))
             (= ["old" "other" "old" "new"]
                (mapv #(t/triple-t3 (:proposition %)) compiled))))

(def upd-builder (txn/open upd-ctx))
(def write-identity (txn/update-single! upd-builder upd-view "n" "single-pred" "new"))
(def transactions-before (c/transaction-count upd-ctx))
(txn/commit! upd-ctx upd-builder)
(def upd-after (rot/refresh! upd-view upd-ctx))
(check! "the whole update lands as ONE transaction"
        (= 1 (- (c/transaction-count upd-ctx) transactions-before)))
(check! "exactly the new value is live afterwards"
        (= ["new"] (rot/values (rot/by-t12 upd-after "n" "single-pred"))))
(check! "the write identity is the new assertion occurrence"
        (and (rot/live-occurrence? upd-after write-identity)
             (= (t/triple "n" "single-pred" "new")
                (rot/proposition-of (rot/event-at upd-after write-identity)))))

(def same-builder (txn/open upd-ctx))
(def same-identity (txn/update-single! same-builder upd-after "n" "single-pred" "new"))
(txn/commit! upd-ctx same-builder)
(def upd-same (rot/refresh! upd-after upd-ctx))
(check! "an update to the SAME value still retracts and re-asserts"
        (and (= ["new"] (rot/values (rot/by-t12 upd-same "n" "single-pred")))
             (not (= same-identity write-identity))
             (not (rot/live-occurrence? upd-same write-identity))
             (rot/live-occurrence? upd-same same-identity)))

;; --------------------------------------------------------------- G. OCC guard
(def stale (txn/open upd-ctx))
(txn/assert! stale (t/triple "n" "single-pred" "stale"))
(def interloper (txn/open upd-ctx))
(txn/assert! interloper (t/triple "n" "other-pred" "landed"))
(txn/commit! upd-ctx interloper)
(def operations-at-drift (c/operation-count upd-ctx))
(check! "a transaction pinned to a superseded sequence refuses to commit"
        (= :transaction-sequence-drift
           (try (txn/commit! upd-ctx stale) nil
                (catch clojure.lang.ExceptionInfo e (:type (ex-data e))))))
(check! "the refused transaction wrote nothing"
        (= operations-at-drift (c/operation-count upd-ctx)))

;; -------------------------------------------------------------- H. store.claims
(def claim-ctx (c/new-term-store "s1-claims"))
(def sess (s/session! claim-ctx))
(s/setup! sess)
(s/def-predicate! sess "risk" "single" "literal")
(def subject (s/mint-node! sess "name" "@assessment"))
(def claim (s/assert! sess subject "risk" "high"))
(def note (s/mint-node! sess claims/source-pred "report.pdf"))
(s/assert! sess note claims/region-pred "p3")
(s/assert! sess note claims/fingerprint-pred "sha256:beef")
(s/link! sess claim claims/evidence-pred note)

(def verified-view (s/mint-node! sess "name" (claims/scoped-view claims/verified-view "alice")))
(def verify-occ (s/link! sess verified-view claims/select-pred claim))
(def co {:schema sess :writers {verify-occ "alice"}})

(check! "a claim's provenance is its evidence chain"
        (= [{:node note :source "report.pdf" :region "p3"
             :fingerprint "sha256:beef" :world nil}]
           (claims/provenance co claim)))
(check! "a selected claim is verified, and names its verifier"
        (and (= :verified (claims/status co claim))
             (= "alice" (claims/verifier co claim))))

(def rejected-view (s/mint-node! sess "name" (claims/scoped-view claims/rejected-view "bob")))
(s/assert! sess claim claims/reason-pred "fingerprint stale")
(def reject-occ (s/link! sess rejected-view claims/select-pred claim))
(def co2 {:schema sess :writers {verify-occ "alice" reject-occ "bob"}})
(check! "the newest verdict selection wins"
        (and (= :rejected (claims/status co2 claim))
             (= "fingerprint stale" (:reason (claims/rejection co2 claim)))
             (= "bob" (:by (claims/rejection co2 claim)))
             (nil? (claims/verifier co2 claim))))

(def unverified (s/assert! sess subject "risk" "low"))
(check! "superseding the claim's proposition supersedes the claim"
        (and (= :superseded (claims/status co2 claim))
             (nil? (claims/status co2 unverified))))
(s/link! sess unverified claims/evidence-pred note)
(check! "a cited but unselected claim is pending"
        (= :pending (claims/status co2 unverified)))
(check! "reverification degrades to an empty program without world records"
        (= [[] []] (claims/reverification-rules co2 "v1" "v2")))

;; --------------------------------------------------------------------- report
(let [rows @checks
      fails (remove second rows)]
  (doseq [[label ok] rows] (println (if ok "  [PASS] " "  [FAIL] ") label))
  (if (empty? fails)
    (println "\nS1 schema foundation:" (count rows) "/" (count rows) "PASS")
    (do (println "\nS1 schema foundation:" (count fails) "FAILED") (System/exit 1))))
