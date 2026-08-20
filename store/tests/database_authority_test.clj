;; database_authority_test.clj — the two-boot adversarial matrix for the graph-edit
;; authority database kernel (thread 019f884c). Proves ONE MEANING PER IDENTITY:
;;
;;   * instanceId  — a non-restorable per-boot GENERATION nonce. Defeats the
;;                   ABA/restart counterexample where a crashed boot never released
;;                   its lease and replay restores its epoch cell byte-for-byte.
;;   * lease.epoch — succession WITHIN one boot; the append-time fence.
;;   * connection sequence — exact monotonic, in-order, exactly-once per connection.
;;
;; Every rejection must return BEFORE any canonical append — asserted by a SHA-256
;; digest of the whole durable log taken around each rejected request.
;;
;;   bb -cp out tests/database_authority_test.clj
;; Scratch /tmp logs only; never a live database.
(require '[store.authority :as a]
         '[store.tools :as tools]
         '[store.store :as c]
         '[store.schema :as s]
         '[clojure.java.io :as io])
(load-file "server.clj")

(def pass (atom 0)) (def fail (atom 0))
(defn check [nm ok]
  (if ok (do (swap! pass inc) (println "  [PASS]" nm))
         (do (swap! fail inc) (println "  [FAIL]" nm))))
(defn scratch-log [] (str "/tmp/store-authority-" (java.util.UUID/randomUUID) ".log"))

;; SHA-256 of the whole durable log — the exact head digest. Any append changes it.
(defn log-digest [db]
  (let [f (io/file (:log db))]
    (if (.exists f)
      (vec (.digest (java.security.MessageDigest/getInstance "SHA-256")
                    (java.nio.file.Files/readAllBytes (.toPath f))))
      [])))

;; the fenced canonical mutation an authority request carries: append one fact.
(defn commit-action [db holder value]
  (fn [] (commit! db holder "@authority-target" "note" :assert value (current-seq db))))

;; ---- a valid descriptor snapshot fixture (runtime/corpus/tools/lifecycle) ----
;; Reuses the accepted primitives-test shape; seal-database-descriptor adds the
;; database/instance/lease/version fields around it.
(def digest-x (a/sha256-text "x"))
(defn input-schema [params]
  {"type" "object"
   "properties" (reduce (fn [m p] (assoc m (:name p) {"type" (:type p) "description" (:name p)})) {} params)
   "required" (vec (keep (fn [p] (when (:required p) (:name p))) params))})
(def served-tools
  (->> (tools/catalog [])
       (filterv (fn [spec] (contains? (set a/expected-tool-order) (:name spec))))
       (mapv (fn [spec] {"name" (:name spec) "description" (:desc spec)
                         "inputSchema" (input-schema (:params spec))}))))
(def catalog {"catalogVersion" "store.graph-edit-tools/v1" "tools" served-tools})
(def entry-a {"moduleId" "src.store.authority" "sourcePath" "src/store/authority.bclj"})
(def manifest (a/normalize-module-manifest! "src" "10" [entry-a] []))
(def snapshot
  {"runtime" {"sealVersion" "store.runtime-seal/v1" "system" "x86_64-linux"
              "roots" ["/nix/store/runtime"] "closureDigest" digest-x}
   "corpus" {"checkoutRoot" "/checkout" "sourceRoot" "/checkout/src"
             "sourceRootRelativeToCheckout" (get manifest "sourceRootRelativeToCheckout")
             "codeLog" "/checkout/.store/code.log"
             "identity" {"checkoutFileKey" "dev:1:ino:2" "sourceFileKey" "dev:1:ino:3"
                         "logFileKey" "dev:1:ino:4"}
             "snapshot" {"graphVersion" (get manifest "graphVersion")
                         "logPrefixBytes" "100" "logPrefixSha256" digest-x
                         "moduleManifest" (select-keys manifest ["manifestVersion" "mappingDigest"
                                                                  "snapshotDigest" "entries"])}}
   "tools" {"catalogVersion" (get catalog "catalogVersion")
            "catalogDigest" (a/tool-catalog-digest! catalog)
            "tools" (get catalog "tools")}
   "lifecycle" {"durability" {"state" "clean"}
                "projection" {"state" "current" "generation" "1"}}})
(def endpoint {"transport" "mtls-tcp" "host" "127.0.0.1" "port" "41454" "serverSpkiSha256" digest-x})
(def spki-a (a/sha256-text "client-a-spki"))
(def spki-b (a/sha256-text "client-b-spki"))

(println "## authority server kernel — two-boot adversarial matrix")

;; ===========================================================================
;; GENERATION IDENTITY — changing instanceId alone changes binding + descriptor.
;; ===========================================================================
(let [db (new-database (scratch-log))
      ctx (authority-context db (fresh-instance-id))
      opened (authority-session-open ctx "R" "client-a" spki-a 60000)
      handle (:handle opened)
      desc-i1 (seal-coordinator-descriptor ctx handle endpoint snapshot)
      desc-i2 (seal-coordinator-descriptor (assoc ctx :instance (fresh-instance-id))
                                           handle endpoint snapshot)]
  (check "generation: sealed descriptor validates"
         (= desc-i1 (a/validate-authority-descriptor! desc-i1)))
  (check "generation: instanceId alone changes the stable binding digest"
         (not= (get desc-i1 "bindingDigest") (get desc-i2 "bindingDigest")))
  (check "generation: instanceId alone changes the descriptor digest"
         (not= (get desc-i1 "descriptorDigest") (get desc-i2 "descriptorDigest")))
  (check "generation: the descriptor binds this boot's exact nonce"
         (= (:instance ctx) (get-in desc-i1 ["coordinator" "instanceId"]))))

;; ===========================================================================
;; TWO-BOOT — G1 acquires, restart as G2 (same log/certs), replay G1's request.
;; The crux: after replay G1's epoch is STILL the live lease, so the epoch fence
;; alone would pass; only the non-restorable generation nonce rejects it.
;; ===========================================================================
(let [log (scratch-log)
      ;; --- boot G1 ---
      co1 (new-database log)
      _   (register-pred! co1 "note" "single" "literal")
      i1  (fresh-instance-id)
      ctx1 (authority-context co1 i1)
      open1 (authority-session-open ctx1 "R" "client-a" spki-a 600000)
      h1 (:handle open1)
      e1 (:epoch h1)
      r1 (authority-session-request ctx1 h1 {:instance i1 :epoch e1 :seq 1}
                                    (commit-action co1 "client-a" "g1-write"))
      ;; --- restart as G2: replay the SAME log; mint a FRESH nonce ---
      co2 {:store (replay log) :log log :lock (Object.)}
      i2  (fresh-instance-id)
      ctx2 (authority-context co2 i2)
      live-e1-after-replay? (fence-ok? co2 "R" "client-a" e1)
      dg-before (log-digest co2)
      ;; replay G1's next record verbatim against G2 (in-order seq, live epoch)
      g1-replay (authority-session-request ctx2 h1 {:instance i1 :epoch e1 :seq 2}
                                           (commit-action co2 "client-a" "replayed"))
      dg-after (log-digest co2)
      ;; --- fresh G2 lease at sequence 1 commits exactly once ---
      open2 (authority-session-open ctx2 "R" "client-a" spki-a 600000)
      h2 (:handle open2)
      e2 (:epoch h2)
      g2-commit (authority-session-request ctx2 h2 {:instance i2 :epoch e2 :seq 1}
                                           (commit-action co2 "client-a" "g2-write"))
      g2-replay (authority-session-request ctx2 h2 {:instance i2 :epoch e2 :seq 1}
                                           (commit-action co2 "client-a" "g2-again"))]
  (check "two-boot: G1 sequence 1 commits under its own boot" (:ok r1))
  (check "two-boot: fresh boot mints a distinct non-restorable nonce" (not= i1 i2))
  (check "two-boot: after replay G1's epoch is STILL the live lease (fence alone would pass)"
         live-e1-after-replay?)
  (check "two-boot: replayed G1 record rejects on GENERATION, not epoch"
         (= :wrong-generation (:reject g1-replay)))
  (check "two-boot: replayed G1 record appended nothing (log head digest unchanged)"
         (= dg-before dg-after))
  (check "two-boot: G2 acquires a strictly newer epoch" (> e2 e1))
  (check "two-boot: fresh G2 lease at sequence 1 commits" (:ok g2-commit))
  (check "two-boot: G2 sequence 1 commits EXACTLY once (replay is out-of-order)"
         (= :out-of-order (:reject g2-replay))))

;; ===========================================================================
;; RENEWAL — within one boot: rotates ONLY epoch/expiry + derived digests; a
;; replay of the pre-renewal epoch is fence-rejected.
;; ===========================================================================
(let [db (new-database (scratch-log))
      _  (register-pred! db "note" "single" "literal")
      i  (fresh-instance-id)
      ctx (authority-context db i)
      open (authority-session-open ctx "R" "client-a" spki-a 600000)
      h1 (:handle open)
      e1 (:epoch h1)
      desc-e1 (seal-coordinator-descriptor ctx h1 endpoint snapshot)
      renewed (authority-session-renew ctx h1 600000)
      h2 (:handle renewed)
      e2 (:epoch h2)
      desc-e2 (seal-coordinator-descriptor ctx h2 endpoint snapshot)
      ;; a first in-boot mutation, then a replay of the OLD (pre-renew) epoch
      ok-seq1 (authority-session-request ctx h2 {:instance i :epoch e2 :seq 1}
                                         (commit-action db "client-a" "post-renew"))
      dg-before (log-digest db)
      stale-epoch (authority-session-request ctx h2 {:instance i :epoch e1 :seq 2}
                                             (commit-action db "client-a" "stale-epoch"))
      dg-after (log-digest db)
      unchanged (fn [k] (= (get desc-e1 k) (get desc-e2 k)))]
  (check "renewal: rotates the epoch upward" (and (:ok renewed) (> e2 e1)))
  (check "renewal: same connection sequence survives renewal (seq 1 commits)" (:ok ok-seq1))
  (check "renewal: changes ONLY epoch+expiry-derived descriptor fields"
         (and (unchanged "runtime") (unchanged "corpus") (unchanged "tools")
              (unchanged "lifecycle") (unchanged "candidateProtocol")
              (= (get-in desc-e1 ["coordinator" "instanceId"])
                 (get-in desc-e2 ["coordinator" "instanceId"]))
              (= (get-in desc-e1 ["coordinator" "endpoint"])
                 (get-in desc-e2 ["coordinator" "endpoint"]))
              (= (get-in desc-e1 ["coordinator" "lease" "id"])
                 (get-in desc-e2 ["coordinator" "lease" "id"]))))
  (check "renewal: epoch/expiry (and their derived digests) DO move"
         (and (not= (get-in desc-e1 ["coordinator" "lease" "epoch"])
                    (get-in desc-e2 ["coordinator" "lease" "epoch"]))
              (not= (get desc-e1 "bindingDigest") (get desc-e2 "bindingDigest"))
              (not= (get desc-e1 "descriptorDigest") (get desc-e2 "descriptorDigest"))))
  (check "replay: a pre-renewal epoch is fence-rejected" (= :fence-lost (:reject stale-epoch)))
  (check "replay: the fence-rejected stale-epoch record appended nothing" (= dg-before dg-after)))

;; ===========================================================================
;; WRONG-PEER — a record whose holder does not hold the live lease is fenced.
;; ===========================================================================
(let [db (new-database (scratch-log))
      _  (register-pred! db "note" "single" "literal")
      i  (fresh-instance-id)
      ctx (authority-context db i)
      open (authority-session-open ctx "R" "client-a" spki-a 600000)
      e1 (:epoch (:handle open))
      forged {:instance i :res "R" :holder "client-b" :client-spki spki-b :epoch e1 :seq (atom 0)}
      dg-before (log-digest db)
      wrong-peer (authority-session-request ctx forged {:instance i :epoch e1 :seq 1}
                                            (commit-action db "client-b" "intruder"))
      dg-after (log-digest db)]
  (check "wrong-peer: a non-holder's fenced record rejects" (= :fence-lost (:reject wrong-peer)))
  (check "wrong-peer: rejected record appended nothing" (= dg-before dg-after)))

;; ===========================================================================
;; SECOND-LEASE — exactly one authority session; a concurrent opener is rejected.
;; ===========================================================================
(let [db (new-database (scratch-log))
      i  (fresh-instance-id)
      ctx (authority-context db i)
      open-a (authority-session-open ctx "R" "client-a" spki-a 600000)
      dg-before (log-digest db)
      open-b (authority-session-open ctx "R" "client-b" spki-b 600000)
      dg-after (log-digest db)]
  (check "second-lease: first opener holds the exclusive session" (:ok open-a))
  (check "second-lease: a concurrent opener is rejected (:held)"
         (and (= :held (:reject open-b)) (= "client-a" (:holder open-b))))
  (check "second-lease: the rejected open appended nothing" (= dg-before dg-after)))

;; ===========================================================================
;; EXPIRY — a lapsed lease fences its own in-flight record; a fresh lease recovers.
;; ===========================================================================
(let [db (new-database (scratch-log))
      _  (register-pred! db "note" "single" "literal")
      i  (fresh-instance-id)
      ctx (authority-context db i)
      open (authority-session-open ctx "R" "client-a" spki-a 1)   ; 1ms ttl
      h1 (:handle open)
      e1 (:epoch h1)
      _ (Thread/sleep 30)
      dg-before (log-digest db)
      expired (authority-session-request ctx h1 {:instance i :epoch e1 :seq 1}
                                         (commit-action db "client-a" "after-expiry"))
      dg-after (log-digest db)
      reopen (authority-session-open ctx "R" "client-a" spki-a 600000)
      h2 (:handle reopen)
      e2 (:epoch h2)
      fresh-commit (authority-session-request ctx h2 {:instance i :epoch e2 :seq 1}
                                              (commit-action db "client-a" "fresh"))]
  (check "expiry: a lapsed lease fences its in-flight record" (= :fence-lost (:reject expired)))
  (check "expiry: the fenced expired record appended nothing" (= dg-before dg-after))
  (check "expiry: a fresh lease takes a strictly newer epoch and commits"
         (and (:ok reopen) (> e2 e1) (:ok fresh-commit))))

;; ===========================================================================
;; TOMBSTONE — release rejects old handles, but permits a fresh lease.
;; ===========================================================================
(let [db (new-database (scratch-log))
      _  (register-pred! db "note" "single" "literal")
      i  (fresh-instance-id)
      ctx (authority-context db i)
      open (authority-session-open ctx "R" "client-a" spki-a 600000)
      h1 (:handle open)
      e1 (:epoch h1)
      released (authority-session-release ctx h1)
      dg-before (log-digest db)
      after-tombstone (authority-session-request ctx h1 {:instance i :epoch e1 :seq 1}
                                                 (commit-action db "client-a" "post-tombstone"))
      dg-after (log-digest db)
      reopen (authority-session-open ctx "R" "client-a" spki-a 600000)
      h2 (:handle reopen)
      e2 (:epoch h2)
      fresh-commit (authority-session-request ctx h2 {:instance i :epoch e2 :seq 1}
                                              (commit-action db "client-a" "fresh"))]
  (check "tombstone: release erases the exact held lease" (:ok released))
  (check "tombstone: an old handle is fence-rejected after release"
         (= :fence-lost (:reject after-tombstone)))
  (check "tombstone: the rejected old-handle record appended nothing" (= dg-before dg-after))
  (check "tombstone: a fresh lease is permitted at a strictly newer epoch"
         (and (:ok reopen) (> e2 e1) (:ok fresh-commit))))

;; ===========================================================================
;; SEQUENCE — out-of-order / duplicate records reject before append.
;; ===========================================================================
(let [db (new-database (scratch-log))
      _  (register-pred! db "note" "single" "literal")
      i  (fresh-instance-id)
      ctx (authority-context db i)
      open (authority-session-open ctx "R" "client-a" spki-a 600000)
      h (:handle open)
      e (:epoch h)
      dg-before-gap (log-digest db)
      gap (authority-session-request ctx h {:instance i :epoch e :seq 2}   ; skips seq 1
                                     (commit-action db "client-a" "gap"))
      dg-after-gap (log-digest db)
      one (authority-session-request ctx h {:instance i :epoch e :seq 1}
                                     (commit-action db "client-a" "one"))
      dup (authority-session-request ctx h {:instance i :epoch e :seq 1}   ; replay of a consumed slot
                                     (commit-action db "client-a" "dup"))
      two (authority-session-request ctx h {:instance i :epoch e :seq 2}
                                     (commit-action db "client-a" "two"))]
  (check "sequence: a gap (out-of-order) record rejects" (= :out-of-order (:reject gap)))
  (check "sequence: the rejected gap record appended nothing" (= dg-before-gap dg-after-gap))
  (check "sequence: exact next sequence commits" (:ok one))
  (check "sequence: a duplicate of a consumed slot rejects (exactly-once)"
         (= :out-of-order (:reject dup)))
  (check "sequence: the following in-order sequence commits" (:ok two)))

;; ===========================================================================
;; CONNECTION DISPATCH — only :authority-open enters the multi-request loop;
;; legacy one-request ops never do.
;; ===========================================================================
(check "dispatch: legacy ops are not authority-open"
       (not (some authority-open-request?
                  [{:op :assert} {:op :version} {:op :status} {:op :edit-prepare}
                   {:op :acquire-lease} {:op :subscribe} {:op :for-log}])))
(check "dispatch: only :authority-open enters the loop"
       (authority-open-request? {:op :authority-open}))

(let [db (new-database (scratch-log))
      _  (register-pred! db "note" "single" "literal")
      ctx (authority-context db (fresh-instance-id))
      i (:instance ctx)
      make-action (fn [req] (commit-action db "client-a" (get-in req [:body :value])))]
  ;; drive run-authority-connection with an in-memory reader whose later records are
  ;; filled in from the epoch the open handshake returns (the wire discovers it too).
  (let [state (atom {:queue [{:op :authority-open :res "R" :holder "client-a"
                              :client-spki spki-a :ttl-ms 600000}]
                     :queued false})
        read-req (fn [] (let [{:keys [queue]} @state]
                          (when-let [nxt (first queue)]
                            (swap! state update :queue rest) nxt)))
        resp (atom [])
        wr (fn [r]
             (swap! resp conj r)
             (when (and (:epoch r) (not (:queued @state)))
               (let [e (:epoch r)]
                 (swap! state assoc :queued true)
                 (swap! state update :queue concat
                        [{:op :authority-request :instance i :epoch e :seq 1 :body {:value "loop-1"}}
                         {:op :authority-request :instance i :epoch e :seq 2 :body {:value "loop-2"}}
                         {:op :authority-release}]))))]
    (run-authority-connection ctx read-req wr make-action)
    (let [rs @resp]
      (check "loop: open handshake acks with instance + epoch"
             (and (:ok (first rs)) (= i (:instance (first rs))) (some? (:epoch (first rs)))))
      (check "loop: processes MULTIPLE requests on one connection"
             (= 2 (count (filter #(and (:ok %) (:seq %)) rs))))
      (check "loop: the two mutations commit at sequences 1 and 2"
             (= [1 2] (mapv :seq (filter #(and (:ok %) (:seq %)) rs))))))
  ;; a connection whose first record is NOT authority-open is refused (legacy stays one-shot).
  (let [rs (atom [])
        q (atom [{:op :assert :te "@x" :p "p" :r "v"}])
        read-req (fn [] (let [n (first @q)] (swap! q rest) n))]
    (run-authority-connection ctx read-req #(swap! rs conj %) (fn [_] (fn [] {:ok 0})))
    (check "loop: a non-authority-open first record is refused"
           (= :not-authority-open (:reject (first @rs))))))

(println (str "\ndatabase-authority: " @pass " / " (+ @pass @fail) " PASS"))
(when (pos? @fail) (System/exit 1))
