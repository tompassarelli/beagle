;; ============================================================================
;; code_rename_spelling_check.clj — minimal decisive CORE rename check (fast, no Beagle,
;; no re-materialize). The human identifier lives as the `v` SPELLING of symbol leaves.
;; References resolve BY SPELLING on cold re-derive (refers_to is derived, 0-persisted).
;; So: after a CORE do-edit-min rename replace!->supersede-prior!, do reference leaves
;; still spell "replace!"? If yes, a cold render re-derives by spelling, can't match the
;; renamed def, and shows "replace!" => the exact FAIL, and it is a CORE bug.
;;   bb -cp out code_rename_spelling_check.clj
;; ============================================================================
(require '[fram.store :as c] '[fram.schema :as s] '[clojure.java.io :as io])
(def root (System/getProperty "user.dir"))
(def code-log (str root "/.fram/code.log"))
(when-not (.exists (io/file code-log)) (println "SKIP — no code.log") (System/exit 0))
(binding [*command-line-args* []] (load-file "server.clj"))
(def flat (str (System/getProperty "java.io.tmpdir") "/rename-spell-" (System/nanoTime) ".code.log"))
(io/copy (io/file code-log) (io/file flat))
(boot-flat! flat)
(def st (:store @db))
(def Vp (c/value-id st "v"))
(defn spell-count [s] (count (filter (fn [cid] (= s (c/literal st (:r (c/fact-of st cid))))) (c/by-p st Vp))))

(println "BEFORE rename:  v=\"replace!\" leaves =" (spell-count "replace!")
         " | v=\"supersede-prior!\" leaves =" (spell-count "supersede-prior!"))
(def resp (do-edit-min {:op "rename" :module "schema" :old "replace!" :new "supersede-prior!"}))
(println "CORE do-edit-min rename:" (pr-str (select-keys resp [:ok :ops :asserts :retracts])))
(def after-old (spell-count "replace!"))
(def after-new (spell-count "supersede-prior!"))
(println "AFTER rename:   v=\"replace!\" leaves =" after-old
         " | v=\"supersede-prior!\" leaves =" after-new)

(println "\n================ CORE RENAME VERDICT (spelling) ================")
(println "  committed:" (boolean (:ok resp)) (str "(" (:ops resp) " ops)"))
(if (pos? after-old)
  (println (format ">>> CORE RED — %d reference leaf/leaves still spelled \"replace!\" after rename.\n    A cold render re-derives refers_to BY SPELLING; \"replace!\" can't match the renamed def\n    \"supersede-prior!\" => renders the old spelling => the exact FAIL. CORE bug (rename relies on\n    identity-refs, but mainline is spelling+derive). FIX before any S3 commit; do NOT split."
                   after-old))
  (println ">>> CORE GREEN — 0 leaves still spelled \"replace!\"; rename rewrote all spellings, so cold\n    re-derive resolves. The earlier FAIL is socket/CLI-specific => SPLIT (bank core, leave socket/#14)."))
(System/exit 0)
